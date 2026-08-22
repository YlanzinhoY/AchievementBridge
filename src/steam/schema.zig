const std = @import("std");
const bkv = @import("binary_key_values.zig");

pub const AchievementLocation = struct {
    stat_id: u32,
    bit: u5,
    permission: i32,
};

/// Resolves an achievement API name to the stat bit used by Steam's native
/// UserGameStats cache. Steam schemas group up to 32 achievements per stat.
pub fn findAchievement(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    app_id: u32,
    api_name: []const u8,
) !AchievementLocation {
    if (api_name.len == 0 or api_name.len > 256 or std.mem.indexOfScalar(u8, api_name, 0) != null)
        return error.InvalidAchievementApiName;
    var document = try bkv.parse(allocator, bytes);
    defer document.deinit();

    var app_buffer: [16]u8 = undefined;
    const app_name = try std.fmt.bufPrint(&app_buffer, "{d}", .{app_id});
    const app = document.child(app_name) orelse blk: {
        if (document.roots.items.len == 1) break :blk &document.roots.items[0];
        return error.SteamSchemaAppNotFound;
    };
    const stats = if (std.ascii.eqlIgnoreCase(app.name, "stats")) app else app.child("stats") orelse return error.SteamSchemaStatsNotFound;
    for (stats.children.items) |*stat| {
        if (stat.tag != .section) continue;
        const stat_id = std.fmt.parseInt(u32, stat.name, 10) catch continue;
        const bits = stat.child("bits") orelse continue;
        for (bits.children.items) |*bit_node| {
            if (bit_node.tag != .section) continue;
            const bit_number = std.fmt.parseInt(u8, bit_node.name, 10) catch continue;
            if (bit_number >= 32) continue;
            const name_node = bit_node.child("name") orelse continue;
            const candidate = bkv.stringValue(bytes, name_node) orelse continue;
            if (!std.ascii.eqlIgnoreCase(candidate, api_name)) continue;
            const permission = if (bit_node.child("permission")) |node|
                @as(i32, @bitCast(@as(u32, @truncate(try bkv.unsignedValue(bytes, node)))))
            else
                0;
            return .{
                .stat_id = stat_id,
                .bit = @intCast(bit_number),
                .permission = permission,
            };
        }
    }
    return error.AchievementNotFoundInSteamSchema;
}

fn appendCString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try output.appendSlice(allocator, value);
    try output.append(allocator, 0);
}

fn beginSection(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    try output.append(allocator, @intFromEnum(bkv.Type.section));
    try appendCString(output, allocator, name);
}

fn writeString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try output.append(allocator, @intFromEnum(bkv.Type.string));
    try appendCString(output, allocator, name);
    try appendCString(output, allocator, value);
}

fn writeInt(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: u32) !void {
    try output.append(allocator, @intFromEnum(bkv.Type.int32));
    try appendCString(output, allocator, name);
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    try output.appendSlice(allocator, &encoded);
}

test "resolve protected achievement to stat id and bit" {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try beginSection(&bytes, std.testing.allocator, "3751950");
    try beginSection(&bytes, std.testing.allocator, "stats");
    try beginSection(&bytes, std.testing.allocator, "1");
    try writeInt(&bytes, std.testing.allocator, "type_int", 4);
    try beginSection(&bytes, std.testing.allocator, "bits");
    try beginSection(&bytes, std.testing.allocator, "9");
    try writeString(&bytes, std.testing.allocator, "name", "ACObsidian_Ach_10");
    try writeInt(&bytes, std.testing.allocator, "permission", 2);
    try bytes.appendSlice(std.testing.allocator, &.{ 8, 8, 8, 8, 8, 8 });

    const result = try findAchievement(std.testing.allocator, bytes.items, 3751950, "acobsidian_ach_10");
    try std.testing.expectEqual(@as(u32, 1), result.stat_id);
    try std.testing.expectEqual(@as(u5, 9), result.bit);
    try std.testing.expectEqual(@as(i32, 2), result.permission);
}
