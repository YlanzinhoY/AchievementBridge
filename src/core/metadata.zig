const std = @import("std");

pub const AchievementMetadata = struct {
    api_name: []u8,
    name: []u8,
    description: []u8,
    icon: []u8,
    hidden: bool = false,
    global_percent: ?f32 = null,

    fn deinit(self: *AchievementMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.api_name);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.icon);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(AchievementMetadata),

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(AchievementMetadata).init(allocator),
        };
    }

    pub fn deinit(self: *Catalog) void {
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.entries.deinit();
        self.* = undefined;
    }

    pub fn put(self: *Catalog, metadata: AchievementMetadata) !void {
        if (self.entries.fetchRemove(metadata.api_name)) |removed| {
            var previous = removed.value;
            previous.deinit(self.allocator);
        }
        try self.entries.put(metadata.api_name, metadata);
    }

    pub fn get(self: *const Catalog, api_name: []const u8) ?*const AchievementMetadata {
        return self.entries.getPtr(api_name);
    }
};
