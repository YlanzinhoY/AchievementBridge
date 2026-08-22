const std = @import("std");
const builtin = @import("builtin");

pub const Library = struct {
    handle: std.os.windows.HMODULE,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Library {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);
        const handle = api.LoadLibraryExW(path_w, null, 0x00000008) orelse return error.LoadSteamClientFailed;
        return .{ .handle = handle };
    }

    pub fn close(self: *Library) void {
        _ = api.FreeLibrary(self.handle);
        self.* = undefined;
    }

    pub fn lookup(self: *const Library, comptime Function: type, name: [:0]const u8) !Function {
        const pointer = api.GetProcAddress(self.handle, name) orelse return error.SteamSymbolNotFound;
        return @ptrCast(pointer);
    }
};

const windows = std.os.windows;
const api = struct {
    extern "kernel32" fn LoadLibraryExW(path: [*:0]const u16, file: ?windows.HANDLE, flags: u32) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) windows.BOOL;
};
