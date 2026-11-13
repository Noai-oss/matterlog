const std = @import("std");
const dvui = @import("dvui");
const state = @import("app_state.zig");
const ui = @import("ui.zig");

fn expectClipboard(expected: []const u8) !void {
    // SDL uses native Windows CRLF on the system clipboard. The testing
    // backend keeps LF; neither form may add/remove any other characters.
    const actual = dvui.clipboardText();
    var normalized: std.ArrayList(u8) = .empty;
    defer normalized.deinit(std.testing.allocator);
    for (actual, 0..) |byte, i| {
        if (byte == '\r' and i + 1 < actual.len and actual[i + 1] == '\n') continue;
        try normalized.append(std.testing.allocator, byte);
    }
    try std.testing.expectEqualStrings(expected, normalized.items);
}

fn bodyHasSelection(tag: []const u8) !bool {
    const id = (try dvui.testing.tagGet(tag)).id;
    // Observe DVUI's actual persisted selection, not an application mirror.
    const selection = dvui.dataGet(null, id, "_selection", dvui.TextLayoutWidget.Selection) orelse return error.SelectionNotFound;
    return selection.start != selection.end;
}

const Harness = struct {
    var app: state.AppState = .{};

    fn frame() !dvui.App.Result {
        ui.draw(&app);
        if (app.processPendingAction(std.testing.allocator)) dvui.refresh(null, @src(), null);
        return .ok;
    }

    fn click(tag: []const u8) !void {
        try dvui.testing.moveTo(tag);
        try dvui.testing.click(.left);
        try dvui.testing.settle(frame);
    }

    fn typeText(text: []const u8) !void {
        try dvui.testing.writeText(text);
        try dvui.testing.settle(frame);
    }

    fn key(code: dvui.enums.Key, mod: dvui.enums.Mod) !void {
        try dvui.testing.pressKey(code, mod);
        try dvui.testing.settle(frame);
    }

    fn draftText() []const u8 {
        return std.mem.sliceTo(&app.draft().buffer, 0);
    }

    fn entryTag(comptime prefix: []const u8, index: usize) ![]const u8 {
        return std.fmt.allocPrint(dvui.currentWindow().arena(), prefix ++ "-{d}", .{app.selectedTask().?.entries.items[index].id});
    }

    fn checkZoomKeys() !void {
        const focus = dvui.focusedWidgetId();
        const win = dvui.currentWindow();
        try key(.equal, .lcontrol);
        try std.testing.expectApproxEqAbs(@as(f32, 1.1), win.content_scale, 0.001);
        try key(.kp_add, .lcontrol);
        try std.testing.expectApproxEqAbs(@as(f32, 1.2), win.content_scale, 0.001);
        try key(.minus, .lcontrol);
        try key(.kp_subtract, .lcontrol);
        try std.testing.expectEqual(@as(f32, 1), win.content_scale);
        var ctrl_shift: dvui.enums.Mod = .lcontrol;
        ctrl_shift.combine(.lshift);
        try key(.equal, ctrl_shift);
        try std.testing.expectApproxEqAbs(@as(f32, 1.1), win.content_scale, 0.001);
        try key(.zero, .lcontrol);
        var altgr: dvui.enums.Mod = .lcontrol;
        altgr.combine(.lalt);
        try key(.equal, altgr);
        try std.testing.expectEqual(@as(f32, 1), win.content_scale);
        for (0..20) |_| _ = try win.addEventKey(.{ .code = .kp_add, .mod = .lcontrol, .action = .repeat });
        try dvui.testing.settle(frame);
        try key(.equal, .lcontrol);
        try std.testing.expectEqual(@as(f32, 1.5), win.content_scale);
        for (0..20) |_| _ = try win.addEventKey(.{ .code = .minus, .mod = .lcontrol, .action = .repeat });
        try dvui.testing.settle(frame);
        try std.testing.expectApproxEqAbs(@as(f32, 0.8), win.content_scale, 0.001);
        try key(.kp_0, .lcontrol);
        try std.testing.expectEqual(@as(f32, 1), win.content_scale);
        try std.testing.expectEqual(focus, dvui.focusedWidgetId());
    }
};

test "empty editor caret starts at the origin on the very first click frame" {
    const Editor = struct {
        var buffer: [1024]u8 = @splat(0);
        var history: @import("text_history.zig").History = .{};
        var cursor: dvui.Rect = .{};
        var selection: dvui.TextLayoutWidget.Selection = .{};
        var multiline = false;

        fn frame() !dvui.App.Result {
            var editor: dvui.TextEntryWidget = undefined;
            editor.init(@src(), .{
                .text = .{ .buffer = &buffer },
                .multiline = multiline,
                .break_lines = multiline,
                .placeholder = "输入当前事项的最新进展……",
            }, .{ .rect = .{ .x = 20, .y = 20, .w = 170, .h = 100 }, .tag = "empty-editor" });
            defer editor.deinit();
            _ = @import("text_editor.zig").process(&editor, &history, false);
            @import("text_editor.zig").draw(&editor);
            cursor = editor.textLayout.cursor_rect;
            selection = editor.textLayout.selection.*;
            return .ok;
        }

        fn expectOrigin() !void {
            try std.testing.expectEqual(@as(f32, 0), cursor.x);
            try std.testing.expectEqual(@as(f32, 0), cursor.y);
            try std.testing.expectEqual(@as(usize, 0), selection.cursor);
            try std.testing.expect(selection.empty());
            try std.testing.expectEqualStrings("", std.mem.sliceTo(&buffer, 0));
        }
    };

    for ([_]bool{ false, true }) |multiline| {
        var t = try dvui.testing.init(.{});
        defer t.deinit();
        @import("theme.zig").apply(t.window);
        Editor.buffer = @splat(0);
        Editor.history = .{};
        defer Editor.history.clear();
        Editor.multiline = multiline;
        try dvui.testing.settle(Editor.frame);
        const rect = (try dvui.testing.tagGet("empty-editor")).rect;
        // Click inside the placeholder, then below it. Check immediately:
        // settling first would hide the one-frame jump reported by users.
        for ([_]f32{ 12, 65 }) |y| {
            dvui.focusWidget(null, null, null);
            try dvui.testing.settle(Editor.frame);
            _ = try t.window.addEventMouseMotion(.{ .pt = .{
                .x = rect.x + 140 * t.window.natural_scale,
                .y = rect.y + y * t.window.natural_scale,
            } });
            _ = try t.window.addEventMouseButton(.left, .press);
            _ = try dvui.testing.step(Editor.frame);
            try Editor.expectOrigin();
            _ = try t.window.addEventMouseButton(.left, .release);
            _ = try dvui.testing.step(Editor.frame);
            try Editor.expectOrigin();
        }
        try dvui.testing.pressKey(.a, .lcontrol);
        _ = try dvui.testing.step(Editor.frame);
        try Editor.expectOrigin();
        try dvui.testing.writeText("在");
        try dvui.testing.settle(Editor.frame);
        try std.testing.expectEqualStrings("在", std.mem.sliceTo(&Editor.buffer, 0));
        try dvui.testing.pressKey(.z, .lcontrol);
        _ = try dvui.testing.step(Editor.frame);
        try Editor.expectOrigin();
        try dvui.testing.pressKey(.y, .lcontrol);
        try dvui.testing.settle(Editor.frame);
        try std.testing.expectEqualStrings("在", std.mem.sliceTo(&Editor.buffer, 0));
    }
}

test "zoom shortcuts work with each editor focused without changing text selection or undo" {
    // Enable DVUI's fallback as well: handled keys must never scale twice.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1100, .h = 760 }, .window_init_opts = .{ .keybinds_zoom = true } });
    defer t.deinit();
    @import("theme.zig").apply(t.window);
    try Harness.app.init(std.testing.allocator, ":memory:");
    defer Harness.app.deinit(std.testing.allocator);
    try dvui.testing.settle(Harness.frame);
    try Harness.checkZoomKeys();
    try Harness.click("new-task");
    try Harness.typeText("缩放测试");
    try Harness.checkZoomKeys();
    try std.testing.expectEqualStrings("缩放测试", std.mem.sliceTo(&Harness.app.rename_buffer, 0));
    try Harness.key(.enter, .none);
    try Harness.click("composer");
    const text = "中文 + = - 0\n第二行 ✅";
    try Harness.typeText(text);
    try Harness.key(.a, .lcontrol);
    try Harness.checkZoomKeys();
    try Harness.key(.c, .lcontrol);
    try expectClipboard(text);
    try std.testing.expectEqualStrings(text, Harness.draftText());
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("", Harness.draftText());
    try Harness.key(.y, .lcontrol);
    try Harness.key(.enter, .lcontrol);
    try Harness.click(try Harness.entryTag("edit-entry", 0));
    try Harness.key(.a, .lcontrol);
    try Harness.checkZoomKeys();
    try Harness.key(.c, .lcontrol);
    try expectClipboard(text);
    try Harness.typeText("已编辑");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings(text, std.mem.sliceTo(&Harness.app.edit_buffer, 0));
    try Harness.key(.escape, .none);
    try std.testing.expectEqualStrings(text, Harness.app.selectedTask().?.entries.items[0].body);

    try Harness.click("zoom-in");
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), t.window.content_scale, 0.001);
    try Harness.click("zoom-reset");
    try std.testing.expectEqual(@as(f32, 1), t.window.content_scale);
    try Harness.click("zoom-out");
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), t.window.content_scale, 0.001);

    try Harness.click("composer");
    try Harness.typeText("前缀 ");
    _ = try t.window.addEventText(.{ .text = "zhong", .selected = true });
    try dvui.testing.settle(Harness.frame);
    try Harness.key(.equal, .lcontrol);
    try std.testing.expect(Harness.app.draft().history.composing);
    try std.testing.expectEqualStrings("前缀 zhong", Harness.draftText());
    try Harness.typeText("中文");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("前缀 ", Harness.draftText());
}

test "SDL keyboard mapping reaches global zoom while typing" {
    if (comptime !@import("test_options").snapshots) return error.SkipZigTest;
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1100, .h = 760 } });
    defer t.deinit();
    @import("theme.zig").apply(t.window);
    try Harness.app.init(std.testing.allocator, ":memory:");
    defer Harness.app.deinit(std.testing.allocator);
    try dvui.testing.settle(Harness.frame);
    try Harness.click("new-task");
    try Harness.key(.enter, .none);
    try Harness.click("composer");
    try Harness.typeText("原文保持不变");
    const c = dvui.backend.c;
    for ([_]c.SDL_Keycode{ c.SDLK_EQUALS, c.SDLK_KP_PLUS, c.SDLK_MINUS, c.SDLK_KP_MINUS, c.SDLK_0 }, [_]u16{ 110, 120, 110, 100, 100 }) |code, expected| {
        var event = std.mem.zeroes(c.SDL_Event);
        event.key.type = c.SDL_EVENT_KEY_DOWN;
        event.key.key = code;
        event.key.mod = c.SDL_KMOD_LCTRL;
        _ = try t.backend.addEvent(t.window, event);
        event.key.type = c.SDL_EVENT_KEY_UP;
        _ = try t.backend.addEvent(t.window, event);
        try dvui.testing.settle(Harness.frame);
        try std.testing.expectEqual(expected, Harness.app.zoom_percent);
        try std.testing.expectEqualStrings("原文保持不变", Harness.draftText());
    }
}

test "zoom keeps composer and saved entry actions reachable in a small window" {
    var t = try dvui.testing.init(.{
        .window_size = .{ .w = 760, .h = 520 },
        .image_dir = if (@import("test_options").snapshots) "release/ui-preview" else null,
    });
    defer t.deinit();
    @import("theme.zig").apply(t.window);
    try Harness.app.init(std.testing.allocator, ":memory:");
    defer Harness.app.deinit(std.testing.allocator);
    try dvui.testing.settle(Harness.frame);
    try Harness.click("new-task");
    try Harness.typeText("缩放后的长文编辑");
    try Harness.key(.enter, .none);
    try Harness.click("composer");
    try Harness.typeText("中文进展第一行，检查不同缩放比例下的换行和按钮。\n第二行\n第三行\n第四行\n第五行\n第六行\n第七行\n第八行\n第九行\n第十行");
    try Harness.key(.enter, .lcontrol);
    try Harness.click(try Harness.entryTag("edit-entry", 0));
    for ([_]u16{ 80, 90, 100, 110, 120, 130, 140, 150 }) |percent| {
        Harness.app.zoom_percent = percent;
        try dvui.testing.settle(Harness.frame);
        for ([_][]const u8{ "composer", "send-entry", "save-entry", "zoom-reset" }) |tag| {
            const data = try dvui.testing.tagGet(tag);
            try std.testing.expect(data.visible);
            try std.testing.expect(data.rect.x >= 0 and data.rect.y >= 0);
            try std.testing.expect(data.rect.x + data.rect.w <= t.window.rect_pixels.w + 1);
            try std.testing.expect(data.rect.y + data.rect.h <= t.window.rect_pixels.h + 1);
        }
        for ([_][]const u8{ "filter-active", "filter-completed", "filter-all" }, [_][]const u8{ "进行中", "已完成", "全部" }) |tag, label| {
            const data = try dvui.testing.tagGet(tag);
            const width = (dvui.Font.theme(.body).textSize(label).w + 16) * t.window.natural_scale;
            try std.testing.expect(data.rect.w + 1 >= width);
        }
        if (percent == 110) try t.saveImage(Harness.frame, null, "zoom-small-110.png");
    }
    try t.saveImage(Harness.frame, null, "zoom-small-150.png");
    try Harness.click("save-entry");
    try std.testing.expect(!Harness.app.hasActiveMode());
}

test "persisted zoom is the user factor and reset preserves system DPI" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1100, .h = 760 } });
    defer t.deinit();
    @import("theme.zig").apply(t.window);
    try Harness.app.init(std.testing.allocator, ":memory:");
    defer Harness.app.deinit(std.testing.allocator);
    try dvui.testing.settle(Harness.frame);
    const system_scale = t.window.natural_scale;
    Harness.app.zoom_percent = 150;
    try dvui.testing.settle(Harness.frame);
    try std.testing.expectEqual(@as(?i64, 150), try Harness.app.store.?.loadZoomPercent());
    try std.testing.expectApproxEqAbs(system_scale * 1.5, t.window.natural_scale, 0.02);
    try Harness.key(.zero, .lcontrol);
    try std.testing.expectEqual(@as(?i64, 100), try Harness.app.store.?.loadZoomPercent());
    try std.testing.expectApproxEqAbs(system_scale, t.window.natural_scale, 0.02);
}

test "full UI preserves task draft undo and resets saved and cancelled edit sessions" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1100, .h = 760 } });
    defer t.deinit();
    @import("theme.zig").apply(t.window);
    try Harness.app.init(std.testing.allocator, ":memory:");
    defer Harness.app.deinit(std.testing.allocator);
    try dvui.testing.settle(Harness.frame);
    try Harness.click("new-task");
    try Harness.typeText("Task A");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("新事项", std.mem.sliceTo(&Harness.app.rename_buffer, 0));
    try Harness.key(.y, .lcontrol);
    try Harness.key(.enter, .none);
    try std.testing.expectEqualStrings("Task A", Harness.app.selectedTask().?.title);
    try Harness.click("composer");
    const original = "中文草稿\n\nKeep this text";
    try Harness.typeText(original);
    try Harness.click("new-task");
    try std.testing.expectEqualStrings("", Harness.draftText());
    try Harness.typeText("Task B");
    try Harness.key(.enter, .none);
    try Harness.click("composer");
    try Harness.typeText("B draft");
    try Harness.click("Task A");
    try std.testing.expectEqualStrings(original, Harness.draftText());
    try Harness.click("composer");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("", Harness.draftText());
    try Harness.key(.y, .lcontrol);
    try std.testing.expectEqualStrings(original, Harness.draftText());
    try Harness.key(.enter, .lcontrol);
    try std.testing.expectEqualStrings("", Harness.draftText());
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("", Harness.draftText());
    try std.testing.expectEqual(@as(usize, 1), Harness.app.selectedTask().?.entries.items.len);
    try std.testing.expectEqualStrings(original, Harness.app.selectedTask().?.entries.items[0].body);

    Harness.app.beginEntryEdit(&Harness.app.selectedTask().?.entries.items[0]);
    try dvui.testing.settle(Harness.frame);
    try Harness.key(.a, .lcontrol);
    try Harness.typeText("changed");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings(original, std.mem.sliceTo(&Harness.app.edit_buffer, 0));
    try Harness.key(.y, .lcontrol);
    try Harness.key(.enter, .lcontrol);
    try std.testing.expectEqualStrings("changed", Harness.app.selectedTask().?.entries.items[0].body);
    Harness.app.beginEntryEdit(&Harness.app.selectedTask().?.entries.items[0]);
    try dvui.testing.settle(Harness.frame);
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings("changed", std.mem.sliceTo(&Harness.app.edit_buffer, 0));
    try Harness.typeText(" cancel me");
    try Harness.key(.escape, .none);
    try std.testing.expect(!Harness.app.hasActiveMode());
    try std.testing.expectEqualStrings("changed", Harness.app.selectedTask().?.entries.items[0].body);
    try Harness.click("Task B");
    try std.testing.expectEqualStrings("B draft", Harness.draftText());
}

test "long entry editor grows with wrapped content and keeps save visible in small windows" {
    for ([_]dvui.Size{ .{ .w = 1100, .h = 760 }, .{ .w = 760, .h = 520 } }) |size| {
        var t = try dvui.testing.init(.{ .window_size = size });
        defer t.deinit();
        @import("theme.zig").apply(t.window);
        try Harness.app.init(std.testing.allocator, ":memory:");
        defer Harness.app.deinit(std.testing.allocator);
        try dvui.testing.settle(Harness.frame);
        try Harness.click("new-task");
        try Harness.key(.escape, .none);
        try Harness.click("composer");
        const body = comptime blk: {
            var text: []const u8 = "";
            for (0..60) |_| text = text ++ "Long paragraph that wraps across the available width, keeping every word intact. ";
            break :blk text;
        };
        const saved_body = std.mem.trim(u8, body, " \t\r\n");
        try Harness.typeText(body);
        try Harness.key(.enter, .lcontrol);
        Harness.app.beginEntryEdit(&Harness.app.selectedTask().?.entries.items[0]);
        try dvui.testing.settle(Harness.frame);
        const expanded = (try dvui.testing.tagGet("entry-editor")).rect;
        const timeline = (try dvui.testing.tagGet("timeline")).rect;
        const save = (try dvui.testing.tagGet("save-entry")).rect;
        try std.testing.expect(expanded.h > 92 * t.window.natural_scale);
        try std.testing.expect(save.y >= timeline.y);
        try std.testing.expect(save.y + save.h <= timeline.y + timeline.h);
        try Harness.key(.a, .lcontrol);
        try Harness.typeText("short");
        const compact = (try dvui.testing.tagGet("entry-editor")).rect;
        try std.testing.expect(compact.h < expanded.h);
        try Harness.key(.z, .lcontrol);
        try std.testing.expectEqualStrings(saved_body, std.mem.sliceTo(&Harness.app.edit_buffer, 0));
        try std.testing.expect((try dvui.testing.tagGet("entry-editor")).rect.h > compact.h);
        try Harness.click("save-entry");
        try std.testing.expectEqualStrings(saved_body, Harness.app.selectedTask().?.entries.items[0].body);
    }
}

test "double click selects text and explicit copy preserves the complete record" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 1100, .h = 760 } });
    defer t.deinit();
    @import("theme.zig").apply(t.window);
    try Harness.app.init(std.testing.allocator, ":memory:");
    defer Harness.app.deinit(std.testing.allocator);
    try dvui.testing.settle(Harness.frame);
    try Harness.click("new-task");
    try Harness.key(.escape, .none);
    try Harness.click("composer");
    const body = "alpha beta gamma\n\n中文 ✅ https://example.com/path";
    try Harness.typeText(body);
    try Harness.key(.enter, .lcontrol);
    const rect = (try dvui.testing.tagGet(try Harness.entryTag("entry-body", 0))).rect;
    _ = try t.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + 10, .y = rect.y + 10 } });
    try dvui.testing.click(.left);
    try dvui.testing.settle(Harness.frame);
    try dvui.testing.click(.left);
    try dvui.testing.settle(Harness.frame);
    try std.testing.expect(!Harness.app.hasActiveMode());
    try Harness.key(.c, .lcontrol);
    try std.testing.expectEqualStrings("alpha", dvui.clipboardText());
    try Harness.click(try Harness.entryTag("copy-entry", 0));
    try expectClipboard(body);
    try std.testing.expectEqual(state.Notice.entry_copied, Harness.app.notice);
    try Harness.click(try Harness.entryTag("edit-entry", 0));
    try std.testing.expect(Harness.app.hasActiveMode());
    try std.testing.expectEqualStrings(body, std.mem.sliceTo(&Harness.app.edit_buffer, 0));
}

test "record selection clears on focus changes but survives dragging and copying" {
    var t = try dvui.testing.init(.{
        .window_size = .{ .w = 1100, .h = 760 },
        .image_dir = if (@import("test_options").snapshots) "release/ui-preview" else null,
    });
    defer t.deinit();
    @import("theme.zig").apply(t.window);
    try Harness.app.init(std.testing.allocator, ":memory:");
    defer Harness.app.deinit(std.testing.allocator);
    try dvui.testing.settle(Harness.frame);
    try Harness.click("new-task");
    try Harness.typeText("选区切换检查");
    try Harness.key(.enter, .none);
    const first = "alpha first record\n第一条进展 ✅";
    const second = "beta second record\n第二条进展 🚀";
    for ([_][]const u8{ first, second }) |body| {
        try Harness.click("composer");
        try Harness.typeText(body);
        try Harness.key(.enter, .lcontrol);
    }
    const entries = Harness.app.selectedTask().?.entries.items;
    var first_tag_buffer: [64]u8 = undefined;
    var second_tag_buffer: [64]u8 = undefined;
    const first_tag = try std.fmt.bufPrint(&first_tag_buffer, "entry-body-{d}", .{entries[0].id});
    const second_tag = try std.fmt.bufPrint(&second_tag_buffer, "entry-body-{d}", .{entries[1].id});
    try Harness.click(first_tag);
    try Harness.key(.a, .lcontrol);
    try std.testing.expect(try bodyHasSelection(first_tag));
    try Harness.key(.c, .lcontrol);
    try expectClipboard(first);
    try std.testing.expect(try bodyHasSelection(first_tag));

    // Later-drawn and earlier-drawn records must both lose their old selection.
    try Harness.click(second_tag);
    try Harness.key(.a, .lcontrol);
    try t.saveImage(Harness.frame, null, "record-selection-focused.png");
    try std.testing.expect(!try bodyHasSelection(first_tag));
    try std.testing.expect(try bodyHasSelection(second_tag));
    try Harness.key(.c, .lcontrol);
    try expectClipboard(second);
    try dvui.testing.moveTo(first_tag);
    try dvui.testing.settle(Harness.frame);
    try std.testing.expect(try bodyHasSelection(second_tag));
    try Harness.click(first_tag);
    try std.testing.expect(!try bodyHasSelection(second_tag));
    try Harness.key(.a, .lcontrol);
    try Harness.click("composer");
    try std.testing.expect(!try bodyHasSelection(first_tag));

    // Clicking a card's padding must clear the previous text selection too.
    try Harness.click(first_tag);
    try Harness.key(.a, .lcontrol);
    const second_rect = (try dvui.testing.tagGet(second_tag)).rect;
    const scale = t.window.natural_scale;
    _ = try t.window.addEventMouseMotion(.{ .pt = .{ .x = second_rect.x - 4 * scale, .y = second_rect.y + 10 * scale } });
    try dvui.testing.click(.left);
    try dvui.testing.settle(Harness.frame);
    try std.testing.expect(!try bodyHasSelection(first_tag));

    // Explicit whole-record copy still works and clears the inactive body.
    try Harness.click(first_tag);
    try Harness.key(.a, .lcontrol);
    try Harness.click(try Harness.entryTag("copy-entry", 1));
    try expectClipboard(second);
    try std.testing.expect(!try bodyHasSelection(first_tag));

    // A captured drag can end outside the body without acting like a new click.
    const first_rect = (try dvui.testing.tagGet(first_tag)).rect;
    _ = try t.window.addEventMouseMotion(.{ .pt = .{ .x = first_rect.x + 10 * scale, .y = first_rect.y + 10 * scale } });
    _ = try t.window.addEventMouseButton(.left, .press);
    try dvui.testing.settle(Harness.frame);
    _ = try t.window.addEventMouseMotion(.{ .pt = .{ .x = first_rect.x + 100 * scale, .y = first_rect.y + 10 * scale } });
    try dvui.testing.settle(Harness.frame);
    try std.testing.expect(try bodyHasSelection(first_tag));
    try dvui.testing.moveTo(second_tag);
    try dvui.testing.settle(Harness.frame);
    _ = try t.window.addEventMouseButton(.left, .release);
    try dvui.testing.settle(Harness.frame);
    try std.testing.expect(try bodyHasSelection(first_tag));
    try Harness.click(second_tag);
    try std.testing.expect(!try bodyHasSelection(first_tag));
}

test "embedded emoji fallback and Chinese wrapping preserve original text and selection" {
    var t = try dvui.testing.init(.{
        .window_size = .{ .w = 760, .h = 520 },
        .image_dir = if (@import("test_options").snapshots) "release/ui-preview" else null,
    });
    defer t.deinit();
    const theme = @import("theme.zig");
    const user_text = @import("user_text.zig");
    theme.apply(t.window);
    const fallback = dvui.Font.theme(.body).withFamily(theme.emoji_family);
    for ([_]u21{ '✅', '🙂', '🚀' }) |cp| {
        try std.testing.expect(user_text.hasGlyph(fallback, cp));
    }
    try Harness.app.init(std.testing.allocator, ":memory:");
    defer Harness.app.deinit(std.testing.allocator);
    try dvui.testing.settle(Harness.frame);
    try Harness.click("new-task");
    try Harness.typeText("本周进展 🚀");
    try Harness.key(.enter, .none);
    try Harness.click("composer");
    const body = "7. 这是一段用于检查中文折行的进展记录，序号后面应该继续显示正文，不能在空格处提前折行。继续输入更多中文，检查窄窗口中的自动换行。\n\n完成 ✅  心情 🙂  发布 🚀\nEnglish words and C:\\Work\\notes.txt";
    try Harness.typeText(body);
    try Harness.key(.home, .lcontrol);
    try Harness.key(.end, .lshift);
    try Harness.key(.c, .lcontrol);
    const first_line = dvui.clipboardText();
    try std.testing.expect(std.mem.startsWith(u8, first_line, "7. 这"));
    try std.testing.expect(first_line.len < body.len);
    try Harness.key(.a, .lcontrol);
    try Harness.key(.c, .lcontrol);
    try expectClipboard(body);
    try Harness.typeText("替换");
    try Harness.key(.z, .lcontrol);
    try std.testing.expectEqualStrings(body, Harness.draftText());
    try Harness.key(.enter, .lcontrol);
    try t.saveImage(Harness.frame, null, "unicode-record.png");
    try Harness.click(try Harness.entryTag("entry-body", 0));
    try Harness.key(.a, .lcontrol);
    try Harness.key(.c, .lcontrol);
    try expectClipboard(body);
    try Harness.click(try Harness.entryTag("edit-entry", 0));
    try Harness.key(.a, .lcontrol);
    try Harness.key(.c, .lcontrol);
    try expectClipboard(body);
    try Harness.key(.right, .none);
    try t.saveImage(Harness.frame, null, "unicode-editor.png");
    try Harness.click("save-entry");
    try std.testing.expectEqualStrings(body, Harness.app.selectedTask().?.entries.items[0].body);
}

test "hints and feedback stay outside the composer at supported window sizes" {
    for ([_]dvui.Size{ .{ .w = 760, .h = 520 }, .{ .w = 1100, .h = 760 } }) |size| {
        for ([_]bool{ false, true }) |dark| {
            var t = try dvui.testing.init(.{
                .window_size = size,
                .window_init_opts = .{ .color_scheme = if (dark) .dark else .light },
                .image_dir = if (@import("test_options").snapshots) "release/ui-preview" else null,
            });
            defer t.deinit();
            @import("theme.zig").apply(t.window);
            try Harness.app.init(std.testing.allocator, ":memory:");
            defer Harness.app.deinit(std.testing.allocator);
            try dvui.testing.settle(Harness.frame);
            try Harness.click("new-task");
            try Harness.typeText("桌面工具体验改进");
            try Harness.key(.enter, .none);
            try Harness.click("composer");
            try Harness.key(.enter, .lcontrol);
            try std.testing.expectEqual(state.Notice.empty_entry, Harness.app.notice);
            const hint = (try dvui.testing.tagGet("composer-hint")).rect;
            const editor = (try dvui.testing.tagGet("composer")).rect;
            const notice = (try dvui.testing.tagGet("notice")).rect;
            const send = (try dvui.testing.tagGet("send-entry")).rect;
            try std.testing.expect(hint.h > 0);
            try std.testing.expect(hint.y + hint.h <= editor.y + 0.5);
            try std.testing.expect(notice.y >= editor.y + editor.h);
            try std.testing.expect(notice.y + notice.h <= t.window.rect_pixels.h);
            try std.testing.expect(send.x >= editor.x + editor.w);
            if (size.w == 760 and !dark) try t.saveImage(Harness.frame, null, "empty-entry-feedback.png");
            try Harness.typeText("已完成 ✅\n草稿切换保留，支持撤销和重做。\n\n下一步\n检查中文输入、长文编辑与复制粘贴。测试反馈随时记录在这里。");
            try Harness.key(.enter, .lcontrol);
            try std.testing.expectEqual(state.Notice.entry_created, Harness.app.notice);
            if (size.w == 1100) try t.saveImage(Harness.frame, null, if (dark) "overview-dark.png" else "overview-light.png");
            if (size.w == 1100 and dark) {
                try Harness.app.setTaskFilter(std.testing.allocator, .all);
                Harness.app.pending = .{ .toggle_task_completed = Harness.app.selected_task_id.? };
                try dvui.testing.settle(Harness.frame);
                try t.saveImage(Harness.frame, null, "completed-dark.png");
            }
        }
    }
}
