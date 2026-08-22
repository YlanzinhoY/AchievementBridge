const std = @import("std");
const local_store = @import("local/store.zig");
const user_stats = @import("steam/user_stats.zig");

const CatalogAchievement = struct {
    api_name: []const u8,
    name: []const u8,
    description: []const u8,
    icon: ?[]const u8,
    icon_gray: ?[]const u8,
    unlocked: bool,
    unlocked_at: ?i64,
    state_source: []const u8,
    hidden: bool,
    global_percent: ?f32,
};

const CatalogDocument = struct {
    schema_version: u32 = 1,
    kind: []const u8 = "achievement_catalog",
    app_id: u32,
    metadata_source: []const u8 = "steam_client",
    achievements: []const CatalogAchievement,
};

/// Produces the stable JSON contract consumed by desktop clients. Steam is authoritative whenever
/// its current client state says an achievement is unlocked; the local store can only promote a
/// locked entry for local display and never writes back through ISteamUserStats.
pub fn renderSteam(
    allocator: std.mem.Allocator,
    app_id: u32,
    achievements: []const user_stats.AchievementState,
    local: ?*const local_store.Store,
) ![]u8 {
    var items: std.ArrayList(CatalogAchievement) = .empty;
    defer items.deinit(allocator);
    try items.ensureTotalCapacity(allocator, achievements.len);

    for (achievements) |achievement| {
        const local_time = if (local) |store| store.unlockedAt(app_id, achievement.api_name) else null;
        const locally_unlocked = local_time != null;
        const unlocked_at: ?i64 = if (achievement.unlocked)
            if (achievement.unlock_time > 0) achievement.unlock_time else null
        else
            local_time;
        items.appendAssumeCapacity(.{
            .api_name = achievement.api_name,
            .name = achievement.name,
            .description = achievement.description,
            .icon = if (achievement.icon.len > 0) achievement.icon else null,
            .icon_gray = if (achievement.icon_gray.len > 0) achievement.icon_gray else null,
            .unlocked = achievement.unlocked or locally_unlocked,
            .unlocked_at = unlocked_at,
            .state_source = if (achievement.unlocked) "steam_client" else if (locally_unlocked) "local_store" else "steam_client",
            .hidden = achievement.hidden,
            .global_percent = achievement.global_percent,
        });
    }

    return std.json.Stringify.valueAlloc(allocator, CatalogDocument{
        .app_id = app_id,
        .achievements = items.items,
    }, .{});
}

test "Steam catalog keeps Steam priority and merges a local unlock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "local.json" });
    defer allocator.free(path);
    var local = try local_store.Store.init(allocator, std.testing.io, path);
    defer local.deinit();
    try local.record(42, "ACH_LOCAL", 123);

    var list = user_stats.AchievementList{ .allocator = allocator };
    defer list.deinit();
    for ([_]struct { id: []const u8, unlocked: bool, time: i64 }{
        .{ .id = "ACH_STEAM", .unlocked = true, .time = 456 },
        .{ .id = "ACH_LOCAL", .unlocked = false, .time = 0 },
    }) |fixture| try list.items.append(allocator, .{
        .api_name = try allocator.dupe(u8, fixture.id),
        .name = try allocator.dupe(u8, fixture.id),
        .description = try allocator.dupe(u8, "description"),
        .icon = try allocator.dupe(u8, "hash.jpg"),
        .icon_gray = try allocator.dupe(u8, "gray.jpg"),
        .unlocked = fixture.unlocked,
        .unlock_time = fixture.time,
        .hidden = false,
        .global_percent = 10,
    });

    const json = try renderSteam(allocator, 42, list.items.items, &local);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state_source\":\"steam_client\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state_source\":\"local_store\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unlocked_at\":123") != null);
}
