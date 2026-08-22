const std = @import("std");
const adapter = @import("../../steam/adapter.zig");
const user_stats = @import("../../steam/user_stats.zig");
const AchievementEvent = @import("../../core/event.zig").AchievementEvent;
const Journal = @import("../../core/journal.zig").Journal;
const WindowsNotifier = @import("../../notifications/windows.zig").Notifier;

pub const Options = struct {
    app_id: u32,
    steam_root: []const u8,
    journal_path: []const u8,
    interval_ms: u32 = 1000,
    recover: bool = true,
    notifications: bool = true,
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    var journal = try Journal.init(allocator, io, options.journal_path);
    defer journal.deinit();
    var notifier: ?WindowsNotifier = if (options.notifications) WindowsNotifier.init() catch |err| fallback: {
        std.debug.print("[SteamProvider] notifications=fallback reason={s}\n", .{@errorName(err)});
        break :fallback null;
    } else null;
    defer if (notifier) |*active| active.deinit();

    var session = try adapter.connect(allocator, options.app_id, options.steam_root);
    defer session.close();
    var previous = try adapter.listAchievements(&session, allocator);
    defer previous.deinit();

    if (!journal.hasSeenProviderGame(.steam, options.app_id)) {
        for (previous.items.items) |achievement| {
            if (achievement.unlocked) try journal.recordProviderBaseline(.steam, options.app_id, achievement.api_name, achievement.unlock_time);
        }
        try journal.markProviderGame(.steam, options.app_id);
    } else if (options.recover) {
        for (previous.items.items) |achievement| {
            if (!achievement.unlocked or journal.containsProvider(.steam, options.app_id, achievement.api_name)) continue;
            try emit(allocator, io, &journal, &notifier, options.app_id, achievement, true);
        }
    }

    std.debug.print("[SteamProvider] appid={d} status=watching achievements={d} mode=read_only_poll\n", .{ options.app_id, previous.items.items.len });
    while (true) {
        try std.Io.sleep(io, .fromMilliseconds(options.interval_ms), .awake);
        const current = adapter.listAchievements(&session, allocator) catch |err| {
            std.debug.print("[SteamProvider] appid={d} refresh_error={s}\n", .{ options.app_id, @errorName(err) });
            continue;
        };
        for (current.items.items) |achievement| {
            if (!achievement.unlocked) continue;
            const old = findAchievement(&previous, achievement.api_name);
            if (old != null and old.?.unlocked) continue;
            try emit(allocator, io, &journal, &notifier, options.app_id, achievement, false);
        }
        previous.deinit();
        previous = current;
    }
}

fn emit(
    allocator: std.mem.Allocator,
    io: std.Io,
    journal: *Journal,
    notifier: *?WindowsNotifier,
    app_id: u32,
    achievement: user_stats.AchievementState,
    recovered: bool,
) !void {
    const detected_at = unixNow(io);
    const event = AchievementEvent{
        .app_id = app_id,
        .source_id = achievement.api_name,
        .provider = .steam,
        .unlocked_at = if (achievement.unlock_time > 0) achievement.unlock_time else detected_at,
        .detected_at = detected_at,
        .recovered = recovered,
    };
    if (!try journal.recordEvent(event)) return;
    std.debug.print(
        "[AchievementBridge]\nprovider=steam\nappid={d}\nachievement={s}\nstate=unlocked\ntimestamp={d}\nrecovered={}\n\n",
        .{ event.app_id, event.source_id, event.unlocked_at, event.recovered },
    );
    if (notifier.*) |*active| active.show(
        allocator,
        event,
        if (achievement.name.len > 0) achievement.name else null,
        if (achievement.description.len > 0) achievement.description else null,
        achievement.global_percent,
    ) catch |err| {
        std.debug.print("[SteamProvider] notification_error={s}\n", .{@errorName(err)});
    };
}

fn findAchievement(list: *const user_stats.AchievementList, api_name: []const u8) ?*const user_stats.AchievementState {
    for (list.items.items) |*achievement| {
        if (std.mem.eql(u8, achievement.api_name, api_name)) return achievement;
    }
    return null;
}

fn unixNow(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}
