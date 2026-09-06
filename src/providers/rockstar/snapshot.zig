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

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyRockstarAchievementState;
    if (trimmed[0] == '{' or looksLikeJsonArray(trimmed)) return parseJson(allocator, trimmed);
    return parseIni(allocator, trimmed);
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !Snapshot {
    const name = std.fs.path.basename(path);
    if (std.ascii.startsWithIgnoreCase(name, "SGTA")) return parseGtaSave(allocator, bytes);
    return parse(allocator, bytes);
}

fn parseGtaSave(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    // Rockstar stores the autosave label as UTF-16LE in the public 260-byte
    // header. The completion percentage is enough to prove ACH00: the first
    // story achievement is awarded at the end of "Franklin and Lamar" (1.6%).
    if (bytes.len < 8) return error.UnsupportedRockstarAchievementState;
    var label_buffer: [256]u8 = undefined;
    var label_len: usize = 0;
    var index: usize = 4;
    const end = @min(bytes.len, 260);
    while (index + 1 < end and label_len < label_buffer.len) : (index += 2) {
        if (bytes[index] == 0 and bytes[index + 1] == 0) break;
        if (bytes[index + 1] != 0) continue;
        label_buffer[label_len] = bytes[index];
        label_len += 1;
    }
    const label = label_buffer[0..label_len];
    const progress = gtaCompletionPercent(label) orelse return error.UnsupportedRockstarAchievementState;
    var result = Snapshot.init(allocator);
    errdefer result.deinit();
    try put(&result, "ACH00", .{ .earned = progress >= 1.6 });
    return result;
}

fn gtaCompletionPercent(label: []const u8) ?f64 {
    const percent_index = std.mem.indexOfScalar(u8, label, '%') orelse return null;
    var start = percent_index;
    while (start > 0) {
        const character = label[start - 1];
        if (!std.ascii.isDigit(character) and character != '.' and character != ',') break;
        start -= 1;
    }
    if (start == percent_index) return null;
    var number_buffer: [32]u8 = undefined;
    const number = label[start..percent_index];
    if (number.len > number_buffer.len) return null;
    for (number, 0..) |character, offset| number_buffer[offset] = if (character == ',') '.' else character;
    return std.fmt.parseFloat(f64, number_buffer[0..number.len]) catch null;
}

fn looksLikeJsonArray(bytes: []const u8) bool {
    if (bytes.len < 2 or bytes[0] != '[') return false;
    var index: usize = 1;
    while (index < bytes.len and std.ascii.isWhitespace(bytes[index])) : (index += 1) {}
    return index < bytes.len and (bytes[index] == '{' or bytes[index] == ']' or bytes[index] == '"');
}

fn parseJson(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    var result = Snapshot.init(allocator);
    errdefer result.deinit();
    try appendJsonCollection(&result, parsed.value);
    if (result.achievements.count() == 0) return error.UnsupportedRockstarAchievementState;
    return result;
}

fn appendJsonCollection(result: *Snapshot, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            if (object.get("Achievements") orelse object.get("achievements")) |nested| {
                try appendJsonCollection(result, nested);
                return;
            }
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                if (parseJsonState(entry.value_ptr.*)) |state| {
                    try put(result, entry.key_ptr.*, state);
                }
            }
        },
        .array => |items| for (items.items) |item| {
            const object = switch (item) {
                .object => |object| object,
                else => continue,
            };
            const id_value = object.get("api_name") orelse object.get("name") orelse
                object.get("id") orelse object.get("AchievementId") orelse continue;
            const id = switch (id_value) {
                .string => |text| text,
                .integer => |number| try std.fmt.allocPrint(result.allocator, "{d}", .{number}),
                else => continue,
            };
            defer if (id_value == .integer) result.allocator.free(id);
            if (parseJsonState(item)) |state| try put(result, id, state);
        },
        else => return error.UnsupportedRockstarAchievementState,
    }
}

fn parseJsonState(value: std.json.Value) ?AchievementState {
    switch (value) {
        .bool, .integer, .float, .string => return .{ .earned = truthy(value) },
        .object => |object| {
            const earned_value = object.get("earned") orelse object.get("Earned") orelse
                object.get("achieved") orelse object.get("Achieved") orelse
                object.get("unlocked") orelse object.get("Unlocked") orelse
                object.get("HaveAchieved") orelse object.get("State") orelse return null;
            const timestamp_value = object.get("earned_time") orelse object.get("unlock_time") orelse
                object.get("UnlockTime") orelse object.get("HaveAchievedTime") orelse
                object.get("DateAchieved") orelse object.get("Time");
            return .{
                .earned = truthy(earned_value),
                .earned_time = if (timestamp_value) |timestamp| integer(timestamp) else 0,
            };
        },
        else => return null,
    }
}

fn parseIni(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var result = Snapshot.init(allocator);
    errdefer result.deinit();
    var current_section: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            const section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            current_section = if (section.len == 0 or std.ascii.eqlIgnoreCase(section, "Achievements") or
                std.ascii.eqlIgnoreCase(section, "SteamAchievements")) null else section;
            continue;
        }
        const section = current_section orelse continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
        const state = try getOrPut(&result, section);
        if (isEarnedKey(key)) {
            state.earned = textTruthy(value);
        } else if (isTimestampKey(key)) {
            state.earned_time = std.fmt.parseInt(i64, value, 10) catch 0;
        }
    }
    if (result.achievements.count() == 0) return error.UnsupportedRockstarAchievementState;
    return result;
}

fn put(snapshot: *Snapshot, id: []const u8, state: AchievementState) !void {
    if (id.len == 0 or id.len > 255) return;
    const owned = try snapshot.allocator.dupe(u8, id);
    errdefer snapshot.allocator.free(owned);
    const entry = try snapshot.achievements.getOrPut(owned);
    if (entry.found_existing) snapshot.allocator.free(owned);
    entry.value_ptr.* = state;
}

fn getOrPut(snapshot: *Snapshot, id: []const u8) !*AchievementState {
    if (snapshot.achievements.getPtr(id)) |existing| return existing;
    const owned = try snapshot.allocator.dupe(u8, id);
    errdefer snapshot.allocator.free(owned);
    try snapshot.achievements.put(owned, .{});
    return snapshot.achievements.getPtr(owned).?;
}

fn truthy(value: std.json.Value) bool {
    return switch (value) {
        .bool => |item| item,
        .integer => |item| item != 0,
        .float => |item| item != 0,
        .string => |item| textTruthy(item),
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

fn textTruthy(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "unlocked") or std.ascii.eqlIgnoreCase(value, "achieved");
}

fn isEarnedKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "Achieved") or std.ascii.eqlIgnoreCase(key, "Earned") or
        std.ascii.eqlIgnoreCase(key, "Unlocked") or std.ascii.eqlIgnoreCase(key, "HaveAchieved") or
        std.ascii.eqlIgnoreCase(key, "State");
}

fn isTimestampKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "UnlockTime") or std.ascii.eqlIgnoreCase(key, "earned_time") or
        std.ascii.eqlIgnoreCase(key, "DateAchieved") or std.ascii.eqlIgnoreCase(key, "HaveAchievedTime") or
        std.ascii.eqlIgnoreCase(key, "Time");
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
            .provider = .rockstar,
            .unlocked_at = if (entry.value_ptr.earned_time > 0) entry.value_ptr.earned_time else detected_at,
            .detected_at = detected_at,
        });
    }
    return events.toOwnedSlice(allocator);
}

test "parse Rockstar compatible JSON and INI snapshots" {
    var json = try parse(std.testing.allocator,
        \\{"Achievements":{"ACH00":{"Achieved":true,"DateAchieved":123},"ACH01":{"Achieved":false}}}
    );
    defer json.deinit();
    try std.testing.expectEqual(@as(usize, 1), json.unlockedCount());
    try std.testing.expectEqual(@as(i64, 123), json.achievements.get("ACH00").?.earned_time);

    var ini = try parse(std.testing.allocator,
        \\[ACH00]
        \\Achieved=1
        \\UnlockTime=456
    );
    defer ini.deinit();
    try std.testing.expect(ini.achievements.get("ACH00").?.earned);
}

test "Rockstar diff emits only a new verified unlock" {
    var before = try parse(std.testing.allocator, "{\"ACH00\":false,\"ACH01\":false}");
    defer before.deinit();
    var after = try parse(std.testing.allocator, "{\"ACH00\":true,\"ACH01\":false}");
    defer after.deinit();
    const events = try diffUnlocked(std.testing.allocator, 3240220, &before, &after, 500);
    defer std.testing.allocator.free(events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(event.ProviderKind.rockstar, events[0].provider);
    try std.testing.expectEqualStrings("ACH00", events[0].source_id);
}

test "parse GTA save header as verified first story milestone" {
    const label = "(Autoarmazenamento) Franklin e Lamar (1.6%) - 09/06/26 02:25:33";
    var bytes = [_]u8{0} ** 260;
    for (label, 0..) |character, offset| bytes[4 + offset * 2] = character;
    var save = try parseFile(std.testing.allocator, "SGTA50015", &bytes);
    defer save.deinit();
    try std.testing.expect(save.achievements.get("ACH00").?.earned);
}

test "GTA prologue save keeps first story milestone locked" {
    const label = "(Autoarmazenamento) Prologo (0,8%) - 09/06/26 02:01:18";
    var bytes = [_]u8{0} ** 260;
    for (label, 0..) |character, offset| bytes[4 + offset * 2] = character;
    var save = try parseFile(std.testing.allocator, "SGTA50015", &bytes);
    defer save.deinit();
    try std.testing.expect(!save.achievements.get("ACH00").?.earned);
}
