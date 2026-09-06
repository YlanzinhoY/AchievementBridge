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

pub const Options = struct {
    roots: []const []const u8,
    journal_path: []const u8,
    interval_ms: u32 = 500,
    recover: bool = true,
    notifications: bool = true,
    steam_root: ?[]const u8 = null,
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

    std.debug.print("[RockstarProvider] status=discovering source=social_club\n", .{});
    while (true) {
        const apps = if (steam_catalog) |*catalog| catalog.apps.items else &.{};
        try discoverNewStates(allocator, io, resolved_options, apps, &journal, &tracked, &notifier, &metadata, &metadata_attempted);
        for (tracked.items) |*state| try checkState(allocator, io, &journal, state, &notifier, &metadata);
        try std.Io.sleep(io, .fromMilliseconds(options.interval_ms), .awake);
    }
}

fn discoverNewStates(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    apps: []const steam_install.InstalledApp,
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
        if (isTracked(tracked.items, candidate.state_file)) continue;
        var current = readSnapshot(allocator, io, candidate.state_file) catch continue;
        errdefer current.deinit();
        if (options.steam_root) |steam_root| {
            if (!metadata_attempted.contains(candidate.app_id)) {
                try metadata_attempted.put(candidate.app_id, {});
                steam_metadata.loadInto(metadata, allocator, candidate.app_id, steam_root) catch |err| {
                    std.debug.print("[RockstarProvider] steam_metadata=unavailable appid={d} reason={s}\n", .{ candidate.app_id, @errorName(err) });
                };
            }
        }
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
