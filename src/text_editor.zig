const std = @import("std");
const dvui = @import("dvui");
const history_module = @import("text_history.zig");
const History = history_module.History;
const Snapshot = history_module.Snapshot;
const user_text = @import("user_text.zig");

pub fn draw(editor: *dvui.TextEntryWidget) void {
    editor.drawBeforeText();
    if (dvui.accesskit_enabled) dvui.currentWindow().accesskit.text_run_parent = editor.data().id;
    const opts = editor.data().options.strip();
    user_text.addText(&editor.textLayout, editor.textGet(), opts);
    editor.textLayout.addTextDone(opts);
    if (editor.len == 0) drawPlaceholder(editor, opts);
    editor.drawAfterText();
}

fn drawPlaceholder(editor: *dvui.TextEntryWidget, opts: dvui.Options) void {
    const placeholder = editor.init_opts.placeholder orelse return;
    if (editor.data().accesskit_node()) |node| {
        dvui.AccessKit.nodeSetPlaceholderWithLength(node, placeholder.ptr, placeholder.len);
    }

    // Placeholder text is decoration, not editable content. Sharing the editor's
    // layout makes a click position the caret within the hint for one frame,
    // before TextEntry clamps the byte offset back to zero.
    if (dvui.accesskit_enabled) dvui.currentWindow().accesskit.text_run_parent = null;
    // Bound the overlay, but let the text layout finish wrapped runs even when
    // their last lines are clipped by a very narrow editor.
    var overlay = dvui.overlay(@src(), .{
        .rect = editor.textLayout.data().contentRect().justSize(),
        .role = .none,
    });
    defer overlay.deinit();
    var hint: dvui.TextLayoutWidget = undefined;
    hint.init(@src(), .{
        .break_lines = editor.init_opts.break_lines,
        .focused = false,
        .process_events_in_deinit = false,
    }, opts.override(.{
        .expand = .both,
        .color_text = editor.textLayout.data().options.color(.text).opacity(0.65),
        .role = .none,
    }));
    defer hint.deinit();
    user_text.addText(&hint, placeholder, .{});
}

pub const Result = struct {
    submit: bool = false,
    history_failed: bool = false,
};

/// Process edits and shortcuts in event order. In particular, text followed by
/// undo or submit within one frame must not be reordered by a shortcut prepass.
pub fn process(editor: *dvui.TextEntryWidget, history: *History, submit_shortcut: bool) Result {
    var result: Result = .{};
    for (dvui.events()) |*event| {
        if (!editor.matchEvent(event)) continue;
        processEvent(editor, history, event, submit_shortcut, &result) catch {
            const composing = history.composing;
            history.clear();
            history.composing = composing;
            result.history_failed = true;
        };
    }
    // Losing focus cancels preedit rather than saving an uncommitted IME string.
    if (dvui.focusedWidgetId() != editor.data().id) {
        history.breakGroup();
        if (history.composing) {
            if (history.composition) |initial| restore(editor, initial);
            history.cancelComposition(editor.text);
        }
    }
    return result;
}

fn processEvent(editor: *dvui.TextEntryWidget, history: *History, event: *dvui.Event, submit_shortcut: bool, result: *Result) !void {
    if (event.evt == .key) {
        const key = event.evt.key;
        if ((key.action == .down or key.action == .repeat) and key.mod.matchBind("ctrl/cmd") and !key.mod.alt()) {
            if ((key.code == .z or (key.code == .y and !key.mod.shift())) and !history.composing) {
                event.handle(@src(), editor.data());
                const restored = if (key.code == .y or key.mod.shift()) history.redo() else history.undo();
                if (restored) |value| restore(editor, value);
                return;
            }
            if (submit_shortcut and key.code == .enter) {
                event.handle(@src(), editor.data());
                if (key.action == .down and !history.composing) result.submit = true;
                history.breakGroup();
                return;
            }
        }
    }

    var text_before: [16 * 1024]u8 = undefined;
    const text = editor.textGet();
    std.debug.assert(text.len <= text_before.len);
    @memcpy(text_before[0..text.len], text);
    const before = snapshot(editor, text_before[0..text.len]);
    const allocator = dvui.currentWindow().gpa;
    const time = dvui.frameTimeNS();
    var is_text_value = false;
    var cancel_preedit = false;
    var preedit = false;
    var kind: history_module.Kind = .isolated;
    switch (event.evt) {
        .text => |value| switch (value.action) {
            .value => |value_text| {
                is_text_value = true;
                const value_string = std.mem.sliceTo(value_text.txt, 0);
                preedit = value_text.selected and value_string.len > 0;
                cancel_preedit = value_text.selected and value_string.len == 0;
                if (std.mem.findScalar(u8, value_string, '\n') == null) kind = .typing;
            },
            .selection => {},
        },
        .key => |key| {
            if (key.action != .up and key.mod == .none) {
                kind = switch (key.code) {
                    .backspace => .backspace,
                    .delete => .delete,
                    else => .isolated,
                };
            }
        },
        else => {},
    }
    if (before.selection.start != before.selection.end) kind = .isolated;
    // Capture the selection replaced by IME before DVUI inserts its preedit.
    if (preedit and !history.composing) {
        history.beginComposition(allocator, before) catch |err| {
            // Allocation failure may disable undo, but must not swallow input.
            editor.processEvent(event);
            history.composing = true;
            return err;
        };
    }
    editor.processEvent(event);
    const after = snapshot(editor, editor.textGet());
    if (history.composing) {
        if (cancel_preedit) {
            if (history.composition) |initial| restore(editor, initial);
            history.cancelComposition(editor.text);
            return;
        }
        if (is_text_value and !preedit) try history.finishComposition(allocator, after, time);
        return;
    }
    try history.record(allocator, before, after, kind, time);
    // Caret moves and mouse clicks delimit typing groups; key-up/motion do not.
    if (std.mem.eql(u8, before.text, after.text)) {
        switch (event.evt) {
            .key => |key| if (key.action != .up and (key.mod.control() or key.mod.command() or key.mod.alt())) {
                history.breakGroup();
            },
            .mouse => |mouse| if (mouse.action == .press) {
                history.breakGroup();
            },
            else => {},
        }
    }
}

fn snapshot(editor: *dvui.TextEntryWidget, text: []const u8) Snapshot {
    const selection = editor.textLayout.selectionGet(editor.len);
    return .{
        .text = text,
        .selection = .{
            .start = selection.start,
            .end = selection.end,
            .cursor = selection.cursor,
            .before = selection.affinity == .before,
        },
    };
}

fn restore(editor: *dvui.TextEntryWidget, value: Snapshot) void {
    editor.textSet(value.text, false);
    editor.textLayout.selection.* = .{
        .start = value.selection.start,
        .end = value.selection.end,
        .cursor = value.selection.cursor,
        .affinity = if (value.selection.before) .before else .after,
    };
    editor.textLayout.sel_move = .none;
    editor.textLayout.scroll_to_cursor = true;
    editor.textLayout.scroll_to_cursor_next_frame = true;
    dvui.refresh(null, @src(), editor.data().id);
}

const Harness = struct {
    var buffers: [2][16 * 1024]u8 = @splat(@splat(0));
    var histories: [2]History = @splat(.{});
    var selections: [2]history_module.Selection = @splat(.{});
    var focus: ?usize = 0;
    var submissions: usize = 0;

    fn reset() void {
        for (&histories) |*item| item.clear();
        buffers = @splat(@splat(0));
        focus = 0;
        submissions = 0;
    }

    fn frame() !dvui.App.Result {
        for (&buffers, &histories, 0..) |*buffer, *history, i| {
            var editor: dvui.TextEntryWidget = undefined;
            editor.init(@src(), .{ .text = .{ .buffer = buffer }, .multiline = true }, .{
                .id_extra = i,
                .tag = if (i == 0) "first" else "second",
                .min_size_content = .{ .w = 300, .h = 80 },
            });
            if (focus == i) {
                dvui.focusWidget(editor.data().id, null, null);
                focus = null;
            }
            const result = process(&editor, history, true);
            if (result.history_failed) return error.HistoryFailed;
            if (result.submit) submissions += 1;
            editor.draw();
            selections[i] = snapshot(&editor, editor.textGet()).selection;
            editor.deinit();
        }
        return .ok;
    }

    fn text(i: usize) []const u8 {
        return std.mem.sliceTo(&buffers[i], 0);
    }

    fn key(code: dvui.enums.Key, mod: dvui.enums.Mod) !void {
        try dvui.testing.pressKey(code, mod);
        try dvui.testing.settle(frame);
    }

    fn typeText(value: []const u8) !void {
        try dvui.testing.writeText(value);
        try dvui.testing.settle(frame);
    }
};

test "actual editor events undo replace cut paste and restore UTF-8 selection" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    Harness.reset();
    defer Harness.reset();
    try dvui.testing.settle(Harness.frame);
    const original = "中文 ✅\n\nEnglish C:\\Work\\notes.txt";
    try Harness.typeText(original);
    try Harness.key(.a, .lcontrol);
    try Harness.typeText("replacement");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings(original, Harness.text(0));
    try std.testing.expectEqual(@as(usize, 0), Harness.selections[0].start);
    try std.testing.expectEqual(original.len, Harness.selections[0].end);
    try Harness.key(.y, .lcontrol);
    try std.testing.expectEqualStrings("replacement", Harness.text(0));
    try Harness.key(.z, .lcontrol);
    var shifted: dvui.enums.Mod = .lcontrol;
    shifted.combine(.lshift);
    try Harness.key(.z, shifted);
    try std.testing.expectEqualStrings("replacement", Harness.text(0));
    try Harness.key(.a, .lcontrol);
    try Harness.key(.x, .lcontrol);
    try std.testing.expectEqualStrings("", Harness.text(0));
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("replacement", Harness.text(0));
    dvui.clipboardTextSet(original);
    try Harness.key(.v, .lcontrol);
    try std.testing.expectEqualStrings(original, Harness.text(0));
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("replacement", Harness.text(0));
    try Harness.typeText("new branch");
    try Harness.key(.y, .lcontrol);
    try std.testing.expectEqualStrings("new branch", Harness.text(0));
}

test "typing groups survive keydown events and undo follows event order and focus" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    Harness.reset();
    defer Harness.reset();
    try dvui.testing.settle(Harness.frame);
    try dvui.testing.pressKey(.a, .none);
    try dvui.testing.writeText("a");
    try dvui.testing.pressKey(.b, .none);
    try dvui.testing.writeText("b");
    try dvui.testing.pressKey(.z, .lcontrol);
    try dvui.testing.settle(Harness.frame);
    try std.testing.expectEqualStrings("", Harness.text(0));
    try Harness.key(.y, .lcontrol);
    try std.testing.expectEqualStrings("ab", Harness.text(0));
    Harness.focus = 1;
    try dvui.testing.settle(Harness.frame);
    try Harness.typeText("second");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("", Harness.text(1));
    try std.testing.expectEqualStrings("ab", Harness.text(0));
    Harness.focus = 0;
    try dvui.testing.settle(Harness.frame);
    try Harness.key(.backspace, .none);
    try std.testing.expectEqualStrings("a", Harness.text(0));
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("ab", Harness.text(0));
    try Harness.key(.home, .none);
    try Harness.key(.delete, .none);
    try std.testing.expectEqualStrings("b", Harness.text(0));
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("ab", Harness.text(0));
}

test "IME commits undo as one operation and submit does not consume preedit" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    Harness.reset();
    defer Harness.reset();
    try dvui.testing.settle(Harness.frame);
    try Harness.typeText("prefix ");
    _ = try t.window.addEventText(.{ .text = "zhong", .selected = true });
    try dvui.testing.settle(Harness.frame);
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("prefix zhong", Harness.text(0));
    try Harness.key(.enter, .lcontrol);
    try std.testing.expectEqual(@as(usize, 0), Harness.submissions);
    _ = try t.window.addEventText(.{ .text = "中文", .selected = true });
    try dvui.testing.settle(Harness.frame);
    try Harness.typeText("中文");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("prefix ", Harness.text(0));
    try Harness.key(.y, .lcontrol);
    try std.testing.expectEqualStrings("prefix 中文", Harness.text(0));
    _ = try t.window.addEventKey(.{ .code = .enter, .mod = .lcontrol, .action = .down });
    _ = try t.window.addEventKey(.{ .code = .enter, .mod = .lcontrol, .action = .repeat });
    try dvui.testing.settle(Harness.frame);
    try std.testing.expectEqual(@as(usize, 1), Harness.submissions);
    try std.testing.expectEqualStrings("prefix 中文", Harness.text(0));
    _ = try t.window.addEventText(.{ .text = "cancel", .selected = true });
    try dvui.testing.settle(Harness.frame);
    Harness.focus = 1;
    try dvui.testing.settle(Harness.frame);
    try std.testing.expectEqualStrings("prefix 中文", Harness.text(0));
    try std.testing.expect(!Harness.histories[0].composing);
    Harness.focus = 0;
    try dvui.testing.settle(Harness.frame);
    try Harness.key(.a, .lcontrol);
    _ = try t.window.addEventText(.{ .text = "replace selection", .selected = true });
    try dvui.testing.settle(Harness.frame);
    _ = try t.window.addEventText(.{ .text = "", .selected = true });
    try dvui.testing.settle(Harness.frame);
    try std.testing.expectEqualStrings("prefix 中文", Harness.text(0));
    try std.testing.expectEqual(@as(usize, 0), Harness.selections[0].start);
    try std.testing.expectEqual("prefix 中文".len, Harness.selections[0].end);
}
