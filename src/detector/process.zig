const std = @import("std");
const builtin = @import("builtin");

pub const Process = struct {
    pid: u32,
    name: []u8,
    executable_path: []u8,

    fn deinit(self: *Process, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.executable_path);
        self.* = undefined;
    }
};

pub const ProcessList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Process) = .empty,

    pub fn deinit(self: *ProcessList) void {
        for (self.items.items) |*process| process.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn enumerate(allocator: std.mem.Allocator) !ProcessList {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const windows = std.os.windows;
    const api = struct {
        const ProcessEntry32W = extern struct {
            size: windows.DWORD,
            usage: windows.DWORD,
            process_id: windows.DWORD,
            default_heap_id: windows.ULONG_PTR,
            module_id: windows.DWORD,
            thread_count: windows.DWORD,
            parent_process_id: windows.DWORD,
            base_priority: windows.LONG,
            flags: windows.DWORD,
            executable_name: [windows.MAX_PATH]windows.WCHAR,
        };

        extern "kernel32" fn CreateToolhelp32Snapshot(flags: windows.DWORD, process_id: windows.DWORD) callconv(.winapi) windows.HANDLE;
        extern "kernel32" fn Process32FirstW(snapshot: windows.HANDLE, entry: *ProcessEntry32W) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn Process32NextW(snapshot: windows.HANDLE, entry: *ProcessEntry32W) callconv(.winapi) windows.BOOL;
        extern "kernel32" fn OpenProcess(access: windows.DWORD, inherit: windows.BOOL, process_id: windows.DWORD) callconv(.winapi) ?windows.HANDLE;
        extern "kernel32" fn QueryFullProcessImageNameW(process: windows.HANDLE, flags: windows.DWORD, path: [*]windows.WCHAR, size: *windows.DWORD) callconv(.winapi) windows.BOOL;
    };

    var result = ProcessList{ .allocator = allocator };
    errdefer result.deinit();
    const snapshot = api.CreateToolhelp32Snapshot(0x00000002, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return error.ProcessSnapshotFailed;
    defer windows.CloseHandle(snapshot);

    var entry: api.ProcessEntry32W = undefined;
    entry.size = @sizeOf(api.ProcessEntry32W);
    if (!api.Process32FirstW(snapshot, &entry).toBool()) return result;
    while (true) {
        if (entry.process_id != 0) {
            if (queryPath(allocator, api, entry.process_id)) |path| {
                errdefer allocator.free(path);
                const name_units = std.mem.indexOfScalar(u16, &entry.executable_name, 0) orelse entry.executable_name.len;
                const name = try std.unicode.wtf16LeToWtf8Alloc(allocator, entry.executable_name[0..name_units]);
                errdefer allocator.free(name);
                try result.items.append(allocator, .{
                    .pid = entry.process_id,
                    .name = name,
                    .executable_path = path,
                });
            } else |_| {}
        }
        if (!api.Process32NextW(snapshot, &entry).toBool()) break;
    }
    return result;
}

fn queryPath(allocator: std.mem.Allocator, comptime api: type, pid: u32) ![]u8 {
    const windows = std.os.windows;
    const handle = api.OpenProcess(0x1000, .FALSE, pid) orelse return error.ProcessAccessDenied;
    defer windows.CloseHandle(handle);
    var buffer: [32768]u16 = undefined;
    var size: windows.DWORD = buffer.len;
    if (!api.QueryFullProcessImageNameW(handle, 0, &buffer, &size).toBool()) return error.ProcessPathUnavailable;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, buffer[0..size]);
}
