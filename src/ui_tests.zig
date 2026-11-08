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
};

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
    const rect = (try dvui.testing.tagGet("entry-body")).rect;
    _ = try t.window.addEventMouseMotion(.{ .pt = .{ .x = rect.x + 10, .y = rect.y + 10 } });
    try dvui.testing.click(.left);
    try dvui.testing.settle(Harness.frame);
    try dvui.testing.click(.left);
    try dvui.testing.settle(Harness.frame);
    try std.testing.expect(!Harness.app.hasActiveMode());
    try Harness.key(.c, .lcontrol);
    try std.testing.expectEqualStrings("alpha", dvui.clipboardText());
    try Harness.click("copy-entry");
    try expectClipboard(body);
    try std.testing.expectEqual(state.Notice.entry_copied, Harness.app.notice);
    try Harness.click("edit-entry");
    try std.testing.expect(Harness.app.hasActiveMode());
    try std.testing.expectEqualStrings(body, std.mem.sliceTo(&Harness.app.edit_buffer, 0));
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
    try Harness.click("entry-body");
    try Harness.key(.a, .lcontrol);
    try Harness.key(.c, .lcontrol);
    try expectClipboard(body);
    try Harness.click("edit-entry");
    try Harness.key(.a, .lcontrol);
    try Harness.key(.c, .lcontrol);
    try expectClipboard(body);
    try Harness.key(.right, .none);
    try t.saveImage(Harness.frame, null, "unicode-editor.png");
    try Harness.click("save-entry");
    try std.testing.expectEqualStrings(body, Harness.app.selectedTask().?.entries.items[0].body);
}
