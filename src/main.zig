const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const sdl_backend = @import("sdl-backend");
const state = @import("app_state.zig");
const ui = @import("ui.zig");
const tray_module = @import("tray.zig");
const instance_module = @import("single_instance.zig");

const app_organization: [:0]const u8 = "";
const app_name: [:0]const u8 = "Matterlog";
const database_filename = "matterlog.db";
const chinese_font_family = "HarmonyOS Sans SC";
const chinese_font_bytes = @embedFile("harmonyos-sans-sc");
const app_icon_bytes = @embedFile("matterlog-icon");

const embedded_fonts = [_]dvui.Font.Source{
    .{
        .family = dvui.Font.array(chinese_font_family),
        .bytes = chinese_font_bytes,
    },
};

var app: state.AppState = .{};
var tray: tray_module.Tray = .{};
var instance: instance_module.SingleInstance = .{};
var startup_frames_remaining: u2 = if (builtin.os.tag == .windows) 2 else 0;

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = &appStart },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = appFrame,
};

pub fn main(init: std.process.Init) !u8 {
    defer instance.deinit();
    if (!try instance.acquire()) return 0;
    return dvui.App.main(init);
}
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

fn appStart() dvui.App.StartOptions {
    if (builtin.os.tag == .windows) {
        // IDI_MATTERLOG in assets/matterlog.rc. Reuse the native, multi-size
        // icon for the window and tray instead of converting the large PNG.
        _ = sdl_backend.c.SDL_SetHint(sdl_backend.c.SDL_HINT_WINDOWS_INTRESOURCE_ICON, "101");
        _ = sdl_backend.c.SDL_SetHint(sdl_backend.c.SDL_HINT_WINDOWS_INTRESOURCE_ICON_SMALL, "101");
        // DVUI/tray handles window close explicitly. Tray initialization can
        // fail while the window is hidden; cleanup must not quit the app.
        _ = sdl_backend.c.SDL_SetHint(sdl_backend.c.SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
    }
    _ = sdl_backend.c.SDL_SetAppMetadata(
        app_name.ptr,
        "0.1.0",
        "org.matterlog.desktop",
    );

    return .{
        .size = .{ .w = 1100.0, .h = 760.0 },
        .min_size = .{ .w = 760.0, .h = 520.0 },
        .title = app_name,
        .org = app_organization,
        .app = app_name,
        .persist_window_geometry = false,
        .icon = if (builtin.os.tag == .windows) null else app_icon_bytes,
        .hidden = builtin.os.tag == .windows,
    };
}

pub fn appInit(win: *dvui.Window) !void {
    var theme = win.theme;
    theme.name = app_name;
    theme.embedded_fonts = embedded_fonts[0..];

    const body_font = dvui.Font.find(.{
        .family = chinese_font_family,
        .size = 11.0,
        .line_height_factor = 1.3,
    });

    theme.font_body = body_font;
    theme.font_heading = body_font.withSize(13.0);
    theme.font_title = body_font.withSize(16.0);
    theme.app1 = .{
        .fill = .fromHex("#e4f3e8"),
        .fill_hover = .fromHex("#d6eadc"),
        .fill_press = .fromHex("#c5dfcd"),
        .text = .fromHex("#28613a"),
        .border = .fromHex("#8fbd9b"),
    };
    win.themeSet(theme);

    const database_path = try databasePath(win.gpa);
    defer win.gpa.free(database_path);
    try app.init(win.gpa, database_path);

    tray.init(win.backend.impl.window) catch |err| {
        std.log.warn("System tray unavailable ({s}): {s}", .{ @errorName(err), sdl_backend.c.SDL_GetError() });
    };
    try instance.attach(win.backend.impl.window);
}

fn databasePath(allocator: std.mem.Allocator) ![:0]u8 {
    const raw_path = sdl_backend.c.SDL_GetPrefPath(
        app_organization.ptr,
        app_name.ptr,
    ) orelse return error.PreferencePathUnavailable;
    defer sdl_backend.c.SDL_free(raw_path);

    const directory = std.mem.span(
        @as([*:0]const u8, @ptrCast(raw_path)),
    );
    return std.fs.path.joinZ(allocator, &.{ directory, database_filename });
}

pub fn appDeinit(win: *dvui.Window) void {
    instance.detach();
    tray.deinit();
    app.deinit(win.gpa);
}

pub fn appFrame() !dvui.App.Result {
    tray.processEvents(dvui.currentWindow());
    if (tray.quit_requested) return .close;
    if (startup_frames_remaining == 0 and instance.takeActivationRequest()) {
        tray_module.showWindow(dvui.currentWindow().backend.impl.window);
    }
    ui.draw(&app);

    if (app.processPendingAction(dvui.currentWindow().gpa)) {
        dvui.refresh(null, @src(), null);
    }

    if (startup_frames_remaining > 0) {
        startup_frames_remaining -= 1;
        const win = dvui.currentWindow();
        // Warm up layout and fonts while hidden. Complete drawing before
        // revealing the window; the normal event loop then presents it.
        if (startup_frames_remaining == 0) {
            win.endRendering(.{});
            if (!sdl_backend.c.SDL_ShowWindow(win.backend.impl.window)) {
                std.log.err("Could not show window: {s}", .{sdl_backend.c.SDL_GetError()});
                return .close;
            }
        }
        dvui.refresh(null, @src(), null);
    }
    return .ok;
}
