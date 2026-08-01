const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

const Error = error{
    DatabaseOpenFailed,
    DatabaseOperationFailed,
    InvalidDatabaseData,
};

pub const Entry = struct {
    id: i64,
    body: []u8,
    edited: bool,
    created_text: []u8,
    updated_text: []u8,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.created_text);
        allocator.free(self.updated_text);
        self.* = undefined;
    }
};

pub const Task = struct {
    id: i64,
    title: []u8,
    entries: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            entry.deinit(allocator);
        }
        self.entries.deinit(allocator);
        allocator.free(self.title);
        self.* = undefined;
    }
};

pub fn deinitTasks(
    allocator: std.mem.Allocator,
    tasks: *std.ArrayList(Task),
) void {
    for (tasks.items) |*task| {
        task.deinit(allocator);
    }
    tasks.deinit(allocator);
    tasks.* = .empty;
}

pub const Database = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8) !Database {
        var handle: ?*c.sqlite3 = null;

        const flags = c.SQLITE_OPEN_READWRITE |
            c.SQLITE_OPEN_CREATE;

        const result = c.sqlite3_open_v2(
            path.ptr,
            &handle,
            flags,
            null,
        );

        if (result != c.SQLITE_OK or handle == null) {
            if (handle) |opened| {
                _ = c.sqlite3_close_v2(opened);
            }
            return Error.DatabaseOpenFailed;
        }

        var database: Database = .{ .handle = handle.? };
        errdefer database.close();
        try database.initialize();
        return database;
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close_v2(self.handle);
        self.* = undefined;
    }

    fn initialize(self: *Database) !void {
        try self.exec("PRAGMA foreign_keys = ON;");
        try self.exec("PRAGMA journal_mode = DELETE;");
        try self.exec("PRAGMA busy_timeout = 3000;");

        try self.exec(
            \\CREATE TABLE IF NOT EXISTS tasks (
            \\    id          INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    title       TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS entries (
            \\    id          INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    task_id     INTEGER NOT NULL,
            \\    body        TEXT NOT NULL,
            \\    created_at  INTEGER NOT NULL DEFAULT (unixepoch()),
            \\    updated_at  INTEGER NOT NULL DEFAULT (unixepoch()),
            \\    edited      INTEGER NOT NULL DEFAULT 0,
            \\    FOREIGN KEY (task_id)
            \\        REFERENCES tasks(id)
            \\        ON DELETE CASCADE
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_entries_task_created
            \\    ON entries(task_id, created_at, id);
        );
    }

    pub fn loadTasks(
        self: *Database,
        allocator: std.mem.Allocator,
    ) !std.ArrayList(Task) {
        var tasks: std.ArrayList(Task) = .empty;
        errdefer deinitTasks(allocator, &tasks);

        const statement = try self.prepare(
            \\SELECT
            \\    id,
            \\    title
            \\FROM tasks
            \\ORDER BY id;
        );
        defer _ = c.sqlite3_finalize(statement);

        while (true) {
            const result = c.sqlite3_step(statement);

            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) {
                return Error.DatabaseOperationFailed;
            }

            var task = try readTask(statement, allocator);
            tasks.append(allocator, task) catch |err| {
                task.deinit(allocator);
                return err;
            };
        }

        for (tasks.items) |*task| {
            task.entries = try self.loadEntries(allocator, task.id);
        }

        return tasks;
    }

    pub fn createTask(self: *Database, title: []const u8) !i64 {
        const statement = try self.prepare("INSERT INTO tasks (title) VALUES (?);");
        defer _ = c.sqlite3_finalize(statement);

        try bindText(statement, 1, title);
        try expectDone(c.sqlite3_step(statement));

        return @intCast(c.sqlite3_last_insert_rowid(self.handle));
    }

    pub fn renameTask(
        self: *Database,
        task_id: i64,
        title: []const u8,
    ) !void {
        const statement = try self.prepare(
            "UPDATE tasks SET title = ? WHERE id = ?;",
        );
        defer _ = c.sqlite3_finalize(statement);

        try bindText(statement, 1, title);
        try bindInt64(statement, 2, task_id);
        try expectDone(c.sqlite3_step(statement));
    }

    pub fn deleteTask(self: *Database, task_id: i64) !void {
        const statement = try self.prepare(
            "DELETE FROM tasks WHERE id = ?;",
        );
        defer _ = c.sqlite3_finalize(statement);

        try bindInt64(statement, 1, task_id);
        try expectDone(c.sqlite3_step(statement));
    }

    pub fn createEntry(
        self: *Database,
        task_id: i64,
        body: []const u8,
    ) !void {
        const statement = try self.prepare(
            "INSERT INTO entries (task_id, body) VALUES (?, ?);",
        );
        defer _ = c.sqlite3_finalize(statement);

        try bindInt64(statement, 1, task_id);
        try bindText(statement, 2, body);
        try expectDone(c.sqlite3_step(statement));
    }

    pub fn updateEntry(
        self: *Database,
        entry_id: i64,
        body: []const u8,
    ) !void {
        const statement = try self.prepare(
            \\UPDATE entries
            \\SET body = ?, updated_at = unixepoch(), edited = 1
            \\WHERE id = ?;
        );
        defer _ = c.sqlite3_finalize(statement);

        try bindText(statement, 1, body);
        try bindInt64(statement, 2, entry_id);
        try expectDone(c.sqlite3_step(statement));
    }

    pub fn deleteEntry(self: *Database, entry_id: i64) !void {
        const statement = try self.prepare("DELETE FROM entries WHERE id = ?;");
        defer _ = c.sqlite3_finalize(statement);

        try bindInt64(statement, 1, entry_id);
        try expectDone(c.sqlite3_step(statement));
    }

    fn loadEntries(
        self: *Database,
        allocator: std.mem.Allocator,
        task_id: i64,
    ) !std.ArrayList(Entry) {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |*entry| {
                entry.deinit(allocator);
            }
            entries.deinit(allocator);
        }

        const statement = try self.prepare(
            \\SELECT
            \\    id,
            \\    body,
            \\    edited,
            \\    strftime('%m-%d %H:%M', created_at, 'unixepoch', 'localtime'),
            \\    strftime('%m-%d %H:%M', updated_at, 'unixepoch', 'localtime')
            \\FROM entries
            \\WHERE task_id = ?
            \\ORDER BY created_at, id;
        );
        defer _ = c.sqlite3_finalize(statement);

        try bindInt64(statement, 1, task_id);

        while (true) {
            const result = c.sqlite3_step(statement);

            if (result == c.SQLITE_DONE) break;
            if (result != c.SQLITE_ROW) {
                return Error.DatabaseOperationFailed;
            }

            var entry = try readEntry(statement, allocator);
            entries.append(allocator, entry) catch |err| {
                entry.deinit(allocator);
                return err;
            };
        }

        return entries;
    }

    fn exec(self: *Database, sql: [:0]const u8) !void {
        const result = c.sqlite3_exec(
            self.handle,
            sql.ptr,
            null,
            null,
            null,
        );

        if (result != c.SQLITE_OK) {
            std.log.err("SQLite exec failed with code {d}", .{result});
            return Error.DatabaseOperationFailed;
        }
    }

    fn prepare(
        self: *Database,
        sql: []const u8,
    ) !*c.sqlite3_stmt {
        var statement: ?*c.sqlite3_stmt = null;
        const result = c.sqlite3_prepare_v2(
            self.handle,
            sql.ptr,
            @intCast(sql.len),
            &statement,
            null,
        );

        if (result != c.SQLITE_OK or statement == null) {
            std.log.err("SQLite prepare failed with code {d}", .{result});
            return Error.DatabaseOperationFailed;
        }

        return statement.?;
    }
};

fn bindText(
    statement: *c.sqlite3_stmt,
    index: c_int,
    value: []const u8,
) !void {
    const result = c.sqlite3_bind_text(
        statement,
        index,
        value.ptr,
        @intCast(value.len),
        c.SQLITE_STATIC,
    );

    if (result != c.SQLITE_OK) {
        return Error.DatabaseOperationFailed;
    }
}

fn bindInt64(
    statement: *c.sqlite3_stmt,
    index: c_int,
    value: i64,
) !void {
    if (c.sqlite3_bind_int64(statement, index, value) != c.SQLITE_OK) {
        return Error.DatabaseOperationFailed;
    }
}

fn expectDone(result: c_int) !void {
    if (result != c.SQLITE_DONE) {
        return Error.DatabaseOperationFailed;
    }
}

fn readTask(
    statement: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,
) !Task {
    const title = try duplicateColumnText(statement, 1, allocator);
    errdefer allocator.free(title);

    return .{
        .id = @intCast(c.sqlite3_column_int64(statement, 0)),
        .title = title,
    };
}

fn readEntry(
    statement: *c.sqlite3_stmt,
    allocator: std.mem.Allocator,
) !Entry {
    const body = try duplicateColumnText(statement, 1, allocator);
    errdefer allocator.free(body);

    const created_text = try duplicateColumnText(statement, 3, allocator);
    errdefer allocator.free(created_text);

    const updated_text = try duplicateColumnText(statement, 4, allocator);
    errdefer allocator.free(updated_text);

    return .{
        .id = @intCast(c.sqlite3_column_int64(statement, 0)),
        .body = body,
        .edited = c.sqlite3_column_int(statement, 2) != 0,
        .created_text = created_text,
        .updated_text = updated_text,
    };
}

fn duplicateColumnText(
    statement: *c.sqlite3_stmt,
    column: c_int,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (c.sqlite3_column_type(statement, column) == c.SQLITE_NULL) {
        return Error.InvalidDatabaseData;
    }

    const text = c.sqlite3_column_text(statement, column);
    if (text == null) {
        return Error.InvalidDatabaseData;
    }

    const length_i32 = c.sqlite3_column_bytes(statement, column);
    if (length_i32 < 0) {
        return Error.InvalidDatabaseData;
    }

    const length: usize = @intCast(length_i32);
    if (length == 0) {
        return allocator.dupe(u8, "");
    }

    const bytes = @as([*c]const u8, @ptrCast(text))[0..length];
    return allocator.dupe(u8, bytes);
}

test "database CRUD and cascade deletion" {
    const allocator = std.testing.allocator;

    var database = try Database.open(":memory:");
    defer database.close();
    const task_id = try database.createTask("初始事项");
    try database.createEntry(task_id, "第一条进展");
    try database.renameTask(task_id, "重命名事项");

    var entry_id: i64 = undefined;
    {
        var tasks = try database.loadTasks(allocator);
        defer deinitTasks(allocator, &tasks);

        try std.testing.expectEqual(@as(usize, 1), tasks.items.len);
        try std.testing.expectEqualStrings("重命名事项", tasks.items[0].title);
        try std.testing.expectEqual(@as(usize, 1), tasks.items[0].entries.items.len);
        try std.testing.expectEqualStrings("第一条进展", tasks.items[0].entries.items[0].body);
        try std.testing.expect(!tasks.items[0].entries.items[0].edited);
        entry_id = tasks.items[0].entries.items[0].id;
    }

    try database.updateEntry(entry_id, "修改后的进展");
    {
        var tasks = try database.loadTasks(allocator);
        defer deinitTasks(allocator, &tasks);

        try std.testing.expectEqualStrings("修改后的进展", tasks.items[0].entries.items[0].body);
        try std.testing.expect(tasks.items[0].entries.items[0].edited);
    }

    try database.deleteEntry(entry_id);
    try database.createEntry(task_id, "用于验证级联删除");
    try database.deleteTask(task_id);

    var tasks = try database.loadTasks(allocator);
    defer deinitTasks(allocator, &tasks);
    try std.testing.expectEqual(@as(usize, 0), tasks.items.len);
}
