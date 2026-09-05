const std = @import("std");
const Library = @import("windows/library.zig").Library;
const vtable = @import("vtable.zig");
const UserStats = @import("user_stats.zig").UserStats;

pub const Client = struct {
    library: Library,
    steam_client: *anyopaque,
    pipe: i32,
    user: i32,
    steam_id: u64,
    user_stats: UserStats,

    pub fn connect(allocator: std.mem.Allocator, app_id: u32, steam_root: []const u8) !Client {
        var app_id_buffer: [16]u8 = undefined;
        const app_id_z = try std.fmt.bufPrintZ(&app_id_buffer, "{d}", .{app_id});
        const app_id_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, app_id_z);
        defer allocator.free(app_id_w);
        if (!api.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("SteamAppId"), app_id_w).toBool()) return error.SetSteamAppIdFailed;
        defer _ = api.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("SteamAppId"), null);

        const library_path = try std.fs.path.join(allocator, &.{ steam_root, "steamclient64.dll" });
        defer allocator.free(library_path);
        var library = try Library.open(allocator, library_path);
        errdefer library.close();
        const CreateInterface = *const fn ([*:0]const u8, ?*i32) callconv(.c) ?*anyopaque;
        const create_interface = try library.lookup(CreateInterface, "CreateInterface");
        const steam_client = create_interface("SteamClient018", null) orelse return error.SteamClientUnavailable;

        const CreateSteamPipe = *const fn (*anyopaque) callconv(.c) i32;
        const pipe = vtable.getMethod(steam_client, 0, CreateSteamPipe)(steam_client);
        if (pipe == 0) return error.CreateSteamPipeFailed;
        errdefer {
            const ReleaseSteamPipe = *const fn (*anyopaque, i32) callconv(.c) u8;
            _ = vtable.getMethod(steam_client, 1, ReleaseSteamPipe)(steam_client, pipe);
        }

        const ConnectToGlobalUser = *const fn (*anyopaque, i32) callconv(.c) i32;
        const user = vtable.getMethod(steam_client, 2, ConnectToGlobalUser)(steam_client, pipe);
        if (user == 0) return error.SteamNotRunning;
        errdefer {
            const ReleaseUser = *const fn (*anyopaque, i32, i32) callconv(.c) void;
            vtable.getMethod(steam_client, 4, ReleaseUser)(steam_client, pipe, user);
        }

        const GetISteamUser = *const fn (*anyopaque, i32, i32, [*:0]const u8) callconv(.c) ?*anyopaque;
        const steam_user = vtable.getMethod(steam_client, 5, GetISteamUser)(steam_client, pipe, user, "SteamUser012") orelse return error.SteamUserUnavailable;
        var steam_id: u64 = 0;
        const GetSteamID = *const fn (*anyopaque, *u64) callconv(.c) void;
        vtable.getMethod(steam_user, 2, GetSteamID)(steam_user, &steam_id);
        if (steam_id == 0) return error.SteamUserIdUnavailable;

        const GetISteamUserStats = *const fn (*anyopaque, i32, i32, [*:0]const u8) callconv(.c) ?*anyopaque;
        const stats_pointer = vtable.getMethod(steam_client, 13, GetISteamUserStats)(steam_client, pipe, user, "STEAMUSERSTATS_INTERFACE_VERSION013") orelse return error.UserStatsUnavailable;
        return .{
            .library = library,
            .steam_client = steam_client,
            .pipe = pipe,
            .user = user,
            .steam_id = steam_id,
            .user_stats = .{ .pointer = stats_pointer },
        };
    }

    pub fn close(self: *Client) void {
        const ReleaseUser = *const fn (*anyopaque, i32, i32) callconv(.c) void;
        vtable.getMethod(self.steam_client, 4, ReleaseUser)(self.steam_client, self.pipe, self.user);
        const ReleaseSteamPipe = *const fn (*anyopaque, i32) callconv(.c) u8;
        _ = vtable.getMethod(self.steam_client, 1, ReleaseSteamPipe)(self.steam_client, self.pipe);
        const Shutdown = *const fn (*anyopaque) callconv(.c) u8;
        _ = vtable.getMethod(self.steam_client, 23, Shutdown)(self.steam_client);
        self.library.close();
        self.* = undefined;
    }

    /// Removes callbacks which were already pending on this dedicated pipe.
    /// StoreStats does not return a call handle, so beginning each transaction
    /// with an empty callback queue prevents an older 1102 result from being
    /// mistaken for the write that follows.
    pub fn drainCallbacks(self: *Client) !usize {
        const CallbackMessage = extern struct {
            user: i32,
            callback: i32,
            param: ?*anyopaque,
            param_size: i32,
        };
        const GetCallback = *const fn (i32, *CallbackMessage, *i32) callconv(.c) u8;
        const FreeLastCallback = *const fn (i32) callconv(.c) void;
        const get_callback = try self.library.lookup(GetCallback, "Steam_BGetCallback");
        const free_last_callback = try self.library.lookup(FreeLastCallback, "Steam_FreeLastCallback");
        var drained: usize = 0;
        var message: CallbackMessage = undefined;
        var failed_call: i32 = 0;
        while (get_callback(self.pipe, &message, &failed_call) != 0) {
            free_last_callback(self.pipe);
            drained += 1;
            if (drained >= 4096) return error.CallbackDrainLimitExceeded;
        }
        return drained;
    }

    /// Waits for Steam to acknowledge StoreStats on this pipe. A successful
    /// StoreStats return only queues the upload; callback 1102 confirms the
    /// server-side result for the selected app.
    pub fn waitForStatsStored(self: *Client, io: std.Io, app_id: u32, timeout_ms: u32) !void {
        const CallbackMessage = extern struct {
            user: i32,
            callback: i32,
            param: ?*anyopaque,
            param_size: i32,
        };
        const UserStatsStored = extern struct {
            game_id: u64,
            result: i32,
        };
        const UserAchievementStored = extern struct {
            game_id: u64,
            group_achievement: bool,
            achievement_name: [128]u8,
            current_progress: u32,
            maximum_progress: u32,
        };
        const GetCallback = *const fn (i32, *CallbackMessage, *i32) callconv(.c) u8;
        const FreeLastCallback = *const fn (i32) callconv(.c) void;
        const get_callback = try self.library.lookup(GetCallback, "Steam_BGetCallback");
        const free_last_callback = try self.library.lookup(FreeLastCallback, "Steam_FreeLastCallback");
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        const timeout_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;
        var transient_result: ?i32 = null;
        while (std.Io.Clock.awake.now(io).nanoseconds - started < timeout_ns) {
            var message: CallbackMessage = undefined;
            var failed_call: i32 = 0;
            while (get_callback(self.pipe, &message, &failed_call) != 0) {
                defer free_last_callback(self.pipe);
                if (message.callback == 1103 and message.param_size >= @sizeOf(UserAchievementStored)) {
                    const raw = message.param orelse continue;
                    const stored: *align(1) const UserAchievementStored = @ptrCast(raw);
                    if (@as(u32, @truncate(stored.game_id)) != app_id) continue;
                    const name_end = std.mem.indexOfScalar(u8, &stored.achievement_name, 0) orelse stored.achievement_name.len;
                    std.debug.print(
                        "[SteamStore] appid={d} achievement={s} progress={d}/{d}\n",
                        .{ app_id, stored.achievement_name[0..name_end], stored.current_progress, stored.maximum_progress },
                    );
                    continue;
                }
                if (message.callback != 1102 or message.param_size < @sizeOf(UserStatsStored)) continue;
                const raw = message.param orelse continue;
                const stored: *align(1) const UserStatsStored = @ptrCast(raw);
                if (@as(u32, @truncate(stored.game_id)) != app_id) continue;
                std.debug.print("[SteamStore] appid={d} result={d}\n", .{ app_id, stored.result });
                if (stored.result != 1) {
                    if (isTransientStoreResult(stored.result)) {
                        transient_result = stored.result;
                        continue;
                    }
                    return error.StoreStatsRejected;
                }
                return;
            }
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
        if (transient_result != null) return error.StoreStatsRateLimited;
        return error.StoreStatsCallbackTimeout;
    }

    pub fn loadCurrentUserStats(self: *Client, io: std.Io, app_id: u32, timeout_ms: u32) !void {
        const CallbackMessage = extern struct {
            user: i32,
            callback: i32,
            param: ?*anyopaque,
            param_size: i32,
        };
        const UserStatsReceived = extern struct {
            game_id: u64,
            result: i32,
            steam_id: u64,
        };
        const GetCallback = *const fn (i32, *CallbackMessage, *i32) callconv(.c) u8;
        const FreeLastCallback = *const fn (i32) callconv(.c) void;
        const get_callback = try self.library.lookup(GetCallback, "Steam_BGetCallback");
        const free_last_callback = try self.library.lookup(FreeLastCallback, "Steam_FreeLastCallback");
        const call_handle = self.user_stats.requestUserStats(self.steam_id);
        if (call_handle == 0) return error.UserStatsRequestFailed;
        const started = std.Io.Clock.awake.now(io).nanoseconds;
        const timeout_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;
        while (std.Io.Clock.awake.now(io).nanoseconds - started < timeout_ns) {
            var message: CallbackMessage = undefined;
            var failed_call: i32 = 0;
            while (get_callback(self.pipe, &message, &failed_call) != 0) {
                defer free_last_callback(self.pipe);
                if (message.callback != 1101 or message.param_size < @sizeOf(UserStatsReceived)) continue;
                const raw = message.param orelse continue;
                const received: *align(1) const UserStatsReceived = @ptrCast(raw);
                // The callback is scoped to this dedicated pipe. SteamForge likewise
                // validates the result without comparing m_steamIDUser; some Windows
                // client builds expose that CSteamID field with ABI-specific packing.
                if (@as(u32, @truncate(received.game_id)) != app_id) continue;
                if (received.result != 1) return error.UserStatsRequestRejected;
                return;
            }
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
        return error.UserStatsCallbackTimeout;
    }
};

fn isTransientStoreResult(result: i32) bool {
    // Busy, Timeout, ServiceUnavailable, Pending, and LimitExceeded. Steam may
    // table the request and emit a later callback on the same pipe.
    return switch (result) {
        10, 16, 20, 22, 25 => true,
        else => false,
    };
}

test "Steam transient StoreStats results can be awaited" {
    try std.testing.expect(isTransientStoreResult(10));
    try std.testing.expect(isTransientStoreResult(16));
    try std.testing.expect(isTransientStoreResult(20));
    try std.testing.expect(isTransientStoreResult(22));
    try std.testing.expect(isTransientStoreResult(25));
    try std.testing.expect(!isTransientStoreResult(1));
    try std.testing.expect(!isTransientStoreResult(2));
    try std.testing.expect(!isTransientStoreResult(8));
}

const windows = std.os.windows;
const api = struct {
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) windows.BOOL;
};
