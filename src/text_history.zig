const std = @import("std");

pub const Selection = struct {
    start: usize = 0,
    end: usize = 0,
    cursor: usize = 0,
    before: bool = false,
};

pub const Snapshot = struct {
    text: []const u8,
    selection: Selection = .{},

    fn clone(self: Snapshot, allocator: std.mem.Allocator) !Snapshot {
        return .{ .text = try allocator.dupe(u8, self.text), .selection = self.selection };
    }
};

pub const Kind = enum { isolated, typing, backspace, delete };

/// Text and selection history, independent of the GUI and database. Snapshots
/// own their strings; moving this value (e.g. in a task map) is safe.
pub const History = struct {
    pub const max_states = 129;
    pub const max_bytes = 256 * 1024;

    allocator: ?std.mem.Allocator = null,
    states: std.ArrayList(Snapshot) = .empty,
    index: usize = 0,
    bytes: usize = 0,
    last_kind: Kind = .isolated,
    last_time: i128 = 0,
    composing: bool = false,
    composition: ?Snapshot = null,

    pub fn clear(self: *History) void {
        if (self.allocator) |allocator| {
            for (self.states.items) |item| allocator.free(item.text);
            self.states.deinit(allocator);
            if (self.composition) |item| allocator.free(item.text);
        }
        self.* = .{};
    }

    pub fn breakGroup(self: *History) void {
        self.last_kind = .isolated;
    }

    pub fn record(self: *History, allocator: std.mem.Allocator, before: Snapshot, after: Snapshot, kind: Kind, time: i128) !void {
        if (std.mem.eql(u8, before.text, after.text)) return;
        // An external replacement starts a new editing session. Never let an
        // old undo step overwrite unrelated text.
        if (self.states.items.len > 0 and !std.mem.eql(u8, self.states.items[self.index].text, before.text)) self.clear();
        const gpa = self.allocator orelse allocator;
        self.allocator = gpa;
        const next = try after.clone(gpa);
        errdefer gpa.free(next.text);

        const grouped = self.index > 0 and kind != .isolated and self.last_kind == kind and
            time >= self.last_time and time - self.last_time <= std.time.ns_per_s and
            before.selection.start == before.selection.end and
            std.meta.eql(self.states.items[self.index].selection, before.selection);

        try self.states.ensureUnusedCapacity(gpa, 2);
        if (self.states.items.len == 0) {
            const initial = try before.clone(gpa);
            self.states.appendAssumeCapacity(initial);
            self.bytes += initial.text.len;
        }
        while (self.states.items.len > self.index + 1) self.removeLast();
        if (grouped) {
            self.removeLast();
        } else {
            self.states.items[self.index].selection = before.selection;
        }
        self.states.appendAssumeCapacity(next);
        self.bytes += next.text.len;
        while (self.states.items.len > max_states or self.bytes > max_bytes) {
            const removed = self.states.orderedRemove(0);
            self.bytes -= removed.text.len;
            gpa.free(removed.text);
        }
        self.index = self.states.items.len - 1;
        self.last_kind = kind;
        self.last_time = time;
    }

    fn removeLast(self: *History) void {
        const removed = self.states.pop().?;
        self.bytes -= removed.text.len;
        self.allocator.?.free(removed.text);
    }

    pub fn undo(self: *History) ?Snapshot {
        self.breakGroup();
        if (self.composing or self.index == 0) return null;
        self.index -= 1;
        return self.states.items[self.index];
    }

    pub fn redo(self: *History) ?Snapshot {
        self.breakGroup();
        if (self.composing or self.index + 1 >= self.states.items.len) return null;
        self.index += 1;
        return self.states.items[self.index];
    }

    pub fn beginComposition(self: *History, allocator: std.mem.Allocator, before: Snapshot) !void {
        if (self.composing) return;
        self.breakGroup();
        const gpa = self.allocator orelse allocator;
        self.allocator = gpa;
        self.composition = try before.clone(gpa);
        self.composing = true;
    }

    pub fn finishComposition(self: *History, allocator: std.mem.Allocator, after: Snapshot, time: i128) !void {
        const before = self.composition;
        self.composition = null;
        self.composing = false;
        if (before) |initial| {
            const gpa = self.allocator.?;
            defer gpa.free(initial.text);
            try self.record(allocator, initial, after, .isolated, time);
        }
    }

    pub fn cancelComposition(self: *History, buffer: []u8) void {
        if (self.composition) |initial| {
            @memset(buffer, 0);
            @memcpy(buffer[0..initial.text.len], initial.text);
            self.allocator.?.free(initial.text);
        }
        self.composition = null;
        self.composing = false;
        self.breakGroup();
    }
};

test "replacement undo restores selection and a new edit drops redo" {
    var history: History = .{};
    defer history.clear();
    const before: Snapshot = .{ .text = "中文\noriginal", .selection = .{ .start = 7, .end = 15, .cursor = 15 } };
    const after: Snapshot = .{ .text = "中文\n替换", .selection = .{ .start = 13, .end = 13, .cursor = 13 } };
    try history.record(std.testing.allocator, before, after, .isolated, 0);
    const restored = history.undo().?;
    try std.testing.expectEqualStrings(before.text, restored.text);
    try std.testing.expectEqualDeep(before.selection, restored.selection);
    try std.testing.expectEqualStrings(after.text, history.redo().?.text);
    _ = history.undo();
    try history.record(std.testing.allocator, before, .{ .text = "different" }, .isolated, 1);
    try std.testing.expectEqual(null, history.redo());
    try std.testing.expectEqualStrings(before.text, history.undo().?.text);
}

test "consecutive typing groups but pauses and explicit boundaries split" {
    var history: History = .{};
    defer history.clear();
    try history.record(std.testing.allocator, .{ .text = "" }, .{ .text = "a" }, .typing, 0);
    try history.record(std.testing.allocator, .{ .text = "a" }, .{ .text = "ab" }, .typing, 1);
    try std.testing.expectEqualStrings("", history.undo().?.text);
    try std.testing.expectEqualStrings("ab", history.redo().?.text);
    try history.record(std.testing.allocator, .{ .text = "ab" }, .{ .text = "abc" }, .typing, 2 * std.time.ns_per_s);
    history.breakGroup();
    try history.record(std.testing.allocator, .{ .text = "abc" }, .{ .text = "abcd" }, .typing, 2 * std.time.ns_per_s + 1);
    try std.testing.expectEqualStrings("abc", history.undo().?.text);
    try std.testing.expectEqualStrings("ab", history.undo().?.text);
}

test "history has count and memory limits and frees discarded snapshots" {
    var history: History = .{};
    defer history.clear();
    var before: [16 * 1024]u8 = @splat('a');
    var after = before;
    for (0..200) |i| {
        after[0] = @intCast(i);
        try history.record(std.testing.allocator, .{ .text = &before }, .{ .text = &after }, .isolated, @intCast(i));
        before = after;
        try std.testing.expect(history.bytes <= History.max_bytes);
        try std.testing.expect(history.states.items.len <= History.max_states);
    }
    try std.testing.expect(history.undo() != null);
    history.clear();
    for (0..200) |i| {
        const b = [_]u8{@intCast(i)};
        const a = [_]u8{@intCast(i + 1)};
        try history.record(std.testing.allocator, .{ .text = &b }, .{ .text = &a }, .isolated, @intCast(i));
    }
    try std.testing.expectEqual(History.max_states, history.states.items.len);
}

test "IME history keeps committed text only" {
    var history: History = .{};
    defer history.clear();
    try history.beginComposition(std.testing.allocator, .{ .text = "prefix " });
    try history.beginComposition(std.testing.allocator, .{ .text = "prefix zhong" });
    try std.testing.expectEqual(null, history.undo());
    try history.finishComposition(std.testing.allocator, .{ .text = "prefix 中文" }, 0);
    try std.testing.expectEqualStrings("prefix ", history.undo().?.text);
    try std.testing.expectEqualStrings("prefix 中文", history.redo().?.text);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var history: History = .{};
    defer history.clear();
    try history.record(allocator, .{ .text = "" }, .{ .text = "first" }, .typing, 0);
    try history.record(allocator, .{ .text = "first" }, .{ .text = "first second" }, .typing, 1);
    _ = history.undo();
    try history.record(allocator, .{ .text = "" }, .{ .text = "branch" }, .isolated, 2);
    try history.beginComposition(allocator, .{ .text = "branch" });
    try history.finishComposition(allocator, .{ .text = "branch中文" }, 3);
}

test "allocation failure releases snapshots and in-progress composition" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
