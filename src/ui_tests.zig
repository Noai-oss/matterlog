const std = @import("std");
const dvui = @import("dvui");
const state = @import("app_state.zig");
const ui = @import("ui.zig");

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
