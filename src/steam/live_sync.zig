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

pub const Options = struct {
    app_id: u32,
    api_name: []const u8,
    unlock_time: u32,
    steam_root: []const u8,
    backup_root: []const u8,
    account_id: ?u32 = null,
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
    stats_path: []u8,
    backup_path: ?[]u8,

    pub fn deinit(self: *Result) void {
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

    const account_id = options.account_id orelse try steam_install.findActiveAccountId();
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
        .stats_path = stats_path,
        .backup_path = backup_path,
    };
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
