const std = @import("std");
const Client = @import("client.zig").Client;
const user_stats = @import("user_stats.zig");

pub const Session = struct {
    app_id: u32,
    client: Client,

    pub fn close(self: *Session) void {
        self.client.close();
        self.* = undefined;
    }
};

pub fn connect(allocator: std.mem.Allocator, app_id: u32, steam_root: []const u8) !Session {
    return .{
        .app_id = app_id,
        .client = try Client.connect(allocator, app_id, steam_root),
    };
}

pub fn listAchievements(session: *const Session, allocator: std.mem.Allocator) !user_stats.AchievementList {
    return session.client.user_stats.listAchievements(allocator);
}

/// Displays a native 1/2 progress toast through the local Steam client only.
/// It never requests current stats and never calls SetAchievement/StoreStats.
pub fn queueAchievementProgressNotification(session: *Session, allocator: std.mem.Allocator, api_name: []const u8) !void {
    if (api_name.len == 0 or api_name.len > 127 or std.mem.indexOfScalar(u8, api_name, 0) != null) return error.InvalidAchievementApiName;
    const api_name_z = try allocator.dupeZ(u8, api_name);
    defer allocator.free(api_name_z);
    if (!session.client.user_stats.indicateAchievementProgress(api_name_z, 1, 2))
        return error.AchievementProgressNotificationFailed;
}
