const std = @import("std");
const AchievementState = @import("../../steam/user_stats.zig").AchievementState;

pub const CatalogInfo = struct {
    achievement_count: usize,
    ignored_legacy_ids: usize,
};

pub const RenderedSchema = struct {
    bytes: []u8,
    info: CatalogInfo,

    pub fn deinit(self: *RenderedSchema, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Converts a Steam achievement catalog into the flat object expected
/// by the Uplay R2-compatible loader. `steam_order + 1` is the objective id;
/// the legacy `id` field is deliberately ignored because scraped catalogs may
/// populate it with unrelated, repeated values.
pub fn renderCatalog(allocator: std.mem.Allocator, bytes: []const u8) !RenderedSchema {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const root = object(parsed.value) orelse return error.InvalidCatalogRoot;
    const game = object(root.get("game") orelse return error.MissingGame) orelse return error.InvalidGame;
    const count_i64 = integer(game.get("achievement_count") orelse return error.MissingAchievementCount) orelse return error.InvalidAchievementCount;
    if (count_i64 <= 0 or count_i64 > 10_000) return error.InvalidAchievementCount;
    const achievement_count: usize = @intCast(count_i64);
    const achievements = array(root.get("achievements") orelse return error.MissingAchievements) orelse return error.InvalidAchievements;
    if (achievements.items.len != achievement_count) return error.AchievementCountMismatch;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    const ordered = try temp.alloc(?std.json.Value, achievement_count);
    @memset(ordered, null);

    var legacy_ids = std.StringHashMap(void).init(temp);
    var ignored_legacy_ids: usize = 0;
    for (achievements.items) |value| {
        const achievement = object(value) orelse return error.InvalidAchievement;
        const order_i64 = integer(achievement.get("steam_order") orelse return error.MissingSteamOrder) orelse return error.InvalidSteamOrder;
        if (order_i64 < 0 or order_i64 >= count_i64) return error.InvalidSteamOrder;
        const order: usize = @intCast(order_i64);
        if (ordered[order] != null) return error.DuplicateSteamOrder;
        _ = string(achievement.get("name") orelse return error.MissingDisplayName) orelse return error.InvalidDisplayName;
        _ = string(achievement.get("description") orelse return error.MissingDescription) orelse return error.InvalidDescription;
        ordered[order] = value;

        if (achievement.get("id")) |legacy_value| if (string(legacy_value)) |legacy_id| {
            ignored_legacy_ids += 1;
            try legacy_ids.put(legacy_id, {});
        };
    }
    for (ordered) |entry| if (entry == null) return error.MissingSteamOrder;

    var schema: std.json.ObjectMap = .empty;
    for (ordered, 0..) |entry, order| {
        const achievement = object(entry.?) orelse unreachable;
        var item: std.json.ObjectMap = .empty;
        try item.put(temp, "displayName", .{ .string = string(achievement.get("name").?).? });
        try item.put(temp, "description", .{ .string = string(achievement.get("description").?).? });
        try item.put(temp, "earned", .{ .integer = 0 });
        const objective_id = try std.fmt.allocPrint(temp, "{d}", .{order + 1});
        try schema.put(temp, objective_id, .{ .object = item });
    }

    const output = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = schema }, .{
        .whitespace = .indent_2,
    });
    return .{
        .bytes = output,
        .info = .{
            .achievement_count = achievement_count,
            .ignored_legacy_ids = if (legacy_ids.count() == ignored_legacy_ids) 0 else ignored_legacy_ids,
        },
    };
}

pub fn enableAchievements(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var found = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const has_cr = raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r';
        const line = if (has_cr) raw_line[0 .. raw_line.len - 1] else raw_line;
        const trimmed = std.mem.trim(u8, line, " \t");
        const separator = std.mem.indexOfScalar(u8, trimmed, '=');
        const is_setting = if (separator) |index|
            std.ascii.eqlIgnoreCase(std.mem.trim(u8, trimmed[0..index], " \t"), "Achievements")
        else
            false;
        if (is_setting) {
            if (found) return error.DuplicateAchievementsSetting;
            found = true;
            try output.appendSlice(allocator, "Achievements = 1");
        } else {
            try output.appendSlice(allocator, line);
        }
        if (has_cr) try output.append(allocator, '\r');
        if (lines.index != null) try output.append(allocator, '\n');
    }
    if (!found) return error.MissingAchievementsSetting;
    return output.toOwnedSlice(allocator);
}

/// Builds the Uplay R2 schema directly from Steam's authoritative catalog.
/// The provider objective id is the numeric suffix of the Steam API name, so
/// the result is reusable for catalogs such as `Outlaws_Ach_19` and
/// `ACObsidian_Ach_30` without a game-specific table.
pub fn renderSteamCatalog(allocator: std.mem.Allocator, achievements: []const AchievementState) ![]u8 {
    if (achievements.len == 0 or achievements.len > 10_000) return error.InvalidAchievementCount;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();
    var schema: std.json.ObjectMap = .empty;
    for (achievements) |achievement| {
        const id = numericSuffix(achievement.api_name) orelse return error.AchievementApiNameHasNoNumericSuffix;
        if (schema.contains(id)) return error.DuplicateAchievementObjectiveId;
        var item: std.json.ObjectMap = .empty;
        try item.put(temp, "displayName", .{ .string = achievement.name });
        try item.put(temp, "description", .{ .string = achievement.description });
        try item.put(temp, "earned", .{ .integer = 0 });
        try schema.put(temp, id, .{ .object = item });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = schema }, .{ .whitespace = .indent_2 });
}

pub fn defaultConfig(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "[Settings]\r\n" ++
        "Language = en-US\r\n" ++
        "Achievements = 1\r\n" ++
        "Logging = 1\r\n" ++
        "SaveType = 0\r\n" ++
        "SavePath =\r\n" ++
        "SaveExtension = .save\r\n");
}

fn numericSuffix(api_name: []const u8) ?[]const u8 {
    var start = api_name.len;
    while (start > 0 and std.ascii.isDigit(api_name[start - 1])) start -= 1;
    if (start == api_name.len) return null;
    const suffix = api_name[start..];
    const value = std.fmt.parseInt(u32, suffix, 10) catch return null;
    if (value == 0) return null;
    return suffix;
}

fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |item| item,
        else => null,
    };
}

fn array(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |item| item,
        else => null,
    };
}

fn string(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |item| item,
        else => null,
    };
}

fn integer(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |item| item,
        else => null,
    };
}

test "catalog uses Steam order and rejects misleading repeated ids" {
    var rendered = try renderCatalog(std.testing.allocator,
        \\{
        \\  "game": {"achievement_count": 2},
        \\  "achievements": [
        \\    {"steam_order": 1, "id": "12", "name": "Templar", "description": "Finish a hunt"},
        \\    {"steam_order": 0, "id": "12", "name": "First", "description": "First description"}
        \\  ]
        \\}
    );
    defer rendered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), rendered.info.achievement_count);
    try std.testing.expectEqual(@as(usize, 2), rendered.info.ignored_legacy_ids);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered.bytes, .{});
    defer parsed.deinit();
    const output = parsed.value.object;
    try std.testing.expectEqualStrings("First", output.get("1").?.object.get("displayName").?.string);
    try std.testing.expectEqualStrings("Templar", output.get("2").?.object.get("displayName").?.string);
    try std.testing.expectEqual(@as(i64, 0), output.get("2").?.object.get("earned").?.integer);
}

test "catalog rejects duplicate Steam order" {
    try std.testing.expectError(error.DuplicateSteamOrder, renderCatalog(std.testing.allocator,
        \\{"game":{"achievement_count":2},"achievements":[
        \\  {"steam_order":0,"name":"A","description":"A"},
        \\  {"steam_order":0,"name":"B","description":"B"}
        \\]}
    ));
}

test "enable achievements preserves CRLF and unrelated settings" {
    const enabled = try enableAchievements(std.testing.allocator, "[Settings]\r\nUsername = user\r\nAchievements = 0\r\nLogging = 0\r\n");
    defer std.testing.allocator.free(enabled);
    try std.testing.expectEqualStrings("[Settings]\r\nUsername = user\r\nAchievements = 1\r\nLogging = 0\r\n", enabled);
}

test "Steam catalog uses API numeric suffix as provider objective" {
    const allocator = std.testing.allocator;
    const achievements = [_]AchievementState{
        .{ .api_name = @constCast("Outlaws_Ach_19"), .name = @constCast("Target"), .description = @constCast("Do it"), .icon = @constCast(""), .icon_gray = @constCast(""), .unlocked = false, .unlock_time = 0, .hidden = false, .global_percent = null },
        .{ .api_name = @constCast("Outlaws_Ach_1"), .name = @constCast("First"), .description = @constCast("Begin"), .icon = @constCast(""), .icon_gray = @constCast(""), .unlocked = false, .unlock_time = 0, .hidden = false, .global_percent = null },
    };
    const rendered = try renderSteamCatalog(allocator, &achievements);
    defer allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Target", parsed.value.object.get("19").?.object.get("displayName").?.string);
    try std.testing.expectEqualStrings("First", parsed.value.object.get("1").?.object.get("displayName").?.string);
}
