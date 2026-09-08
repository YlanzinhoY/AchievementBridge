const std = @import("std");
const bridge = @import("../root.zig");

pub const Context = struct {
    io: std.Io,
    gse_roots: []const []const u8,
    r2_roots: []const []const u8,
    rune_roots: []const []const u8,
    rockstar_roots: []const []const u8,
    spool_root: []const u8,
    journal_path: []const u8,
    replay_guard_path: []const u8,
    support_root: []const u8,
    interval_ms: u32,
    recover: bool,
    notifications: bool,
};

pub fn run(context: *const Context) !void {
    std.debug.print("[AchievementBridge] mode=watch-all providers=gse,rune,rockstar,ubisoft,uplay_r2 sessions=enabled\n", .{});
    const session_thread = try std.Thread.spawn(.{}, watchSessionWorker, .{context});
    const gse_thread = try std.Thread.spawn(.{}, watchGseWorker, .{context});
    const rune_thread = try std.Thread.spawn(.{}, watchRuneWorker, .{context});
    const rockstar_thread = try std.Thread.spawn(.{}, watchRockstarWorker, .{context});
    const ubisoft_thread = try std.Thread.spawn(.{}, watchUbisoftWorker, .{context});
    const r2_thread = try std.Thread.spawn(.{}, watchR2Worker, .{context});
    session_thread.join();
    gse_thread.join();
    rune_thread.join();
    rockstar_thread.join();
    ubisoft_thread.join();
    r2_thread.join();
}

fn watchRockstarWorker(context: *const Context) void {
    while (true) {
        bridge.providers.rockstar.watcher.run(std.heap.smp_allocator, context.io, .{
            .roots = context.rockstar_roots,
            .journal_path = context.journal_path,
            .interval_ms = context.interval_ms,
            .recover = context.recover,
            .notifications = context.notifications,
            .steam_root = null,
        }) catch |err| {
            std.debug.print("[AchievementBridge] provider=rockstar restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn watchSessionWorker(context: *const Context) void {
    while (true) {
        runSessionMonitor(context) catch |err| {
            std.debug.print("[AchievementBridge] provider=sessions restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn runSessionMonitor(context: *const Context) !void {
    const allocator = std.heap.smp_allocator;
    const steam_root = try bridge.detector.steam_install.findSteamRoot(allocator, context.io);
    defer allocator.free(steam_root);
    var catalog = try bridge.detector.steam_install.discover(allocator, context.io, steam_root);
    defer catalog.deinit();
    var monitor = bridge.host.session_monitor.Monitor.init(allocator, context.io, &catalog);
    defer monitor.deinit();
    try monitor.run(.{ .interval_ms = @max(context.interval_ms, 1000) });
}

fn watchRuneWorker(context: *const Context) void {
    while (true) {
        bridge.providers.rune.watcher.run(std.heap.smp_allocator, context.io, .{
            .roots = context.rune_roots,
            .journal_path = context.journal_path,
            .interval_ms = context.interval_ms,
            .recover = context.recover,
            .notifications = context.notifications,
            .steam_root = null,
        }) catch |err| {
            std.debug.print("[AchievementBridge] provider=rune restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn watchGseWorker(context: *const Context) void {
    while (true) {
        bridge.gse.watcher.run(std.heap.smp_allocator, context.io, .{
            .roots = context.gse_roots,
            .journal_path = context.journal_path,
            .interval_ms = context.interval_ms,
            .recover = context.recover,
            .notifications = context.notifications,
            .steam_root = null,
        }) catch |err| {
            std.debug.print("[AchievementBridge] provider=gse restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}

fn watchUbisoftWorker(context: *const Context) void {
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

fn watchR2Worker(context: *const Context) void {
    while (true) {
        bridge.providers.uplay_r2.watcher.run(std.heap.smp_allocator, context.io, .{
            .roots = context.r2_roots,
            .journal_path = context.journal_path,
            .replay_guard_path = context.replay_guard_path,
            .support_root = context.support_root,
            .interval_ms = context.interval_ms,
            .recover = context.recover,
            .notifications = context.notifications,
        }) catch |err| {
            std.debug.print("[AchievementBridge] provider=uplay_r2 restart_reason={s}\n", .{@errorName(err)});
            std.Io.sleep(context.io, .fromSeconds(1), .awake) catch {};
        };
    }
}
