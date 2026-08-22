const std = @import("std");
const builtin = @import("builtin");
const AchievementEvent = @import("../core/event.zig").AchievementEvent;

pub const Notifier = struct {
    window: std.os.windows.HWND,
    icon: ?std.os.windows.HICON,

    pub fn init() !Notifier {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const window = api.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral("Achievement Bridge Notifications"),
            0,
            0,
            0,
            0,
            0,
            hwnd_message,
            null,
            null,
            null,
        ) orelse return error.NotificationWindowFailed;
        errdefer _ = api.DestroyWindow(window);
        const icon = api.LoadIconW(null, @ptrFromInt(32512));
        var data = baseData(window, icon);
        data.flags = nif_icon | nif_tip;
        writeWide(&data.tip, "Achievement Bridge");
        if (!api.Shell_NotifyIconW(nim_add, &data).toBool()) return error.NotificationIconFailed;
        return .{ .window = window, .icon = icon };
    }

    pub fn deinit(self: *Notifier) void {
        var data = baseData(self.window, self.icon);
        _ = api.Shell_NotifyIconW(nim_delete, &data);
        _ = api.DestroyWindow(self.window);
        self.* = undefined;
    }

    pub fn show(self: *Notifier, allocator: std.mem.Allocator, _: AchievementEvent, display_name: ?[]const u8, description: ?[]const u8, global_percent: ?f32) !void {
        const title = display_name orelse "Achievement Unlocked";
        const text = description orelse "";
        const body = if (global_percent) |percent|
            if (text.len > 0)
                try std.fmt.allocPrint(allocator, "{s}\nRaridade global: {d:.1}%", .{ text, percent })
            else
                try std.fmt.allocPrint(allocator, "Raridade global: {d:.1}%", .{percent})
        else if (text.len > 0)
            try allocator.dupe(u8, text)
        else
            try allocator.dupe(u8, "Conquista desbloqueada");
        defer allocator.free(body);
        var data = baseData(self.window, self.icon);
        data.flags = nif_info;
        data.info_flags = niif_info | niif_respect_quiet_time;
        writeWide(&data.info_title, title);
        writeWide(&data.info, body);
        if (!api.Shell_NotifyIconW(nim_modify, &data).toBool()) return error.NotificationDisplayFailed;
        _ = api.MessageBeep(0x00000040);
    }
};

const windows = std.os.windows;
const NotifyIconDataW = extern struct {
    size: windows.DWORD = @sizeOf(NotifyIconDataW),
    window: windows.HWND,
    id: u32 = 1,
    flags: u32 = 0,
    callback_message: u32 = 0,
    icon: ?windows.HICON = null,
    tip: [128]u16 = @splat(0),
    state: u32 = 0,
    state_mask: u32 = 0,
    info: [256]u16 = @splat(0),
    version_or_timeout: u32 = 0,
    info_title: [64]u16 = @splat(0),
    info_flags: u32 = 0,
    guid: windows.GUID = .{ .Data1 = 0, .Data2 = 0, .Data3 = 0, .Data4 = @splat(0) },
    balloon_icon: ?windows.HICON = null,
};

const api = struct {
    extern "user32" fn CreateWindowExW(
        extended_style: u32,
        class_name: [*:0]const u16,
        window_name: [*:0]const u16,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: ?windows.HWND,
        menu: ?windows.HMENU,
        instance: ?windows.HINSTANCE,
        parameter: ?*anyopaque,
    ) callconv(.winapi) ?windows.HWND;
    extern "user32" fn DestroyWindow(window: windows.HWND) callconv(.winapi) windows.BOOL;
    extern "user32" fn LoadIconW(instance: ?windows.HINSTANCE, icon_name: [*:0]const u16) callconv(.winapi) ?windows.HICON;
    extern "user32" fn MessageBeep(kind: u32) callconv(.winapi) windows.BOOL;
    extern "shell32" fn Shell_NotifyIconW(message: u32, data: *NotifyIconDataW) callconv(.winapi) windows.BOOL;
};

const hwnd_message: ?windows.HWND = @ptrFromInt(std.math.maxInt(usize) - 2);
const nim_add: u32 = 0;
const nim_modify: u32 = 1;
const nim_delete: u32 = 2;
const nif_icon: u32 = 0x00000002;
const nif_tip: u32 = 0x00000004;
const nif_info: u32 = 0x00000010;
const niif_info: u32 = 0x00000001;
const niif_respect_quiet_time: u32 = 0x00000080;

fn baseData(window: windows.HWND, icon: ?windows.HICON) NotifyIconDataW {
    return .{ .window = window, .icon = icon };
}

fn writeWide(destination: []u16, source: []const u8) void {
    @memset(destination, 0);
    if (destination.len < 2) return;
    _ = std.unicode.wtf8ToWtf16Le(destination[0 .. destination.len - 1], source) catch 0;
}
