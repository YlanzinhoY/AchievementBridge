const std = @import("std");
const bkv = @import("binary_key_values.zig");

pub const Mutation = struct {
    bytes: []u8,
    changed: bool,
    unlock_time: u32,
    crc: u32,

    pub fn deinit(self: *Mutation, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Adds one achievement bit to a native UserGameStats cache. Existing nodes are
/// edited in place and new nodes are spliced immediately before their parent
/// terminator, so unrelated stats and unknown KeyValues fields survive intact.
pub fn unlock(
    allocator: std.mem.Allocator,
    existing: []const u8,
    stat_id: u32,
    bit: u5,
    requested_unlock_time: u32,
) !Mutation {
    if (requested_unlock_time == 0) return error.InvalidAchievementUnlockTime;

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    if (existing.len == 0) {
        try writeEmptyCache(&output, allocator);
    } else {
        try output.appendSlice(allocator, existing);
    }

    var stat_name_buffer: [16]u8 = undefined;
    const stat_name = try std.fmt.bufPrint(&stat_name_buffer, "{d}", .{stat_id});
    var bit_name_buffer: [4]u8 = undefined;
    const bit_name = try std.fmt.bufPrint(&bit_name_buffer, "{d}", .{bit});
    const mask = @as(u32, 1) << bit;
    var changed = false;
    var unlock_time = requested_unlock_time;

    {
        var document = try bkv.parse(allocator, output.items);
        defer document.deinit();
        const cache = document.child("cache") orelse return error.SteamStatsCacheRootNotFound;
        if (cache.child(stat_name)) |stat| {
            if (stat.tag != .section) return error.InvalidSteamStatSection;
            const data = stat.child("data") orelse return error.SteamStatDataNotFound;
            if (data.tag != .int32 or data.value_len != 4) return error.InvalidSteamStatData;
            const old_value: u32 = @intCast(try bkv.unsignedValue(output.items, data));
            if ((old_value & mask) == 0) {
                writeU32(output.items[data.value_offset..][0..4], old_value | mask);
                changed = true;
            }

            if (stat.child("AchievementTimes")) |times| {
                if (times.tag != .section) return error.InvalidSteamAchievementTimes;
                if (times.child(bit_name)) |time_node| {
                    if (time_node.tag != .int32 or time_node.value_len != 4) return error.InvalidSteamAchievementTime;
                    const old_time: u32 = @intCast(try bkv.unsignedValue(output.items, time_node));
                    if (old_time != 0) {
                        unlock_time = old_time;
                    } else {
                        writeU32(output.items[time_node.value_offset..][0..4], requested_unlock_time);
                        changed = true;
                    }
                } else {
                    var encoded: std.ArrayList(u8) = .empty;
                    defer encoded.deinit(allocator);
                    try writeInt(&encoded, allocator, bit_name, requested_unlock_time);
                    try output.insertSlice(allocator, times.end_offset, encoded.items);
                    changed = true;
                }
            } else {
                var encoded: std.ArrayList(u8) = .empty;
                defer encoded.deinit(allocator);
                try beginSection(&encoded, allocator, "AchievementTimes");
                try writeInt(&encoded, allocator, bit_name, requested_unlock_time);
                try encoded.append(allocator, @intFromEnum(bkv.Type.end));
                try output.insertSlice(allocator, stat.end_offset, encoded.items);
                changed = true;
            }
        } else {
            var encoded: std.ArrayList(u8) = .empty;
            defer encoded.deinit(allocator);
            try beginSection(&encoded, allocator, stat_name);
            try writeInt(&encoded, allocator, "data", mask);
            try beginSection(&encoded, allocator, "AchievementTimes");
            try writeInt(&encoded, allocator, bit_name, requested_unlock_time);
            try encoded.appendSlice(allocator, &.{
                @intFromEnum(bkv.Type.end),
                @intFromEnum(bkv.Type.end),
            });
            try output.insertSlice(allocator, cache.end_offset, encoded.items);
            changed = true;
        }
    }

    const crc = try computeCrc(allocator, output.items);
    {
        var document = try bkv.parse(allocator, output.items);
        defer document.deinit();
        const cache = document.child("cache") orelse return error.SteamStatsCacheRootNotFound;
        const crc_node = cache.child("crc") orelse return error.SteamStatsCacheCrcNotFound;
        if (crc_node.tag != .int32 or crc_node.value_len != 4) return error.InvalidSteamStatsCacheCrc;
        const old_crc: u32 = @intCast(try bkv.unsignedValue(output.items, crc_node));
        if (old_crc != crc) {
            writeU32(output.items[crc_node.value_offset..][0..4], crc);
            changed = true;
        }
    }

    return .{
        .bytes = try output.toOwnedSlice(allocator),
        .changed = changed,
        .unlock_time = unlock_time,
        .crc = crc,
    };
}

const CrcStat = struct {
    id: u32,
    value: u32,
    has_achievement_times: bool = false,
    unlock_times: [32]u32 = @splat(0),
};

pub fn computeCrc(allocator: std.mem.Allocator, bytes: []const u8) !u32 {
    var document = try bkv.parse(allocator, bytes);
    defer document.deinit();
    const cache = document.child("cache") orelse return error.SteamStatsCacheRootNotFound;

    var stats: std.ArrayList(CrcStat) = .empty;
    defer stats.deinit(allocator);
    for (cache.children.items) |*stat_node| {
        if (stat_node.tag != .section) continue;
        const stat_id = std.fmt.parseInt(u32, stat_node.name, 10) catch continue;
        const data_node = stat_node.child("data") orelse continue;
        const value: u32 = @truncate(try bkv.unsignedValue(bytes, data_node));
        var stat = CrcStat{ .id = stat_id, .value = value };
        if (stat_node.child("AchievementTimes")) |times| {
            if (times.tag != .section) return error.InvalidSteamAchievementTimes;
            stat.has_achievement_times = true;
            for (times.children.items) |*time_node| {
                const bit_number = std.fmt.parseInt(u8, time_node.name, 10) catch continue;
                if (bit_number >= 32) continue;
                stat.unlock_times[bit_number] = @truncate(try bkv.unsignedValue(bytes, time_node));
            }
        }
        try stats.append(allocator, stat);
    }
    std.mem.sort(CrcStat, stats.items, {}, struct {
        fn lessThan(_: void, left: CrcStat, right: CrcStat) bool {
            return left.id < right.id;
        }
    }.lessThan);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    for (stats.items) |stat| {
        try appendU32(&input, allocator, stat.id);
        try appendU32(&input, allocator, stat.value);
    }
    for (stats.items) |stat| {
        if (!stat.has_achievement_times) continue;
        try appendU32(&input, allocator, stat.id);
        try appendU32(&input, allocator, stat.value);
        for (stat.unlock_times, 0..) |timestamp, bit_number| {
            if (timestamp == 0) continue;
            try appendU32(&input, allocator, @intCast(bit_number));
            try appendU32(&input, allocator, timestamp);
        }
    }
    return if (input.items.len == 0) 0 else std.hash.Crc32.hash(input.items);
}

fn writeEmptyCache(output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try beginSection(output, allocator, "cache");
    try writeInt(output, allocator, "crc", 0);
    try writeInt(output, allocator, "PendingChanges", 0);
    try output.appendSlice(allocator, &.{
        @intFromEnum(bkv.Type.end),
        @intFromEnum(bkv.Type.end),
    });
}

fn beginSection(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) !void {
    try output.append(allocator, @intFromEnum(bkv.Type.section));
    try appendCString(output, allocator, name);
}

fn writeInt(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: u32) !void {
    try output.append(allocator, @intFromEnum(bkv.Type.int32));
    try appendCString(output, allocator, name);
    var encoded: [4]u8 = undefined;
    writeU32(&encoded, value);
    try output.appendSlice(allocator, &encoded);
}

fn appendCString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try output.appendSlice(allocator, value);
    try output.append(allocator, 0);
}

fn appendU32(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var encoded: [4]u8 = undefined;
    writeU32(&encoded, value);
    try output.appendSlice(allocator, &encoded);
}

fn writeU32(destination: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, destination, value, .little);
}

test "unlock reproduces the proven Black Flag native cache" {
    const expected = &[_]u8{
        0x00, 'c', 'a', 'c', 'h', 'e', 0x00,
        0x02, 'c', 'r', 'c', 0x00, 0x85, 0xB6, 0x63, 0xED,
        0x02, 'P', 'e', 'n', 'd', 'i', 'n', 'g', 'C', 'h', 'a', 'n', 'g', 'e', 's', 0x00, 0, 0, 0, 0,
        0x00, '1', 0x00,
        0x02, 'd', 'a', 't', 'a', 0x00, 0x00, 0x02, 0x00, 0x00,
        0x00, 'A', 'c', 'h', 'i', 'e', 'v', 'e', 'm', 'e', 'n', 't', 'T', 'i', 'm', 'e', 's', 0x00,
        0x02, '9', 0x00, 0x2D, 0x69, 0x89, 0x6A,
        0x08, 0x08, 0x08, 0x08,
    };
    var mutation = try unlock(std.testing.allocator, &.{}, 1, 9, 1787390253);
    defer mutation.deinit(std.testing.allocator);
    try std.testing.expect(mutation.changed);
    try std.testing.expectEqual(@as(u32, 0xED63B685), mutation.crc);
    try std.testing.expectEqualSlices(u8, expected, mutation.bytes);
}

test "unlock is idempotent and preserves unknown fields" {
    var first = try unlock(std.testing.allocator, &.{}, 1, 9, 1787390253);
    defer first.deinit(std.testing.allocator);
    const cache_end = first.bytes.len - 2;
    const unknown = &[_]u8{ 0x01, 'N', 'o', 't', 'e', 0x00, 'k', 'e', 'e', 'p', 0x00 };
    var extended: std.ArrayList(u8) = .empty;
    defer extended.deinit(std.testing.allocator);
    try extended.appendSlice(std.testing.allocator, first.bytes);
    try extended.insertSlice(std.testing.allocator, cache_end, unknown);

    var second = try unlock(std.testing.allocator, extended.items, 1, 9, 2000000000);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(!second.changed); // Unknown fields do not participate in Steam's CRC.
    try std.testing.expectEqual(@as(u32, 1787390253), second.unlock_time);
    try std.testing.expect(std.mem.indexOf(u8, second.bytes, unknown) != null);

    var third = try unlock(std.testing.allocator, second.bytes, 1, 9, 2000000000);
    defer third.deinit(std.testing.allocator);
    try std.testing.expect(!third.changed);
    try std.testing.expectEqualSlices(u8, second.bytes, third.bytes);
}
