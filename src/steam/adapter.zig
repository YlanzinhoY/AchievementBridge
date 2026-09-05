const std = @import("std");
const Client = @import("client.zig").Client;
const user_stats = @import("user_stats.zig");

const preview_store_timeout_ms: u32 = 120_000;
const preview_minimum_store_interval_ms: u32 = 15_000;
const preview_store_attempts: u8 = 3;

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

/// Displays a native 1/2 progress toast without calling SetAchievement or
/// StoreStats. Sync callers may use it after confirming their durable local
/// state; the notification-preview command uses it without writing any state.
pub fn queueAchievementProgressNotification(session: *Session, allocator: std.mem.Allocator, io: std.Io, api_name: []const u8) !void {
    if (api_name.len == 0 or api_name.len > 127 or std.mem.indexOfScalar(u8, api_name, 0) != null) return error.InvalidAchievementApiName;
    const api_name_z = try allocator.dupeZ(u8, api_name);
    defer allocator.free(api_name_z);
    try session.client.loadCurrentUserStats(io, session.app_id, 5000);
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

/// Triggers Steam's real achievement-unlocked toast, keeps it visible long
/// enough for inspection, then restores the original locked state. This is an
/// explicit testing operation and refuses achievements that were already
/// unlocked so their legitimate state and timestamp cannot be destroyed.
pub fn previewAchievementUnlock(
    session: *Session,
    allocator: std.mem.Allocator,
    io: std.Io,
    api_name: []const u8,
    hold_ms: u32,
) !void {
    if (api_name.len == 0 or api_name.len > 127 or std.mem.indexOfScalar(u8, api_name, 0) != null) return error.InvalidAchievementApiName;
    const api_name_z = try allocator.dupeZ(u8, api_name);
    defer allocator.free(api_name_z);

    try session.client.loadCurrentUserStats(io, session.app_id, 10_000);
    if (try session.client.user_stats.isAchievementUnlocked(api_name_z))
        return error.AchievementAlreadyUnlockedForPreview;
    if (!session.client.user_stats.setAchievement(api_name_z))
        return error.SetAchievementFailed;

    var rollback_required = true;
    defer {
        if (rollback_required) rollbackPreviewAchievement(session, io, api_name_z) catch |err|
            std.debug.print("[SteamNotificationPreview] emergency_rollback_error={s}\n", .{@errorName(err)});
    }

    try storePreviewStats(session, io, "unlock");
    if (!try session.client.user_stats.isAchievementUnlocked(api_name_z))
        return error.AchievementPreviewUnlockUnconfirmed;

    // Steam rate-limits StoreStats. Waiting between the unlock and rollback
    // avoids immediately tabling the restoration request.
    const rollback_delay_ms = @max(hold_ms, preview_minimum_store_interval_ms);
    try std.Io.sleep(io, .fromMilliseconds(rollback_delay_ms), .awake);
    try rollbackPreviewAchievement(session, io, api_name_z);
    rollback_required = false;

    try session.client.loadCurrentUserStats(io, session.app_id, 10_000);
    if (try session.client.user_stats.isAchievementUnlocked(api_name_z))
        return error.AchievementPreviewRollbackUnconfirmed;
}

fn rollbackPreviewAchievement(session: *Session, io: std.Io, api_name_z: [*:0]const u8) !void {
    if (!session.client.user_stats.clearAchievement(api_name_z))
        return error.ClearAchievementFailed;
    try storePreviewStats(session, io, "rollback");
}

fn storePreviewStats(session: *Session, io: std.Io, phase: []const u8) !void {
    var attempt: u8 = 1;
    while (attempt <= preview_store_attempts) : (attempt += 1) {
        const drained = try session.client.drainCallbacks();
        if (drained != 0)
            std.debug.print(
                "[SteamNotificationPreview] phase={s} attempt={d} drained_callbacks={d}\n",
                .{ phase, attempt, drained },
            );
        if (!session.client.user_stats.storeStats()) {
            if (attempt == preview_store_attempts) return error.StoreStatsFailed;
            std.debug.print(
                "[SteamNotificationPreview] phase={s} attempt={d} retry=StoreStatsFailed\n",
                .{ phase, attempt },
            );
            try std.Io.sleep(io, .fromMilliseconds(1000), .awake);
            continue;
        }
        session.client.waitForStatsStored(io, session.app_id, preview_store_timeout_ms) catch |err| {
            const retryable = err == error.StoreStatsRejected or
                err == error.StoreStatsRateLimited or
                err == error.StoreStatsCallbackTimeout;
            if (!retryable or attempt == preview_store_attempts) return err;
            std.debug.print(
                "[SteamNotificationPreview] phase={s} attempt={d} retry={s}\n",
                .{ phase, attempt, @errorName(err) },
            );
            const retry_delay_ms: u32 = if (err == error.StoreStatsRejected) 1000 else preview_minimum_store_interval_ms;
            try std.Io.sleep(io, .fromMilliseconds(retry_delay_ms), .awake);
            continue;
        };
        return;
    }
    unreachable;
}
