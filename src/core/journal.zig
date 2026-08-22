const std = @import("std");
const event = @import("event.zig");

const Record = struct {
    kind: []const u8,
    app_id: u32,
    provider: []const u8 = "gse",
    source_id: ?[]const u8 = null,
    unlocked_at: i64 = 0,
    detected_at: i64 = 0,
    recovered: bool = false,
};

pub const Journal = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    seen_games: std.StringHashMap(void),
    seen_events: std.StringHashMap(void),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !Journal {
        var self = Journal{
            .allocator = allocator,
            .io = io,
            .path = try allocator.dupe(u8, path),
            .seen_games = std.StringHashMap(void).init(allocator),
            .seen_events = std.StringHashMap(void).init(allocator),
        };
        errdefer self.deinit();
        try self.load();
        return self;
    }

    pub fn deinit(self: *Journal) void {
        var keys = self.seen_events.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.seen_events.deinit();
        var game_keys = self.seen_games.keyIterator();
        while (game_keys.next()) |key| self.allocator.free(key.*);
        self.seen_games.deinit();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    fn load(self: *Journal) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.path,
            self.allocator,
            .limited(32 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            var parsed = std.json.parseFromSlice(Record, self.allocator, trimmed, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            defer parsed.deinit();
            const provider = parseProvider(parsed.value.provider);
            if (std.mem.eql(u8, parsed.value.kind, "game") or std.mem.eql(u8, parsed.value.kind, "event")) {
                try self.rememberGame(provider, parsed.value.app_id);
            }
            if (parsed.value.source_id) |source_id| try self.remember(provider, parsed.value.app_id, source_id);
        }
    }

    pub fn hasSeenGame(self: *const Journal, app_id: u32) bool {
        return self.hasSeenProviderGame(.gse, app_id);
    }

    pub fn hasSeenProviderGame(self: *const Journal, provider: event.ProviderKind, app_id: u32) bool {
        const key = makeGameKey(self.allocator, provider, app_id) catch return false;
        defer self.allocator.free(key);
        return self.seen_games.contains(key);
    }

    pub fn contains(self: *const Journal, app_id: u32, source_id: []const u8) bool {
        return self.containsProvider(.gse, app_id, source_id);
    }

    pub fn containsProvider(self: *const Journal, provider: event.ProviderKind, app_id: u32, source_id: []const u8) bool {
        const key = makeKey(self.allocator, provider, app_id, source_id) catch return false;
        defer self.allocator.free(key);
        return self.seen_events.contains(key);
    }

    pub fn markGame(self: *Journal, app_id: u32) !void {
        return self.markProviderGame(.gse, app_id);
    }

    pub fn markProviderGame(self: *Journal, provider: event.ProviderKind, app_id: u32) !void {
        if (self.hasSeenProviderGame(provider, app_id)) return;
        try self.append(.{ .kind = "game", .app_id = app_id, .provider = @tagName(provider) });
        try self.rememberGame(provider, app_id);
    }

    pub fn recordBaseline(self: *Journal, app_id: u32, source_id: []const u8, unlocked_at: i64) !void {
        return self.recordProviderBaseline(.gse, app_id, source_id, unlocked_at);
    }

    pub fn recordProviderBaseline(self: *Journal, provider: event.ProviderKind, app_id: u32, source_id: []const u8, unlocked_at: i64) !void {
        if (self.containsProvider(provider, app_id, source_id)) return;
        try self.append(.{
            .kind = "baseline",
            .app_id = app_id,
            .provider = @tagName(provider),
            .source_id = source_id,
            .unlocked_at = unlocked_at,
        });
        try self.remember(provider, app_id, source_id);
    }

    pub fn recordEvent(self: *Journal, achievement: event.AchievementEvent) !bool {
        if (self.containsProvider(achievement.provider, achievement.app_id, achievement.source_id)) return false;
        try self.append(.{
            .kind = "event",
            .app_id = achievement.app_id,
            .provider = @tagName(achievement.provider),
            .source_id = achievement.source_id,
            .unlocked_at = achievement.unlocked_at,
            .detected_at = achievement.detected_at,
            .recovered = achievement.recovered,
        });
        try self.rememberGame(achievement.provider, achievement.app_id);
        try self.remember(achievement.provider, achievement.app_id, achievement.source_id);
        return true;
    }

    fn remember(self: *Journal, provider: event.ProviderKind, app_id: u32, source_id: []const u8) !void {
        const key = try makeKey(self.allocator, provider, app_id, source_id);
        errdefer self.allocator.free(key);
        const result = try self.seen_events.getOrPut(key);
        if (result.found_existing) self.allocator.free(key);
    }

    fn rememberGame(self: *Journal, provider: event.ProviderKind, app_id: u32) !void {
        const key = try makeGameKey(self.allocator, provider, app_id);
        errdefer self.allocator.free(key);
        const result = try self.seen_games.getOrPut(key);
        if (result.found_existing) self.allocator.free(key);
    }

    fn append(self: *Journal, record: Record) !void {
        if (std.fs.path.dirname(self.path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(self.io, parent);
        }
        const json = try std.json.Stringify.valueAlloc(self.allocator, record, .{});
        defer self.allocator.free(json);
        var file = try std.Io.Dir.cwd().createFile(self.io, self.path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
        defer file.close(self.io);
        const offset = try file.length(self.io);
        try file.writePositionalAll(self.io, json, offset);
        try file.writePositionalAll(self.io, "\n", offset + json.len);
    }
};

fn makeKey(allocator: std.mem.Allocator, provider: event.ProviderKind, app_id: u32, source_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{d}:{s}", .{ @tagName(provider), app_id, source_id });
}

fn makeGameKey(allocator: std.mem.Allocator, provider: event.ProviderKind, app_id: u32) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ @tagName(provider), app_id });
}

fn parseProvider(value: []const u8) event.ProviderKind {
    return std.meta.stringToEnum(event.ProviderKind, value) orelse .gse;
}

test "journal persists baseline, events, and deduplication" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "journal.jsonl" });
    defer allocator.free(path);

    {
        var first = try Journal.init(allocator, std.testing.io, path);
        defer first.deinit();
        try first.recordBaseline(42, "ACH_OLD", 100);
        try std.testing.expect(!first.hasSeenGame(42));
        try first.markGame(42);
        try std.testing.expect(try first.recordEvent(.{
            .app_id = 42,
            .source_id = "ACH_NEW",
            .unlocked_at = 200,
            .detected_at = 201,
        }));
        try std.testing.expect(!(try first.recordEvent(.{
            .app_id = 42,
            .source_id = "ACH_NEW",
            .unlocked_at = 200,
            .detected_at = 202,
        })));
        try std.testing.expect(try first.recordEvent(.{
            .app_id = 42,
            .provider = .steam,
            .source_id = "ACH_NEW",
            .unlocked_at = 200,
            .detected_at = 202,
        }));
    }

    {
        var reopened = try Journal.init(allocator, std.testing.io, path);
        defer reopened.deinit();
        try std.testing.expect(reopened.hasSeenGame(42));
        try std.testing.expect(reopened.contains(42, "ACH_OLD"));
        try std.testing.expect(reopened.contains(42, "ACH_NEW"));
        try std.testing.expect(reopened.containsProvider(.steam, 42, "ACH_NEW"));
        try std.testing.expect(reopened.hasSeenProviderGame(.steam, 42));
    }
}
