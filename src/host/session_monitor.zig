const std = @import("std");
const process_detector = @import("../detector/process.zig");
const runtime_detector = @import("../detector/runtime.zig");
const steam_install = @import("../detector/steam_install.zig");
const resolver = @import("../resolver/provider_resolver.zig");
const core_session = @import("../core/session.zig");

pub const Options = struct {
    interval_ms: u32 = 1000,
    once: bool = false,
};

const HostedSession = struct {
    session: core_session.GameSession,
    name: []u8,
    executable_path: []u8,
    install_dir: []u8,

    fn deinit(self: *HostedSession, allocator: std.mem.Allocator) void {
        self.session.deinit(allocator);
        allocator.free(self.name);
        allocator.free(self.executable_path);
        allocator.free(self.install_dir);
        self.* = undefined;
    }
};

pub const Monitor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    catalog: *const steam_install.Catalog,
    active: std.AutoHashMap(u32, HostedSession),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, catalog: *const steam_install.Catalog) Monitor {
        return .{
            .allocator = allocator,
            .io = io,
            .catalog = catalog,
            .active = std.AutoHashMap(u32, HostedSession).init(allocator),
        };
    }

    pub fn deinit(self: *Monitor) void {
        var iterator = self.active.valueIterator();
        while (iterator.next()) |session| session.deinit(self.allocator);
        self.active.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Monitor, options: Options) !void {
        while (true) {
            try self.poll();
            if (options.once) return;
            try std.Io.sleep(self.io, .fromMilliseconds(options.interval_ms), .awake);
        }
    }

    pub fn poll(self: *Monitor) !void {
        var processes = try process_detector.enumerate(self.allocator);
        defer processes.deinit();
        var seen = std.AutoHashMap(u32, void).init(self.allocator);
        defer seen.deinit();

        for (processes.items.items) |process| {
            if (self.active.contains(process.pid)) {
                try seen.put(process.pid, {});
                continue;
            }
            const process_dir = std.fs.path.dirname(process.executable_path) orelse continue;
            const installed = findContainingApp(self.catalog, process.executable_path);
            if (installed == null and !runtime_detector.hasDirectIndicator(self.allocator, self.io, process_dir)) continue;
            const game_dir = if (installed) |app| app.install_dir else process_dir;
            var report = runtime_detector.detect(self.allocator, self.io, game_dir) catch continue;
            defer report.deinit();
            if (report.runtimes.items.len == 0) continue;
            const candidates = try resolver.resolve(self.allocator, &report);
            defer self.allocator.free(candidates);
            if (candidates.len == 0) continue;

            var hosted = try createHosted(self.allocator, process, installed, game_dir);
            errdefer hosted.deinit(self.allocator);
            try hosted.session.transition(.resolving_providers);
            for (candidates) |candidate| try hosted.session.providers.append(self.allocator, .{
                .kind = candidate.provider,
                .confidence = candidate.confidence,
            });
            try hosted.session.transition(.loading_providers);
            for (hosted.session.providers.items) |*provider| provider.active = switch (provider.kind) {
                .gse, .rune, .steam, .ubisoft, .uplay_r2 => true,
                .epic, .gog, .ea, .xbox => false,
            };
            try hosted.session.transition(.watching);
            try self.active.put(process.pid, hosted);
            try seen.put(process.pid, {});
            printStarted(&hosted.session);
        }

        var ended: std.ArrayList(u32) = .empty;
        defer ended.deinit(self.allocator);
        var iterator = self.active.iterator();
        while (iterator.next()) |entry| {
            if (!seen.contains(entry.key_ptr.*)) try ended.append(self.allocator, entry.key_ptr.*);
        }
        for (ended.items) |pid| {
            const hosted = self.active.getPtr(pid) orelse continue;
            try hosted.session.transition(.finished);
            std.debug.print("[GameSession] pid={d} state=finished\n", .{pid});
            hosted.deinit(self.allocator);
            _ = self.active.remove(pid);
        }
        std.debug.print("[AchievementBridge] active_game_sessions={d}\n", .{self.active.count()});
    }
};

fn createHosted(
    allocator: std.mem.Allocator,
    process: process_detector.Process,
    installed: ?*const steam_install.InstalledApp,
    game_dir: []const u8,
) !HostedSession {
    const name = try allocator.dupe(u8, if (installed) |app| app.name else process.name);
    errdefer allocator.free(name);
    const executable_path = try allocator.dupe(u8, process.executable_path);
    errdefer allocator.free(executable_path);
    const install_dir = try allocator.dupe(u8, game_dir);
    errdefer allocator.free(install_dir);
    return .{
        .name = name,
        .executable_path = executable_path,
        .install_dir = install_dir,
        .session = .{ .identity = .{
            .pid = process.pid,
            .app_id = if (installed) |app| app.app_id else null,
            .name = name,
            .executable_path = executable_path,
            .install_dir = install_dir,
        } },
    };
}

fn findContainingApp(catalog: *const steam_install.Catalog, executable_path: []const u8) ?*const steam_install.InstalledApp {
    for (catalog.apps.items) |*app| {
        if (executable_path.len <= app.install_dir.len) continue;
        if (!std.ascii.startsWithIgnoreCase(executable_path, app.install_dir)) continue;
        const boundary = executable_path[app.install_dir.len];
        if (boundary == '\\' or boundary == '/') return app;
    }
    return null;
}

fn printStarted(session: *const core_session.GameSession) void {
    std.debug.print("[GameSession] pid={d}", .{session.identity.pid.?});
    if (session.identity.app_id) |app_id| std.debug.print(" appid={d}", .{app_id});
    if (session.identity.name) |name| std.debug.print(" name={s}", .{name});
    std.debug.print(" state={s}\n", .{@tagName(session.state)});
    for (session.providers.items) |provider| std.debug.print(
        "  provider={s} confidence={d} active={}\n",
        .{ @tagName(provider.kind), provider.confidence, provider.active },
    );
}
