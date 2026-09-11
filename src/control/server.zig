const std = @import("std");
const bridge = @import("../root.zig");

pub const protocol_version: u16 = 1;
pub const default_port: u16 = 47_651;

pub const Options = struct {
    port: u16 = default_port,
    steam_root: ?[]const u8 = null,
    backup_root: []const u8,
};

const Request = struct {
    version: u16,
    id: []const u8,
    method: []const u8,
    params: Params = .{},
};

const Params = struct {
    app_id: ?u32 = null,
    achievement: ?[]const u8 = null,
    duration_ms: ?u32 = null,
    wait_for_game_dir: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    timestamp: ?u32 = null,
    native_toast: bool = true,
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    steam_root: ?[]u8,
    backup_root: []u8,
    gtav_enhanced: bridge.providers.rockstar.games.gtav_enhanced.Monitor,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        steam_root: ?[]const u8,
        backup_root: []const u8,
    ) !State {
        return .{
            .allocator = allocator,
            .io = io,
            .steam_root = if (steam_root) |root| try allocator.dupe(u8, root) else null,
            .backup_root = try allocator.dupe(u8, backup_root),
            .gtav_enhanced = bridge.providers.rockstar.games.gtav_enhanced.Monitor.init(allocator),
        };
    }

    fn deinit(self: *State) void {
        self.gtav_enhanced.deinit();
        if (self.steam_root) |root| self.allocator.free(root);
        self.allocator.free(self.backup_root);
        self.* = undefined;
    }

    fn getSteamRoot(self: *State) ![]const u8 {
        if (self.steam_root == null)
            self.steam_root = try bridge.detector.steam_install.findSteamRoot(self.allocator, self.io);
        return self.steam_root.?;
    }

    fn connectSession(self: *State, app_id: u32) !bridge.steam.adapter.Session {
        return bridge.steam.adapter.connect(self.allocator, app_id, try self.getSteamRoot());
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var state = try State.init(
        allocator,
        io,
        options.steam_root,
        options.backup_root,
    );
    defer state.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", options.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print(
        "[AchievementBridgeCore] status=ready address=127.0.0.1 port={d} protocol={d}\n",
        .{ options.port, protocol_version },
    );
    while (true) {
        var stream = server.accept(io) catch |err| {
            std.debug.print("[AchievementBridgeCore] accept_error={s}\n", .{@errorName(err)});
            continue;
        };
        handleConnection(&state, &stream) catch |err|
            std.debug.print("[AchievementBridgeCore] request_error={s}\n", .{@errorName(err)});
    }
}

fn handleConnection(state: *State, stream: *std.Io.net.Stream) !void {
    defer stream.close(state.io);
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var read_buffer: [64 * 1024]u8 = undefined;
    var stream_reader = stream.reader(state.io, &read_buffer);
    const line = (try stream_reader.interface.takeDelimiter('\n')) orelse return;

    var write_buffer: [64 * 1024]u8 = undefined;
    var stream_writer = stream.writer(state.io, &write_buffer);
    const writer = &stream_writer.interface;

    var parsed = std.json.parseFromSlice(Request, allocator, line, .{ .ignore_unknown_fields = true }) catch {
        try writeError(allocator, writer, "", "invalid_request", "The request is not valid JSON for protocol v1");
        return;
    };
    defer parsed.deinit();
    const request = parsed.value;
    if (request.version != protocol_version) {
        try writeError(allocator, writer, request.id, "unsupported_version", "Unsupported protocol version");
        return;
    }

    dispatch(state, allocator, writer, request) catch |err| {
        try writeError(allocator, writer, request.id, @errorName(err), @errorName(err));
    };
}

fn dispatch(state: *State, allocator: std.mem.Allocator, writer: *std.Io.Writer, request: Request) !void {
    if (std.mem.eql(u8, request.method, "health")) {
        try writeSuccess(allocator, writer, request.id, .{
            .service = "achievement-bridge-core",
            .status = "ready",
            .protocol_version = protocol_version,
            .steam_session_scope = "request",
            .monitoring = false,
            .stopping = false,
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "list_achievements")) {
        const app_id = request.params.app_id orelse return error.MissingAppId;
        var session = try state.connectSession(app_id);
        defer session.close();
        try session.client.loadCurrentUserStats(state.io, app_id, 10_000);
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        try bridge.steam.user_stats.resolveAchievementImageUrls(&achievements, app_id);
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .achievements = achievements.items.items,
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "sample_native_provider")) {
        const app_id = request.params.app_id orelse return error.MissingAppId;
        const provider = request.params.provider orelse return error.MissingProvider;
        if (!std.mem.eql(u8, provider, "rockstar") or
            app_id != bridge.providers.rockstar.games.gtav_enhanced.app_id)
            return error.NativeProviderNotSupported;

        const sampled = try state.gtav_enhanced.sample();
        if (sampled == null) {
            try writeSuccess(allocator, writer, request.id, .{
                .app_id = app_id,
                .provider = provider,
                .active = false,
                .achievements = &[_][]const u8{},
            });
            return;
        }
        const sample = sampled.?;
        var achievements: std.ArrayList([]const u8) = .empty;
        defer achievements.deinit(allocator);
        for (1..bridge.providers.rockstar.games.gtav_enhanced.maximum_internal_id + 1) |internal_id| {
            if (!sample.unlocked.isSet(internal_id)) continue;
            const api_name = bridge.providers.rockstar.games.gtav_enhanced.steamAchievement(internal_id) orelse continue;
            try achievements.append(allocator, api_name);
        }
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .provider = provider,
            .active = true,
            .pid = sample.pid,
            .just_attached = sample.just_attached,
            .achievements = achievements.items,
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "preview_achievement")) {
        const app_id = request.params.app_id orelse return error.MissingAppId;
        const wanted = request.params.achievement orelse return error.MissingAchievement;
        const duration_ms = request.params.duration_ms orelse 7000;
        if (duration_ms < 1000 or duration_ms > 60_000) return error.InvalidNotificationDuration;
        if (request.params.wait_for_game_dir) |game_dir| {
            while (!try gameRunning(game_dir)) try std.Io.sleep(state.io, .fromMilliseconds(500), .awake);
        }

        var session = try state.connectSession(app_id);
        defer session.close();
        try session.client.loadCurrentUserStats(state.io, app_id, 5000);
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        const achievement = findAchievement(achievements.items.items, wanted) orelse return error.AchievementNotFound;
        const now = unixNow(state.io);
        var notifier = try bridge.notifications.windows.Notifier.init();
        defer notifier.deinit();
        try notifier.show(allocator, .{
            .app_id = app_id,
            .source_id = achievement.api_name,
            .provider = .steam,
            .unlocked_at = now,
            .detected_at = now,
        }, achievement.name, achievement.description, achievement.global_percent);
        try std.Io.sleep(state.io, .fromMilliseconds(@min(duration_ms, 2_000)), .awake);
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .achievement = achievement.api_name,
            .name = achievement.name,
            .preview_mode = "bridge_notification",
            .native_unlock_toast = false,
            .steam_state_changed = false,
            .state_after = if (achievement.unlocked) "unlocked" else "locked",
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "project_local_achievement")) {
        const app_id = request.params.app_id orelse return error.MissingAppId;
        const wanted = request.params.achievement orelse return error.MissingAchievement;
        const provider = request.params.provider orelse return error.MissingProvider;

        var local = try bridge.steam.live_sync.sync(allocator, state.io, .{
            .app_id = app_id,
            .api_name = wanted,
            .unlock_time = request.params.timestamp orelse @intCast(unixNow(state.io)),
            .steam_root = try state.getSteamRoot(),
            .backup_root = state.backup_root,
            .experimental_native_notification = request.params.native_toast,
        });
        defer local.deinit();
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .achievement = local.api_name,
            .provider = provider,
            .route = "steam_local_projection",
            .server_request = false,
            .changed = local.changed,
            .projection_confirmed = local.cache_confirmed and local.host_status == .captured,
            .host_status = @tagName(local.host_status),
            .stat_id = local.stat_id,
            .bit = local.bit,
            .permission = local.permission,
            .native_notification = @tagName(local.native_notification),
        });
        return;
    }
    return error.UnknownMethod;
}

fn writeSuccess(allocator: std.mem.Allocator, writer: *std.Io.Writer, id: []const u8, result: anytype) !void {
    try writeJson(allocator, writer, .{
        .version = protocol_version,
        .id = id,
        .ok = true,
        .result = result,
    });
}

fn writeError(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    id: []const u8,
    code: []const u8,
    message: []const u8,
) !void {
    try writeJson(allocator, writer, .{
        .version = protocol_version,
        .id = id,
        .ok = false,
        .@"error" = .{ .code = code, .message = message },
    });
}

fn writeJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    try writer.writeAll(json);
    try writer.writeAll("\n");
    try writer.flush();
}

fn findAchievement(
    achievements: []const bridge.steam.user_stats.AchievementState,
    wanted: []const u8,
) ?*const bridge.steam.user_stats.AchievementState {
    for (achievements) |*achievement| {
        if (std.ascii.eqlIgnoreCase(achievement.api_name, wanted)) return achievement;
        if (numericSuffix(achievement.api_name)) |suffix|
            if (std.mem.eql(u8, suffix, wanted)) return achievement;
    }
    return null;
}

fn numericSuffix(api_name: []const u8) ?[]const u8 {
    var start = api_name.len;
    while (start > 0 and std.ascii.isDigit(api_name[start - 1])) start -= 1;
    if (start == api_name.len) return null;
    return api_name[start..];
}

fn gameRunning(game_dir: []const u8) !bool {
    var processes = try bridge.detector.process.enumerate(std.heap.page_allocator);
    defer processes.deinit();
    const normalized = std.mem.trimEnd(u8, game_dir, "\\/");
    for (processes.items.items) |process| {
        if (process.executable_path.len <= normalized.len) continue;
        if (!std.ascii.startsWithIgnoreCase(process.executable_path, normalized)) continue;
        const boundary = process.executable_path[normalized.len];
        if (boundary == '\\' or boundary == '/') return true;
    }
    return false;
}

fn unixNow(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

test "provider objective resolves to canonical Steam API name" {
    const achievements = [_]bridge.steam.user_stats.AchievementState{
        .{
            .api_name = @constCast("Outlaws_Ach_19"),
            .name = @constCast("The heavier they fall"),
            .description = @constCast(""),
            .icon = @constCast(""),
            .icon_gray = @constCast(""),
            .unlocked = false,
            .unlock_time = 0,
            .hidden = false,
            .global_percent = null,
        },
    };
    const achievement = findAchievement(&achievements, "19") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Outlaws_Ach_19", achievement.api_name);
}
