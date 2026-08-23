const std = @import("std");
const discovery = @import("../gse/discovery.zig");
const snapshot = @import("../gse/snapshot.zig");
const AchievementEvent = @import("../../core/event.zig").AchievementEvent;
const Journal = @import("../../core/journal.zig").Journal;
const WindowsNotifier = @import("../../notifications/windows.zig").Notifier;
const MetadataCatalog = @import("../../core/metadata.zig").Catalog;
const steam_metadata = @import("../../steam/metadata.zig");
const mapper = @import("../../core/mapper.zig");
const replay_guard = @import("replay_guard.zig");

pub const Options = struct {
    roots: []const []const u8,
    journal_path: []const u8,
    interval_ms: u32 = 500,
    recover: bool = true,
    notifications: bool = true,
    steam_app_id: ?u32 = null,
    steam_root: ?[]const u8 = null,
    replay_guard_path: ?[]const u8 = null,
};

const Tracked = struct {
    product_id: u32,
    path: []u8,
    state: snapshot.Snapshot,
    mtime_ns: i96,
    size: u64,

    fn deinit(self: *Tracked, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.state.deinit();
        self.* = undefined;
    }
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    var candidates = try discovery.discover(allocator, io, roots);
    defer candidates.deinit();
    for (candidates.items.items) |candidate| {
        var state = readSnapshot(allocator, io, candidate.state_file) catch continue;
        defer state.deinit();
        std.debug.print("[UplayR2Provider] product_id={d} unlocked={d}/{d}\n", .{ candidate.app_id, state.unlockedCount(), state.achievements.count() });
    }
    if (candidates.items.items.len == 0) std.debug.print("[UplayR2Provider] nenhum achievements.json encontrado\n", .{});
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var journal = try Journal.init(allocator, io, options.journal_path);
    defer journal.deinit();
    var notifier: ?WindowsNotifier = if (options.notifications) WindowsNotifier.init() catch null else null;
    defer if (notifier) |*active| active.deinit();
    var guard: ?replay_guard.Guard = if (options.replay_guard_path) |path|
        try replay_guard.Guard.init(allocator, io, path)
    else
        null;
    defer if (guard) |*active| active.deinit();
    var tracked: std.ArrayList(Tracked) = .empty;
    defer {
        for (tracked.items) |*item| item.deinit(allocator);
        tracked.deinit(allocator);
    }
    var metadata = MetadataCatalog.init(allocator);
    defer metadata.deinit();
    if (options.steam_app_id) |steam_app_id| if (options.steam_root) |steam_root| {
        steam_metadata.loadInto(&metadata, allocator, steam_app_id, steam_root) catch |err| {
            std.debug.print("[UplayR2Provider] steam_metadata=unavailable reason={s}\n", .{@errorName(err)});
        };
    };
    std.debug.print("[UplayR2Provider] status=discovering\n", .{});
    while (true) {
        var candidates = try discovery.discover(allocator, io, options.roots);
        defer candidates.deinit();
        for (candidates.items.items) |candidate| {
            const stat = std.Io.Dir.cwd().statFile(io, candidate.state_file, .{}) catch continue;
            if (findTracked(tracked.items, candidate.app_id, candidate.state_file)) |item| {
                if (item.mtime_ns == stat.mtime.nanoseconds and item.size == stat.size) continue;
                var current = readSnapshot(allocator, io, candidate.state_file) catch continue;
                errdefer current.deinit();
                try emitNew(allocator, io, &journal, &notifier, &guard, candidate.app_id, candidate.state_file, &item.state, &current, false, options.steam_app_id, &metadata);
                item.state.deinit();
                item.state = current;
                item.mtime_ns = stat.mtime.nanoseconds;
                item.size = stat.size;
                continue;
            }
            var current = readSnapshot(allocator, io, candidate.state_file) catch continue;
            errdefer current.deinit();
            if (!journal.hasSeenProviderGame(.uplay_r2, candidate.app_id)) {
                var iterator = current.achievements.iterator();
                while (iterator.next()) |entry| if (entry.value_ptr.earned) try journal.recordProviderBaseline(.uplay_r2, candidate.app_id, entry.key_ptr.*, entry.value_ptr.earned_time);
                try journal.markProviderGame(.uplay_r2, candidate.app_id);
            } else if (options.recover) {
                var empty = snapshot.Snapshot.init(allocator);
                defer empty.deinit();
                try emitNew(allocator, io, &journal, &notifier, &guard, candidate.app_id, candidate.state_file, &empty, &current, true, options.steam_app_id, &metadata);
            }
            try tracked.append(allocator, .{
                .product_id = candidate.app_id,
                .path = try allocator.dupe(u8, candidate.state_file),
                .state = current,
                .mtime_ns = stat.mtime.nanoseconds,
                .size = stat.size,
            });
            std.debug.print("[UplayR2Provider] product_id={d} status=watching\n", .{candidate.app_id});
        }
        try std.Io.sleep(io, .fromMilliseconds(options.interval_ms), .awake);
    }
}

fn emitNew(allocator: std.mem.Allocator, io: std.Io, journal: *Journal, notifier: *?WindowsNotifier, guard: *?replay_guard.Guard, product_id: u32, state_path: []const u8, before: *const snapshot.Snapshot, after: *snapshot.Snapshot, recovered: bool, steam_app_id: ?u32, metadata: *const MetadataCatalog) !void {
    var iterator = after.achievements.iterator();
    while (iterator.next()) |entry| {
        if (!entry.value_ptr.earned) continue;
        const old = before.achievements.get(entry.key_ptr.*);
        if (old != null and old.?.earned) continue;
        if (guard.*) |*active| if (active.suppresses(product_id, entry.key_ptr.*)) {
            try active.suppressReplay(state_path);
            entry.value_ptr.* = .{};
            std.debug.print(
                "[UplayR2ReplayGuard] product_id={d} achievement={s} state=startup_replay_suppressed next=await_gameplay\n",
                .{ product_id, entry.key_ptr.* },
            );
            continue;
        };
        const detected_at = unixNow(io);
        const event = AchievementEvent{
            .app_id = product_id,
            .source_id = entry.key_ptr.*,
            .provider = .uplay_r2,
            .unlocked_at = if (entry.value_ptr.earned_time > 0) entry.value_ptr.earned_time else detected_at,
            .detected_at = detected_at,
            .recovered = recovered,
        };
        const awaited_gameplay = if (guard.*) |*active| active.awaitsGameplay(product_id, entry.key_ptr.*) else false;
        const recorded = try journal.recordEvent(event);
        if (awaited_gameplay) if (guard.*) |*active| try active.complete();
        if (!recorded) continue;
        std.debug.print("[AchievementBridge]\nprovider=uplay_r2\nproduct_id={d}\nachievement={s}\nstate=unlocked\ntimestamp={d}\nrecovered={}\n\n", .{ product_id, event.source_id, event.unlocked_at, event.recovered });
        const mapping = if (steam_app_id) |canonical_app_id| mapper.mapNumericSuffix(event.source_id, canonical_app_id, metadata) else null;
        const details = if (mapping) |mapped| metadata.get(mapped.canonical_achievement_id) else null;
        if (mapping) |mapped| std.debug.print("[AchievementBridge] mapping={s}->{s} confidence={d}\n", .{ event.source_id, mapped.canonical_achievement_id, mapped.confidence });
        if (notifier.*) |*active| active.show(
            allocator,
            event,
            if (details) |item| item.name else null,
            if (details) |item| item.description else null,
            if (details) |item| item.global_percent else null,
        ) catch {};
    }
}

fn readSnapshot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !snapshot.Snapshot {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    return snapshot.parse(allocator, bytes);
}

fn findTracked(items: []Tracked, product_id: u32, path: []const u8) ?*Tracked {
    for (items) |*item| if (item.product_id == product_id and std.mem.eql(u8, item.path, path)) return item;
    return null;
}

fn unixNow(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}
