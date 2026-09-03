const std = @import("std");

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

pub fn discover(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8) !CandidateList {
    var result = CandidateList{ .allocator = allocator };
    errdefer result.deinit();
    for (roots) |root| try scanRoot(allocator, io, root, &result);
    return result;
}

fn scanRoot(allocator: std.mem.Allocator, io: std.Io, root: []const u8, result: *CandidateList) !void {
    const direct_file = try std.fs.path.join(allocator, &.{ root, "achievements.ini" });
    defer allocator.free(direct_file);
    if (fileExists(io, direct_file)) {
        if (std.fmt.parseInt(u32, std.fs.path.basename(root), 10)) |app_id| {
            try addCandidate(allocator, app_id, direct_file, result);
            return;
        } else |_| {}
    }

    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const app_id = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const state_file = try std.fs.path.join(allocator, &.{ root, entry.name, "achievements.ini" });
        defer allocator.free(state_file);
        if (fileExists(io, state_file)) try addCandidate(allocator, app_id, state_file, result);
    }
}

fn addCandidate(allocator: std.mem.Allocator, app_id: u32, state_file: []const u8, result: *CandidateList) !void {
    for (result.items.items) |candidate| {
        if (candidate.app_id == app_id and std.mem.eql(u8, candidate.state_file, state_file)) return;
    }
    try result.items.append(allocator, .{
        .app_id = app_id,
        .state_file = try allocator.dupe(u8, state_file),
    });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "missing RUNE root produces no candidates" {
    var result = try discover(std.testing.allocator, std.testing.io, &.{"missing-rune-root"});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.items.items.len);
}
