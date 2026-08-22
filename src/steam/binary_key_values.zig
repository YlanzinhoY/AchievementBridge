const std = @import("std");

pub const Type = enum(u8) {
    section = 0x00,
    string = 0x01,
    int32 = 0x02,
    float32 = 0x03,
    pointer = 0x04,
    wide_string = 0x05,
    color = 0x06,
    uint64 = 0x07,
    end = 0x08,
    int64 = 0x0a,
    alternate_end = 0x0b,
};

pub const Node = struct {
    tag: Type,
    name: []const u8,
    value_offset: usize = 0,
    value_len: usize = 0,
    end_offset: usize = 0,
    children: std.ArrayList(Node) = .empty,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children.items) |*entry| entry.deinit(allocator);
        self.children.deinit(allocator);
        self.* = undefined;
    }

    pub fn child(self: *const Node, name: []const u8) ?*const Node {
        for (self.children.items) |*candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) return candidate;
        }
        return null;
    }

    pub fn childMut(self: *Node, name: []const u8) ?*Node {
        for (self.children.items) |*candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) return candidate;
        }
        return null;
    }
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    roots: std.ArrayList(Node) = .empty,

    pub fn deinit(self: *Document) void {
        for (self.roots.items) |*node| node.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn child(self: *const Document, name: []const u8) ?*const Node {
        for (self.roots.items) |*candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) return candidate;
        }
        return null;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Document {
    var position: usize = 0;
    var document = Document{ .allocator = allocator };
    errdefer document.deinit();
    document.roots = try readChildren(allocator, bytes, &position, 0, false);
    if (position < bytes.len) {
        for (bytes[position..]) |byte| if (byte != 0) return error.TrailingBinaryKeyValueData;
    }
    return document;
}

pub fn unsignedValue(bytes: []const u8, node: *const Node) !u64 {
    const value = bytes[node.value_offset .. node.value_offset + node.value_len];
    return switch (node.tag) {
        .int32, .float32, .pointer, .color => std.mem.readInt(u32, value[0..4], .little),
        .uint64, .int64 => std.mem.readInt(u64, value[0..8], .little),
        .string => std.fmt.parseInt(u64, value[0 .. value.len - 1], 10),
        else => error.BinaryKeyValueNotNumeric,
    };
}

pub fn stringValue(bytes: []const u8, node: *const Node) ?[]const u8 {
    if (node.tag != .string or node.value_len == 0) return null;
    return bytes[node.value_offset .. node.value_offset + node.value_len - 1];
}

fn readChildren(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    position: *usize,
    depth: usize,
    expect_end: bool,
) !std.ArrayList(Node) {
    if (depth > 128) return error.BinaryKeyValueTooDeep;
    var children: std.ArrayList(Node) = .empty;
    errdefer {
        for (children.items) |*node| node.deinit(allocator);
        children.deinit(allocator);
    }
    while (position.* < bytes.len) {
        const raw_tag = bytes[position.*];
        position.* += 1;
        if (raw_tag == @intFromEnum(Type.end) or raw_tag == @intFromEnum(Type.alternate_end)) return children;
        const tag: Type = switch (raw_tag) {
            0x00 => .section,
            0x01 => .string,
            0x02 => .int32,
            0x03 => .float32,
            0x04 => .pointer,
            0x05 => .wide_string,
            0x06 => .color,
            0x07 => .uint64,
            0x0a => .int64,
            else => return error.UnknownBinaryKeyValueType,
        };
        const name = try readCString(bytes, position);
        var node = Node{ .tag = tag, .name = name };
        errdefer node.deinit(allocator);
        switch (tag) {
            .section => {
                node.children = try readChildren(allocator, bytes, position, depth + 1, true);
                node.end_offset = position.* - 1;
            },
            .string => {
                node.value_offset = position.*;
                _ = try readCString(bytes, position);
                node.value_len = position.* - node.value_offset;
            },
            .wide_string => {
                node.value_offset = position.*;
                try skipWideCString(bytes, position);
                node.value_len = position.* - node.value_offset;
            },
            .int32, .float32, .pointer, .color => {
                node.value_offset = position.*;
                node.value_len = 4;
                try advance(bytes, position, 4);
            },
            .uint64, .int64 => {
                node.value_offset = position.*;
                node.value_len = 8;
                try advance(bytes, position, 8);
            },
            .end, .alternate_end => unreachable,
        }
        try children.append(allocator, node);
    }
    if (expect_end) return error.UnterminatedBinaryKeyValueSection;
    return children;
}

fn readCString(bytes: []const u8, position: *usize) ![]const u8 {
    const start = position.*;
    const relative_end = std.mem.indexOfScalar(u8, bytes[start..], 0) orelse return error.UnterminatedBinaryKeyValueString;
    if (relative_end > 64 * 1024) return error.BinaryKeyValueStringTooLong;
    position.* = start + relative_end + 1;
    return bytes[start .. start + relative_end];
}

fn skipWideCString(bytes: []const u8, position: *usize) !void {
    const start = position.*;
    while (position.* + 1 < bytes.len) : (position.* += 2) {
        if (bytes[position.*] == 0 and bytes[position.* + 1] == 0) {
            position.* += 2;
            if (position.* - start > 128 * 1024) return error.BinaryKeyValueStringTooLong;
            return;
        }
    }
    return error.UnterminatedBinaryKeyValueString;
}

fn advance(bytes: []const u8, position: *usize, count: usize) !void {
    if (position.* + count > bytes.len) return error.TruncatedBinaryKeyValue;
    position.* += count;
}

test "parse binary key values and expose offsets" {
    const bytes = [_]u8{
        0x00, 'c', 'a', 'c', 'h', 'e', 0,
        0x02, 'c', 'r', 'c', 0, 0x78, 0x56, 0x34, 0x12,
        0x00, '1', 0,
        0x02, 'd', 'a', 't', 'a', 0, 0x00, 0x02, 0x00, 0x00,
        0x08, 0x08, 0x08,
    };
    var document = try parse(std.testing.allocator, &bytes);
    defer document.deinit();
    const cache = document.child("CACHE").?;
    try std.testing.expectEqual(@as(u64, 0x12345678), try unsignedValue(&bytes, cache.child("crc").?));
    try std.testing.expectEqual(@as(u64, 512), try unsignedValue(&bytes, cache.child("1").?.child("data").?));
    try std.testing.expectEqual(@as(usize, bytes.len - 2), cache.end_offset);
}

test "reject truncated binary key values" {
    const bytes = [_]u8{ 0x00, 'x', 0, 0x02, 'v', 0, 1 };
    try std.testing.expectError(error.TruncatedBinaryKeyValue, parse(std.testing.allocator, &bytes));
}
