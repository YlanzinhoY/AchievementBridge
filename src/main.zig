const std = @import("std");
const bridge = @import("achievement_bridge");

const Command = enum { scan, watch, watch_all, probe, games, sessions, host, catalog, local_record, steam_read, steam_unlock, steam_local_clear, steam_local_sync, steam_watch, gse_steam_sync, rune_scan, rune_watch, rune_steam_sync, ubisoft_scan, ubisoft_watch, uplay_r2_diagnose, uplay_r2_prepare, uplay_r2_arm_replay, uplay_r2_scan, uplay_r2_watch, notify_test, help };

const Cli = struct {
    command: Command = .watch,
    roots: std.ArrayList([]const u8) = .empty,
    journal_path: ?[]const u8 = null,
    interval_ms: u32 = 500,
    recover: bool = true,
    game_dir: ?[]const u8 = null,
    steam_root: ?[]const u8 = null,
    notifications: bool = true,
    schema_paths: std.ArrayList([]const u8) = .empty,
    language: []const u8 = "brazilian",
    app_id: ?u32 = null,
    steam_mapping: bool = true,
    once: bool = false,
    catalog_path: ?[]const u8 = null,
    achievement_id: ?[]const u8 = null,
    unlock_time: ?u32 = null,
    duration_ms: u32 = 7000,
    wait_for_game: bool = false,
    confirm_steam_write: bool = false,
    confirm_local_write: bool = false,
    experimental_steam_notification: bool = false,
    local_store_path: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var cli = try parseArgs(allocator, args);

    if (cli.command == .help) {
        printHelp();
        return;
    }

    if (cli.command == .probe) {
        const game_dir = cli.game_dir orelse return error.MissingGameDir;
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else bridge.detector.steam_install.findSteamRoot(allocator, init.io) catch null;
        if (steam_root) |root| {
            var catalog = try bridge.detector.steam_install.discover(allocator, init.io, root);
            defer catalog.deinit();
            if (catalog.findByInstallDir(game_dir)) |app| {
                std.debug.print("[AchievementBridge] identity appid={d} name={s}\n", .{ app.app_id, app.name });
            }
        }
        var report = try bridge.detector.runtime.detect(allocator, init.io, game_dir);
        defer report.deinit();
        const candidates = try bridge.resolver.resolve(allocator, &report);
        std.debug.print("[AchievementBridge] game_dir={s}\n", .{game_dir});
        std.debug.print("Runtime candidates:\n", .{});
        for (report.runtimes.items) |runtime| {
            std.debug.print("  {s}: confidence={d} evidence={d}\n", .{ @tagName(runtime.kind), runtime.confidence, runtime.evidence_count });
        }
        std.debug.print("Provider candidates:\n", .{});
        for (candidates) |candidate| {
            std.debug.print("  {s}: confidence={d}\n", .{ @tagName(candidate.provider), candidate.confidence });
        }
        return;
    }

    if (cli.command == .games) {
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var catalog = try bridge.detector.steam_install.discover(allocator, init.io, steam_root);
        defer catalog.deinit();
        std.debug.print("[AchievementBridge] steam_root={s} installed_apps={d}\n", .{ catalog.steam_root, catalog.apps.items.len });
        for (catalog.apps.items) |app| std.debug.print("  appid={d} name={s} dir={s}\n", .{ app.app_id, app.name, app.install_dir });
        return;
    }

    if (cli.command == .sessions) {
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var catalog = try bridge.detector.steam_install.discover(allocator, init.io, steam_root);
        defer catalog.deinit();
        var processes = try bridge.detector.process.enumerate(allocator);
        defer processes.deinit();
        var found: usize = 0;
        for (processes.items.items) |process| {
            const process_dir = std.fs.path.dirname(process.executable_path) orelse continue;
            const installed = findContainingApp(&catalog, process.executable_path);
            if (installed == null and !bridge.detector.runtime.hasDirectIndicator(allocator, init.io, process_dir)) continue;
            const game_dir = if (installed) |app| app.install_dir else process_dir;
            var report = bridge.detector.runtime.detect(allocator, init.io, game_dir) catch continue;
            defer report.deinit();
            if (report.runtimes.items.len == 0) continue;
            found += 1;
            std.debug.print("[GameSession] pid={d} process={s}", .{ process.pid, process.name });
            if (installed) |app| std.debug.print(" appid={d} name={s}", .{ app.app_id, app.name });
            std.debug.print(" dir={s}\n", .{game_dir});
            for (report.runtimes.items) |detected| std.debug.print("  runtime={s} confidence={d}\n", .{ @tagName(detected.kind), detected.confidence });
        }
        std.debug.print("[AchievementBridge] active_game_sessions={d}\n", .{found});
        return;
    }

    if (cli.command == .host) {
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var catalog = try bridge.detector.steam_install.discover(allocator, init.io, steam_root);
        defer catalog.deinit();
        var monitor = bridge.host.session_monitor.Monitor.init(allocator, init.io, &catalog);
        defer monitor.deinit();
        try monitor.run(.{ .interval_ms = cli.interval_ms, .once = cli.once });
        return;
    }

    if (cli.command == .steam_read) {
        const app_id = cli.app_id orelse return error.MissingAppId;
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var session = try bridge.steam.adapter.connect(allocator, app_id, steam_root);
        defer session.close();
        session.client.loadCurrentUserStats(init.io, app_id, 10_000) catch |err|
            std.debug.print("[SteamAdapter] appid={d} stats_refresh_warning={s}\n", .{ app_id, @errorName(err) });
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        std.debug.print("[SteamAdapter] connected=true appid={d} achievements={d}\n", .{ app_id, achievements.items.items.len });
        for (achievements.items.items, 0..) |achievement, index| {
            std.debug.print("[{d}] {s} {s} name={s}", .{ index, achievement.api_name, if (achievement.unlocked) "unlocked" else "locked", achievement.name });
            if (achievement.global_percent) |percent| std.debug.print(" global={d:.2}%", .{percent});
            if (achievement.unlock_time > 0) std.debug.print(" timestamp={d}", .{achievement.unlock_time});
            std.debug.print("\n", .{});
        }
        return;
    }

    if (cli.command == .catalog) {
        const app_id = cli.app_id orelse return error.MissingAppId;
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var session = try bridge.steam.adapter.connect(allocator, app_id, steam_root);
        defer session.close();
        session.client.loadCurrentUserStats(init.io, app_id, 10_000) catch |err|
            std.debug.print("[SteamCatalog] appid={d} stats_refresh_warning={s}\n", .{ app_id, @errorName(err) });
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        const store_path = cli.local_store_path orelse try defaultLocalStorePath(allocator, init.environ_map);
        var local = try bridge.local.store.Store.init(allocator, init.io, store_path);
        defer local.deinit();
        const json = try bridge.catalog.renderSteam(allocator, app_id, achievements.items.items, &local);
        defer allocator.free(json);
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }

    if (cli.command == .local_record) {
        if (!cli.confirm_local_write) return error.LocalWriteConfirmationRequired;
        const app_id = cli.app_id orelse return error.MissingAppId;
        const wanted = cli.achievement_id orelse return error.MissingAchievement;
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var session = try bridge.steam.adapter.connect(allocator, app_id, steam_root);
        defer session.close();
        session.client.loadCurrentUserStats(init.io, app_id, 10_000) catch |err|
            std.debug.print("[LocalStore] appid={d} stats_refresh_warning={s}\n", .{ app_id, @errorName(err) });
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        const achievement = findAchievement(achievements.items.items, wanted) orelse return error.AchievementNotFound;
        const unlocked_at = if (achievement.unlocked and achievement.unlock_time > 0) achievement.unlock_time else unixNow(init.io);
        const store_path = cli.local_store_path orelse try defaultLocalStorePath(allocator, init.environ_map);
        var local = try bridge.local.store.Store.init(allocator, init.io, store_path);
        defer local.deinit();
        try local.record(app_id, achievement.api_name, unlocked_at);
        std.debug.print(
            "[LocalStore] appid={d} achievement={s} name={s} recorded=true steam_was_unlocked={} path={s}\n",
            .{ app_id, achievement.api_name, achievement.name, achievement.unlocked, store_path },
        );
        return;
    }

    if (cli.command == .steam_unlock) {
        if (!cli.confirm_steam_write) return error.SteamWriteConfirmationRequired;
        const app_id = cli.app_id orelse return error.MissingAppId;
        const wanted = cli.achievement_id orelse return error.MissingAchievement;
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var session = try bridge.steam.adapter.connect(allocator, app_id, steam_root);
        defer session.close();
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        const achievement = findAchievement(achievements.items.items, wanted) orelse return error.AchievementNotFound;
        const result = bridge.steam.adapter.unlockAchievement(&session, allocator, init.io, achievement.api_name) catch |err| {
            if (err == error.SetAchievementFailed) std.debug.print(
                "[SteamWrite] appid={d} achievement={s} refused=true hint=achievement_may_be_protected_by_publisher\n",
                .{ app_id, achievement.api_name },
            );
            return err;
        };
        std.debug.print(
            "[SteamWrite] appid={d} achievement={s} name={s} result={s} server_acknowledged={}\n",
            .{ app_id, achievement.api_name, achievement.name, @tagName(result), result == .stored },
        );
        return;
    }

    if (cli.command == .rune_steam_sync) {
        const app_id = cli.app_id orelse return error.MissingAppId;
        const wanted = cli.achievement_id orelse return error.MissingAchievement;
        if (cli.roots.items.len == 0) try cli.roots.append(allocator, try defaultRuneRoot(allocator, init.environ_map));
        try verifyRuneUnlock(allocator, init.io, cli.roots.items, app_id, wanted);

        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var session = try bridge.steam.adapter.connect(allocator, app_id, steam_root);
        defer session.close();
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        const achievement = findAchievement(achievements.items.items, wanted) orelse return error.AchievementNotFound;
        const result = try bridge.steam.adapter.unlockAchievement(&session, allocator, init.io, achievement.api_name);
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .appid = app_id,
            .achievement = achievement.api_name,
            .verified_provider = "rune",
            .result = @tagName(result),
            .server_acknowledged = result == .stored or result == .already_unlocked,
        }, .{});
        defer allocator.free(json);
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }

    if (cli.command == .gse_steam_sync) {
        const app_id = cli.app_id orelse return error.MissingAppId;
        const wanted = cli.achievement_id orelse return error.MissingAchievement;
        if (cli.roots.items.len == 0) try addDefaultGseRoots(allocator, init.environ_map, &cli.roots);
        try verifyGseUnlock(allocator, init.io, cli.roots.items, app_id, wanted);

        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        var session = try bridge.steam.adapter.connect(allocator, app_id, steam_root);
        defer session.close();
        var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
        defer achievements.deinit();
        const achievement = findAchievement(achievements.items.items, wanted) orelse return error.AchievementNotFound;
        const result = try bridge.steam.adapter.unlockAchievement(&session, allocator, init.io, achievement.api_name);
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .appid = app_id,
            .achievement = achievement.api_name,
            .verified_provider = "gse",
            .result = @tagName(result),
            .server_acknowledged = result == .stored or result == .already_unlocked,
        }, .{});
        defer allocator.free(json);
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }

    if (cli.command == .watch_all) {
        const appdata = init.environ_map.get("APPDATA") orelse return error.MissingAppData;
        const localappdata = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
        const journal_path = cli.journal_path orelse try defaultJournalPath(allocator, init.environ_map);
        const replay_guard_path = try defaultR2ReplayGuardPath(allocator, init.environ_map);
        const gse_roots = &[_][]const u8{
            try std.fs.path.join(allocator, &.{ appdata, "GSE Saves" }),
            try std.fs.path.join(allocator, &.{ appdata, "Goldberg SteamEmu Saves" }),
        };
        const r2_roots = &[_][]const u8{
            try std.fs.path.join(allocator, &.{ appdata, "Goldberg UplayEmu Saves" }),
        };
        const rune_roots = &[_][]const u8{try defaultRuneRoot(allocator, init.environ_map)};
        const spool_root = try std.fs.path.join(allocator, &.{ localappdata, "Ubisoft Game Launcher", "spool" });
        const context = WatchAllContext{
            .io = init.io,
            .gse_roots = gse_roots,
            .r2_roots = r2_roots,
            .rune_roots = rune_roots,
            .spool_root = spool_root,
            .journal_path = journal_path,
            .replay_guard_path = replay_guard_path,
            .interval_ms = cli.interval_ms,
            .recover = cli.recover,
            .notifications = cli.notifications,
        };
        try runAllWatchers(&context);
        return;
    }

    if (cli.command == .steam_local_clear) {
        if (!cli.confirm_local_write) return error.LocalWriteConfirmationRequired;
        if (try steamRunning(allocator)) return error.SteamMustBeStoppedForLocalClear;
        const app_id = cli.app_id orelse return error.MissingAppId;
        const wanted = cli.achievement_id orelse return error.MissingAchievement;
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        const backup_root = try defaultBackupRoot(allocator, init.environ_map);
        var result = try bridge.steam.live_sync.clear(allocator, init.io, .{
            .app_id = app_id,
            .api_name = wanted,
            .steam_root = steam_root,
            .backup_root = backup_root,
        });
        defer result.deinit();
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .appid = app_id,
            .achievement = wanted,
            .changed = result.changed,
            .account_id = result.account_id,
            .stat_id = result.stat_id,
            .bit = result.bit,
            .permission = result.permission,
            .crc = result.crc,
            .stats_path = result.stats_path,
            .backup_path = result.backup_path,
        }, .{});
        defer allocator.free(json);
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }

    if (cli.command == .steam_local_sync) {
        const app_id = cli.app_id orelse return error.MissingAppId;
        const wanted = cli.achievement_id orelse return error.MissingAchievement;
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        const backup_root = try defaultBackupRoot(allocator, init.environ_map);
        const timestamp: u32 = cli.unlock_time orelse @intCast(@max(unixNow(init.io), 1));
        var result = try bridge.steam.live_sync.sync(allocator, init.io, .{
            .app_id = app_id,
            .api_name = wanted,
            .unlock_time = timestamp,
            .steam_root = steam_root,
            .backup_root = backup_root,
            .experimental_native_notification = cli.experimental_steam_notification,
        });
        defer result.deinit();
        const json = try std.json.Stringify.valueAlloc(allocator, .{
            .appid = app_id,
            .achievement = wanted,
            .changed = result.changed,
            .account_id = result.account_id,
            .stat_id = result.stat_id,
            .bit = result.bit,
            .permission = result.permission,
            .timestamp = result.unlock_time,
            .crc = result.crc,
            .host_status = @tagName(result.host_status),
            .cache_confirmed = result.cache_confirmed,
            .steam_refreshed = result.steam_refreshed,
            .steam_confirmed = result.steam_confirmed,
            .native_notification = @tagName(result.native_notification),
            .stats_path = result.stats_path,
            .backup_path = result.backup_path,
        }, .{});
        defer allocator.free(json);
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }

    if (cli.command == .steam_watch) {
        const app_id = cli.app_id orelse return error.MissingAppId;
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        const journal_path = cli.journal_path orelse try defaultJournalPath(allocator, init.environ_map);
        try bridge.providers.steam.watcher.run(allocator, init.io, .{
            .app_id = app_id,
            .steam_root = steam_root,
            .journal_path = journal_path,
            .interval_ms = cli.interval_ms,
            .recover = cli.recover,
            .notifications = cli.notifications,
        });
        return;
    }

    if (cli.command == .ubisoft_scan or cli.command == .ubisoft_watch) {
        const localappdata = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
        const spool_root = if (cli.roots.items.len > 0) cli.roots.items[0] else try std.fs.path.join(allocator, &.{ localappdata, "Ubisoft Game Launcher", "spool" });
        if (cli.command == .ubisoft_scan) {
            try bridge.providers.ubisoft.watcher.scan(allocator, init.io, spool_root);
        } else {
            const journal_path = cli.journal_path orelse try defaultJournalPath(allocator, init.environ_map);
            try bridge.providers.ubisoft.watcher.run(allocator, init.io, .{
                .spool_root = spool_root,
                .journal_path = journal_path,
                .interval_ms = cli.interval_ms,
                .recover = cli.recover,
                .notifications = cli.notifications,
            });
        }
        return;
    }

    if (cli.command == .uplay_r2_diagnose) {
        const game_dir = cli.game_dir orelse return error.MissingGameDir;
        const report = try bridge.providers.uplay_r2.diagnostic.diagnose(allocator, init.io, game_dir);
        std.debug.print("[UplayR2Provider] loader={} config={} schema={} enabled={} ready={}\n", .{
            report.loader_found,
            report.config_found,
            report.schema_found,
            report.achievements_enabled,
            report.ready(),
        });
        return;
    }

    if (cli.command == .uplay_r2_prepare) {
        const game_dir = cli.game_dir orelse return error.MissingGameDir;
        const catalog_path = cli.catalog_path orelse return error.MissingCatalog;
        const before = try bridge.providers.uplay_r2.diagnostic.diagnose(allocator, init.io, game_dir);
        if (!before.loader_found) return error.UplayR2LoaderNotFound;
        if (!before.config_found) return error.UplayR2ConfigNotFound;

        const catalog_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, catalog_path, allocator, .limited(32 * 1024 * 1024));
        defer allocator.free(catalog_bytes);
        var rendered = try bridge.providers.uplay_r2.schema.renderCatalog(allocator, catalog_bytes);
        defer rendered.deinit(allocator);

        const schema_path = try std.fs.path.join(allocator, &.{ game_dir, "achievements_schema.json" });
        try backupExisting(allocator, init.io, schema_path);
        try writeAtomic(init.io, schema_path, rendered.bytes);

        const config_path = try findUplayR2Config(allocator, init.io, game_dir);
        const config_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, config_path, allocator, .limited(1024 * 1024));
        defer allocator.free(config_bytes);
        const enabled_config = try bridge.providers.uplay_r2.schema.enableAchievements(allocator, config_bytes);
        defer allocator.free(enabled_config);
        try backupExisting(allocator, init.io, config_path);
        try writeAtomic(init.io, config_path, enabled_config);

        const after = try bridge.providers.uplay_r2.diagnostic.diagnose(allocator, init.io, game_dir);
        std.debug.print(
            "[UplayR2Prepare] schema={s} achievements={d} ignored_legacy_ids={d} backup_suffix=.achievement-bridge.bak ready={}\n",
            .{ schema_path, rendered.info.achievement_count, rendered.info.ignored_legacy_ids, after.ready() },
        );
        return;
    }

    if (cli.command == .uplay_r2_arm_replay) {
        if (!cli.confirm_local_write) return error.LocalWriteConfirmationRequired;
        const product_id = cli.app_id orelse return error.MissingAppId;
        const achievement = cli.achievement_id orelse return error.MissingAchievement;
        const replay_guard_path = try defaultR2ReplayGuardPath(allocator, init.environ_map);
        try bridge.providers.uplay_r2.replay_guard.arm(allocator, init.io, replay_guard_path, product_id, achievement);
        std.debug.print(
            "[UplayR2ReplayGuard] product_id={d} achievement={s} state=armed path={s}\n",
            .{ product_id, achievement, replay_guard_path },
        );
        return;
    }

    if (cli.command == .notify_test) {
        if (!cli.confirm_steam_write) return error.TemporarySteamWriteConfirmationRequired;
        const app_id = cli.app_id orelse return error.MissingAppId;
        const wanted = cli.achievement_id orelse return error.MissingAchievement;
        if (cli.wait_for_game) {
            const game_dir = cli.game_dir orelse return error.MissingGameDir;
            std.debug.print("[NotificationPreview] status=waiting_for_game dir={s}\n", .{game_dir});
            while (!try gameRunning(game_dir)) try std.Io.sleep(init.io, .fromMilliseconds(500), .awake);
            std.debug.print("[NotificationPreview] status=game_detected\n", .{});
        }
        const steam_root = if (cli.steam_root) |root| try allocator.dupe(u8, root) else try bridge.detector.steam_install.findSteamRoot(allocator, init.io);
        try simulateSteamNotification(allocator, init.io, app_id, steam_root, wanted, cli.duration_ms);
        return;
    }

    if (cli.command == .uplay_r2_scan or cli.command == .uplay_r2_watch) {
        if (cli.roots.items.len == 0) {
            if (init.environ_map.get("APPDATA")) |appdata| try cli.roots.append(allocator, try std.fs.path.join(allocator, &.{ appdata, "Goldberg UplayEmu Saves" }));
            if (cli.game_dir) |game_dir| try cli.roots.append(allocator, try std.fs.path.join(allocator, &.{ game_dir, "saves" }));
        }
        if (cli.command == .uplay_r2_scan) {
            try bridge.providers.uplay_r2.watcher.scan(allocator, init.io, cli.roots.items);
        } else {
            const journal_path = cli.journal_path orelse try defaultJournalPath(allocator, init.environ_map);
            const replay_guard_path = try defaultR2ReplayGuardPath(allocator, init.environ_map);
            const mapping_root: ?[]const u8 = if (cli.app_id != null)
                if (cli.steam_root) |root| root else bridge.detector.steam_install.findSteamRoot(allocator, init.io) catch null
            else
                null;
            try bridge.providers.uplay_r2.watcher.run(allocator, init.io, .{
                .roots = cli.roots.items,
                .journal_path = journal_path,
                .interval_ms = cli.interval_ms,
                .recover = cli.recover,
                .notifications = cli.notifications,
                .steam_app_id = cli.app_id,
                .steam_root = mapping_root,
                .replay_guard_path = replay_guard_path,
            });
        }
        return;
    }

    if (cli.command == .rune_scan or cli.command == .rune_watch) {
        if (cli.roots.items.len == 0) try cli.roots.append(allocator, try defaultRuneRoot(allocator, init.environ_map));
        if (cli.command == .rune_scan) {
            try bridge.providers.rune.watcher.scan(allocator, init.io, cli.roots.items);
        } else {
            const rune_journal_path = cli.journal_path orelse try defaultJournalPath(allocator, init.environ_map);
            const rune_steam_root: ?[]const u8 = if (cli.steam_mapping)
                if (cli.steam_root) |root| root else bridge.detector.steam_install.findSteamRoot(allocator, init.io) catch null
            else
                null;
            try bridge.providers.rune.watcher.run(allocator, init.io, .{
                .roots = cli.roots.items,
                .journal_path = rune_journal_path,
                .interval_ms = cli.interval_ms,
                .recover = cli.recover,
                .notifications = cli.notifications,
                .steam_root = rune_steam_root,
            });
        }
        return;
    }

    if (cli.roots.items.len == 0) {
        if (init.environ_map.get("APPDATA")) |appdata| {
            try cli.roots.append(allocator, try std.fs.path.join(allocator, &.{ appdata, "GSE Saves" }));
            try cli.roots.append(allocator, try std.fs.path.join(allocator, &.{ appdata, "Goldberg SteamEmu Saves" }));
        }
    }
    if (cli.roots.items.len == 0) return error.NoGseRoot;

    const journal_path = cli.journal_path orelse try defaultJournalPath(allocator, init.environ_map);
    const mapping_steam_root: ?[]const u8 = if (cli.steam_mapping)
        if (cli.steam_root) |root| root else bridge.detector.steam_install.findSteamRoot(allocator, init.io) catch null
    else
        null;

    switch (cli.command) {
        .scan => try bridge.gse.watcher.scan(allocator, init.io, cli.roots.items),
        .watch => try bridge.gse.watcher.run(allocator, init.io, .{
            .roots = cli.roots.items,
            .journal_path = journal_path,
            .interval_ms = cli.interval_ms,
            .recover = cli.recover,
            .notifications = cli.notifications,
            .schema_paths = cli.schema_paths.items,
            .language = cli.language,
            .steam_root = mapping_steam_root,
        }),
        .watch_all => unreachable,
        .probe => unreachable,
        .games => unreachable,
        .sessions => unreachable,
        .host => unreachable,
        .catalog => unreachable,
        .local_record => unreachable,
        .steam_read => unreachable,
        .steam_unlock => unreachable,
        .steam_local_clear => unreachable,
        .steam_local_sync, .gse_steam_sync => unreachable,
        .steam_watch => unreachable,
        .rune_scan => unreachable,
        .rune_watch => unreachable,
        .rune_steam_sync => unreachable,
        .ubisoft_scan => unreachable,
        .ubisoft_watch => unreachable,
        .uplay_r2_diagnose => unreachable,
        .uplay_r2_prepare => unreachable,
        .uplay_r2_arm_replay => unreachable,
        .uplay_r2_scan => unreachable,
        .uplay_r2_watch => unreachable,
        .notify_test => unreachable,
        .help => unreachable,
    }
}

const WatchAllContext = struct {
    io: std.Io,
    gse_roots: []const []const u8,
    r2_roots: []const []const u8,
    rune_roots: []const []const u8,
    spool_root: []const u8,
    journal_path: []const u8,
    replay_guard_path: []const u8,
    interval_ms: u32,
    recover: bool,
    notifications: bool,
};

fn runAllWatchers(context: *const WatchAllContext) !void {
    std.debug.print("[AchievementBridge] mode=watch-all providers=gse,rune,ubisoft,uplay_r2 sessions=enabled\n", .{});
    const session_thread = try std.Thread.spawn(.{}, watchSessionWorker, .{context});
    const gse_thread = try std.Thread.spawn(.{}, watchGseWorker, .{context});
    const rune_thread = try std.Thread.spawn(.{}, watchRuneWorker, .{context});
    const ubisoft_thread = try std.Thread.spawn(.{}, watchUbisoftWorker, .{context});
    const r2_thread = try std.Thread.spawn(.{}, watchR2Worker, .{context});
    session_thread.join();
    gse_thread.join();
    rune_thread.join();
    ubisoft_thread.join();
    r2_thread.join();
}

fn watchSessionWorker(context: *const WatchAllContext) void {
    while (true) {
        runSessionMonitor(context) catch |err| {
            std.debug.print("[AchievementBridge] provider=sessions restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn runSessionMonitor(context: *const WatchAllContext) !void {
    const allocator = std.heap.smp_allocator;
    const steam_root = try bridge.detector.steam_install.findSteamRoot(allocator, context.io);
    defer allocator.free(steam_root);
    var catalog = try bridge.detector.steam_install.discover(allocator, context.io, steam_root);
    defer catalog.deinit();
    var monitor = bridge.host.session_monitor.Monitor.init(allocator, context.io, &catalog);
    defer monitor.deinit();
    try monitor.run(.{ .interval_ms = @max(context.interval_ms, 1000) });
}

fn watchRuneWorker(context: *const WatchAllContext) void {
    while (true) {
        bridge.providers.rune.watcher.run(std.heap.smp_allocator, context.io, .{
            .roots = context.rune_roots,
            .journal_path = context.journal_path,
            .interval_ms = context.interval_ms,
            .recover = context.recover,
            .notifications = context.notifications,
            // watch-all lives for the whole LuaTools session. Initializing the
            // Steam client here makes Steam associate this process with the
            // queried App ID until the process exits. Metadata and local Steam
            // sync are deliberately handled by LuaTools through short-lived
            // Bridge commands after an actual provider event is emitted.
            .steam_root = null,
        }) catch |err| {
            std.debug.print("[AchievementBridge] provider=rune restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn watchGseWorker(context: *const WatchAllContext) void {
    while (true) {
        bridge.gse.watcher.run(std.heap.smp_allocator, context.io, .{
            .roots = context.gse_roots,
            .journal_path = context.journal_path,
            .interval_ms = context.interval_ms,
            .recover = context.recover,
            .notifications = context.notifications,
            // Keep the persistent watcher detached from every Steam App ID.
            // LuaTools enriches and synchronizes emitted events in isolated,
            // short-lived Bridge processes.
            .steam_root = null,
        }) catch |err| {
            std.debug.print("[AchievementBridge] provider=gse restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn watchUbisoftWorker(context: *const WatchAllContext) void {
    while (true) {
        bridge.providers.ubisoft.watcher.run(std.heap.smp_allocator, context.io, .{
            .spool_root = context.spool_root,
            .journal_path = context.journal_path,
            .interval_ms = context.interval_ms,
            .recover = context.recover,
            .notifications = context.notifications,
        }) catch |err| {
            std.debug.print("[AchievementBridge] provider=ubisoft restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn watchR2Worker(context: *const WatchAllContext) void {
    while (true) {
        bridge.providers.uplay_r2.watcher.run(std.heap.smp_allocator, context.io, .{
            .roots = context.r2_roots,
            .journal_path = context.journal_path,
            .replay_guard_path = context.replay_guard_path,
            .interval_ms = context.interval_ms,
            .recover = context.recover,
            .notifications = context.notifications,
        }) catch |err| {
            std.debug.print("[AchievementBridge] provider=uplay_r2 restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Cli {
    var cli = Cli{};
    var index: usize = 1;
    if (index < args.len and !std.mem.startsWith(u8, args[index], "--")) {
        if (std.mem.eql(u8, args[index], "scan")) cli.command = .scan else if (std.mem.eql(u8, args[index], "watch")) cli.command = .watch else if (std.mem.eql(u8, args[index], "watch-all")) cli.command = .watch_all else if (std.mem.eql(u8, args[index], "probe")) cli.command = .probe else if (std.mem.eql(u8, args[index], "games")) cli.command = .games else if (std.mem.eql(u8, args[index], "sessions")) cli.command = .sessions else if (std.mem.eql(u8, args[index], "host")) cli.command = .host else if (std.mem.eql(u8, args[index], "catalog")) cli.command = .catalog else if (std.mem.eql(u8, args[index], "local-record")) cli.command = .local_record else if (std.mem.eql(u8, args[index], "steam-read")) cli.command = .steam_read else if (std.mem.eql(u8, args[index], "steam-unlock")) cli.command = .steam_unlock else if (std.mem.eql(u8, args[index], "steam-local-clear")) cli.command = .steam_local_clear else if (std.mem.eql(u8, args[index], "steam-local-sync")) cli.command = .steam_local_sync else if (std.mem.eql(u8, args[index], "steam-watch")) cli.command = .steam_watch else if (std.mem.eql(u8, args[index], "gse-steam-sync")) cli.command = .gse_steam_sync else if (std.mem.eql(u8, args[index], "rune-scan")) cli.command = .rune_scan else if (std.mem.eql(u8, args[index], "rune-watch")) cli.command = .rune_watch else if (std.mem.eql(u8, args[index], "rune-steam-sync")) cli.command = .rune_steam_sync else if (std.mem.eql(u8, args[index], "ubisoft-scan")) cli.command = .ubisoft_scan else if (std.mem.eql(u8, args[index], "ubisoft-watch")) cli.command = .ubisoft_watch else if (std.mem.eql(u8, args[index], "uplay-r2-diagnose")) cli.command = .uplay_r2_diagnose else if (std.mem.eql(u8, args[index], "uplay-r2-prepare")) cli.command = .uplay_r2_prepare else if (std.mem.eql(u8, args[index], "uplay-r2-arm-replay")) cli.command = .uplay_r2_arm_replay else if (std.mem.eql(u8, args[index], "uplay-r2-scan")) cli.command = .uplay_r2_scan else if (std.mem.eql(u8, args[index], "uplay-r2-watch")) cli.command = .uplay_r2_watch else if (std.mem.eql(u8, args[index], "notify-test")) cli.command = .notify_test else if (std.mem.eql(u8, args[index], "help")) cli.command = .help else return error.UnknownCommand;
        index += 1;
    }
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            cli.command = .help;
        } else if (std.mem.eql(u8, arg, "--no-recovery")) {
            cli.recover = false;
        } else if (std.mem.eql(u8, arg, "--no-notifications")) {
            cli.notifications = false;
        } else if (std.mem.eql(u8, arg, "--no-steam-mapping")) {
            cli.steam_mapping = false;
        } else if (std.mem.eql(u8, arg, "--once")) {
            cli.once = true;
        } else if (std.mem.eql(u8, arg, "--wait-for-game")) {
            cli.wait_for_game = true;
        } else if (std.mem.eql(u8, arg, "--confirm-steam-write")) {
            cli.confirm_steam_write = true;
        } else if (std.mem.eql(u8, arg, "--confirm-local-write")) {
            cli.confirm_local_write = true;
        } else if (std.mem.eql(u8, arg, "--experimental-steam-notification")) {
            cli.experimental_steam_notification = true;
        } else if (std.mem.eql(u8, arg, "--local-store")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.local_store_path = args[index];
        } else if (std.mem.eql(u8, arg, "--catalog")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.catalog_path = args[index];
        } else if (std.mem.eql(u8, arg, "--achievement")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.achievement_id = args[index];
        } else if (std.mem.eql(u8, arg, "--timestamp")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.unlock_time = try std.fmt.parseInt(u32, args[index], 10);
            if (cli.unlock_time.? == 0) return error.InvalidAchievementUnlockTime;
        } else if (std.mem.eql(u8, arg, "--duration-ms")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.duration_ms = try std.fmt.parseInt(u32, args[index], 10);
            if (cli.duration_ms < 1000 or cli.duration_ms > 60_000) return error.InvalidNotificationDuration;
        } else if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            try cli.roots.append(allocator, args[index]);
        } else if (std.mem.eql(u8, arg, "--game-dir")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.game_dir = args[index];
        } else if (std.mem.eql(u8, arg, "--steam-root")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.steam_root = args[index];
        } else if (std.mem.eql(u8, arg, "--schema")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            try cli.schema_paths.append(allocator, args[index]);
        } else if (std.mem.eql(u8, arg, "--language")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.language = args[index];
        } else if (std.mem.eql(u8, arg, "--appid")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.app_id = try std.fmt.parseInt(u32, args[index], 10);
        } else if (std.mem.eql(u8, arg, "--journal")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.journal_path = args[index];
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            index += 1;
            if (index >= args.len) return error.MissingOptionValue;
            cli.interval_ms = try std.fmt.parseInt(u32, args[index], 10);
            if (cli.interval_ms < 100) return error.IntervalTooSmall;
        } else {
            return error.UnknownOption;
        }
    }
    return cli;
}

fn printHelp() void {
    std.debug.print(
        \\Achievement Bridge 0.1.0 - GSE Provider MVP
        \\
        \\Uso:
        \\  achievement-bridge scan [--root PATH]
        \\  achievement-bridge watch [--root PATH] [--journal PATH] [--interval-ms 500]
        \\  achievement-bridge watch-all [--journal PATH] [--interval-ms 500]
        \\  achievement-bridge probe --game-dir PATH
        \\  achievement-bridge games [--steam-root PATH]
        \\  achievement-bridge sessions [--steam-root PATH]
        \\  achievement-bridge host [--steam-root PATH] [--interval-ms 1000]
        \\  achievement-bridge catalog --appid ID [--steam-root PATH]
        \\  achievement-bridge local-record --appid ID --achievement API_NAME --confirm-local-write
        \\  achievement-bridge steam-read --appid ID [--steam-root PATH]
        \\  achievement-bridge steam-unlock --appid ID --achievement API_NAME --confirm-steam-write
        \\  achievement-bridge steam-local-clear --appid ID --achievement API_NAME --confirm-local-write
        \\  achievement-bridge steam-local-sync --appid ID --achievement API_NAME [--timestamp UNIX] [--experimental-steam-notification]
        \\  achievement-bridge steam-watch --appid ID [--steam-root PATH]
        \\  achievement-bridge gse-steam-sync --appid ID --achievement API_NAME [--root GSE_PATH]
        \\  achievement-bridge rune-scan [--root RUNE_PATH]
        \\  achievement-bridge rune-watch [--root RUNE_PATH]
        \\  achievement-bridge rune-steam-sync --appid ID --achievement API_NAME [--root RUNE_PATH]
        \\  achievement-bridge ubisoft-scan [--root SPOOL_PATH]
        \\  achievement-bridge ubisoft-watch [--root SPOOL_PATH]
        \\  achievement-bridge uplay-r2-diagnose --game-dir PATH
        \\  achievement-bridge uplay-r2-prepare --game-dir PATH --catalog FILE
        \\  achievement-bridge uplay-r2-arm-replay --appid R2_PRODUCT_ID --achievement ID --confirm-local-write
        \\  achievement-bridge uplay-r2-scan [--root SAVE_PATH]
        \\  achievement-bridge uplay-r2-watch [--root SAVE_PATH] [--appid STEAM_ID]
        \\  achievement-bridge notify-test --appid ID --achievement API_NAME --confirm-steam-write
        \\
        \\Sem --root, observa automaticamente:
        \\  %APPDATA%\\GSE Saves
        \\  %APPDATA%\\Goldberg SteamEmu Saves
        \\  %PUBLIC%\\Documents\\Steam\\RUNE
        \\
        \\Opcoes:
        \\  --root PATH        Root contendo pastas <appid>, ou a propria pasta <appid>
        \\  --game-dir PATH    Pasta do jogo para detectar runtimes e providers
        \\  --steam-root PATH  Sobrescrever a instalacao Steam detectada no Registry
        \\  --schema PATH      Schema GSE steam_settings/achievements.json (repetivel)
        \\  --catalog PATH     Catalogo ordenado para gerar achievements_schema.json
        \\  --achievement ID   API name ou sufixo numerico para a previa da notificacao
        \\  --timestamp UNIX   Momento original do unlock usado pela sincronizacao local automatica
        \\  --duration-ms N    Tempo antes do rollback da previa (1000-60000; padrao: 7000)
        \\  --wait-for-game    Aguardar um processo do diretorio do jogo antes da previa
        \\  --confirm-steam-write Confirmacao obrigatoria para alterar conquistas da conta Steam
        \\  --confirm-local-write Confirmacao obrigatoria para alterar estado local ou o store local
        \\  --experimental-steam-notification Tentar toast do Overlay via StoreStats ou progresso (experimental)
        \\  --local-store PATH Sobrescrever o arquivo JSON de conquistas locais
        \\  --language LANG    Idioma do metadata local (padrao: brazilian)
        \\  --appid ID         Steam AppID para operacoes somente leitura
        \\  --journal PATH     Journal JSONL para recovery e deduplicacao
        \\  --no-recovery      Nao reproduzir unlocks ocorridos enquanto o bridge estava fechado
        \\  --no-notifications Desativar popup e som nativos do Windows
        \\  --no-steam-mapping Nao buscar metadata/mapping exato pelo Steam Client
        \\  --once             Executar apenas um ciclo do monitor de sessoes
        \\  --interval-ms N    Intervalo de observacao (minimo 100 ms)
        \\  -h, --help         Mostrar esta ajuda
        \\
    , .{});
}

fn defaultJournalPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("LOCALAPPDATA")) |localappdata| {
        return std.fs.path.join(allocator, &.{ localappdata, "AchievementBridge", "journal.jsonl" });
    }
    return ".achievement-bridge/journal.jsonl";
}

fn defaultRuneRoot(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("PUBLIC")) |public| {
        return std.fs.path.join(allocator, &.{ public, "Documents", "Steam", "RUNE" });
    }
    if (environ_map.get("SystemDrive")) |drive| {
        return std.fs.path.join(allocator, &.{ drive, "Users", "Public", "Documents", "Steam", "RUNE" });
    }
    return error.MissingPublicProfile;
}

fn addDefaultGseRoots(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map, roots: *std.ArrayList([]const u8)) !void {
    const appdata = environ_map.get("APPDATA") orelse return error.MissingAppData;
    try roots.append(allocator, try std.fs.path.join(allocator, &.{ appdata, "GSE Saves" }));
    try roots.append(allocator, try std.fs.path.join(allocator, &.{ appdata, "Goldberg SteamEmu Saves" }));
}

fn verifyGseUnlock(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, app_id: u32, api_name: []const u8) !void {
    var candidates = try bridge.gse.discovery.discover(allocator, io, roots);
    defer candidates.deinit();
    for (candidates.items.items) |candidate| {
        if (candidate.app_id != app_id) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, candidate.state_file, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        var state = try bridge.gse.snapshot.parse(allocator, bytes);
        defer state.deinit();
        const achievement = state.achievements.get(api_name) orelse return error.GseAchievementNotFound;
        if (!achievement.earned) return error.GseAchievementNotUnlocked;
        return;
    }
    return error.GseAppNotFound;
}

fn verifyRuneUnlock(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, app_id: u32, api_name: []const u8) !void {
    var candidates = try bridge.providers.rune.discovery.discover(allocator, io, roots);
    defer candidates.deinit();
    for (candidates.items.items) |candidate| {
        if (candidate.app_id != app_id) continue;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, candidate.state_file, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(bytes);
        var state = try bridge.providers.rune.snapshot.parse(allocator, bytes);
        defer state.deinit();
        const achievement = state.achievements.get(api_name) orelse return error.RuneAchievementNotFound;
        if (!achievement.earned) return error.RuneAchievementNotUnlocked;
        return;
    }
    return error.RuneAppNotFound;
}

fn defaultLocalStorePath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("LOCALAPPDATA")) |localappdata| {
        return std.fs.path.join(allocator, &.{ localappdata, "AchievementBridge", "local-achievements.json" });
    }
    return ".achievement-bridge/local-achievements.json";
}

fn defaultR2ReplayGuardPath(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("LOCALAPPDATA")) |localappdata| {
        return std.fs.path.join(allocator, &.{ localappdata, "AchievementBridge", "r2-replay-guard.json" });
    }
    return ".achievement-bridge/r2-replay-guard.json";
}

fn defaultBackupRoot(allocator: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    if (environ_map.get("LOCALAPPDATA")) |localappdata| {
        return std.fs.path.join(allocator, &.{ localappdata, "AchievementBridge", "backups" });
    }
    return ".achievement-bridge/backups";
}

fn findAchievement(items: []const bridge.steam.user_stats.AchievementState, wanted: []const u8) ?*const bridge.steam.user_stats.AchievementState {
    for (items) |*achievement| {
        if (std.ascii.eqlIgnoreCase(achievement.api_name, wanted)) return achievement;
        if (numericSuffix(achievement.api_name)) |suffix| if (std.mem.eql(u8, suffix, wanted)) return achievement;
    }
    return null;
}

fn simulateSteamNotification(
    allocator: std.mem.Allocator,
    io: std.Io,
    app_id: u32,
    steam_root: []const u8,
    wanted: []const u8,
    duration_ms: u32,
) !void {
    var session = try bridge.steam.adapter.connect(allocator, app_id, steam_root);
    defer session.close();
    try session.client.loadCurrentUserStats(io, app_id, 5000);
    var achievements = try bridge.steam.adapter.listAchievements(&session, allocator);
    defer achievements.deinit();
    const achievement = findAchievement(achievements.items.items, wanted) orelse return error.AchievementNotFound;
    if (achievement.unlocked) return error.AchievementAlreadyUnlockedForPreview;

    try bridge.steam.adapter.previewAchievementUnlock(&session, allocator, io, achievement.api_name, duration_ms);
    std.debug.print(
        "[SteamNotificationPreview] appid={d} achievement={s} name={s} native_unlock_toast=true temporary_unlock_stored=true rollback_stored=true state_after=locked requested_duration_ms={d}\n",
        .{
            app_id,
            achievement.api_name,
            achievement.name,
            duration_ms,
        },
    );
}

fn numericSuffix(api_name: []const u8) ?[]const u8 {
    var start = api_name.len;
    while (start > 0 and std.ascii.isDigit(api_name[start - 1])) start -= 1;
    if (start == api_name.len) return null;
    return api_name[start..];
}

fn findUplayR2Config(allocator: std.mem.Allocator, io: std.Io, game_dir: []const u8) ![]u8 {
    for ([_][]const u8{ "upc_r2.ini", "uplay_r2.ini" }) |name| {
        const path = try std.fs.path.join(allocator, &.{ game_dir, name });
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }
    return error.UplayR2ConfigNotFound;
}

fn backupExisting(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().access(io, path, .{}) catch return;
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.achievement-bridge.bak", .{path});
    defer allocator.free(backup_path);
    if (std.Io.Dir.cwd().access(io, backup_path, .{})) |_| return else |_| {}
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    try writeAtomic(io, backup_path, bytes);
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

fn unixNow(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn steamRunning(allocator: std.mem.Allocator) !bool {
    var processes = try bridge.detector.process.enumerate(allocator);
    defer processes.deinit();
    for (processes.items.items) |process| {
        if (std.ascii.eqlIgnoreCase(process.name, "steam.exe")) return true;
    }
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

fn findContainingApp(catalog: *const bridge.detector.steam_install.Catalog, executable_path: []const u8) ?*const bridge.detector.steam_install.InstalledApp {
    for (catalog.apps.items) |*app| {
        if (executable_path.len <= app.install_dir.len) continue;
        if (!std.ascii.startsWithIgnoreCase(executable_path, app.install_dir)) continue;
        const boundary = executable_path[app.install_dir.len];
        if (boundary == '\\' or boundary == '/') return app;
    }
    return null;
}

test "parse CLI roots and interval" {
    const allocator = std.testing.allocator;
    var cli = try parseArgs(allocator, &.{ "achievement-bridge", "watch", "--root", "X:/saves", "--interval-ms", "750" });
    defer cli.roots.deinit(allocator);
    try std.testing.expectEqual(Command.watch, cli.command);
    try std.testing.expectEqual(@as(u32, 750), cli.interval_ms);
    try std.testing.expectEqualStrings("X:/saves", cli.roots.items[0]);
}

test "parse experimental Steam notification opt-in" {
    const allocator = std.testing.allocator;
    var cli = try parseArgs(allocator, &.{
        "achievement-bridge",
        "steam-local-sync",
        "--appid",
        "3751950",
        "--achievement",
        "ACObsidian_Ach_10",
        "--experimental-steam-notification",
    });
    defer cli.roots.deinit(allocator);
    defer cli.schema_paths.deinit(allocator);
    try std.testing.expectEqual(Command.steam_local_sync, cli.command);
    try std.testing.expect(cli.experimental_steam_notification);
}

test "parse temporary Steam unlock preview" {
    const allocator = std.testing.allocator;
    var cli = try parseArgs(allocator, &.{
        "achievement-bridge",
        "notify-test",
        "--appid",
        "2638890",
        "--achievement",
        "ACHIEVEMENT_050",
        "--confirm-steam-write",
        "--duration-ms",
        "9000",
    });
    defer cli.roots.deinit(allocator);
    defer cli.schema_paths.deinit(allocator);
    try std.testing.expectEqual(Command.notify_test, cli.command);
    try std.testing.expectEqual(@as(u32, 2638890), cli.app_id.?);
    try std.testing.expectEqualStrings("ACHIEVEMENT_050", cli.achievement_id.?);
    try std.testing.expectEqual(@as(u32, 9000), cli.duration_ms);
    try std.testing.expect(cli.confirm_steam_write);
    try std.testing.expect(!cli.confirm_local_write);
}

test "parse RUNE watcher command" {
    const allocator = std.testing.allocator;
    var cli = try parseArgs(allocator, &.{ "achievement-bridge", "rune-watch", "--root", "C:/RUNE", "--interval-ms", "250" });
    defer cli.roots.deinit(allocator);
    defer cli.schema_paths.deinit(allocator);
    try std.testing.expectEqual(Command.rune_watch, cli.command);
    try std.testing.expectEqualStrings("C:/RUNE", cli.roots.items[0]);
    try std.testing.expectEqual(@as(u32, 250), cli.interval_ms);
}

test "RUNE Steam sync requires app and achievement" {
    const allocator = std.testing.allocator;
    var cli = try parseArgs(allocator, &.{ "achievement-bridge", "rune-steam-sync", "--appid", "3046600", "--achievement", "ACHIEVEMENT_02" });
    defer cli.roots.deinit(allocator);
    defer cli.schema_paths.deinit(allocator);
    try std.testing.expectEqual(Command.rune_steam_sync, cli.command);
    try std.testing.expectEqual(@as(u32, 3046600), cli.app_id.?);
    try std.testing.expectEqualStrings("ACHIEVEMENT_02", cli.achievement_id.?);
}

test "GSE Steam sync requires app and achievement" {
    const allocator = std.testing.allocator;
    var cli = try parseArgs(allocator, &.{ "achievement-bridge", "gse-steam-sync", "--appid", "2638890", "--achievement", "ACHIEVEMENT_002" });
    defer cli.roots.deinit(allocator);
    defer cli.schema_paths.deinit(allocator);
    try std.testing.expectEqual(Command.gse_steam_sync, cli.command);
    try std.testing.expectEqual(@as(u32, 2638890), cli.app_id.?);
    try std.testing.expectEqualStrings("ACHIEVEMENT_002", cli.achievement_id.?);
}

test "parse confirmed local achievement clear" {
    const allocator = std.testing.allocator;
    var cli = try parseArgs(allocator, &.{
        "achievement-bridge",
        "steam-local-clear",
        "--appid",
        "3751950",
        "--achievement",
        "ACObsidian_Ach_10",
        "--confirm-local-write",
    });
    defer cli.roots.deinit(allocator);
    defer cli.schema_paths.deinit(allocator);
    try std.testing.expectEqual(Command.steam_local_clear, cli.command);
    try std.testing.expect(cli.confirm_local_write);
}
