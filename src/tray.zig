const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("sdl-backend").c;

pub const Tray = struct {
    icon: ?*c.SDL_Tray = null,
    window: ?*c.SDL_Window = null,
    quit_requested: bool = false,

    // Keep this struct at a stable address while callbacks are registered.
    pub fn init(self: *Tray, window: *c.SDL_Window) !void {
        if (builtin.os.tag != .windows) return;

        // A null surface reuses the same native icon as the window and EXE.
        // Converting the full-size PNG here is slow on Windows (per-pixel GDI).
        const icon = c.SDL_CreateTray(null, "Matterlog") orelse
            return error.TrayCreateFailed;
        errdefer c.SDL_DestroyTray(icon);

        const menu = c.SDL_CreateTrayMenu(icon) orelse return error.TrayMenuFailed;
        const open_entry = c.SDL_InsertTrayEntryAt(menu, -1, "打开 Matterlog", c.SDL_TRAYENTRY_BUTTON) orelse
            return error.TrayMenuFailed;
        const quit_entry = c.SDL_InsertTrayEntryAt(menu, -1, "退出", c.SDL_TRAYENTRY_BUTTON) orelse
            return error.TrayMenuFailed;

        self.* = .{ .icon = icon, .window = window };
        c.SDL_SetTrayEntryCallback(open_entry, openCallback, self);
        c.SDL_SetTrayEntryCallback(quit_entry, quitCallback, self);
    }

    pub fn deinit(self: *Tray) void {
        if (self.icon) |icon| c.SDL_DestroyTray(icon);
        self.* = .{};
    }

    pub fn processEvents(self: *Tray, win: *dvui.Window) void {
        if (self.icon == null or self.quit_requested) return;

        var close_requested = false;
        for (dvui.events()) |*event| {
            if (event.handled or event.evt != .window or event.evt.window.action != .close) continue;
            if (!dvui.eventMatch(event, .{ .id = win.data().id, .r = win.rect_pixels })) continue;

            event.handle(@src(), win.data());
            close_requested = true;
        }

        // Hiding can enqueue more SDL/DVUI events, so do it after iteration.
        // appStart disables SDL's automatic QUIT; DVUI handles unconsumed close events.
        if (close_requested and !c.SDL_HideWindow(self.window.?)) {
            std.log.warn("Could not hide window to tray: {s}", .{c.SDL_GetError()});
            self.quit_requested = true;
        }
    }

    fn openCallback(userdata: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(userdata.?));
        showWindow(self.window.?);
    }

    fn quitCallback(userdata: ?*anyopaque, _: ?*c.SDL_TrayEntry) callconv(.c) void {
        const self: *Tray = @ptrCast(@alignCast(userdata.?));
        self.quit_requested = true;

        // Wake DVUI even when the hidden window is idle in SDL_WaitEventTimeout.
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_USER;
        _ = c.SDL_PushEvent(&event);
    }
};

pub fn showWindow(window: *c.SDL_Window) void {
    if (!c.SDL_ShowWindow(window)) {
        std.log.warn("Could not show window: {s}", .{c.SDL_GetError()});
        return;
    }
    if (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_MINIMIZED != 0) {
        _ = c.SDL_RestoreWindow(window);
    }
    _ = c.SDL_RaiseWindow(window);
}
