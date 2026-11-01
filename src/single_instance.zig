const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl-backend").c;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

const mutex_name = wide("Local\\org.matterlog.desktop.instance.v1");
const window_property = wide("org.matterlog.desktop.instance.v1");
const activation_message_name = wide("org.matterlog.desktop.activate.v1");

extern "kernel32" fn CreateMutexW(attributes: ?*anyopaque, initial_owner: c_int, name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn ReleaseMutex(handle: *anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "user32" fn RegisterWindowMessageW(name: [*:0]const u16) callconv(.winapi) u32;
extern "user32" fn SetPropW(window: *anyopaque, name: [*:0]const u16, value: *anyopaque) callconv(.winapi) c_int;
extern "user32" fn GetPropW(window: *anyopaque, name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn RemovePropW(window: *anyopaque, name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "user32" fn EnumWindows(callback: *const fn (*anyopaque, isize) callconv(.winapi) c_int, parameter: isize) callconv(.winapi) c_int;
extern "user32" fn GetWindowThreadProcessId(window: *anyopaque, process_id: *u32) callconv(.winapi) u32;
extern "user32" fn AllowSetForegroundWindow(process_id: u32) callconv(.winapi) c_int;
extern "user32" fn PostMessageW(window: *anyopaque, message: u32, wparam: usize, lparam: isize) callconv(.winapi) c_int;

pub const SingleInstance = struct {
    mutex: ?*anyopaque = null,
    owns_mutex: bool = false,
    hwnd: ?*anyopaque = null,
    activation_message: u32 = 0,
    activation_requested: bool = false,

    /// Call before SDL/window/database initialization. Keep this struct at a
    /// stable address until deinit. False means the existing app was notified.
    pub fn acquire(self: *SingleInstance) !bool {
        if (builtin.os.tag != .windows) return true;

        self.activation_message = RegisterWindowMessageW(activation_message_name);
        if (self.activation_message == 0) return error.InstanceMessageRegistrationFailed;
        self.mutex = CreateMutexW(null, 0, mutex_name) orelse return error.InstanceMutexFailed;

        // Another launch may own the mutex before it has created its window.
        // Retry discovery, and take over if that process exits during startup.
        for (0..250) |_| {
            switch (WaitForSingleObject(self.mutex.?, 0)) {
                0, 0x80 => { // WAIT_OBJECT_0 / WAIT_ABANDONED
                    self.owns_mutex = true;
                    return true;
                },
                0x102 => {}, // WAIT_TIMEOUT: another instance owns it
                else => return error.InstanceMutexWaitFailed,
            }

            var window: ?*anyopaque = null;
            _ = EnumWindows(findWindow, @bitCast(@intFromPtr(&window)));
            if (window) |hwnd| {
                var process_id: u32 = 0;
                _ = GetWindowThreadProcessId(hwnd, &process_id);
                // A launch from Explorer can pass its foreground permission
                // to the existing app, which will restore its own SDL window.
                if (process_id != 0) _ = AllowSetForegroundWindow(process_id);
                if (PostMessageW(hwnd, self.activation_message, 0, 0) != 0) return false;
            }
            Sleep(20);
        }
        return error.ExistingInstanceNotReady;
    }

    /// Publish the main window only after its event hook is ready.
    pub fn attach(self: *SingleInstance, window: *c.SDL_Window) !void {
        if (builtin.os.tag != .windows) return;
        self.hwnd = c.SDL_GetPointerProperty(
            c.SDL_GetWindowProperties(window),
            c.SDL_PROP_WINDOW_WIN32_HWND_POINTER,
            null,
        ) orelse return error.InstanceWindowUnavailable;
        c.SDL_SetWindowsMessageHook(messageHook, self);
        errdefer self.detach();
        if (SetPropW(self.hwnd.?, window_property, @ptrFromInt(1)) == 0) {
            return error.InstanceWindowRegistrationFailed;
        }
    }

    pub fn takeActivationRequest(self: *SingleInstance) bool {
        const requested = self.activation_requested;
        self.activation_requested = false;
        return requested;
    }

    /// Detach while the SDL window still exists.
    pub fn detach(self: *SingleInstance) void {
        if (builtin.os.tag != .windows) return;
        if (self.hwnd) |hwnd| {
            _ = RemovePropW(hwnd, window_property);
            c.SDL_SetWindowsMessageHook(null, null);
            self.hwnd = null;
        }
    }

    pub fn deinit(self: *SingleInstance) void {
        if (builtin.os.tag != .windows) return;
        self.detach();
        if (self.mutex) |mutex| {
            if (self.owns_mutex) _ = ReleaseMutex(mutex);
            _ = CloseHandle(mutex);
        }
        self.* = .{};
    }

    fn findWindow(hwnd: *anyopaque, parameter: isize) callconv(.winapi) c_int {
        if (GetPropW(hwnd, window_property) == null) return 1;
        const result: *?*anyopaque = @ptrFromInt(@as(usize, @bitCast(parameter)));
        result.* = hwnd;
        return 0;
    }

    fn messageHook(userdata: ?*anyopaque, message: ?*c.MSG) callconv(.c) bool {
        const self: *SingleInstance = @ptrCast(@alignCast(userdata.?));
        // SDL exposes MSG as opaque; only its HWND/UINT prefix is needed.
        const Header = extern struct { hwnd: ?*anyopaque, message: u32 };
        const header: *const Header = @ptrCast(@alignCast(message orelse return true));
        if (header.hwnd != self.hwnd or header.message != self.activation_message) return true;

        self.activation_requested = true;
        // Wake DVUI when it is waiting with the window hidden in the tray.
        // Restore from appFrame, outside the native message callback.
        var event = std.mem.zeroes(c.SDL_Event);
        event.type = c.SDL_EVENT_USER;
        _ = c.SDL_PushEvent(&event);
        return false;
    }
};
