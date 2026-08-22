const std = @import("std");
const spool = @import("spool.zig");
const discovery = @import("discovery.zig");
const AchievementEvent = @import("../../core/event.zig").AchievementEvent;
const Journal = @import("../../core/journal.zig").Journal;
const WindowsNotifier = @import("../../notifications/windows.zig").Notifier;

pub const Options = struct {
    spool_root: []const u8,
    journal_path: []const u8,
    interval_ms: u32 = 500,
    recover: bool = true,
    notifications: bool = true,
};

const TrackedProduct = struct {
    product_id: u32,
    spool_file: []u8,
    state: spool.Snapshot,
    mtime_ns: i96,
    file_size: u64,

    fn deinit(self: *TrackedProduct, allocator: std.mem.Allocator) void {
        allocator.free(self.spool_file);
        self.state.deinit();
        self.* = undefined;
    }
};

pub fn scan(allocator: std.mem.Allocator, io: std.Io, spool_root: []const u8) !void {
    var candidates = try discovery.discover(allocator, io, spool_root);
    defer candidates.deinit();
    for (candidates.items.items) |candidate| {
        var state = readSnapshot(allocator, io, candidate.spool_file) catch |err| {
            std.debug.print("[UbisoftProvider] product_id={d} parse_error={s}\n", .{ candidate.product_id, @errorName(err) });
            continue;
        };
        defer state.deinit();
        std.debug.print("[UbisoftProvider] product_id={d} unlocked={d}\n", .{ candidate.product_id, state.unlocked.count() });
    }
    if (candidates.items.items.len == 0) std.debug.print("[UbisoftProvider] nenhum spool encontrado\n", .{});
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var journal = try Journal.init(allocator, io, options.journal_path);
    defer journal.deinit();
    var notifier: ?WindowsNotifier = if (options.notifications) WindowsNotifier.init() catch |err| fallback: {
        std.debug.print("[UbisoftProvider] notifications=fallback reason={s}\n", .{@errorName(err)});
        break :fallback null;
    } else null;
    defer if (notifier) |*active| active.deinit();
    var tracked: std.ArrayList(TrackedProduct) = .empty;
    defer {
        for (tracked.items) |*product| product.deinit(allocator);
        tracked.deinit(allocator);
    }

    std.debug.print("[UbisoftProvider] status=discovering mode=offline_spool\n", .{});
    while (true) {
        var candidates = try discovery.discover(allocator, io, options.spool_root);
        defer candidates.deinit();
        for (candidates.items.items) |candidate| {
            const stat = std.Io.Dir.cwd().statFile(io, candidate.spool_file, .{}) catch continue;
            if (findTracked(tracked.items, candidate.product_id)) |product| {
                const same_file = std.mem.eql(u8, product.spool_file, candidate.spool_file);
                if (same_file and stat.mtime.nanoseconds == product.mtime_ns and stat.size == product.file_size) continue;
                var current = readSnapshot(allocator, io, candidate.spool_file) catch |err| {
                    std.debug.print("[UbisoftProvider] product_id={d} parse_retry={s}\n", .{ candidate.product_id, @errorName(err) });
                    continue;
                };
                errdefer current.deinit();
                try emitNew(allocator, io, &journal, &notifier, candidate.product_id, &product.state, &current, false);
                const new_path = if (same_file) null else try allocator.dupe(u8, candidate.spool_file);
                product.state.deinit();
                product.state = current;
                if (new_path) |path| {
                    allocator.free(product.spool_file);
                    product.spool_file = path;
                }
                product.mtime_ns = stat.mtime.nanoseconds;
                product.file_size = stat.size;
                continue;
            }

            var current = readSnapshot(allocator, io, candidate.spool_file) catch continue;
            errdefer current.deinit();
            if (!journal.hasSeenProviderGame(.ubisoft, candidate.product_id)) {
                var iterator = current.unlocked.iterator();
                while (iterator.next()) |entry| {
                    var id_buffer: [32]u8 = undefined;
                    const source_id = try std.fmt.bufPrint(&id_buffer, "{d}", .{entry.key_ptr.*});
                    try journal.recordProviderBaseline(.ubisoft, candidate.product_id, source_id, entry.value_ptr.*);
                }
                try journal.markProviderGame(.ubisoft, candidate.product_id);
            } else if (options.recover) {
                var empty = spool.Snapshot.init(allocator);
                defer empty.deinit();
                try emitNew(allocator, io, &journal, &notifier, candidate.product_id, &empty, &current, true);
            }
            try tracked.append(allocator, .{
                .product_id = candidate.product_id,
                .spool_file = try allocator.dupe(u8, candidate.spool_file),
                .state = current,
                .mtime_ns = stat.mtime.nanoseconds,
                .file_size = stat.size,
            });
            std.debug.print("[UbisoftProvider] product_id={d} status=watching unlocked={d}\n", .{ candidate.product_id, current.unlocked.count() });
        }
        try std.Io.sleep(io, .fromMilliseconds(options.interval_ms), .awake);
    }
}

fn emitNew(
    allocator: std.mem.Allocator,
    io: std.Io,
    journal: *Journal,
    notifier: *?WindowsNotifier,
    product_id: u32,
    previous: *const spool.Snapshot,
    current: *const spool.Snapshot,
    recovered: bool,
) !void {
    var iterator = current.unlocked.iterator();
    while (iterator.next()) |entry| {
        if (previous.unlocked.contains(entry.key_ptr.*)) continue;
        var id_buffer: [32]u8 = undefined;
        const source_id = try std.fmt.bufPrint(&id_buffer, "{d}", .{entry.key_ptr.*});
        if (journal.containsProvider(.ubisoft, product_id, source_id)) continue;
        const detected_at = unixNow(io);
        const event = AchievementEvent{
            .app_id = product_id,
            .source_id = source_id,
            .provider = .ubisoft,
            .unlocked_at = entry.value_ptr.*,
            .detected_at = detected_at,
            .recovered = recovered,
        };
        if (!try journal.recordEvent(event)) continue;
        std.debug.print(
            "[AchievementBridge]\nprovider=ubisoft\nproduct_id={d}\nachievement={s}\nstate=unlocked\ntimestamp={d}\nrecovered={}\n\n",
            .{ product_id, source_id, event.unlocked_at, event.recovered },
        );
        if (notifier.*) |*active| active.show(allocator, event, null, null, null) catch |err| {
            std.debug.print("[UbisoftProvider] notification_error={s}\n", .{@errorName(err)});
        };
    }
}

fn readSnapshot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !spool.Snapshot {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(bytes);
    return spool.parse(allocator, bytes);
}

fn findTracked(products: []TrackedProduct, product_id: u32) ?*TrackedProduct {
    for (products) |*product| if (product.product_id == product_id) return product;
    return null;
}

fn unixNow(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}
