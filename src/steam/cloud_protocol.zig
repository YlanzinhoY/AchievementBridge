const std = @import("std");

pub const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\AchievementBridge.CloudRedirect.v1");
pub const protocol_magic: u32 = 0x31554241; // "ABU1" little-endian
pub const protocol_version: u32 = 1;

pub const Command = enum(u32) { ping = 0, capture_native_stats = 1 };
pub const Status = enum(u32) {
    ok = 0,
    invalid_request = 1,
    cloud_redirect_unavailable = 2,
    app_not_managed = 3,
    stats_sync_disabled = 4,
};

pub const Request = extern struct {
    magic: u32 = protocol_magic,
    version: u32 = protocol_version,
    command: u32,
    app_id: u32,
    stat_id: u32,
    bit: u32,
    unlock_time: u32,
};

pub const Response = extern struct {
    magic: u32 = protocol_magic,
    version: u32 = protocol_version,
    status: u32,
};

test "cloud host protocol stays fixed width" {
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(Request));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Response));
    const request = Request{ .command = 0, .app_id = 0, .stat_id = 0, .bit = 0, .unlock_time = 0 };
    try std.testing.expectEqual(@as(u32, protocol_magic), request.magic);
}
