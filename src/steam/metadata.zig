const std = @import("std");
const core_metadata = @import("../core/metadata.zig");
const adapter = @import("adapter.zig");

pub fn loadInto(
    catalog: *core_metadata.Catalog,
    allocator: std.mem.Allocator,
    app_id: u32,
    steam_root: []const u8,
) !void {
    var session = try adapter.connect(allocator, app_id, steam_root);
    defer session.close();
    var achievements = try adapter.listAchievements(&session, allocator);
    defer achievements.deinit();
    for (achievements.items.items) |achievement| {
        const api_name = try allocator.dupe(u8, achievement.api_name);
        errdefer allocator.free(api_name);
        const name = try allocator.dupe(u8, achievement.name);
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, achievement.description);
        errdefer allocator.free(description);
        try catalog.put(.{
            .api_name = api_name,
            .name = name,
            .description = description,
            .icon = try allocator.dupe(u8, ""),
            .hidden = achievement.hidden,
            .global_percent = achievement.global_percent,
        });
    }
}
