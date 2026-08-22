const std = @import("std");

pub const StoredAchievement = struct {
    app_id: u32,
    api_name: []const u8,
    unlocked_at: i64,
};

const FileData = struct {
    version: u32 = 1,
    achievements: []const StoredAchievement = &.{},
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    entries: std.ArrayList(StoredAchievement) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        var self = Store{
            .allocator = allocator,
            .io = io,
            .path = try allocator.dupe(u8, path),
        };
        errdefer self.deinit();
        try self.load();
        return self;
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |entry| self.allocator.free(entry.api_name);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn unlockedAt(self: *const Store, app_id: u32, api_name: []const u8) ?i64 {
        for (self.entries.items) |entry| {
            if (entry.app_id == app_id and std.mem.eql(u8, entry.api_name, api_name)) return entry.unlocked_at;
        }
        return null;
    }

    /// Records a local-only unlock and atomically persists the store. Existing entries are updated
    /// rather than duplicated so the file remains deterministic across repeated imports.
    pub fn record(self: *Store, app_id: u32, api_name: []const u8, unlocked_at: i64) !void {
        if (api_name.len == 0 or api_name.len > 256 or std.mem.indexOfScalar(u8, api_name, 0) != null)
            return error.InvalidAchievementApiName;
        for (self.entries.items) |*entry| {
            if (entry.app_id != app_id or !std.mem.eql(u8, entry.api_name, api_name)) continue;
            entry.unlocked_at = unlocked_at;
            return self.save();
        }
        try self.entries.append(self.allocator, .{
            .app_id = app_id,
            .api_name = try self.allocator.dupe(u8, api_name),
            .unlocked_at = unlocked_at,
        });
        try self.save();
    }

    fn load(self: *Store) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            self.path,
            self.allocator,
            .limited(8 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);

        var parsed = try std.json.parseFromSlice(FileData, self.allocator, bytes, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (parsed.value.version != 1) return error.UnsupportedLocalStoreVersion;
        for (parsed.value.achievements) |entry| {
            if (entry.api_name.len == 0 or entry.api_name.len > 256) continue;
            try self.entries.append(self.allocator, .{
                .app_id = entry.app_id,
                .api_name = try self.allocator.dupe(u8, entry.api_name),
                .unlocked_at = entry.unlocked_at,
            });
        }
    }

    fn save(self: *Store) !void {
        if (std.fs.path.dirname(self.path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(self.io, parent);
        }
        const json = try std.json.Stringify.valueAlloc(self.allocator, FileData{
            .achievements = self.entries.items,
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, self.path, .{
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        try atomic.file.writePositionalAll(self.io, json, 0);
        try atomic.replace(self.io);
    }
};

test "local store persists and updates one achievement" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "local-achievements.json" });
    defer allocator.free(path);

    {
        var store = try Store.init(allocator, std.testing.io, path);
        defer store.deinit();
        try store.record(1145350, "AchClearErebus", 100);
        try store.record(1145350, "AchClearErebus", 200);
        try std.testing.expectEqual(@as(i64, 200), store.unlockedAt(1145350, "AchClearErebus").?);
        try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
    }

    {
        var reopened = try Store.init(allocator, std.testing.io, path);
        defer reopened.deinit();
        try std.testing.expectEqual(@as(i64, 200), reopened.unlockedAt(1145350, "AchClearErebus").?);
        try std.testing.expect(reopened.unlockedAt(2542020, "1") == null);
    }
}
