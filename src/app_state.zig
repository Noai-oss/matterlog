const std = @import("std");
const database = @import("database.zig");

const title_capacity = 256;
const entry_capacity = 16 * 1024;

pub const Notice = enum {
    none,
    confirm_delete_task,
    confirm_delete_entry,
    empty_title,
    empty_entry,
    task_created,
    task_renamed,
    task_completed,
    task_reopened,
    task_deleted,
    entry_created,
    entry_updated,
    entry_deleted,
    database_error,
};

pub const PendingAction = union(enum) {
    none,
    create_task,
    rename_task: i64,
    toggle_task_completed: i64,
    delete_task: i64,
    create_entry: i64,
    update_entry: i64,
    delete_entry: i64,
};

pub const Mode = union(enum) {
    none,
    rename_task: i64,
    edit_entry: i64,
    confirm_delete_task: i64,
    confirm_delete_entry: i64,
};

pub const EntryClick = struct {
    entry_id: i64,
    time_ns: i128,
    x: f32,
    y: f32,
};

pub const TaskFilter = enum {
    active,
    completed,
    all,
};

pub const AppState = struct {
    store: ?database.Database = null,
    tasks: std.ArrayList(database.Task) = .empty,

    sidebar_ratio: f32 = 0.28,
    composer_height: f32 = 100,
    selected_task_id: ?i64 = null,
    task_filter: TaskFilter = .active,

    draft: [entry_capacity]u8 = @splat(0),
    rename_buffer: [title_capacity]u8 = @splat(0),
    edit_buffer: [entry_capacity]u8 = @splat(0),

    mode: Mode = .none,
    scroll_to_latest: bool = false,
    focus_composer: bool = false,
    composer_ime_active: bool = false,
    edit_ime_active: bool = false,
    last_entry_click: ?EntryClick = null,

    notice: Notice = .none,
    pending: PendingAction = .none,

    pub fn init(
        self: *AppState,
        allocator: std.mem.Allocator,
        database_path: [:0]const u8,
    ) !void {
        self.* = .{};
        errdefer self.deinit(allocator);

        self.store = try database.Database.open(database_path);
        try self.reloadData(allocator, null);
    }

    pub fn deinit(self: *AppState, allocator: std.mem.Allocator) void {
        database.deinitTasks(allocator, &self.tasks);
        if (self.store) |*store| store.close();
        self.* = .{};
    }

    /// Applies an action queued by the immediate-mode UI. Returns true when a
    /// refresh is required.
    pub fn processPendingAction(
        self: *AppState,
        allocator: std.mem.Allocator,
    ) bool {
        const action = self.pending;
        self.pending = .none;

        switch (action) {
            .none => return false,
            .create_task => self.processCreateTask(allocator) catch |err| self.databaseFailure(err),
            .rename_task => |task_id| {
                self.processRenameTask(allocator, task_id) catch |err| self.databaseFailure(err);
            },
            .toggle_task_completed => |task_id| {
                self.processToggleTaskCompleted(allocator, task_id) catch |err| self.databaseFailure(err);
            },
            .delete_task => |task_id| {
                self.processDeleteTask(allocator, task_id) catch |err| self.databaseFailure(err);
            },
            .create_entry => |task_id| {
                self.processCreateEntry(allocator, task_id) catch |err| self.databaseFailure(err);
            },
            .update_entry => |entry_id| {
                self.processUpdateEntry(allocator, entry_id) catch |err| self.databaseFailure(err);
            },
            .delete_entry => |entry_id| {
                self.processDeleteEntry(allocator, entry_id) catch |err| self.databaseFailure(err);
            },
        }

        return true;
    }

    pub fn selectedTask(self: *AppState) ?*database.Task {
        const selected_id = self.selected_task_id orelse return null;
        for (self.tasks.items) |*task| {
            if (task.id == selected_id) return task;
        }
        return null;
    }

    pub fn selectTask(self: *AppState, task_id: i64) void {
        self.resetTaskInteraction();
        self.selected_task_id = task_id;
    }

    pub fn setTaskFilter(self: *AppState, filter: TaskFilter) void {
        if (self.task_filter == filter) return;

        self.cancelMode();
        self.task_filter = filter;

        if (self.selected_task_id) |selected_id| {
            for (self.tasks.items) |task| {
                if (task.id == selected_id and self.taskVisible(&task)) return;
            }
        }

        self.resetTaskInteraction();
        self.selected_task_id = self.firstVisibleTaskId();
    }

    pub fn taskVisible(self: *const AppState, task: *const database.Task) bool {
        return switch (self.task_filter) {
            .active => !task.completed,
            .completed => task.completed,
            .all => true,
        };
    }

    pub fn hasVisibleTasks(self: *const AppState) bool {
        for (self.tasks.items) |*task| {
            if (self.taskVisible(task)) return true;
        }
        return false;
    }

    pub fn beginRename(self: *AppState, task: *const database.Task) void {
        self.cancelMode();
        setBuffer(self.rename_buffer[0..], task.title);
        self.mode = .{ .rename_task = task.id };
    }

    pub fn isRenamingTask(self: *const AppState, task_id: i64) bool {
        return switch (self.mode) {
            .rename_task => |id| id == task_id,
            else => false,
        };
    }

    pub fn requestTaskDeletion(self: *AppState, task_id: i64) void {
        self.cancelMode();
        self.mode = .{ .confirm_delete_task = task_id };
        self.notice = .confirm_delete_task;
    }

    pub fn isConfirmingTaskDeletion(self: *const AppState, task_id: i64) bool {
        return switch (self.mode) {
            .confirm_delete_task => |id| id == task_id,
            else => false,
        };
    }

    pub fn beginEntryEdit(self: *AppState, entry: *const database.Entry) void {
        self.cancelMode();
        setBuffer(self.edit_buffer[0..], entry.body);
        self.edit_ime_active = false;
        self.mode = .{ .edit_entry = entry.id };
    }

    pub fn isEditingEntry(self: *const AppState, entry_id: i64) bool {
        return switch (self.mode) {
            .edit_entry => |id| id == entry_id,
            else => false,
        };
    }

    pub fn requestEntryDeletion(self: *AppState, entry_id: i64) void {
        self.cancelMode();
        self.mode = .{ .confirm_delete_entry = entry_id };
        self.notice = .confirm_delete_entry;
    }

    pub fn isConfirmingEntryDeletion(self: *const AppState, entry_id: i64) bool {
        return switch (self.mode) {
            .confirm_delete_entry => |id| id == entry_id,
            else => false,
        };
    }

    pub fn hasActiveMode(self: *const AppState) bool {
        return switch (self.mode) {
            .none => false,
            else => true,
        };
    }

    pub fn cancelMode(self: *AppState) void {
        switch (self.mode) {
            .rename_task => clearBuffer(self.rename_buffer[0..]),
            .edit_entry => {
                clearBuffer(self.edit_buffer[0..]);
                self.edit_ime_active = false;
            },
            .none,
            .confirm_delete_task,
            .confirm_delete_entry,
            => {},
        }
        self.mode = .none;
        self.last_entry_click = null;
        self.notice = .none;
    }

    fn processCreateTask(
        self: *AppState,
        allocator: std.mem.Allocator,
    ) !void {
        const task_id = try self.storePtr().createTask("新事项");
        self.task_filter = .active;
        try self.reloadData(allocator, task_id);

        if (self.selectedTask()) |task| self.beginRename(task);
        self.notice = .task_created;
    }

    fn processRenameTask(
        self: *AppState,
        allocator: std.mem.Allocator,
        task_id: i64,
    ) !void {
        const title = trimmedBuffer(self.rename_buffer[0..]);
        if (title.len == 0) {
            self.notice = .empty_title;
            return;
        }

        try self.storePtr().renameTask(task_id, title);
        try self.reloadData(allocator, task_id);

        self.mode = .none;
        clearBuffer(self.rename_buffer[0..]);
        self.notice = .task_renamed;
    }

    fn processToggleTaskCompleted(
        self: *AppState,
        allocator: std.mem.Allocator,
        task_id: i64,
    ) !void {
        const completed = blk: {
            for (self.tasks.items) |task| {
                if (task.id == task_id) break :blk !task.completed;
            }
            return;
        };
        const previous_selected_id = self.selected_task_id;

        try self.storePtr().setTaskCompleted(task_id, completed);
        try self.reloadData(allocator, task_id);

        if (self.selected_task_id != previous_selected_id) {
            self.resetTaskInteraction();
        }
        self.notice = if (self.selected_task_id == null)
            .none
        else if (completed)
            .task_completed
        else
            .task_reopened;
    }

    fn processDeleteTask(
        self: *AppState,
        allocator: std.mem.Allocator,
        task_id: i64,
    ) !void {
        const preferred_id = self.replacementTaskId(task_id);
        try self.storePtr().deleteTask(task_id);
        try self.reloadData(allocator, preferred_id);

        self.mode = .none;
        clearBuffer(self.draft[0..]);
        clearBuffer(self.rename_buffer[0..]);
        clearBuffer(self.edit_buffer[0..]);
        self.scroll_to_latest = false;
        self.focus_composer = false;
        self.composer_ime_active = false;
        self.edit_ime_active = false;
        self.notice = .task_deleted;
    }

    fn processCreateEntry(
        self: *AppState,
        allocator: std.mem.Allocator,
        task_id: i64,
    ) !void {
        const body = trimmedBuffer(self.draft[0..]);
        if (body.len == 0) {
            self.notice = .empty_entry;
            return;
        }

        try self.storePtr().createEntry(task_id, body);
        try self.reloadData(allocator, task_id);

        clearBuffer(self.draft[0..]);
        self.scroll_to_latest = true;
        self.focus_composer = true;
        self.composer_ime_active = false;
        self.notice = .entry_created;
    }

    fn processUpdateEntry(
        self: *AppState,
        allocator: std.mem.Allocator,
        entry_id: i64,
    ) !void {
        const body = trimmedBuffer(self.edit_buffer[0..]);
        if (body.len == 0) {
            self.notice = .empty_entry;
            return;
        }

        const selected_id = self.selected_task_id;
        try self.storePtr().updateEntry(entry_id, body);
        try self.reloadData(allocator, selected_id);

        self.mode = .none;
        clearBuffer(self.edit_buffer[0..]);
        self.edit_ime_active = false;
        self.notice = .entry_updated;
    }

    fn processDeleteEntry(
        self: *AppState,
        allocator: std.mem.Allocator,
        entry_id: i64,
    ) !void {
        const selected_id = self.selected_task_id;
        try self.storePtr().deleteEntry(entry_id);
        try self.reloadData(allocator, selected_id);

        self.mode = .none;
        clearBuffer(self.edit_buffer[0..]);
        self.notice = .entry_deleted;
    }

    fn reloadData(
        self: *AppState,
        allocator: std.mem.Allocator,
        preferred_task_id: ?i64,
    ) !void {
        var new_tasks = try self.storePtr().loadTasks(allocator);
        errdefer database.deinitTasks(allocator, &new_tasks);

        const wanted_id = preferred_task_id orelse self.selected_task_id;
        database.deinitTasks(allocator, &self.tasks);
        self.tasks = new_tasks;

        if (self.tasks.items.len == 0) {
            self.selected_task_id = null;
            return;
        }

        if (wanted_id) |id| {
            for (self.tasks.items) |task| {
                if (task.id == id and self.taskVisible(&task)) {
                    self.selected_task_id = id;
                    return;
                }
            }
        }

        self.selected_task_id = self.firstVisibleTaskId();
    }

    fn storePtr(self: *AppState) *database.Database {
        if (self.store) |*store| return store;
        unreachable;
    }

    fn replacementTaskId(self: *AppState, deleting_id: i64) ?i64 {
        for (self.tasks.items, 0..) |task, index| {
            if (task.id != deleting_id) continue;
            if (index + 1 < self.tasks.items.len) return self.tasks.items[index + 1].id;
            if (index > 0) return self.tasks.items[index - 1].id;
            return null;
        }
        return self.selected_task_id;
    }

    fn firstVisibleTaskId(self: *const AppState) ?i64 {
        for (self.tasks.items) |*task| {
            if (self.taskVisible(task)) return task.id;
        }
        return null;
    }

    fn resetTaskInteraction(self: *AppState) void {
        self.cancelMode();
        clearBuffer(self.draft[0..]);
        self.scroll_to_latest = false;
        self.focus_composer = false;
        self.composer_ime_active = false;
    }

    fn databaseFailure(self: *AppState, err: anyerror) void {
        self.notice = .database_error;
        std.log.err("Matterlog database operation failed: {s}", .{@errorName(err)});
    }
};

fn clearBuffer(buffer: []u8) void {
    @memset(buffer, 0);
}

fn setBuffer(buffer: []u8, text: []const u8) void {
    clearBuffer(buffer);
    if (buffer.len == 0) return;

    var length = @min(buffer.len - 1, text.len);
    if (length < text.len) {
        // Do not truncate inside a UTF-8 continuation byte.
        while (length > 0 and (text[length] & 0xc0) == 0x80) length -= 1;
    }
    @memcpy(buffer[0..length], text[0..length]);
}

fn bufferText(buffer: []const u8) []const u8 {
    const length = std.mem.findScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..length];
}

fn trimmedBuffer(buffer: []const u8) []const u8 {
    return std.mem.trim(u8, bufferText(buffer), " \t\r\n");
}

test "cancelMode clears only the active mode buffer" {
    var app: AppState = .{};
    setBuffer(app.draft[0..], "draft stays");
    setBuffer(app.rename_buffer[0..], "temporary title");
    app.mode = .{ .rename_task = 7 };
    app.notice = .empty_title;

    app.cancelMode();

    try std.testing.expect(!app.hasActiveMode());
    try std.testing.expectEqual(Notice.none, app.notice);
    try std.testing.expectEqualStrings("", bufferText(app.rename_buffer[0..]));
    try std.testing.expectEqualStrings("draft stays", bufferText(app.draft[0..]));

    setBuffer(app.edit_buffer[0..], "temporary edit");
    app.mode = .{ .edit_entry = 11 };
    app.edit_ime_active = true;
    app.last_entry_click = .{
        .entry_id = 11,
        .time_ns = 1,
        .x = 2,
        .y = 3,
    };
    app.cancelMode();

    try std.testing.expectEqualStrings("", bufferText(app.edit_buffer[0..]));
    try std.testing.expect(!app.edit_ime_active);
    try std.testing.expectEqual(null, app.last_entry_click);
    try std.testing.expectEqualStrings("draft stays", bufferText(app.draft[0..]));
}

test "cancelMode leaves draft intact for confirmation modes" {
    var app: AppState = .{};
    setBuffer(app.draft[0..], "unsent progress");
    app.mode = .{ .confirm_delete_entry = 13 };
    app.notice = .confirm_delete_entry;

    app.cancelMode();

    try std.testing.expect(!app.hasActiveMode());
    try std.testing.expectEqualStrings("unsent progress", bufferText(app.draft[0..]));
}
