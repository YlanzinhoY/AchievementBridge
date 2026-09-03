const std = @import("std");
const event = @import("../../core/event.zig");

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
        while (values.next()) |state| if (state.earned) {
            count += 1;
        };
        return count;
    }
};

/// Parses RUNE's per-game achievements.ini. Only API-name sections are state;
/// the trailing [SteamAchievements] section is an index and must be ignored.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var result = Snapshot.init(allocator);
    errdefer result.deinit();

    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            current_section = if (name.len == 0 or std.ascii.eqlIgnoreCase(name, "SteamAchievements")) null else name;
            continue;
        }

        const section = current_section orelse continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "Achieved") and !std.ascii.eqlIgnoreCase(key, "UnlockTime")) continue;

        const entry = try getOrPut(&result, section);
        if (std.ascii.eqlIgnoreCase(key, "Achieved")) {
            entry.earned = std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
        } else {
            entry.earned_time = std.fmt.parseInt(i64, value, 10) catch 0;
        }
    }
    return result;
}

fn getOrPut(snapshot: *Snapshot, api_name: []const u8) !*AchievementState {
    if (snapshot.achievements.getPtr(api_name)) |existing| return existing;
    const owned = try snapshot.allocator.dupe(u8, api_name);
    errdefer snapshot.allocator.free(owned);
    try snapshot.achievements.put(owned, .{});
    return snapshot.achievements.getPtr(owned).?;
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
            .provider = .rune,
            .unlocked_at = if (entry.value_ptr.earned_time > 0) entry.value_ptr.earned_time else detected_at,
            .detected_at = detected_at,
        });
    }
    return events.toOwnedSlice(allocator);
}

test "parse RUNE achievements ini and ignore index section" {
    var state = try parse(std.testing.allocator,
        \\[ACHIEVEMENT_02]
        \\Achieved=1
        \\CurProgress=0
        \\MaxProgress=0
        \\UnlockTime=1788325557
        \\
        \\[SteamAchievements]
        \\00000=ACHIEVEMENT_02
        \\Count=1
    );
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.achievements.count());
    try std.testing.expectEqual(@as(usize, 1), state.unlockedCount());
    try std.testing.expectEqual(@as(i64, 1788325557), state.achievements.get("ACHIEVEMENT_02").?.earned_time);
}

test "detect a newly appended RUNE achievement" {
    var before = try parse(std.testing.allocator,
        \\[ACHIEVEMENT_02]
        \\Achieved=1
        \\UnlockTime=100
    );
    defer before.deinit();
    var after = try parse(std.testing.allocator,
        \\[ACHIEVEMENT_02]
        \\Achieved=1
        \\UnlockTime=100
        \\[ACHIEVEMENT_03]
        \\Achieved=1
        \\UnlockTime=200
    );
    defer after.deinit();
    const events = try diffUnlocked(std.testing.allocator, 3046600, &before, &after, 300);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("ACHIEVEMENT_03", events[0].source_id);
    try std.testing.expectEqual(event.ProviderKind.rune, events[0].provider);
    try std.testing.expectEqual(@as(i64, 200), events[0].unlocked_at);
}
