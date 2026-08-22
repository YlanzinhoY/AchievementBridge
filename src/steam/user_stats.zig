const std = @import("std");
const vtable = @import("vtable.zig");

pub const AchievementState = struct {
    api_name: []u8,
    name: []u8,
    description: []u8,
    icon: []u8,
    icon_gray: []u8,
    unlocked: bool,
    unlock_time: i64,
    hidden: bool,
    global_percent: ?f32,

    pub fn deinit(self: *AchievementState, allocator: std.mem.Allocator) void {
        allocator.free(self.api_name);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.icon);
        allocator.free(self.icon_gray);
        self.* = undefined;
    }
};

pub const AchievementList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(AchievementState) = .empty,

    pub fn deinit(self: *AchievementList) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const UserStats = struct {
    pointer: *anyopaque,

    pub fn isAchievementUnlocked(self: *const UserStats, api_name: [*:0]const u8) !bool {
        var achieved: u8 = 0;
        var unlock_time: u32 = 0;
        if (!self.getAchievementAndUnlockTime(api_name, &achieved, &unlock_time)) return error.GetAchievementFailed;
        return achieved != 0;
    }

    /// Changes the current Steam user's in-memory state. Call storeStats after
    /// this succeeds to persist the unlock on Steam's servers.
    pub fn setAchievement(self: *const UserStats, api_name: [*:0]const u8) bool {
        const Function = *const fn (*anyopaque, [*:0]const u8) callconv(.c) u8;
        return vtable.getMethod(self.pointer, 6, Function)(self.pointer, api_name) != 0;
    }

    /// Uploads pending stats and achievement changes to Steam.
    pub fn storeStats(self: *const UserStats) bool {
        const Function = *const fn (*anyopaque) callconv(.c) u8;
        return vtable.getMethod(self.pointer, 9, Function)(self.pointer) != 0;
    }

    pub fn requestUserStats(self: *const UserStats, steam_id: u64) u64 {
        const Function = *const fn (*anyopaque, u64) callconv(.c) u64;
        return vtable.getMethod(self.pointer, 15, Function)(self.pointer, steam_id);
    }

    pub fn listAchievements(self: *const UserStats, allocator: std.mem.Allocator) !AchievementList {
        var result = AchievementList{ .allocator = allocator };
        errdefer result.deinit();
        const count = self.getNumAchievements();
        if (count > 10000) return error.InvalidAchievementCount;
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const api_name_z = self.getAchievementName(index) orelse continue;
            const api_name = std.mem.span(api_name_z);
            var achieved: u8 = 0;
            var unlock_time: u32 = 0;
            if (!self.getAchievementAndUnlockTime(api_name_z, &achieved, &unlock_time)) continue;
            const display_name = self.getDisplayAttribute(api_name_z, "name") orelse api_name;
            const description = self.getDisplayAttribute(api_name_z, "desc") orelse "";
            const hidden_text = self.getDisplayAttribute(api_name_z, "hidden") orelse "0";
            const icon = self.getDisplayAttribute(api_name_z, "icon") orelse "";
            const icon_gray = self.getDisplayAttribute(api_name_z, "icon_gray") orelse "";
            var global_percent: f32 = 0;
            const has_percent = self.getGlobalPercent(api_name_z, &global_percent);

            const owned_api_name = try allocator.dupe(u8, api_name);
            errdefer allocator.free(owned_api_name);
            const owned_name = try allocator.dupe(u8, display_name);
            errdefer allocator.free(owned_name);
            const owned_description = try allocator.dupe(u8, description);
            errdefer allocator.free(owned_description);
            const owned_icon = try allocator.dupe(u8, icon);
            errdefer allocator.free(owned_icon);
            const owned_icon_gray = try allocator.dupe(u8, icon_gray);
            errdefer allocator.free(owned_icon_gray);
            try result.items.append(allocator, .{
                .api_name = owned_api_name,
                .name = owned_name,
                .description = owned_description,
                .icon = owned_icon,
                .icon_gray = owned_icon_gray,
                .unlocked = achieved != 0,
                .unlock_time = unlock_time,
                .hidden = std.mem.eql(u8, hidden_text, "1"),
                .global_percent = if (has_percent) global_percent else null,
            });
        }
        return result;
    }

    fn getNumAchievements(self: *const UserStats) u32 {
        const Function = *const fn (*anyopaque) callconv(.c) u32;
        return vtable.getMethod(self.pointer, 13, Function)(self.pointer);
    }

    fn getAchievementName(self: *const UserStats, index: u32) ?[*:0]const u8 {
        const Function = *const fn (*anyopaque, u32) callconv(.c) ?[*:0]const u8;
        return vtable.getMethod(self.pointer, 14, Function)(self.pointer, index);
    }

    fn getAchievementAndUnlockTime(self: *const UserStats, api_name: [*:0]const u8, achieved: *u8, unlock_time: *u32) bool {
        const Function = *const fn (*anyopaque, [*:0]const u8, *u8, *u32) callconv(.c) u8;
        return vtable.getMethod(self.pointer, 8, Function)(self.pointer, api_name, achieved, unlock_time) != 0;
    }

    fn getDisplayAttribute(self: *const UserStats, api_name: [*:0]const u8, key: [:0]const u8) ?[]const u8 {
        const Function = *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]const u8;
        const result = vtable.getMethod(self.pointer, 11, Function)(self.pointer, api_name, key) orelse return null;
        return std.mem.span(result);
    }

    fn getGlobalPercent(self: *const UserStats, api_name: [*:0]const u8, percent: *f32) bool {
        const Function = *const fn (*anyopaque, [*:0]const u8, *f32) callconv(.c) u8;
        return vtable.getMethod(self.pointer, 36, Function)(self.pointer, api_name, percent) != 0;
    }
};

test "Steam write methods use ISteamUserStats013 slots 6 and 9" {
    const Fake = struct {
        var set_called = false;
        var store_called = false;

        fn unused(_: *anyopaque) callconv(.c) u8 {
            return 0;
        }

        fn set(_: *anyopaque, name: [*:0]const u8) callconv(.c) u8 {
            set_called = std.mem.eql(u8, std.mem.span(name), "ACH_TEST");
            return @intFromBool(set_called);
        }

        fn store(_: *anyopaque) callconv(.c) u8 {
            store_called = true;
            return 1;
        }
    };
    Fake.set_called = false;
    Fake.store_called = false;
    var methods = [_]*const anyopaque{@ptrCast(&Fake.unused)} ** 10;
    methods[6] = @ptrCast(&Fake.set);
    methods[9] = @ptrCast(&Fake.store);
    var object: [*]const *const anyopaque = &methods;
    const stats = UserStats{ .pointer = @ptrCast(&object) };
    try std.testing.expect(stats.setAchievement("ACH_TEST"));
    try std.testing.expect(stats.storeStats());
    try std.testing.expect(Fake.set_called);
    try std.testing.expect(Fake.store_called);
}
