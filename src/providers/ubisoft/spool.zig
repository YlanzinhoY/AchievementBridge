const std = @import("std");

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    unlocked: std.AutoHashMap(u64, i64),

    pub fn init(allocator: std.mem.Allocator) Snapshot {
        return .{ .allocator = allocator, .unlocked = std.AutoHashMap(u64, i64).init(allocator) };
    }

    pub fn deinit(self: *Snapshot) void {
        self.unlocked.deinit();
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Snapshot {
    var snapshot = Snapshot.init(allocator);
    errdefer snapshot.deinit();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const tag = try readVarint(bytes, &offset, bytes.len);
        const field_number = tag >> 3;
        const wire_type: u3 = @intCast(tag & 7);
        if (field_number == 1 and wire_type == 2) {
            const payload_length = try readVarint(bytes, &offset, bytes.len);
            const payload_end = std.math.add(usize, offset, std.math.cast(usize, payload_length) orelse return error.InvalidSpool) catch return error.InvalidSpool;
            if (payload_end > bytes.len) return error.TruncatedSpool;
            const achievement_id = try findFirstVarint(bytes, 1, offset, payload_end, 0);
            const earned_time_raw = try findFirstVarint(bytes, 2, offset, payload_end, 0);
            if (achievement_id != null and earned_time_raw != null and achievement_id.? > 0 and earned_time_raw.? > 0) {
                const earned_time_u64 = if (earned_time_raw.? >= 10_000_000_000) earned_time_raw.? / 1000 else earned_time_raw.?;
                const earned_time = std.math.cast(i64, earned_time_u64) orelse return error.InvalidTimestamp;
                const result = try snapshot.unlocked.getOrPut(achievement_id.?);
                if (!result.found_existing or earned_time < result.value_ptr.*) result.value_ptr.* = earned_time;
            }
            offset = payload_end;
        } else {
            offset = try skipField(bytes, offset, wire_type, bytes.len);
        }
    }
    return snapshot;
}

fn findFirstVarint(bytes: []const u8, target_field: u64, start: usize, end: usize, depth: u8) !?u64 {
    var offset = start;
    while (offset < end) {
        const tag = try readVarint(bytes, &offset, end);
        const field_number = tag >> 3;
        const wire_type: u3 = @intCast(tag & 7);
        if (wire_type == 0) {
            const value = try readVarint(bytes, &offset, end);
            if (field_number == target_field) return value;
        } else if (wire_type == 2) {
            const payload_length = try readVarint(bytes, &offset, end);
            const payload_end = std.math.add(usize, offset, std.math.cast(usize, payload_length) orelse return error.InvalidSpool) catch return error.InvalidSpool;
            if (payload_end > end) return error.TruncatedSpool;
            if (depth < 4) if (try findFirstVarint(bytes, target_field, offset, payload_end, depth + 1)) |value| return value;
            offset = payload_end;
        } else {
            offset = try skipField(bytes, offset, wire_type, end);
        }
    }
    return null;
}

fn readVarint(bytes: []const u8, offset: *usize, end: usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var count: u8 = 0;
    while (offset.* < end and count < 10) : (count += 1) {
        const byte = bytes[offset.*];
        offset.* += 1;
        value |= @as(u64, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) return value;
        if (shift >= 63) return error.VarintTooLarge;
        shift += 7;
    }
    return if (offset.* >= end) error.TruncatedSpool else error.VarintTooLarge;
}

fn skipField(bytes: []const u8, start: usize, wire_type: u3, end: usize) !usize {
    var offset = start;
    switch (wire_type) {
        0 => _ = try readVarint(bytes, &offset, end),
        1 => offset = std.math.add(usize, offset, 8) catch return error.InvalidSpool,
        2 => {
            const length = try readVarint(bytes, &offset, end);
            offset = std.math.add(usize, offset, std.math.cast(usize, length) orelse return error.InvalidSpool) catch return error.InvalidSpool;
        },
        5 => offset = std.math.add(usize, offset, 4) catch return error.InvalidSpool,
        else => return error.UnsupportedWireType,
    }
    if (offset > end or offset > bytes.len) return error.TruncatedSpool;
    return offset;
}

test "parse Ubisoft spool records and normalize millisecond timestamps" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendVarint(&payload, allocator, 8);
    try appendVarint(&payload, allocator, 27);
    try appendVarint(&payload, allocator, 16);
    try appendVarint(&payload, allocator, 1_700_000_000_000);
    try appendVarint(&bytes, allocator, 10);
    try appendVarint(&bytes, allocator, payload.items.len);
    try bytes.appendSlice(allocator, payload.items);
    var snapshot = try parse(allocator, bytes.items);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(i64, 1_700_000_000), snapshot.unlocked.get(27).?);
}

fn appendVarint(list: *std.ArrayList(u8), allocator: std.mem.Allocator, initial: u64) !void {
    var value = initial;
    while (value >= 0x80) {
        try list.append(allocator, @intCast((value & 0x7f) | 0x80));
        value >>= 7;
    }
    try list.append(allocator, @intCast(value));
}
