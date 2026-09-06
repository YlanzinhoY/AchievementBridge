const std = @import("std");
const bridge = @import("../root.zig");

pub const protocol_version: u16 = 1;
pub const default_port: u16 = 47_651;

pub const Options = struct {
    port: u16 = default_port,
    steam_root: ?[]const u8 = null,
    preview_transaction_path: []const u8,
    monitor: MonitorDefaults,
};

pub const MonitorDefaults = struct {
    gse_roots: []const []const u8,
    r2_roots: []const []const u8,
    rune_roots: []const []const u8,
    rockstar_roots: []const []const u8,
    spool_root: []const u8,
    journal_path: []const u8,
    replay_guard_path: []const u8,
    backup_root: []const u8,
    support_root: []const u8,
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
    interval_ms: u32 = 500,
    journal_path: ?[]const u8 = null,
    recover: bool = true,
    notifications: bool = true,
    provider: ?[]const u8 = null,
    timestamp: ?u32 = null,
    native_toast: bool = true,
};

const GameSupport = struct {
    app_id: u32,
    name: []const u8,
    directory: []const u8,
    provider: []const u8,
    confidence: u8,
    achievement_count: ?usize,
    state_available: bool,
    status: []const u8,
    provider_product_id: ?u32 = null,
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    steam_root: ?[]u8,
    preview_transaction_path: []u8,
    monitor: MonitorDefaults,
    monitor_started: bool = false,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        steam_root: ?[]const u8,
        preview_transaction_path: []const u8,
        monitor: MonitorDefaults,
    ) !State {
        return .{
            .allocator = allocator,
            .io = io,
            .steam_root = if (steam_root) |root| try allocator.dupe(u8, root) else null,
            .preview_transaction_path = try allocator.dupe(u8, preview_transaction_path),
            .monitor = monitor,
        };
    }

    fn deinit(self: *State) void {
        if (self.steam_root) |root| self.allocator.free(root);
        self.allocator.free(self.preview_transaction_path);
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

    fn recoverPendingPreview(self: *State) !void {
        var pending = (try bridge.steam.preview_transaction.load(
            self.allocator,
            self.io,
            self.preview_transaction_path,
        )) orelse return;
        defer pending.deinit();
        var session = try self.connectSession(pending.app_id);
        defer session.close();
        const cleared = try bridge.steam.adapter.rollbackAchievementPreview(
            &session,
            self.allocator,
            self.io,
            pending.achievement,
        );
        try bridge.steam.preview_transaction.clear(self.io, self.preview_transaction_path);
        std.debug.print(
            "[SteamNotificationPreview] recovery=true appid={d} achievement={s} cleared={} state_after=locked\n",
            .{ pending.app_id, pending.achievement, cleared },
        );
    }

    fn startMonitor(self: *State, params: Params) !void {
        if (self.monitor_started) return;
        if (params.interval_ms < 100) return error.IntervalTooSmall;
        const context = try self.allocator.create(bridge.host.all_watchers.Context);
        context.* = .{
            .io = self.io,
            .gse_roots = self.monitor.gse_roots,
            .r2_roots = self.monitor.r2_roots,
            .rune_roots = self.monitor.rune_roots,
            .rockstar_roots = self.monitor.rockstar_roots,
            .spool_root = self.monitor.spool_root,
            .journal_path = if (params.journal_path) |path|
                try self.allocator.dupe(u8, path)
            else
                self.monitor.journal_path,
            .replay_guard_path = self.monitor.replay_guard_path,
            .support_root = self.monitor.support_root,
            .interval_ms = params.interval_ms,
            .recover = params.recover,
            .notifications = params.notifications,
        };
        const thread = try std.Thread.spawn(.{}, monitorWorker, .{context});
        thread.detach();
        self.monitor_started = true;
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var state = try State.init(
        allocator,
        io,
        options.steam_root,
        options.preview_transaction_path,
        options.monitor,
    );
    defer state.deinit();

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", options.port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    std.debug.print(
        "[AchievementBridgeCore] status=ready address=127.0.0.1 port={d} protocol={d}\n",
        .{ options.port, protocol_version },
    );
    state.recoverPendingPreview() catch |err|
        std.debug.print("[SteamNotificationPreview] recovery_pending=true error={s}\n", .{@errorName(err)});

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
            .monitoring = state.monitor_started,
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "start_monitor")) {
        try state.startMonitor(request.params);
        try writeSuccess(allocator, writer, request.id, .{
            .monitoring = state.monitor_started,
            .interval_ms = request.params.interval_ms,
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
        var rockstar_candidates = try bridge.providers.rockstar.discovery.discoverWithApps(
            allocator,
            state.io,
            state.monitor.rockstar_roots,
            catalog.apps.items,
        );
        defer rockstar_candidates.deinit();
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

            if (try bridge.game_support.load(allocator, state.io, state.monitor.support_root, app.app_id)) |loaded_value| {
                var loaded = loaded_value;
                defer loaded.deinit();
                const manifest = loaded.value();
                const diagnostic = bridge.providers.uplay_r2.diagnostic.diagnose(allocator, state.io, app.install_dir) catch null;
                if (diagnostic != null and diagnostic.?.ready() and manifest.catalog_count > 0) {
                    var product_id = manifest.provider_product_id orelse
                        try bridge.game_support.readUplayProductId(allocator, state.io, app.install_dir);
                    if (product_id == null) product_id =
                        try bridge.game_support.findRecentUnclaimedUplayProductId(
                            allocator,
                            state.io,
                            state.monitor.support_root,
                            state.monitor.r2_roots,
                            app.app_id,
                            manifest.prepared_at,
                        );
                    const source_state = if (product_id) |id|
                        try bridge.game_support.findSourceState(allocator, state.io, state.monitor.r2_roots, id)
                    else
                        null;
                    defer if (source_state) |path| allocator.free(path);
                    const complete = product_id != null and source_state != null;
                    if (product_id != manifest.provider_product_id or complete != manifest.capabilities.sync_to_steam) {
                        const refreshed_path = try bridge.game_support.save(allocator, state.io, state.monitor.support_root, .{
                            .steam_app_id = manifest.steam_app_id,
                            .game = manifest.game,
                            .game_directory = manifest.game_directory,
                            .provider = manifest.provider,
                            .provider_product_id = product_id,
                            .source_state = source_state,
                            .mapping = manifest.mapping,
                            .catalog_count = manifest.catalog_count,
                            .prepared_at = manifest.prepared_at,
                            .capabilities = .{
                                .detect = true,
                                .monitor = true,
                                .map_to_steam = true,
                                .sync_to_steam = complete,
                                .popup = true,
                            },
                        });
                        allocator.free(refreshed_path);
                    }
                    try games.append(allocator, .{
                        .app_id = app.app_id,
                        .name = app.name,
                        .directory = app.install_dir,
                        .provider = "uplay_r2",
                        .confidence = 100,
                        .achievement_count = manifest.catalog_count,
                        .state_available = complete,
                        .status = if (complete) "COMPLETO" else "AGUARDA DADOS",
                        .provider_product_id = product_id,
                    });
                    continue;
                }
            }

            const state_available = !std.mem.eql(u8, provider, "rockstar") or
                hasRockstarState(rockstar_candidates.items.items, app.app_id);
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
                .state_available = state_available,
                .status = classifySupport(provider, confidence, achievement_count, state_available),
            });
        }
        try writeSuccess(allocator, writer, request.id, .{ .games = games.items });
        return;
    }
    if (std.mem.eql(u8, request.method, "prepare_game_support")) {
        const app_id = request.params.app_id orelse return error.MissingAppId;
        const steam_root = try state.getSteamRoot();
        var catalog = try bridge.detector.steam_install.discover(allocator, state.io, steam_root);
        defer catalog.deinit();
        const app = catalog.findByAppId(app_id) orelse return error.SteamAppNotInstalled;
        const diagnostic = try bridge.providers.uplay_r2.diagnostic.diagnose(allocator, state.io, app.install_dir);
        if (!diagnostic.loader_found) return error.UplayR2LoaderNotFound;

        var session = try state.connectSession(app_id);
        defer session.close();
        try session.client.loadCurrentUserStats(state.io, app_id, 10_000);
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        if (achievements.items.items.len == 0) return error.SteamAchievementCatalogEmpty;
        const schema_bytes = try bridge.providers.uplay_r2.schema.renderSteamCatalog(allocator, achievements.items.items);
        defer allocator.free(schema_bytes);
        const schema_path = try std.fs.path.join(allocator, &.{ app.install_dir, "achievements_schema.json" });
        try backupFileOnce(allocator, state.io, schema_path);
        try writeAtomic(state.io, schema_path, schema_bytes);

        const config_path = try uplayConfigPath(allocator, state.io, app.install_dir);
        const config_bytes = std.Io.Dir.cwd().readFileAlloc(state.io, config_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try bridge.providers.uplay_r2.schema.defaultConfig(allocator),
            else => return err,
        };
        defer allocator.free(config_bytes);
        const enabled_config = bridge.providers.uplay_r2.schema.enableAchievements(allocator, config_bytes) catch |err| switch (err) {
            error.MissingAchievementsSetting => try bridge.providers.uplay_r2.schema.defaultConfig(allocator),
            else => return err,
        };
        defer allocator.free(enabled_config);
        try backupFileOnce(allocator, state.io, config_path);
        try writeAtomic(state.io, config_path, enabled_config);

        var correlation_since = unixNow(state.io);
        if (try bridge.game_support.load(allocator, state.io, state.monitor.support_root, app_id)) |prior_value| {
            var prior = prior_value;
            correlation_since = prior.value().prepared_at;
            prior.deinit();
        }
        var product_id = try bridge.game_support.readUplayProductId(allocator, state.io, app.install_dir);
        if (product_id == null) product_id =
            try bridge.game_support.findRecentUnclaimedUplayProductId(
                allocator,
                state.io,
                state.monitor.support_root,
                state.monitor.r2_roots,
                app.app_id,
                correlation_since,
            );
        const source_state = if (product_id) |id|
            try bridge.game_support.findSourceState(allocator, state.io, state.monitor.r2_roots, id)
        else
            null;
        defer if (source_state) |path| allocator.free(path);
        const complete = product_id != null and source_state != null;
        const manifest_path = try bridge.game_support.save(allocator, state.io, state.monitor.support_root, .{
            .steam_app_id = app_id,
            .game = app.name,
            .game_directory = app.install_dir,
            .provider = "uplay_r2",
            .provider_product_id = product_id,
            .source_state = source_state,
            .mapping = "numeric_suffix",
            .catalog_count = achievements.items.items.len,
            .prepared_at = unixNow(state.io),
            .capabilities = .{
                .detect = true,
                .monitor = true,
                .map_to_steam = true,
                .sync_to_steam = complete,
                .popup = true,
            },
        });
        defer allocator.free(manifest_path);
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .game = app.name,
            .provider = "uplay_r2",
            .provider_product_id = product_id,
            .achievement_count = achievements.items.items.len,
            .schema_path = schema_path,
            .config_path = config_path,
            .manifest_path = manifest_path,
            .status = if (complete) "COMPLETO" else "AGUARDA DADOS",
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "preview_achievement")) {
        try state.recoverPendingPreview();
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
        try bridge.steam.preview_transaction.save(
            allocator,
            state.io,
            state.preview_transaction_path,
            app_id,
            achievement.api_name,
            unixNow(state.io),
        );
        const preview = try bridge.steam.adapter.previewAchievementUnlock(&session, allocator, state.io, achievement.api_name, duration_ms);
        try bridge.steam.preview_transaction.clear(state.io, state.preview_transaction_path);
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .achievement = achievement.api_name,
            .name = achievement.name,
            .preview_mode = @tagName(preview),
            .native_unlock_toast = preview == .unlock_rolled_back,
            .temporary_unlock_stored = preview == .unlock_rolled_back,
            .rollback_stored = preview == .unlock_rolled_back,
            .state_after = "locked",
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "rollback_achievement_preview")) {
        const app_id = request.params.app_id orelse return error.MissingAppId;
        const wanted = request.params.achievement orelse return error.MissingAchievement;
        var session = try state.connectSession(app_id);
        defer session.close();
        try session.client.loadCurrentUserStats(state.io, app_id, 10_000);
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        const achievement = findAchievement(achievements.items.items, wanted) orelse return error.AchievementNotFound;
        const cleared = try bridge.steam.adapter.rollbackAchievementPreview(
            &session,
            allocator,
            state.io,
            achievement.api_name,
        );
        if (try bridge.steam.preview_transaction.load(allocator, state.io, state.preview_transaction_path)) |loaded| {
            var pending = loaded;
            defer pending.deinit();
            if (pending.app_id == app_id and std.ascii.eqlIgnoreCase(pending.achievement, achievement.api_name))
                try bridge.steam.preview_transaction.clear(state.io, state.preview_transaction_path);
        }
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .achievement = achievement.api_name,
            .name = achievement.name,
            .rollback_stored = cleared,
            .state_after = "locked",
        });
        return;
    }
    if (std.mem.eql(u8, request.method, "sync_achievement")) {
        const app_id = request.params.app_id orelse return error.MissingAppId;
        const wanted = request.params.achievement orelse return error.MissingAchievement;
        const provider = request.params.provider orelse return error.MissingProvider;
        if (std.mem.eql(u8, provider, "gse")) {
            try verifyGseUnlock(state, allocator, app_id, wanted);
        } else if (std.mem.eql(u8, provider, "rune")) {
            try verifyRuneUnlock(state, allocator, app_id, wanted);
        } else if (std.mem.eql(u8, provider, "rockstar")) {
            try verifyRockstarUnlock(state, allocator, app_id, wanted);
        } else if (std.mem.eql(u8, provider, "uplay_r2")) {
            try verifyUplayR2Unlock(state, allocator, app_id, wanted);
        } else {
            return error.UnsupportedSyncProvider;
        }

        var direct_error: ?[]const u8 = null;
        var canonical_achievement = wanted;
        if (state.connectSession(app_id)) |connected| {
            var session = connected;
            defer session.close();
            if (bridge.steam.adapter.listAchievements(&session, allocator)) |achievement_list| {
                var achievements = achievement_list;
                defer achievements.deinit();
                const achievement = findAchievement(achievements.items.items, wanted) orelse
                    return error.AchievementNotFound;
                canonical_achievement = try allocator.dupe(u8, achievement.api_name);
                if (bridge.steam.adapter.unlockAchievement(
                    &session,
                    allocator,
                    state.io,
                    achievement.api_name,
                )) |result| {
                    try writeSuccess(allocator, writer, request.id, .{
                        .app_id = app_id,
                        .achievement = achievement.api_name,
                        .provider = provider,
                        .route = "steam_abi",
                        .result = @tagName(result),
                        .server_acknowledged = true,
                    });
                    return;
                } else |err| {
                    direct_error = @errorName(err);
                }
            } else |err| {
                direct_error = @errorName(err);
            }
        } else |err| {
            direct_error = @errorName(err);
        }

        var local = try bridge.steam.live_sync.sync(allocator, state.io, .{
            .app_id = app_id,
            .api_name = canonical_achievement,
            .unlock_time = request.params.timestamp orelse @intCast(unixNow(state.io)),
            .steam_root = try state.getSteamRoot(),
            .backup_root = state.monitor.backup_root,
            .experimental_native_notification = request.params.native_toast,
        });
        defer local.deinit();
        try writeSuccess(allocator, writer, request.id, .{
            .app_id = app_id,
            .achievement = canonical_achievement,
            .provider = provider,
            .route = "steam_local_cache",
            .direct_error = direct_error,
            .changed = local.changed,
            .cache_confirmed = local.cache_confirmed,
            .steam_confirmed = local.steam_confirmed,
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

fn selectProvider(candidates: []const bridge.resolver.Candidate) ?bridge.resolver.Candidate {
    const priority = [_]bridge.event.ProviderKind{
        .gse, .rune, .rockstar, .uplay_r2, .ubisoft, .steam, .epic, .gog, .ea, .xbox,
    };
    for (priority) |wanted| {
        for (candidates) |candidate| if (candidate.provider == wanted) return candidate;
    }
    return null;
}

fn supportsStandaloneSync(provider: []const u8, confidence: u8) bool {
    return confidence >= 60 and
        (std.mem.eql(u8, provider, "gse") or std.mem.eql(u8, provider, "rune") or
            std.mem.eql(u8, provider, "rockstar"));
}

fn classifySupport(provider: []const u8, confidence: u8, achievement_count: ?usize, state_available: bool) []const u8 {
    if (supportsStandaloneSync(provider, confidence)) {
        if (std.mem.eql(u8, provider, "rockstar") and !state_available) return "AGUARDA DADOS";
        if (achievement_count) |count| if (count == 0) return "SEM CATÁLOGO";
        return "COMPLETO";
    }
    if (confidence >= 60 and
        (std.mem.eql(u8, provider, "ubisoft") or std.mem.eql(u8, provider, "uplay_r2")))
        return "SÓ DETECTA";
    if (confidence >= 50 and std.mem.eql(u8, provider, "steam")) return "NATIVO";
    return "SEM SUPORTE";
}

fn hasRockstarState(candidates: []const bridge.providers.rockstar.discovery.Candidate, app_id: u32) bool {
    for (candidates) |candidate| if (candidate.app_id == app_id) return true;
    return false;
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

fn verifyGseUnlock(state: *State, allocator: std.mem.Allocator, app_id: u32, api_name: []const u8) !void {
    var candidates = try bridge.gse.discovery.discover(allocator, state.io, state.monitor.gse_roots);
    defer candidates.deinit();
    for (candidates.items.items) |candidate| {
        if (candidate.app_id != app_id) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(state.io, candidate.state_file, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        var snapshot = try bridge.gse.snapshot.parse(allocator, bytes);
        defer snapshot.deinit();
        const achievement = snapshot.achievements.get(api_name) orelse return error.GseAchievementNotFound;
        if (!achievement.earned) return error.GseAchievementNotUnlocked;
        return;
    }
    return error.GseAppNotFound;
}

fn verifyRuneUnlock(state: *State, allocator: std.mem.Allocator, app_id: u32, api_name: []const u8) !void {
    var candidates = try bridge.providers.rune.discovery.discover(allocator, state.io, state.monitor.rune_roots);
    defer candidates.deinit();
    for (candidates.items.items) |candidate| {
        if (candidate.app_id != app_id) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(state.io, candidate.state_file, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(bytes);
        var snapshot = try bridge.providers.rune.snapshot.parse(allocator, bytes);
        defer snapshot.deinit();
        const achievement = snapshot.achievements.get(api_name) orelse return error.RuneAchievementNotFound;
        if (!achievement.earned) return error.RuneAchievementNotUnlocked;
        return;
    }
    return error.RuneAppNotFound;
}

fn verifyRockstarUnlock(state: *State, allocator: std.mem.Allocator, app_id: u32, api_name: []const u8) !void {
    if (app_id == bridge.providers.rockstar.games.gtav_enhanced.app_id) {
        const internal_id = bridge.providers.rockstar.games.gtav_enhanced.internalAchievement(api_name) orelse
            return error.RockstarAchievementNotFound;
        var monitor = bridge.providers.rockstar.games.gtav_enhanced.Monitor.init(allocator);
        defer monitor.deinit();
        const sample = (try monitor.sample()) orelse return error.RockstarGameNotRunning;
        if (!sample.unlocked.isSet(internal_id)) return error.RockstarAchievementNotUnlocked;
        return;
    }

    const steam_root = try state.getSteamRoot();
    var catalog = try bridge.detector.steam_install.discover(allocator, state.io, steam_root);
    defer catalog.deinit();
    var candidates = try bridge.providers.rockstar.discovery.discoverWithApps(
        allocator,
        state.io,
        state.monitor.rockstar_roots,
        catalog.apps.items,
    );
    defer candidates.deinit();
    var found_locked = false;
    for (candidates.items.items) |candidate| {
        if (candidate.app_id != app_id) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(state.io, candidate.state_file, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        var snapshot = try bridge.providers.rockstar.snapshot.parseFile(allocator, candidate.state_file, bytes);
        defer snapshot.deinit();
        const achievement = snapshot.achievements.get(api_name) orelse continue;
        if (achievement.earned) return;
        found_locked = true;
    }
    if (found_locked) return error.RockstarAchievementNotUnlocked;
    return error.RockstarAchievementNotFound;
}

fn verifyUplayR2Unlock(state: *State, allocator: std.mem.Allocator, app_id: u32, api_name: []const u8) !void {
    var loaded = (try bridge.game_support.load(allocator, state.io, state.monitor.support_root, app_id)) orelse
        return error.SupportManifestNotFound;
    defer loaded.deinit();
    const manifest = loaded.value();
    const product_id = manifest.provider_product_id orelse
        (try bridge.game_support.readUplayProductId(allocator, state.io, manifest.game_directory)) orelse
        return error.UplayProductIdNotAvailable;
    var candidates = try bridge.gse.discovery.discover(allocator, state.io, state.monitor.r2_roots);
    defer candidates.deinit();
    for (candidates.items.items) |candidate| {
        if (candidate.app_id != product_id) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(state.io, candidate.state_file, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        var snapshot = try bridge.gse.snapshot.parse(allocator, bytes);
        defer snapshot.deinit();
        const source_id = numericSuffix(api_name) orelse api_name;
        const achievement = snapshot.achievements.get(source_id) orelse return error.UplayAchievementNotFound;
        if (!achievement.earned) return error.UplayAchievementNotUnlocked;
        return;
    }
    return error.UplayStateNotFound;
}

fn unixNow(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn uplayConfigPath(allocator: std.mem.Allocator, io: std.Io, game_dir: []const u8) ![]u8 {
    for ([_][]const u8{ "upc_r2.ini", "uplay_r2.ini" }) |name| {
        const path = try std.fs.path.join(allocator, &.{ game_dir, name });
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }
    return std.fs.path.join(allocator, &.{ game_dir, "upc_r2.ini" });
}

fn backupFileOnce(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.achievement-bridge.bak", .{path});
    defer allocator.free(backup_path);
    std.Io.Dir.cwd().access(io, backup_path, .{}) catch {
        try writeAtomic(io, backup_path, bytes);
        return;
    };
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.replace(io);
}

fn monitorWorker(context: *const bridge.host.all_watchers.Context) void {
    bridge.host.all_watchers.run(context) catch |err|
        std.debug.print("[AchievementBridge] monitor_stopped=true error={s}\n", .{@errorName(err)});
}

test "support classification distinguishes native, full, and detected providers" {
    try std.testing.expectEqualStrings("COMPLETO", classifySupport("gse", 100, 52, true));
    try std.testing.expectEqualStrings("COMPLETO", classifySupport("rockstar", 100, 77, true));
    try std.testing.expectEqualStrings("AGUARDA DADOS", classifySupport("rockstar", 100, 77, false));
    try std.testing.expectEqualStrings("SEM CATÁLOGO", classifySupport("rune", 90, 0, true));
    try std.testing.expectEqualStrings("SÓ DETECTA", classifySupport("ubisoft", 90, null, true));
    try std.testing.expectEqualStrings("NATIVO", classifySupport("steam", 75, null, true));
    try std.testing.expectEqualStrings("SEM SUPORTE", classifySupport("epic", 85, null, true));
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
