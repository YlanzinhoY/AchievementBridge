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

pub const UnlockResult = enum {
    already_unlocked,
    stored,
};

pub const NotificationRequestResult = enum {
    already_unlocked,
    store_queued,
    progress_queued,
};

pub fn isAchievementUnlocked(session: *const Session, allocator: std.mem.Allocator, api_name: []const u8) !bool {
    if (api_name.len == 0 or api_name.len > 127 or std.mem.indexOfScalar(u8, api_name, 0) != null) return error.InvalidAchievementApiName;
    const api_name_z = try allocator.dupeZ(u8, api_name);
    defer allocator.free(api_name_z);
    return session.client.user_stats.isAchievementUnlocked(api_name_z);
}

/// Displays the native progress toast only after the caller has independently
/// confirmed that the local Steam state contains the achievement.
pub fn queueAchievementProgressNotification(session: *Session, allocator: std.mem.Allocator, io: std.Io, api_name: []const u8) !void {
    if (api_name.len == 0 or api_name.len > 127 or std.mem.indexOfScalar(u8, api_name, 0) != null) return error.InvalidAchievementApiName;
    const api_name_z = try allocator.dupeZ(u8, api_name);
    defer allocator.free(api_name_z);
    try session.client.loadCurrentUserStats(io, session.app_id, 5000);
    if (!try session.client.user_stats.isAchievementUnlocked(api_name_z)) return error.AchievementNotConfirmed;
    if (!session.client.user_stats.indicateAchievementProgress(api_name_z, 1, 2))
        return error.AchievementProgressNotificationFailed;
}

/// Experimental notification path. It first tries the normal achievement write.
/// If Steam refuses SetAchievement, it asks the overlay for a 1/2 progress toast
/// for the same API name; that fallback changes no Steam achievement state.
pub fn queueAchievementNotification(session: *Session, allocator: std.mem.Allocator, io: std.Io, api_name: []const u8) !NotificationRequestResult {
    if (api_name.len == 0 or api_name.len > 127 or std.mem.indexOfScalar(u8, api_name, 0) != null) return error.InvalidAchievementApiName;
    const api_name_z = try allocator.dupeZ(u8, api_name);
    defer allocator.free(api_name_z);
    try session.client.loadCurrentUserStats(io, session.app_id, 5000);
    if (try session.client.user_stats.isAchievementUnlocked(api_name_z)) return .already_unlocked;
    var set = false;
    for (0..3) |_| {
        if (session.client.user_stats.setAchievement(api_name_z)) {
            set = true;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
    if (!set) {
        if (!session.client.user_stats.indicateAchievementProgress(api_name_z, 1, 2))
            return error.AchievementProgressNotificationFailed;
        return .progress_queued;
    }
    if (!session.client.user_stats.storeStats()) return error.StoreStatsFailed;
    return .store_queued;
}

/// Explicit write operation. The caller is responsible for presenting an
/// opt-in boundary before invoking this function.
pub fn unlockAchievement(session: *Session, allocator: std.mem.Allocator, io: std.Io, api_name: []const u8) !UnlockResult {
    if (api_name.len == 0 or api_name.len > 127 or std.mem.indexOfScalar(u8, api_name, 0) != null) return error.InvalidAchievementApiName;
    const api_name_z = try allocator.dupeZ(u8, api_name);
    defer allocator.free(api_name_z);
    try session.client.loadCurrentUserStats(io, session.app_id, 10_000);
    if (try session.client.user_stats.isAchievementUnlocked(api_name_z)) return .already_unlocked;
    var set = false;
    for (0..3) |_| {
        if (session.client.user_stats.setAchievement(api_name_z)) {
            set = true;
            break;
        }
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
    if (!set) return error.SetAchievementFailed;
    if (!session.client.user_stats.storeStats()) return error.StoreStatsFailed;
    try session.client.waitForStatsStored(io, session.app_id, 10_000);
    return .stored;
}
