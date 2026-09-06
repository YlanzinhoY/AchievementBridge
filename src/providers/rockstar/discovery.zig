const std = @import("std");
const snapshot = @import("snapshot.zig");

pub const Candidate = struct {
    app_id: u32,
    state_file: []u8,

    pub fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.state_file);
        self.* = undefined;
    }
};

pub const CandidateList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Candidate) = .empty,

    pub fn deinit(self: *CandidateList) void {
        for (self.items.items) |*candidate| candidate.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

const state_names = [_][]const u8{
    "achievements.ini",     "achievements.json",   "achiev.ini",      "stats.ini",
    "achievements.bin",     "achieve.dat",         "achievement.dat", "achievements.dat",
    "accomplishments.json", "accomplishments.dat", "awards.json",     "awards.dat",
    "stats.bin",            "user_stats.ini",      "stats.json",
};

pub fn discover(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8) !CandidateList {
    var result = CandidateList{ .allocator = allocator };
    errdefer result.deinit();
    for (roots) |root| try scanRoot(allocator, io, root, &result);
    return result;
}

fn scanRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8, result: *CandidateList) !void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and entry.depth() >= 6) {
            walker.leave(io);
            continue;
        }
        if (entry.kind != .file or !isStateName(entry.basename)) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const app_id = inferAppId(path) orelse continue;
        if (!try isReadableState(allocator, io, path)) continue;
        try addCandidate(allocator, app_id, path, result);
    }
}

fn isReadableState(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch return false;
    defer allocator.free(bytes);
    var parsed = snapshot.parse(allocator, bytes) catch return false;
    parsed.deinit();
    return true;
}

fn isStateName(name: []const u8) bool {
    for (state_names) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) return true;
    return false;
}

pub fn inferAppId(path: []const u8) ?u32 {
    var components = std.mem.tokenizeAny(u8, path, "\\/");
    while (components.next()) |component| {
        if (titleAppId(component)) |app_id| return app_id;
    }
    return null;
}

fn titleAppId(title: []const u8) ?u32 {
    const Entry = struct { title: []const u8, app_id: u32 };
    const entries = [_]Entry{
        .{ .title = "GTAV Enhanced", .app_id = 3240220 },
        .{ .title = "GTA V Enhanced", .app_id = 3240220 },
        .{ .title = "Grand Theft Auto V Enhanced", .app_id = 3240220 },
        .{ .title = "GTA V", .app_id = 271590 },
        .{ .title = "Grand Theft Auto V", .app_id = 271590 },
        .{ .title = "GTA IV", .app_id = 12210 },
        .{ .title = "Grand Theft Auto IV", .app_id = 12210 },
        .{ .title = "Red Dead Redemption 2", .app_id = 1174180 },
        .{ .title = "RDR2", .app_id = 1174180 },
        .{ .title = "Max Payne 3", .app_id = 204100 },
        .{ .title = "L.A. Noire", .app_id = 110800 },
        .{ .title = "LA Noire", .app_id = 110800 },
        .{ .title = "Bully Scholarship Edition", .app_id = 12200 },
        .{ .title = "Bully", .app_id = 12200 },
    };
    for (entries) |entry| if (std.ascii.eqlIgnoreCase(title, entry.title)) return entry.app_id;
    return null;
}

fn addCandidate(allocator: std.mem.Allocator, app_id: u32, path: []const u8, result: *CandidateList) !void {
    for (result.items.items) |candidate| {
        if (candidate.app_id == app_id and std.ascii.eqlIgnoreCase(candidate.state_file, path)) return;
    }
    try result.items.append(allocator, .{
        .app_id = app_id,
        .state_file = try allocator.dupe(u8, path),
    });
}

test "infer Steam AppIDs from Rockstar profile paths" {
    try std.testing.expectEqual(@as(?u32, 3240220), inferAppId("C:/Users/Public/Documents/Socialclub/RUNE/GTAV Enhanced/101/achievements.json"));
    try std.testing.expectEqual(@as(?u32, 1174180), inferAppId("C:/Profiles/ABCD/Titles/RDR2/achievements.dat"));
    try std.testing.expectEqual(@as(?u32, null), inferAppId("C:/Profiles/Unknown Game/achievements.json"));
}

test "discover only readable Rockstar achievement state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const profile = try std.fs.path.join(allocator, &.{ root, "RUNE", "GTAV Enhanced", "101001101010" });
    defer allocator.free(profile);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, profile);
    const readable = try std.fs.path.join(allocator, &.{ profile, "achievements.json" });
    defer allocator.free(readable);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, readable, .{});
    try file.writeStreamingAll(std.testing.io, "{\"ACH00\":{\"Achieved\":true}}");
    file.close(std.testing.io);
    const proprietary = try std.fs.path.join(allocator, &.{ profile, "achievements.dat" });
    defer allocator.free(proprietary);
    var binary = try std.Io.Dir.cwd().createFile(std.testing.io, proprietary, .{});
    try binary.writeStreamingAll(std.testing.io, "\\x00\\x01\\x02");
    binary.close(std.testing.io);

    var found = try discover(allocator, std.testing.io, &.{root});
    defer found.deinit();
    try std.testing.expectEqual(@as(usize, 1), found.items.items.len);
    try std.testing.expectEqual(@as(u32, 3240220), found.items.items[0].app_id);
}
