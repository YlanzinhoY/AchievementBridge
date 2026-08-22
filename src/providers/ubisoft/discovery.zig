const std = @import("std");

pub const Candidate = struct {
    product_id: u32,
    spool_file: []u8,
    mtime_ns: i96,

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.spool_file);
        self.* = undefined;
    }
};

pub const CandidateList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Candidate) = .empty,

    pub fn deinit(self: *CandidateList) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn discover(allocator: std.mem.Allocator, io: std.Io, spool_root: []const u8) !CandidateList {
    var result = CandidateList{ .allocator = allocator };
    errdefer result.deinit();
    var root = std.Io.Dir.openDirAbsolute(io, spool_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return err,
    };
    defer root.close(io);
    var users = root.iterate();
    while (try users.next(io)) |user| {
        if (user.kind != .directory) continue;
        var user_dir = root.openDir(io, user.name, .{ .iterate = true }) catch continue;
        defer user_dir.close(io);
        var files = user_dir.iterate();
        while (try files.next(io)) |file| {
            if (file.kind != .file or !std.ascii.endsWithIgnoreCase(file.name, ".spool")) continue;
            const stem = file.name[0 .. file.name.len - ".spool".len];
            const product_id = std.fmt.parseInt(u32, stem, 10) catch continue;
            const full_path = try std.fs.path.join(allocator, &.{ spool_root, user.name, file.name });
            errdefer allocator.free(full_path);
            const stat = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch {
                allocator.free(full_path);
                continue;
            };
            if (findProduct(result.items.items, product_id)) |existing| {
                if (stat.mtime.nanoseconds <= existing.mtime_ns) {
                    allocator.free(full_path);
                    continue;
                }
                allocator.free(existing.spool_file);
                existing.spool_file = full_path;
                existing.mtime_ns = stat.mtime.nanoseconds;
            } else try result.items.append(allocator, .{
                .product_id = product_id,
                .spool_file = full_path,
                .mtime_ns = stat.mtime.nanoseconds,
            });
        }
    }
    return result;
}

fn findProduct(items: []Candidate, product_id: u32) ?*Candidate {
    for (items) |*item| if (item.product_id == product_id) return item;
    return null;
}
