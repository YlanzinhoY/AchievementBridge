const std = @import("std");
const event = @import("../../core/event.zig");

pub const ParseError = error{
    InvalidRoot,
    InvalidAchievement,
};

pub const AchievementState = struct {
    earned: bool = false,
    earned_time: i64 = 0,
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    achievements: std.StringHashMap(AchievementState),

    pub fn init(allocator: std.mem.Allocator) Snapshot {
        return .{
            .allocator = allocator,
            .achievements = std.StringHashMap(AchievementState).init(allocator),
        };
    }

    pub fn deinit(self: *Snapshot) void {
        var keys = self.achievements.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.achievements.deinit();
        self.* = undefined;
    }

    pub fn unlockedCount(self: *const Snapshot) usize {
        var count: usize = 0;
        var values = self.achievements.valueIterator();
        while (values.next()) |state| {
            if (state.earned) count += 1;
        }
        return count;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return ParseError.InvalidRoot,
    };

    var result = Snapshot.init(allocator);
    errdefer result.deinit();

    var iterator = root.iterator();
    while (iterator.next()) |entry| {
        const state = try parseState(entry.value_ptr.*);
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        try result.achievements.put(name, state);
    }
    return result;
}

fn parseState(value: std.json.Value) ParseError!AchievementState {
    if (value == .bool) return .{ .earned = value.bool };
    const object = switch (value) {
        .object => |object| object,
        else => return ParseError.InvalidAchievement,
    };

    const earned_value = object.get("earned") orelse
        object.get("Achieved") orelse
        object.get("unlocked");
    const timestamp_value = object.get("earned_time") orelse
        object.get("unlock_time") orelse
        object.get("UnlockTime");

    return .{
        .earned = if (earned_value) |item| truthy(item) else false,
        .earned_time = if (timestamp_value) |item| integer(item) else 0,
    };
}

fn truthy(value: std.json.Value) bool {
    return switch (value) {
        .bool => |item| item,
        .integer => |item| item != 0,
        .float => |item| item != 0,
        .string => |item| std.mem.eql(u8, item, "1") or std.ascii.eqlIgnoreCase(item, "true"),
        else => false,
    };
}

fn integer(value: std.json.Value) i64 {
    return switch (value) {
        .integer => |item| item,
        .float => |item| @intFromFloat(item),
        .string => |item| std.fmt.parseInt(i64, item, 10) catch 0,
        else => 0,
    };
}

pub fn diffUnlocked(
    allocator: std.mem.Allocator,
    app_id: u32,
    before: *const Snapshot,
    after: *const Snapshot,
    detected_at: i64,
) ![]event.AchievementEvent {
    var events: std.ArrayList(event.AchievementEvent) = .empty;
    errdefer events.deinit(allocator);

    var iterator = after.achievements.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value_ptr.earned) continue;
        const previous = before.achievements.get(entry.key_ptr.*);
        if (previous != null and previous.?.earned) continue;
        try events.append(allocator, .{
            .app_id = app_id,
            .source_id = entry.key_ptr.*,
            .unlocked_at = if (entry.value_ptr.earned_time > 0) entry.value_ptr.earned_time else detected_at,
            .detected_at = detected_at,
        });
    }
    return events.toOwnedSlice(allocator);
}

test "parse GSE snapshot and detect locked to unlocked" {
    const allocator = std.testing.allocator;
    var before = try parse(allocator,
        \\{
        \\  "ACH_FIRST": {"earned": false, "earned_time": 0},
        \\  "ACH_OLD": {"earned": true, "earned_time": 100}
        \\}
    );
    defer before.deinit();

    var after = try parse(allocator,
        \\{
        \\  "ACH_FIRST": {"earned": true, "earned_time": 1234},
        \\  "ACH_OLD": {"earned": true, "earned_time": 100}
        \\}
    );
    defer after.deinit();

    const events = try diffUnlocked(allocator, 1145350, &before, &after, 2000);
    defer allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ACH_FIRST", events[0].source_id);
    try std.testing.expectEqual(@as(i64, 1234), events[0].unlocked_at);
}

test "accept common Goldberg-compatible truthy encodings" {
    const allocator = std.testing.allocator;
    var value = try parse(allocator,
        \\{"A":{"earned":1},"B":{"Achieved":true},"C":{"unlocked":"true"}}
    );
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 3), value.unlockedCount());
}
