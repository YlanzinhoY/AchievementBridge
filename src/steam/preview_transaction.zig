const std = @import("std");

pub const version: u8 = 1;

pub const Record = struct {
    allocator: std.mem.Allocator,
    app_id: u32,
    achievement: []u8,
    started_at: i64,

    pub fn deinit(self: *Record) void {
        self.allocator.free(self.achievement);
        self.* = undefined;
    }
};

const FileData = struct {
    version: u8 = version,
    app_id: u32,
    achievement: []const u8,
    started_at: i64,
};

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    app_id: u32,
    achievement: []const u8,
    started_at: i64,
) !void {
    if (app_id == 0 or !validAchievement(achievement)) return error.InvalidPreviewTransaction;
    const json = try std.json.Stringify.valueAlloc(allocator, FileData{
        .app_id = app_id,
        .achievement = achievement,
        .started_at = started_at,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, json, 0);
    try atomic.replace(io);
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?Record {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(FileData, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.version != version) return error.UnsupportedPreviewTransactionVersion;
    if (parsed.value.app_id == 0 or !validAchievement(parsed.value.achievement))
        return error.InvalidPreviewTransaction;
    return .{
        .allocator = allocator,
        .app_id = parsed.value.app_id,
        .achievement = try allocator.dupe(u8, parsed.value.achievement),
        .started_at = parsed.value.started_at,
    };
}

pub fn clear(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn validAchievement(value: []const u8) bool {
    if (value.len == 0 or value.len > 127 or std.mem.indexOfScalar(u8, value, 0) != null) return false;
    return true;
}

test "preview transaction survives restart and clears atomically" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "preview-transaction-v1.json",
    });
    defer allocator.free(path);

    try std.testing.expect((try load(allocator, std.testing.io, path)) == null);
    try save(allocator, std.testing.io, path, 2638890, "ACHIEVEMENT_001", 1234);
    var record = (try load(allocator, std.testing.io, path)).?;
    defer record.deinit();
    try std.testing.expectEqual(@as(u32, 2638890), record.app_id);
    try std.testing.expectEqualStrings("ACHIEVEMENT_001", record.achievement);
    try std.testing.expectEqual(@as(i64, 1234), record.started_at);

    try clear(std.testing.io, path);
    try std.testing.expect((try load(allocator, std.testing.io, path)) == null);
}
