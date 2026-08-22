const std = @import("std");
const windows = std.os.windows;
const protocol = @import("cloud_protocol.zig");

pub fn ping(timeout_ms: u32) !void {
    try transact(.{
        .command = @intFromEnum(protocol.Command.ping),
        .app_id = 0,
        .stat_id = 0,
        .bit = 0,
        .unlock_time = 0,
    }, timeout_ms);
}

pub fn captureNativeStats(app_id: u32, stat_id: u32, bit: u5, unlock_time: u32, timeout_ms: u32) !void {
    try transact(.{
        .command = @intFromEnum(protocol.Command.capture_native_stats),
        .app_id = app_id,
        .stat_id = stat_id,
        .bit = bit,
        .unlock_time = unlock_time,
    }, timeout_ms);
}

fn transact(request: protocol.Request, timeout_ms: u32) !void {
    if (!kernel32.WaitNamedPipeW(protocol.pipe_name_w, timeout_ms).toBool()) return error.AchievementCloudHostUnavailable;
    const pipe = kernel32.CreateFileW(protocol.pipe_name_w, 0xC0000000, 0, null, 3, 0, null);
    if (pipe == windows.INVALID_HANDLE_VALUE) return error.AchievementCloudHostUnavailable;
    defer _ = kernel32.CloseHandle(pipe);

    var written: u32 = 0;
    if (!kernel32.WriteFile(pipe, &request, @sizeOf(protocol.Request), &written, null).toBool() or written != @sizeOf(protocol.Request))
        return error.AchievementCloudHostWriteFailed;
    var response: protocol.Response = undefined;
    var read: u32 = 0;
    if (!kernel32.ReadFile(pipe, &response, @sizeOf(protocol.Response), &read, null).toBool() or read != @sizeOf(protocol.Response))
        return error.AchievementCloudHostReadFailed;
    if (response.magic != protocol.protocol_magic or response.version != protocol.protocol_version)
        return error.AchievementCloudHostProtocolMismatch;
    return switch (response.status) {
        @intFromEnum(protocol.Status.ok) => {},
        @intFromEnum(protocol.Status.app_not_managed) => error.AchievementAppNotManaged,
        @intFromEnum(protocol.Status.stats_sync_disabled) => error.AchievementStatsSyncDisabled,
        @intFromEnum(protocol.Status.cloud_redirect_unavailable) => error.CloudRedirectUnavailable,
        else => error.AchievementCloudHostRejected,
    };
}

const kernel32 = struct {
    extern "kernel32" fn WaitNamedPipeW(name: [*:0]const u16, timeout: u32) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, creation: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn ReadFile(handle: windows.HANDLE, buffer: *anyopaque, count: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WriteFile(handle: windows.HANDLE, buffer: *const anyopaque, count: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
};

test "cloud ipc request encodes one achievement bit" {
    const request = protocol.Request{
        .command = @intFromEnum(protocol.Command.capture_native_stats),
        .app_id = 3751950,
        .stat_id = 1,
        .bit = 9,
        .unlock_time = 1787390253,
    };
    try std.testing.expectEqual(@as(u32, 3751950), request.app_id);
    try std.testing.expectEqual(@as(u32, 9), request.bit);
}
