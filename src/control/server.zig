const std = @import("std");
const bridge = @import("../root.zig");

pub const protocol_version: u16 = 1;
pub const default_port: u16 = 47_651;

pub const Options = struct {
    port: u16 = default_port,
    steam_root: ?[]const u8 = null,
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
    verify_schema: bool = false,
};

const GameSupport = struct {
    app_id: u32,
    name: []const u8,
    directory: []const u8,
    provider: []const u8,
    confidence: u8,
    achievement_count: ?usize,
    status: []const u8,
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    steam_root: ?[]u8,

    fn init(allocator: std.mem.Allocator, io: std.Io, steam_root: ?[]const u8) !State {
        return .{
            .allocator = allocator,
            .io = io,
            .steam_root = if (steam_root) |root| try allocator.dupe(u8, root) else null,
        };
    }

    fn deinit(self: *State) void {
        if (self.steam_root) |root| self.allocator.free(root);
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
    var state = try State.init(allocator, io, options.steam_root);
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
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .achievements = achievements.items.items,
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "inspect_games")) {
        const steam_root = try state.getSteamRoot();
        var catalog = try bridge.detector.steam_install.discover(allocator, state.io, steam_root);
        defer catalog.deinit();
        var games: std.ArrayList(GameSupport) = .empty;
        defer games.deinit(allocator);
        for (catalog.apps.items) |app| {
            var provider: []const u8 = "none";
            var confidence: u8 = 0;
            if (bridge.detector.runtime.detect(allocator, state.io, app.install_dir)) |detected| {
                var report = detected;
                defer report.deinit();
                const candidates = try bridge.resolver.resolve(allocator, &report);
                defer allocator.free(candidates);
                if (selectProvider(candidates)) |selected| {
                    provider = @tagName(selected.provider);
                    confidence = selected.confidence;
                }
            } else |_| {}

            var achievement_count: ?usize = null;
            if (request.params.verify_schema and supportsStandaloneSync(provider, confidence)) {
                if (state.connectSession(app.app_id)) |connected| {
                    var session = connected;
                    defer session.close();
                    if (session.client.loadCurrentUserStats(state.io, app.app_id, 10_000)) |_| {
                        if (bridge.steam.adapter.listAchievements(&session, allocator)) |achievement_list| {
                            var achievements = achievement_list;
                            achievement_count = achievements.items.items.len;
                            achievements.deinit();
                        } else |_| {}
                    } else |_| {}
                } else |_| {}
            }
            try games.append(allocator, .{
                .app_id = app.app_id,
                .name = app.name,
                .directory = app.install_dir,
                .provider = provider,
                .confidence = confidence,
                .achievement_count = achievement_count,
                .status = classifySupport(provider, confidence, achievement_count),
            });
        }
        try writeSuccess(allocator, writer, request.id, .{ .games = games.items });
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
        if (achievement.unlocked) return error.AchievementAlreadyUnlockedForPreview;
        try bridge.steam.adapter.previewAchievementUnlock(&session, allocator, state.io, achievement.api_name, duration_ms);
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .achievement = achievement.api_name,
            .name = achievement.name,
            .native_unlock_toast = true,
            .temporary_unlock_stored = true,
            .rollback_stored = true,
            .state_after = "locked",
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

fn selectProvider(candidates: []const bridge.resolver.Candidate) ?bridge.resolver.Candidate {
    const priority = [_]bridge.event.ProviderKind{
        .gse, .rune, .uplay_r2, .ubisoft, .steam, .epic, .gog, .ea, .xbox,
    };
    for (priority) |wanted| {
        for (candidates) |candidate| if (candidate.provider == wanted) return candidate;
    }
    return null;
}

fn supportsStandaloneSync(provider: []const u8, confidence: u8) bool {
    return confidence >= 60 and
        (std.mem.eql(u8, provider, "gse") or std.mem.eql(u8, provider, "rune"));
}

fn classifySupport(provider: []const u8, confidence: u8, achievement_count: ?usize) []const u8 {
    if (supportsStandaloneSync(provider, confidence)) {
        if (achievement_count) |count| if (count == 0) return "SEM CATÁLOGO";
        return "COMPLETO";
    }
    if (confidence >= 60 and
        (std.mem.eql(u8, provider, "ubisoft") or std.mem.eql(u8, provider, "uplay_r2")))
        return "SÓ DETECTA";
    if (confidence >= 50 and std.mem.eql(u8, provider, "steam")) return "NATIVO";
    return "SEM SUPORTE";
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
