const std = @import("std");
const dvui = @import("dvui");
const sdl_backend = @import("sdl-backend");
const state = @import("app_state.zig");
const ui = @import("ui.zig");

const app_organization: [:0]const u8 = "";
const app_name: [:0]const u8 = "Matterlog";
const database_filename = "matterlog.db";
const chinese_font_family = "HarmonyOS Sans SC";
const chinese_font_bytes = @embedFile("fonts/HarmonyOS_Sans_SC.ttf");
const app_icon_bytes = @embedFile("matterlog-icon.png");

const embedded_fonts = [_]dvui.Font.Source{
    .{
        .family = dvui.Font.array(chinese_font_family),
        .bytes = chinese_font_bytes,
    },
};

var app: state.AppState = .{};

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = &appStart },
    .initFn = appInit,
    .deinitFn = appDeinit,
    .frameFn = appFrame,
};

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

fn appStart() dvui.App.StartOptions {
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
        .icon = app_icon_bytes,
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
    win.themeSet(theme);

    const database_path = try databasePath(win.gpa);
    defer win.gpa.free(database_path);
    try app.init(win.gpa, database_path);
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
    app.deinit(win.gpa);
}

pub fn appFrame() !dvui.App.Result {
    ui.draw(&app);

    if (app.processPendingAction(dvui.currentWindow().gpa)) {
        dvui.refresh(null, @src(), null);
    }
    return .ok;
}
