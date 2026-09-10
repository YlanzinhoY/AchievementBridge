const std = @import("std");
const event = @import("../../core/event.zig");
const Journal = @import("../../core/journal.zig").Journal;
const discovery = @import("discovery.zig");
const snapshot = @import("snapshot.zig");
const WindowsNotifier = @import("../../notifications/windows.zig").Notifier;
const MetadataCatalog = @import("../../core/metadata.zig").Catalog;
const steam_metadata = @import("../../steam/metadata.zig");
const mapper = @import("../../core/mapper.zig");
const steam_install = @import("../../detector/steam_install.zig");
const process_detector = @import("../../detector/process.zig");
const gtav_enhanced = @import("games/gtav_enhanced.zig");

pub const Options = struct {
    roots: []const []const u8,
    journal_path: []const u8,
    interval_ms: u32 = 500,
    recover: bool = true,
    notifications: bool = true,
    steam_root: ?[]const u8 = null,
    stop_requested: ?*const std.atomic.Value(bool) = null,
};

const TrackedState = struct {
    app_id: u32,
    state_file: []u8,
    state: snapshot.Snapshot,
    mtime_ns: i96,
    file_size: u64,

    fn deinit(self: *TrackedState, allocator: std.mem.Allocator) void {
        self.state.deinit();
        allocator.free(self.state_file);
        self.* = undefined;
    }
};

const GtavEnhancedState = struct {
    monitor: gtav_enhanced.Monitor,
    previous: ?gtav_enhanced.UnlockSet = null,
    pid: ?u32 = null,
    last_error: ?anyerror = null,

    fn init(allocator: std.mem.Allocator) GtavEnhancedState {
        return .{ .monitor = gtav_enhanced.Monitor.init(allocator) };
    }

    fn deinit(self: *GtavEnhancedState) void {
        self.monitor.deinit();
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var journal = try Journal.init(allocator, io, options.journal_path);
    defer journal.deinit();
    var tracked: std.ArrayList(TrackedState) = .empty;
    defer {
        for (tracked.items) |*state| state.deinit(allocator);
        tracked.deinit(allocator);
    }
    var notifier: ?WindowsNotifier = if (options.notifications) WindowsNotifier.init() catch |err| fallback: {
        std.debug.print("[RockstarProvider] notifications=fallback reason={s}\n", .{@errorName(err)});
        break :fallback null;
    } else null;
    defer if (notifier) |*active| active.deinit();
    var metadata = MetadataCatalog.init(allocator);
    defer metadata.deinit();
    var metadata_attempted = std.AutoHashMap(u32, void).init(allocator);
    defer metadata_attempted.deinit();
    var detected_steam_root: ?[]u8 = null;
    defer if (detected_steam_root) |root| allocator.free(root);
    const steam_root = options.steam_root orelse root: {
        detected_steam_root = steam_install.findSteamRoot(allocator, io) catch null;
        break :root if (detected_steam_root) |root| root else null;
    };
    var steam_catalog: ?steam_install.Catalog = if (steam_root) |root|
        steam_install.discover(allocator, io, root) catch null
    else
        null;
    defer if (steam_catalog) |*catalog| catalog.deinit();
    var resolved_options = options;
    resolved_options.steam_root = steam_root;
    var gtav_state = GtavEnhancedState.init(allocator);
    defer gtav_state.deinit();

    std.debug.print("[RockstarProvider] status=discovering source=social_club\n", .{});
    while (!shouldStop(options.stop_requested)) {
        const apps = if (steam_catalog) |*catalog| catalog.apps.items else &.{};
        var processes = try process_detector.enumerate(allocator);
        defer processes.deinit();
        try discoverNewStates(allocator, io, resolved_options, apps, processes.items.items, &journal, &tracked, &notifier, &metadata, &metadata_attempted);
        var tracked_index: usize = 0;
        while (tracked_index < tracked.items.len) {
            const state = &tracked.items[tracked_index];
            if (isAppRunning(state.app_id, apps, processes.items.items)) {
                try checkState(allocator, io, &journal, state, &notifier, &metadata);
                tracked_index += 1;
                continue;
            }
            // Games commonly write their final save immediately before exit.
            // Read it once, then stop tracking until a matching process starts.
            try checkState(allocator, io, &journal, state, &notifier, &metadata);
            std.debug.print("[RockstarProvider] appid={d} status=stopped file={s}\n", .{ state.app_id, state.state_file });
            state.deinit(allocator);
            _ = tracked.orderedRemove(tracked_index);
        }
        try checkGtavEnhanced(
            allocator,
            io,
            steam_root,
            &journal,
            &gtav_state,
            &notifier,
            &metadata,
            &metadata_attempted,
        );
        try std.Io.sleep(io, .fromMilliseconds(options.interval_ms), .awake);
    }
}

fn shouldStop(stop_requested: ?*const std.atomic.Value(bool)) bool {
    return if (stop_requested) |flag| flag.load(.acquire) else false;
}

fn discoverNewStates(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    apps: []const steam_install.InstalledApp,
    processes: []const process_detector.Process,
    journal: *Journal,
    tracked: *std.ArrayList(TrackedState),
    notifier: *?WindowsNotifier,
    metadata: *MetadataCatalog,
    metadata_attempted: *std.AutoHashMap(u32, void),
) !void {
    var candidates = try discovery.discoverWithApps(allocator, io, options.roots, apps);
    defer candidates.deinit();
    var first_seen_apps = std.AutoHashMap(u32, void).init(allocator);
    defer first_seen_apps.deinit();

    for (candidates.items.items) |candidate| {
        if (!isAppRunning(candidate.app_id, apps, processes)) continue;
        if (isTracked(tracked.items, candidate.state_file)) continue;
        var current = readSnapshot(allocator, io, candidate.state_file) catch continue;
        errdefer current.deinit();
        try ensureSteamMetadata(allocator, options.steam_root, candidate.app_id, metadata, metadata_attempted);
        const stat = try std.Io.Dir.cwd().statFile(io, candidate.state_file, .{});
        if (!journal.hasSeenProviderGame(.rockstar, candidate.app_id) or first_seen_apps.contains(candidate.app_id)) {
            var iterator = current.achievements.iterator();
            while (iterator.next()) |entry| if (entry.value_ptr.earned) {
                try journal.recordProviderBaseline(.rockstar, candidate.app_id, entry.key_ptr.*, entry.value_ptr.earned_time);
            };
            try first_seen_apps.put(candidate.app_id, {});
        } else if (options.recover) {
            try replayMissed(allocator, journal, candidate.app_id, &current, notifier, metadata, io);
        }
        try tracked.append(allocator, .{
            .app_id = candidate.app_id,
            .state_file = try allocator.dupe(u8, candidate.state_file),
            .state = current,
            .mtime_ns = stat.mtime.nanoseconds,
            .file_size = stat.size,
        });
        std.debug.print("[RockstarProvider] appid={d} status=watching unlocked={d} file={s}\n", .{
            candidate.app_id,
            current.unlockedCount(),
            candidate.state_file,
        });
    }
    var iterator = first_seen_apps.keyIterator();
    while (iterator.next()) |app_id| try journal.markProviderGame(.rockstar, app_id.*);
}

fn isAppRunning(
    app_id: u32,
    apps: []const steam_install.InstalledApp,
    processes: []const process_detector.Process,
) bool {
    if (app_id == gtav_enhanced.app_id) {
        for (processes) |process| {
            if (std.ascii.eqlIgnoreCase(process.name, gtav_enhanced.executable_name)) return true;
        }
        return false;
    }
    for (apps) |app| {
        if (app.app_id != app_id) continue;
        const install_dir = std.mem.trimEnd(u8, app.install_dir, "\\/");
        for (processes) |process| {
            if (process.executable_path.len <= install_dir.len) continue;
            if (!std.ascii.startsWithIgnoreCase(process.executable_path, install_dir)) continue;
            const boundary = process.executable_path[install_dir.len];
            if (boundary == '\\' or boundary == '/') return true;
        }
        return false;
    }
    return false;
}

fn checkGtavEnhanced(
    allocator: std.mem.Allocator,
    io: std.Io,
    steam_root: ?[]const u8,
    journal: *Journal,
    tracked: *GtavEnhancedState,
    notifier: *?WindowsNotifier,
    metadata: *MetadataCatalog,
    metadata_attempted: *std.AutoHashMap(u32, void),
) !void {
    const sampled = tracked.monitor.sample() catch |err| {
        if (tracked.last_error == null or tracked.last_error.? != err) {
            std.debug.print("[RockstarProvider] adapter=gtav_enhanced status=waiting reason={s}\n", .{@errorName(err)});
        }
        tracked.last_error = err;
        return;
    };
    tracked.last_error = null;
    const sample = sampled orelse {
        if (tracked.pid != null) {
            std.debug.print("[RockstarProvider] adapter=gtav_enhanced status=stopped pid={d}\n", .{tracked.pid.?});
        }
        tracked.previous = null;
        tracked.pid = null;
        return;
    };

    try ensureSteamMetadata(allocator, steam_root, gtav_enhanced.app_id, metadata, metadata_attempted);
    if (sample.just_attached or tracked.previous == null or tracked.pid != sample.pid) {
        // A live process begins with a baseline: achievements that existed before
        // the Bridge attached must not produce a burst of historical popups.
        for (1..gtav_enhanced.maximum_internal_id + 1) |internal_id| {
            if (!sample.unlocked.isSet(internal_id)) continue;
            const api_name = gtav_enhanced.steamAchievement(internal_id) orelse continue;
            try journal.recordProviderBaseline(.rockstar, gtav_enhanced.app_id, api_name, 0);
        }
        try journal.markProviderGame(.rockstar, gtav_enhanced.app_id);
        tracked.previous = sample.unlocked;
        tracked.pid = sample.pid;
        std.debug.print(
            "[RockstarProvider] adapter=gtav_enhanced appid={d} status=watching pid={d} unlocked={d}/{d} source=live_memory\n",
            .{ gtav_enhanced.app_id, sample.pid, sample.unlocked.count(), gtav_enhanced.maximum_internal_id },
        );
        return;
    }

    const previous = tracked.previous.?;
    for (1..gtav_enhanced.maximum_internal_id + 1) |internal_id| {
        if (!sample.unlocked.isSet(internal_id) or previous.isSet(internal_id)) continue;
        const api_name = gtav_enhanced.steamAchievement(internal_id) orelse continue;
        const detected_at = unixNow(io);
        const achievement = event.AchievementEvent{
            .app_id = gtav_enhanced.app_id,
            .source_id = api_name,
            .provider = .rockstar,
            .unlocked_at = detected_at,
            .detected_at = detected_at,
        };
        if (try journal.recordEvent(achievement)) emitEvent(allocator, notifier, metadata, achievement);
    }
    tracked.previous = sample.unlocked;
}

fn ensureSteamMetadata(
    allocator: std.mem.Allocator,
    steam_root: ?[]const u8,
    app_id: u32,
    metadata: *MetadataCatalog,
    attempted: *std.AutoHashMap(u32, void),
) !void {
    const root = steam_root orelse return;
    if (attempted.contains(app_id)) return;
    try attempted.put(app_id, {});
    steam_metadata.loadInto(metadata, allocator, app_id, root) catch |err| {
        std.debug.print("[RockstarProvider] steam_metadata=unavailable appid={d} reason={s}\n", .{ app_id, @errorName(err) });
    };
}

fn replayMissed(
    allocator: std.mem.Allocator,
    journal: *Journal,
    app_id: u32,
    current: *const snapshot.Snapshot,
    notifier: *?WindowsNotifier,
    metadata: *const MetadataCatalog,
    io: std.Io,
) !void {
    var iterator = current.achievements.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value_ptr.earned or journal.containsProvider(.rockstar, app_id, entry.key_ptr.*)) continue;
        const detected_at = unixNow(io);
        const achievement = event.AchievementEvent{
            .app_id = app_id,
            .source_id = entry.key_ptr.*,
            .provider = .rockstar,
            .unlocked_at = if (entry.value_ptr.earned_time > 0) entry.value_ptr.earned_time else detected_at,
            .detected_at = detected_at,
            .recovered = true,
        };
        if (try journal.recordEvent(achievement)) emitEvent(allocator, notifier, metadata, achievement);
    }
}

fn checkState(
    allocator: std.mem.Allocator,
    io: std.Io,
    journal: *Journal,
    tracked: *TrackedState,
    notifier: *?WindowsNotifier,
    metadata: *const MetadataCatalog,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, tracked.state_file, .{}) catch return;
    if (stat.mtime.nanoseconds == tracked.mtime_ns and stat.size == tracked.file_size) return;
    var current = readSnapshot(allocator, io, tracked.state_file) catch |err| {
        std.debug.print("[RockstarProvider] appid={d} parse_retry={s}\n", .{ tracked.app_id, @errorName(err) });
        return;
    };
    errdefer current.deinit();
    const events = try snapshot.diffUnlocked(allocator, tracked.app_id, &tracked.state, &current, unixNow(io));
    defer allocator.free(events);
    for (events) |achievement| if (try journal.recordEvent(achievement)) {
        emitEvent(allocator, notifier, metadata, achievement);
    };
    tracked.state.deinit();
    tracked.state = current;
    tracked.mtime_ns = stat.mtime.nanoseconds;
    tracked.file_size = stat.size;
}

fn readSnapshot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !snapshot.Snapshot {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    return snapshot.parseFile(allocator, path, bytes);
}

fn isTracked(states: []const TrackedState, path: []const u8) bool {
    for (states) |state| if (std.ascii.eqlIgnoreCase(state.state_file, path)) return true;
    return false;
}

fn unixNow(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn emitEvent(
    allocator: std.mem.Allocator,
    notifier: *?WindowsNotifier,
    metadata: *const MetadataCatalog,
    achievement: event.AchievementEvent,
) void {
    std.debug.print(
        "[AchievementBridge]\nprovider=rockstar\nappid={d}\nachievement={s}\nstate=unlocked\ntimestamp={d}\nrecovered={}\n\n",
        .{ achievement.app_id, achievement.source_id, achievement.unlocked_at, achievement.recovered },
    );
    const details = metadata.get(achievement.source_id);
    const display_name = if (details) |item| item.name else null;
    const description = if (details) |item| item.description else null;
    const global_percent = if (details) |item| item.global_percent else null;
    if (mapper.mapExact(achievement, metadata)) |mapping| {
        std.debug.print("[RockstarProvider] mapping={s}->{s} confidence={d}\n", .{ achievement.source_id, mapping.canonical_achievement_id, mapping.confidence });
    }
    if (notifier.*) |*active| active.show(allocator, achievement, display_name, description, global_percent) catch |err| {
        std.debug.print("[RockstarProvider] notification_error={s}\n", .{@errorName(err)});
    };
}

test "GTA save watcher requires the real game process" {
    const launcher = [_]process_detector.Process{.{
        .pid = 10,
        .name = @constCast("PlayGTAV.exe"),
        .executable_path = @constCast("D:/SteamLibrary/steamapps/common/Grand Theft Auto V Enhanced/PlayGTAV.exe"),
    }};
    try std.testing.expect(!isAppRunning(gtav_enhanced.app_id, &.{}, &launcher));

    const game = [_]process_detector.Process{.{
        .pid = 11,
        .name = @constCast("GTA5_Enhanced.exe"),
        .executable_path = @constCast("D:/SteamLibrary/steamapps/common/Grand Theft Auto V Enhanced/GTA5_Enhanced.exe"),
    }};
    try std.testing.expect(isAppRunning(gtav_enhanced.app_id, &.{}, &game));
}

test "generic Rockstar save watcher follows installed game directory" {
    const apps = [_]steam_install.InstalledApp{.{
        .app_id = 4_242_424,
        .name = @constCast("Future Rockstar Game"),
        .install_dir = @constCast("D:/SteamLibrary/steamapps/common/Future Rockstar Game"),
        .library_root = @constCast("D:/SteamLibrary"),
    }};
    const unrelated = [_]process_detector.Process{.{
        .pid = 12,
        .name = @constCast("launcher.exe"),
        .executable_path = @constCast("C:/Program Files/Rockstar Games/Launcher/launcher.exe"),
    }};
    try std.testing.expect(!isAppRunning(4_242_424, &apps, &unrelated));

    const game = [_]process_detector.Process{.{
        .pid = 13,
        .name = @constCast("FutureGame.exe"),
        .executable_path = @constCast("D:/SteamLibrary/steamapps/common/Future Rockstar Game/bin/FutureGame.exe"),
    }};
    try std.testing.expect(isAppRunning(4_242_424, &apps, &game));
}
