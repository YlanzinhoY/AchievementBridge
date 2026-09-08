const std = @import("std");

const file_magic: u32 = 0x564F_4241; // "ABOV"
const file_version: u32 = 1;
const header_size = 16;
const entry_size = 144;
const max_entries = 4096;

pub fn clearAchievement(
    allocator: std.mem.Allocator,
    io: std.Io,
    steam_root: []const u8,
    account_id: u32,
    app_id: u32,
    stat_id: u32,
    bit: u5,
) !bool {
    const path = try std.fs.path.join(allocator, &.{ steam_root, "AchievementBridge", "achievement-overlays-v1.bin" });
    defer allocator.free(path);
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(existing);
    const bytes = try allocator.dupe(u8, existing);
    defer allocator.free(bytes);
    if (!try clearBytes(bytes, account_id, app_id, stat_id, bit)) return false;

    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.replace(io);
    return true;
}

fn clearBytes(bytes: []u8, account_id: u32, app_id: u32, stat_id: u32, bit: u5) !bool {
    if (bytes.len < header_size) return error.InvalidAchievementOverlay;
    if (readU32(bytes[0..4]) != file_magic or readU32(bytes[4..8]) != file_version)
        return error.InvalidAchievementOverlay;
    const count = readU32(bytes[8..12]);
    if (count > max_entries) return error.InvalidAchievementOverlay;
    const payload_size = std.math.mul(usize, count, entry_size) catch return error.InvalidAchievementOverlay;
    const expected_size = std.math.add(usize, header_size, payload_size) catch return error.InvalidAchievementOverlay;
    if (bytes.len != expected_size) return error.InvalidAchievementOverlay;
    const payload = bytes[header_size..];
    if (readU32(bytes[12..16]) != std.hash.Crc32.hash(payload)) return error.InvalidAchievementOverlayCrc;

    const mask = @as(u32, 1) << bit;
    var changed = false;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const offset = header_size + index * entry_size;
        if (readU32(bytes[offset..][0..4]) != account_id or
            readU32(bytes[offset + 4 ..][0..4]) != app_id or
            readU32(bytes[offset + 8 ..][0..4]) != stat_id) continue;
        const old_bits = readU32(bytes[offset + 12 ..][0..4]);
        if ((old_bits & mask) == 0) continue;
        writeU32(bytes[offset + 12 ..][0..4], old_bits & ~mask);
        writeU32(bytes[offset + 16 + @as(usize, bit) * 4 ..][0..4], 0);
        changed = true;
    }
    if (changed) writeU32(bytes[12..16], std.hash.Crc32.hash(payload));
    return changed;
}

fn readU32(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

fn writeU32(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .little);
}

test "clear one persistent overlay bit and preserve neighbors" {
    var bytes: [header_size + entry_size]u8 = @splat(0);
    writeU32(bytes[0..4], file_magic);
    writeU32(bytes[4..8], file_version);
    writeU32(bytes[8..12], 1);
    writeU32(bytes[16..20], 1208830004);
    writeU32(bytes[20..24], 2842040);
    writeU32(bytes[24..28], 4);
    writeU32(bytes[28..32], (@as(u32, 1) << 15) | (@as(u32, 1) << 16));
    writeU32(bytes[32 + 15 * 4 ..][0..4], 1234);
    writeU32(bytes[32 + 16 * 4 ..][0..4], 5678);
    writeU32(bytes[12..16], std.hash.Crc32.hash(bytes[header_size..]));

    try std.testing.expect(try clearBytes(&bytes, 1208830004, 2842040, 4, 15));
    try std.testing.expectEqual(@as(u32, @as(u32, 1) << 16), readU32(bytes[28..32]));
    try std.testing.expectEqual(@as(u32, 0), readU32(bytes[32 + 15 * 4 ..][0..4]));
    try std.testing.expectEqual(@as(u32, 5678), readU32(bytes[32 + 16 * 4 ..][0..4]));
    try std.testing.expectEqual(std.hash.Crc32.hash(bytes[header_size..]), readU32(bytes[12..16]));
}
