const std = @import("std");
const dvui = @import("dvui");
const zoom = @import("zoom.zig");

// Run before any text entry so it cannot swallow application-wide shortcuts.
pub fn process(percent: *u16) void {
    for (dvui.events()) |*event| {
        if (event.handled or event.evt != .key) continue;
        const key = event.evt.key;
        if (!key.mod.matchBind("ctrl/cmd") or key.mod.alt()) continue;
        const action: enum { increase, decrease, reset } = switch (key.code) {
            .equal, .kp_add => .increase,
            .minus, .kp_subtract => .decrease,
            .zero, .kp_0 => if (!key.mod.shift()) .reset else continue,
            else => continue,
        };
        // Also consume key-up and keys at the limit: DVUI's fallback must not
        // apply a second, unbounded change when no text field has focus.
        event.handle(@src(), dvui.currentWindow().data());
        if (key.action == .up) continue;
        percent.* = switch (action) {
            .increase => @min(zoom.max_percent, percent.* + zoom.step),
            .decrease => @max(zoom.min_percent, percent.* - zoom.step),
            .reset => zoom.default_percent,
        };
    }
    apply(percent.*);
}

pub fn apply(percent: u16) void {
    const win = dvui.currentWindow();
    const scale = zoom.scale(percent);
    if (win.content_scale == scale) return;
    // Window.begin combines this user factor with the current system DPI.
    win.content_scale = scale;
    dvui.refresh(null, @src(), null);
}

pub fn draw(percent: *u16) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .style = .window,
        .padding = .{ .x = 10, .y = 2, .w = 10, .h = 2 },
    });
    defer row.deinit();
    const font = dvui.Font.theme(.body).withSize(10);
    dvui.label(@src(), "界面缩放", .{}, .{ .font = font, .gravity_y = 0.5, .margin = .{ .w = 6 } });
    var button_opts: dvui.Options = .{ .font = font, .padding = .{ .x = 6, .y = 3, .w = 6, .h = 3 }, .margin = .{ .w = 3 } };
    button_opts.tag = if (@import("builtin").is_test) "zoom-out" else null;
    if (dvui.button(@src(), "−", .{}, button_opts)) percent.* = @max(zoom.min_percent, percent.* - zoom.step);
    button_opts.tag = if (@import("builtin").is_test) "zoom-reset" else null;
    var label_buffer: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, "{d}%", .{percent.*}) catch unreachable;
    if (dvui.button(@src(), label, .{}, button_opts)) percent.* = zoom.default_percent;
    button_opts.tag = if (@import("builtin").is_test) "zoom-in" else null;
    if (dvui.button(@src(), "+", .{}, button_opts)) percent.* = @min(zoom.max_percent, percent.* + zoom.step);
    dvui.labelNoFmt(@src(), if (@import("builtin").os.tag == .macos) "Cmd +/− · Cmd 0 重置" else "Ctrl +/− · Ctrl 0 重置", .{}, .{
        .font = font,
        .expand = .horizontal,
        .max_size_content = .width(0),
        .gravity_y = 0.5,
    });
    apply(percent.*);
}
