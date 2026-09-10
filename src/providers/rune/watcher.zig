const std = @import("std");
const event = @import("../../core/event.zig");
const Journal = @import("../../core/journal.zig").Journal;
const discovery = @import("discovery.zig");
const snapshot = @import("snapshot.zig");
const WindowsNotifier = @import("../../notifications/windows.zig").Notifier;
const MetadataCatalog = @import("../../core/metadata.zig").Catalog;
const steam_metadata = @import("../../steam/metadata.zig");
const mapper = @import("../../core/mapper.zig");

pub const Options = struct {
    roots: []const []const u8,
    journal_path: []const u8,
    interval_ms: u32 = 500,
    recover: bool = true,
    notifications: bool = true,
    steam_root: ?[]const u8 = null,
    stop_requested: ?*const std.atomic.Value(bool) = null,
};

const TrackedGame = struct {
    app_id: u32,
    state_file: []u8,
    state: snapshot.Snapshot,
    mtime_ns: i96,
    file_size: u64,

    fn deinit(self: *TrackedGame, allocator: std.mem.Allocator) void {
        self.state.deinit();
        allocator.free(self.state_file);
        self.* = undefined;
    }
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    var candidates = try discovery.discover(allocator, io, roots);
    defer candidates.deinit();
    if (candidates.items.items.len == 0) {
        std.debug.print("[RuneProvider] nenhum achievements.ini encontrado\n", .{});
        return;
    }
    for (candidates.items.items) |candidate| {
        var state = readSnapshot(allocator, io, candidate.state_file) catch |err| {
            std.debug.print("[RuneProvider] appid={d} erro={s} arquivo={s}\n", .{ candidate.app_id, @errorName(err), candidate.state_file });
            continue;
        };
        defer state.deinit();
        std.debug.print("[RuneProvider] appid={d} unlocked={d} arquivo={s}\n", .{
            candidate.app_id,
            state.unlockedCount(),
            candidate.state_file,
        });
    }
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var journal = try Journal.init(allocator, io, options.journal_path);
    defer journal.deinit();
    var tracked: std.ArrayList(TrackedGame) = .empty;
    defer {
        for (tracked.items) |*game| game.deinit(allocator);
        tracked.deinit(allocator);
    }

    var notifier: ?WindowsNotifier = if (options.notifications) WindowsNotifier.init() catch |err| fallback: {
        std.debug.print("[RuneProvider] notifications=fallback reason={s}\n", .{@errorName(err)});
        break :fallback null;
    } else null;
    defer if (notifier) |*active| active.deinit();
    var metadata = MetadataCatalog.init(allocator);
    defer metadata.deinit();
    var steam_metadata_attempted = std.AutoHashMap(u32, void).init(allocator);
    defer steam_metadata_attempted.deinit();

    std.debug.print("[RuneProvider] status=discovering\n", .{});
    while (!shouldStop(options.stop_requested)) {
        try discoverNewGames(allocator, io, options, &journal, &tracked, &notifier, &metadata, &steam_metadata_attempted);
        for (tracked.items) |*game| try checkGame(allocator, io, &journal, game, &notifier, &metadata);
        try std.Io.sleep(io, .fromMilliseconds(options.interval_ms), .awake);
    }
}

fn shouldStop(stop_requested: ?*const std.atomic.Value(bool)) bool {
    return if (stop_requested) |flag| flag.load(.acquire) else false;
}

fn discoverNewGames(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    journal: *Journal,
    tracked: *std.ArrayList(TrackedGame),
    notifier: *?WindowsNotifier,
    metadata: *MetadataCatalog,
    steam_metadata_attempted: *std.AutoHashMap(u32, void),
) !void {
    var candidates = try discovery.discover(allocator, io, options.roots);
    defer candidates.deinit();
    for (candidates.items.items) |candidate| {
        if (isTracked(tracked.items, candidate.state_file)) continue;
        var current = readSnapshot(allocator, io, candidate.state_file) catch |err| {
            std.debug.print("[RuneProvider] appid={d} snapshot_error={s}\n", .{ candidate.app_id, @errorName(err) });
            continue;
        };
        errdefer current.deinit();
        if (options.steam_root) |steam_root| {
            if (!steam_metadata_attempted.contains(candidate.app_id)) {
                try steam_metadata_attempted.put(candidate.app_id, {});
                steam_metadata.loadInto(metadata, allocator, candidate.app_id, steam_root) catch |err| {
                    std.debug.print("[RuneProvider] steam_metadata=unavailable appid={d} reason={s}\n", .{ candidate.app_id, @errorName(err) });
                };
            }
        }

        const stat = try std.Io.Dir.cwd().statFile(io, candidate.state_file, .{});
        if (!journal.hasSeenProviderGame(.rune, candidate.app_id)) {
            var iterator = current.achievements.iterator();
            while (iterator.next()) |entry| if (entry.value_ptr.earned) {
                try journal.recordProviderBaseline(.rune, candidate.app_id, entry.key_ptr.*, entry.value_ptr.earned_time);
            };
            try journal.markProviderGame(.rune, candidate.app_id);
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
        std.debug.print("[RuneProvider] appid={d} status=watching unlocked={d}\n", .{ candidate.app_id, current.unlockedCount() });
    }
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
        if (!entry.value_ptr.earned or journal.containsProvider(.rune, app_id, entry.key_ptr.*)) continue;
        const detected_at = unixNow(io);
        const achievement = event.AchievementEvent{
            .app_id = app_id,
            .source_id = entry.key_ptr.*,
            .provider = .rune,
            .unlocked_at = if (entry.value_ptr.earned_time > 0) entry.value_ptr.earned_time else detected_at,
            .detected_at = detected_at,
            .recovered = true,
        };
        if (try journal.recordEvent(achievement)) emitEvent(allocator, notifier, metadata, achievement);
    }
}

fn checkGame(
    allocator: std.mem.Allocator,
    io: std.Io,
    journal: *Journal,
    game: *TrackedGame,
    notifier: *?WindowsNotifier,
    metadata: *const MetadataCatalog,
) !void {
    const stat = std.Io.Dir.cwd().statFile(io, game.state_file, .{}) catch return;
    if (stat.mtime.nanoseconds == game.mtime_ns and stat.size == game.file_size) return;
    var current = readSnapshot(allocator, io, game.state_file) catch |err| {
        std.debug.print("[RuneProvider] appid={d} parse_retry={s}\n", .{ game.app_id, @errorName(err) });
        return;
    };
    errdefer current.deinit();
    const events = try snapshot.diffUnlocked(allocator, game.app_id, &game.state, &current, unixNow(io));
    defer allocator.free(events);
    for (events) |achievement| if (try journal.recordEvent(achievement)) {
        emitEvent(allocator, notifier, metadata, achievement);
    };
    game.state.deinit();
    game.state = current;
    game.mtime_ns = stat.mtime.nanoseconds;
    game.file_size = stat.size;
}

fn readSnapshot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !snapshot.Snapshot {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);
    return snapshot.parse(allocator, bytes);
}

fn isTracked(games: []const TrackedGame, path: []const u8) bool {
    for (games) |game| if (std.mem.eql(u8, game.state_file, path)) return true;
    return false;
}

fn unixNow(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn emitEvent(allocator: std.mem.Allocator, notifier: *?WindowsNotifier, metadata: *const MetadataCatalog, achievement: event.AchievementEvent) void {
    std.debug.print(
        "[AchievementBridge]\nprovider=rune\nappid={d}\nachievement={s}\nstate=unlocked\ntimestamp={d}\nrecovered={}\n\n",
        .{ achievement.app_id, achievement.source_id, achievement.unlocked_at, achievement.recovered },
    );
    const details = metadata.get(achievement.source_id);
    const display_name = if (details) |item| item.name else null;
    const description = if (details) |item| item.description else null;
    const global_percent = if (details) |item| item.global_percent else null;
    if (mapper.mapExact(achievement, metadata)) |mapping| {
        std.debug.print("[RuneProvider] mapping={s}->{s} confidence={d}\n", .{ achievement.source_id, mapping.canonical_achievement_id, mapping.confidence });
    }
    if (notifier.*) |*active| active.show(allocator, achievement, display_name, description, global_percent) catch |err| {
        std.debug.print("[RuneProvider] notification_error={s}\n", .{@errorName(err)});
    };
}
