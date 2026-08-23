const std = @import("std");

pub const Phase = enum {
    suppress_next,
    await_gameplay,
    complete,
};

const PersistedState = struct {
    version: u8 = 1,
    product_id: u32,
    achievement: []const u8,
    phase: Phase,
};

/// Opt-in, one-achievement guard used when an R2 game replays an old unlock
/// while loading a save. The first signal is suppressed and re-locked in the
/// emulator state; the following signal is treated as gameplay and completes
/// the guard. Normal provider operation is unchanged when no guard is armed.
pub const Guard = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    product_id: u32 = 0,
    achievement: ?[]u8 = null,
    phase: Phase = .complete,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Guard {
        var result = Guard{ .allocator = allocator, .io = io, .path = path };
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return err,
        };
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(PersistedState, allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value.version != 1 or !validAchievement(parsed.value.achievement)) return error.InvalidReplayGuard;
        result.product_id = parsed.value.product_id;
        result.achievement = try allocator.dupe(u8, parsed.value.achievement);
        result.phase = parsed.value.phase;
        return result;
    }

    pub fn deinit(self: *Guard) void {
        if (self.achievement) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn suppresses(self: *const Guard, product_id: u32, achievement: []const u8) bool {
        return self.matches(product_id, achievement) and self.phase == .suppress_next;
    }

    pub fn awaitsGameplay(self: *const Guard, product_id: u32, achievement: []const u8) bool {
        return self.matches(product_id, achievement) and self.phase == .await_gameplay;
    }

    pub fn suppressReplay(self: *Guard, save_path: []const u8) !void {
        const achievement = self.achievement orelse return error.ReplayGuardNotArmed;
        try relockAchievement(self.allocator, self.io, save_path, achievement);
        self.phase = .await_gameplay;
        try self.persist();
    }

    pub fn complete(self: *Guard) !void {
        self.phase = .complete;
        try self.persist();
    }

    fn matches(self: *const Guard, product_id: u32, achievement: []const u8) bool {
        return self.product_id == product_id and if (self.achievement) |wanted|
            std.mem.eql(u8, wanted, achievement)
        else
            false;
    }

    fn persist(self: *const Guard) !void {
        const achievement = self.achievement orelse return error.ReplayGuardNotArmed;
        const json = try std.json.Stringify.valueAlloc(self.allocator, PersistedState{
            .product_id = self.product_id,
            .achievement = achievement,
            .phase = self.phase,
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);
        try writeAtomic(self.io, self.path, json);
    }
};

pub fn arm(allocator: std.mem.Allocator, io: std.Io, path: []const u8, product_id: u32, achievement: []const u8) !void {
    if (product_id == 0 or !validAchievement(achievement)) return error.InvalidReplayGuard;
    const json = try std.json.Stringify.valueAlloc(allocator, PersistedState{
        .product_id = product_id,
        .achievement = achievement,
        .phase = .suppress_next,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try writeAtomic(io, path, json);
}

fn relockAchievement(allocator: std.mem.Allocator, io: std.Io, path: []const u8, achievement: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.InvalidAchievementState,
    };
    const value = root.getPtr(achievement) orelse return error.AchievementNotFound;
    const state = switch (value.*) {
        .object => |*object| object,
        else => return error.InvalidAchievementState,
    };
    try state.put(allocator, "earned", .{ .integer = 0 });
    try state.put(allocator, "earned_time", .{ .integer = 0 });

    const output = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    defer allocator.free(output);
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.achievement-bridge-replay-guard.bak", .{path});
    defer allocator.free(backup_path);
    try writeAtomic(io, backup_path, bytes);
    try writeAtomic(io, path, output);
}

fn validAchievement(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') return false;
    return true;
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.replace(io);
}

test "armed replay guard suppresses once then awaits gameplay" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const guard_path = try std.fs.path.join(allocator, &.{ root, "guard.json" });
    defer allocator.free(guard_path);
    const save_path = try std.fs.path.join(allocator, &.{ root, "achievements.json" });
    defer allocator.free(save_path);
    try writeAtomic(std.testing.io, save_path,
        \\{"30":{"earned":1,"earned_time":123},"31":{"earned":1,"earned_time":456}}
    );
    try arm(allocator, std.testing.io, guard_path, 66088, "30");

    var guard = try Guard.init(allocator, std.testing.io, guard_path);
    defer guard.deinit();
    try std.testing.expect(guard.suppresses(66088, "30"));
    try guard.suppressReplay(save_path);
    try std.testing.expect(guard.awaitsGameplay(66088, "30"));

    const save_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, save_path, allocator, .limited(64 * 1024));
    defer allocator.free(save_bytes);
    var state = try std.json.parseFromSlice(std.json.Value, allocator, save_bytes, .{});
    defer state.deinit();
    const achievement = state.value.object.get("30").?.object;
    try std.testing.expectEqual(@as(i64, 0), achievement.get("earned").?.integer);
    try std.testing.expectEqual(@as(i64, 0), achievement.get("earned_time").?.integer);
    try std.testing.expectEqual(@as(i64, 1), state.value.object.get("31").?.object.get("earned").?.integer);

    try guard.complete();
    try std.testing.expect(!guard.awaitsGameplay(66088, "30"));
}
