const std = @import("std");
const event = @import("event.zig");
const MetadataCatalog = @import("metadata.zig").Catalog;

pub const MappingMethod = enum {
    exact_api_name,
    numeric_suffix,
};

pub const Mapping = struct {
    canonical_app_id: u32,
    canonical_achievement_id: []const u8,
    method: MappingMethod,
    confidence: u8,
};

pub fn mapExact(achievement: event.AchievementEvent, catalog: *const MetadataCatalog) ?Mapping {
    const details = catalog.get(achievement.source_id) orelse return null;
    return .{
        .canonical_app_id = achievement.app_id,
        .canonical_achievement_id = details.api_name,
        .method = .exact_api_name,
        .confidence = 100,
    };
}

pub fn mapNumericSuffix(source_id: []const u8, canonical_app_id: u32, catalog: *const MetadataCatalog) ?Mapping {
    if (source_id.len == 0) return null;
    for (source_id) |character| if (!std.ascii.isDigit(character)) return null;
    var match: ?[]const u8 = null;
    var iterator = catalog.entries.keyIterator();
    while (iterator.next()) |api_name| {
        var digit_start = api_name.len;
        while (digit_start > 0 and std.ascii.isDigit(api_name.*[digit_start - 1])) digit_start -= 1;
        if (digit_start == api_name.len or !std.mem.eql(u8, api_name.*[digit_start..], source_id)) continue;
        if (match != null) return null;
        match = api_name.*;
    }
    return .{
        .canonical_app_id = canonical_app_id,
        .canonical_achievement_id = match orelse return null,
        .method = .numeric_suffix,
        .confidence = 95,
    };
}

test "exact API name mapping requires verified metadata" {
    var catalog = MetadataCatalog.init(std.testing.allocator);
    defer catalog.deinit();
    try catalog.put(.{
        .api_name = try std.testing.allocator.dupe(u8, "ACH_BOSS"),
        .name = try std.testing.allocator.dupe(u8, "Boss"),
        .description = try std.testing.allocator.dupe(u8, ""),
        .icon = try std.testing.allocator.dupe(u8, ""),
    });
    const mapping = mapExact(.{
        .app_id = 42,
        .source_id = "ACH_BOSS",
        .unlocked_at = 1,
        .detected_at = 1,
    }, &catalog).?;
    try std.testing.expectEqual(@as(u8, 100), mapping.confidence);
}

test "numeric Ubisoft objective maps to a unique Steam API suffix" {
    var catalog = MetadataCatalog.init(std.testing.allocator);
    defer catalog.deinit();
    try catalog.put(.{
        .api_name = try std.testing.allocator.dupe(u8, "ACObsidian_Ach_19"),
        .name = try std.testing.allocator.dupe(u8, "Gunslinger"),
        .description = try std.testing.allocator.dupe(u8, ""),
        .icon = try std.testing.allocator.dupe(u8, ""),
    });
    const mapping = mapNumericSuffix("19", 3751950, &catalog).?;
    try std.testing.expectEqualStrings("ACObsidian_Ach_19", mapping.canonical_achievement_id);
    try std.testing.expectEqual(@as(u8, 95), mapping.confidence);
}
