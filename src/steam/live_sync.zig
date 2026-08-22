const std = @import("std");
const adapter = @import("adapter.zig");
const cloud_ipc = @import("cloud_ipc.zig");
const local_cache = @import("local_cache.zig");
const schema = @import("schema.zig");
const steam_install = @import("../detector/steam_install.zig");

pub const HostStatus = enum {
    captured,
    unavailable,
    app_not_managed,
    stats_sync_disabled,
    rejected,
};

pub const NativeNotificationStatus = enum {
    not_requested,
    not_new,
    store_queued,
    progress_queued,
    already_unlocked,
    steam_unavailable,
    stats_unavailable,
    set_failed,
    progress_failed,
    store_failed,
};

pub const Options = struct {
    app_id: u32,
    api_name: []const u8,
    unlock_time: u32,
    steam_root: []const u8,
    backup_root: []const u8,
    account_id: ?u32 = null,
    experimental_native_notification: bool = false,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    changed: bool,
    account_id: u32,
    stat_id: u32,
    bit: u5,
    permission: i32,
    unlock_time: u32,
    crc: u32,
    host_status: HostStatus,
    steam_refreshed: bool,
    native_notification: NativeNotificationStatus,
    stats_path: []u8,
    backup_path: ?[]u8,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.stats_path);
        if (self.backup_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
};

pub const ClearOptions = struct {
    app_id: u32,
    api_name: []const u8,
    steam_root: []const u8,
    backup_root: []const u8,
    account_id: ?u32 = null,
};

pub const ClearResult = struct {
    allocator: std.mem.Allocator,
    changed: bool,
    account_id: u32,
    stat_id: u32,
    bit: u5,
    permission: i32,
    crc: u32,
    stats_path: []u8,
    backup_path: ?[]u8,

    pub fn deinit(self: *ClearResult) void {
        self.allocator.free(self.stats_path);
        if (self.backup_path) |path| self.allocator.free(path);
        self.* = undefined;
    }
};

/// Persists one provider unlock in Steam's native local cache and asks the
/// in-process proxy to recapture it. Host refresh failures are reported as a
/// status instead of rolling back the durable local state.
pub fn sync(allocator: std.mem.Allocator, io: std.Io, options: Options) !Result {
    if (options.app_id == 0) return error.InvalidSteamAppId;
    if (options.unlock_time == 0) return error.InvalidAchievementUnlockTime;

    const schema_name = try std.fmt.allocPrint(allocator, "UserGameStatsSchema_{d}.bin", .{options.app_id});
    defer allocator.free(schema_name);
    const schema_path = try std.fs.path.join(allocator, &.{ options.steam_root, "appcache", "stats", schema_name });
    defer allocator.free(schema_path);
    const schema_bytes = try std.Io.Dir.cwd().readFileAlloc(io, schema_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(schema_bytes);
    const location = try schema.findAchievement(allocator, schema_bytes, options.app_id, options.api_name);

    const account_id = options.account_id orelse (steam_install.findActiveAccountId() catch
        try findStatsAccountId(allocator, io, options.steam_root, options.app_id));
    const stats_name = try std.fmt.allocPrint(allocator, "UserGameStats_{d}_{d}.bin", .{ account_id, options.app_id });
    defer allocator.free(stats_name);
    const stats_path = try std.fs.path.join(allocator, &.{ options.steam_root, "appcache", "stats", stats_name });
    errdefer allocator.free(stats_path);

    const existing = std.Io.Dir.cwd().readFileAlloc(io, stats_path, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => try allocator.alloc(u8, 0),
        else => return err,
    };
    defer allocator.free(existing);
    var mutation = try local_cache.unlock(allocator, existing, location.stat_id, location.bit, options.unlock_time);
    defer mutation.deinit(allocator);

    const native_notification: NativeNotificationStatus = if (!options.experimental_native_notification)
        .not_requested
    else if (!mutation.changed)
        .not_new
    else
        tryNativeNotification(allocator, io, options.app_id, options.api_name, options.steam_root);

    var backup_path: ?[]u8 = null;
    errdefer if (backup_path) |path| allocator.free(path);
    if (mutation.changed) {
        if (existing.len > 0) backup_path = try backup(allocator, io, options.backup_root, options.app_id, stats_name, existing);
        try writeAtomic(io, stats_path, mutation.bytes);
    }

    const host_status: HostStatus = blk: {
        cloud_ipc.captureNativeStats(options.app_id, location.stat_id, location.bit, mutation.unlock_time, 1500) catch |err| {
            break :blk switch (err) {
                error.AchievementCloudHostUnavailable, error.CloudRedirectUnavailable => .unavailable,
                error.AchievementAppNotManaged => .app_not_managed,
                error.AchievementStatsSyncDisabled => .stats_sync_disabled,
                else => .rejected,
            };
        };
        break :blk .captured;
    };

    var steam_refreshed = false;
    if (host_status == .captured) {
        if (adapter.connect(allocator, options.app_id, options.steam_root)) |session_value| {
            var session = session_value;
            defer session.close();
            if (session.client.loadCurrentUserStats(io, options.app_id, 5000)) |_| {
                steam_refreshed = true;
            } else |_| {}
        } else |_| {}
    }

    return .{
        .allocator = allocator,
        .changed = mutation.changed,
        .account_id = account_id,
        .stat_id = location.stat_id,
        .bit = location.bit,
        .permission = location.permission,
        .unlock_time = mutation.unlock_time,
        .crc = mutation.crc,
        .host_status = host_status,
        .steam_refreshed = steam_refreshed,
        .native_notification = native_notification,
        .stats_path = stats_path,
        .backup_path = backup_path,
    };
}

/// Controlled local reset used to verify the unlock pipeline. The caller must
/// require explicit confirmation and ensure Steam is stopped before entering.
pub fn clear(allocator: std.mem.Allocator, io: std.Io, options: ClearOptions) !ClearResult {
    if (options.app_id == 0) return error.InvalidSteamAppId;

    const schema_name = try std.fmt.allocPrint(allocator, "UserGameStatsSchema_{d}.bin", .{options.app_id});
    defer allocator.free(schema_name);
    const schema_path = try std.fs.path.join(allocator, &.{ options.steam_root, "appcache", "stats", schema_name });
    defer allocator.free(schema_path);
    const schema_bytes = try std.Io.Dir.cwd().readFileAlloc(io, schema_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(schema_bytes);
    const location = try schema.findAchievement(allocator, schema_bytes, options.app_id, options.api_name);

    const account_id = options.account_id orelse (steam_install.findActiveAccountId() catch
        try findStatsAccountId(allocator, io, options.steam_root, options.app_id));
    const stats_name = try std.fmt.allocPrint(allocator, "UserGameStats_{d}_{d}.bin", .{ account_id, options.app_id });
    defer allocator.free(stats_name);
    const stats_path = try std.fs.path.join(allocator, &.{ options.steam_root, "appcache", "stats", stats_name });
    errdefer allocator.free(stats_path);
    const existing = try std.Io.Dir.cwd().readFileAlloc(io, stats_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(existing);
    var mutation = try local_cache.clearAchievement(allocator, existing, location.stat_id, location.bit);
    defer mutation.deinit(allocator);

    var backup_path: ?[]u8 = null;
    errdefer if (backup_path) |path| allocator.free(path);
    if (mutation.changed) {
        backup_path = try backup(allocator, io, options.backup_root, options.app_id, stats_name, existing);
        try writeAtomic(io, stats_path, mutation.bytes);
    }
    return .{
        .allocator = allocator,
        .changed = mutation.changed,
        .account_id = account_id,
        .stat_id = location.stat_id,
        .bit = location.bit,
        .permission = location.permission,
        .crc = mutation.crc,
        .stats_path = stats_path,
        .backup_path = backup_path,
    };
}

fn tryNativeNotification(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_id: u32,
    api_name: []const u8,
    steam_root: []const u8,
) NativeNotificationStatus {
    var session = adapter.connect(allocator, app_id, steam_root) catch return .steam_unavailable;
    defer session.close();
    const queued = adapter.queueAchievementNotification(&session, allocator, io, api_name) catch |err| return switch (err) {
        error.UserStatsRequestFailed,
        error.UserStatsRequestRejected,
        error.UserStatsCallbackTimeout,
        error.GetAchievementFailed,
        => .stats_unavailable,
        error.AchievementProgressNotificationFailed => .progress_failed,
        error.StoreStatsFailed => .store_failed,
        else => .steam_unavailable,
    };
    return switch (queued) {
        .already_unlocked => .already_unlocked,
        .store_queued => .store_queued,
        .progress_queued => .progress_queued,
    };
}

fn findStatsAccountId(allocator: std.mem.Allocator, io: std.Io, steam_root: []const u8, app_id: u32) !u32 {
    const stats_root = try std.fs.path.join(allocator, &.{ steam_root, "appcache", "stats" });
    defer allocator.free(stats_root);
    var directory = try std.Io.Dir.cwd().openDir(io, stats_root, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var found: ?u32 = null;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const candidate = parseStatsAccountId(entry.name, app_id) orelse continue;
        if (found != null and found.? != candidate) return error.SteamStatsAccountAmbiguous;
        found = candidate;
    }
    return found orelse error.SteamStatsCacheNotFound;
}

fn parseStatsAccountId(filename: []const u8, app_id: u32) ?u32 {
    const prefix = "UserGameStats_";
    if (!std.mem.startsWith(u8, filename, prefix)) return null;
    var suffix_buffer: [32]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "_{d}.bin", .{app_id}) catch return null;
    if (!std.mem.endsWith(u8, filename, suffix)) return null;
    const account_text = filename[prefix.len .. filename.len - suffix.len];
    if (account_text.len == 0) return null;
    return std.fmt.parseInt(u32, account_text, 10) catch null;
}

fn backup(
    allocator: std.mem.Allocator,
    io: std.Io,
    backup_root: []const u8,
    app_id: u32,
    stats_name: []const u8,
    bytes: []const u8,
) ![]u8 {
    const app_name = try std.fmt.allocPrint(allocator, "{d}", .{app_id});
    defer allocator.free(app_name);
    const directory = try std.fs.path.join(allocator, &.{ backup_root, app_name });
    defer allocator.free(directory);
    const now_ns = std.Io.Clock.real.now(io).nanoseconds;
    const nonce: u64 = @intCast(@max(now_ns, 0));
    const filename = try std.fmt.allocPrint(allocator, "{d}-{s}.bak", .{ nonce, stats_name });
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ directory, filename });
    errdefer allocator.free(path);
    try writeAtomic(io, path, bytes);
    return path;
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.replace(io);
}

test "parse native stats account id" {
    try std.testing.expectEqual(@as(?u32, 1208830004), parseStatsAccountId("UserGameStats_1208830004_3751950.bin", 3751950));
    try std.testing.expectEqual(@as(?u32, null), parseStatsAccountId("UserGameStatsSchema_3751950.bin", 3751950));
    try std.testing.expectEqual(@as(?u32, null), parseStatsAccountId("UserGameStats_1208830004_2749950.bin", 3751950));
}
