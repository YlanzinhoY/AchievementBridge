const std = @import("std");
const windows = std.os.windows;
const protocol = @import("cloud_protocol.zig");
const pipe_name_w = protocol.pipe_name_w;
const Command = protocol.Command;
const Status = protocol.Status;
const Request = protocol.Request;
const Response = protocol.Response;

const NotifyFn = ?*const fn (i32, [*:0]const u8, [*:0]const u8) callconv(.c) void;
const AchievementBlock = extern struct {
    stat_id: u32,
    bits: u32,
    unlock_times: [32]u32,
};
const PlaytimeInfo = extern struct {
    minutes_forever: u32,
    minutes_last_two_weeks: u32,
    last_played_time: u32,
    playtime_windows: u32,
    playtime_mac: u32,
    playtime_linux: u32,
};

const RealApi = struct {
    module: windows.HMODULE,
    init: *const fn ([*:0]const u8, NotifyFn) callconv(.c) bool,
    handle_rpc: *const fn ([*:0]const u8, u32, u32, ?[*]const u8, u32, ?[*]u8, u32, *u32, *i32) callconv(.c) bool,
    add_app: ?*const fn (u32) callconv(.c) void,
    remove_app: ?*const fn (u32) callconv(.c) void,
    is_app: *const fn (u32) callconv(.c) bool,
    set_account_id: ?*const fn (u32) callconv(.c) void,
    set_apps: *const fn (?[*]const u32, u32) callconv(.c) void,
    drain_playtime_updates: ?*const fn () callconv(.c) void,
    shutdown: *const fn () callconv(.c) void,
    install_vtable_hooks: ?*const fn () callconv(.c) bool,
    enable_stats_sync: ?*const fn (bool, bool) callconv(.c) void,
    notify_app_running: ?*const fn (u32, bool) callconv(.c) void,
    notify_stats_stored: ?*const fn (u32) callconv(.c) void,
    notify_stats_stored_from: ?*const fn (u32, u32) callconv(.c) void,
    get_playtime: ?*const fn (u32, *PlaytimeInfo) callconv(.c) bool,
    get_achievements: ?*const fn (u32, [*]AchievementBlock, u32) callconv(.c) u32,
};

var real: ?RealApi = null;
var server_thread: ?std.Thread = null;
var stopping: std.atomic.Value(bool) = .init(false);
var initialized: std.atomic.Value(bool) = .init(false);
var state_mutex: std.atomic.Mutex = .unlocked;
var managed_apps: [4096]u32 = undefined;
var managed_app_count: usize = 0;
const OverlayEntry = struct { app_id: u32, block: AchievementBlock };
var overlays: [4096]OverlayEntry = undefined;
var overlay_count: usize = 0;

export fn CR_InitCloudSave(steam_path: [*:0]const u8, notify: NotifyFn) callconv(.c) bool {
    if (real == null) real = loadRealApi(steam_path) catch null;
    const ok = if (real) |api| api.init(steam_path, notify) else true;
    if (ok and server_thread == null) {
        stopping.store(false, .release);
        server_thread = std.Thread.spawn(.{}, servePipe, .{}) catch null;
    }
    initialized.store(ok, .release);
    return ok;
}

export fn CR_HandleCloudRpc(method: [*:0]const u8, app_id: u32, account_id: u32, request: ?[*]const u8, request_len: u32, response: ?[*]u8, response_max_len: u32, response_len: *u32, eresult: *i32) callconv(.c) bool {
    const api = real orelse return false;
    return api.handle_rpc(method, app_id, account_id, request, request_len, response, response_max_len, response_len, eresult);
}

export fn CR_AddApp(app_id: u32) callconv(.c) void {
    addManagedApp(app_id);
    if (real) |api| if (api.add_app) |function| function(app_id);
}

export fn CR_RemoveApp(app_id: u32) callconv(.c) void {
    removeManagedApp(app_id);
    if (real) |api| if (api.remove_app) |function| function(app_id);
}

export fn CR_IsApp(app_id: u32) callconv(.c) bool {
    return isManagedApp(app_id);
}

export fn CR_SetAccountId(account_id: u32) callconv(.c) void {
    if (real) |api| if (api.set_account_id) |function| function(account_id);
}

export fn CR_SetApps(app_ids: ?[*]const u32, count: u32) callconv(.c) void {
    {
        lockState();
        defer state_mutex.unlock();
        managed_app_count = 0;
        if (app_ids) |items| {
            const safe_count: usize = @min(count, managed_apps.len);
            @memcpy(managed_apps[0..safe_count], items[0..safe_count]);
            managed_app_count = safe_count;
        }
    }
    if (real) |api| api.set_apps(app_ids, count);
}

export fn CR_DrainPlaytimeUpdates() callconv(.c) void {
    if (real) |api| if (api.drain_playtime_updates) |function| function();
}

export fn CR_InstallVtableHooks() callconv(.c) bool {
    if (real) |api| if (api.install_vtable_hooks) |function| return function();
    return false;
}

export fn CR_EnableStatsSync(achievements: bool, playtime: bool) callconv(.c) void {
    if (real) |api| if (api.enable_stats_sync) |function| function(achievements, playtime);
}

export fn CR_NotifyAppRunning(app_id: u32, running: bool) callconv(.c) void {
    if (real) |api| if (api.notify_app_running) |function| function(app_id, running);
}

export fn CR_NotifyStatsStored(app_id: u32) callconv(.c) void {
    if (real) |api| if (api.notify_stats_stored) |function| function(app_id);
}

export fn CR_NotifyStatsStoredFrom(app_id: u32, native_app_id: u32) callconv(.c) void {
    if (real) |api| if (api.notify_stats_stored_from) |function| function(app_id, native_app_id);
}

export fn CR_GetPlaytime(app_id: u32, output: *PlaytimeInfo) callconv(.c) bool {
    if (real) |api| if (api.get_playtime) |function| return function(app_id, output);
    return false;
}

export fn CR_GetAchievements(app_id: u32, output: [*]AchievementBlock, max_blocks: u32) callconv(.c) u32 {
    var count: u32 = 0;
    if (real) |api| if (api.get_achievements) |function| {
        count = @min(function(app_id, output, max_blocks), max_blocks);
    };

    lockState();
    defer state_mutex.unlock();
    for (overlays[0..overlay_count]) |entry| {
        if (entry.app_id != app_id) continue;
        var target: ?*AchievementBlock = null;
        for (output[0..count]) |*candidate| {
            if (candidate.stat_id == entry.block.stat_id) {
                target = candidate;
                break;
            }
        }
        if (target == null and count < max_blocks) {
            output[count] = std.mem.zeroes(AchievementBlock);
            output[count].stat_id = entry.block.stat_id;
            target = &output[count];
            count += 1;
        }
        if (target) |block| {
            block.bits |= entry.block.bits;
            for (entry.block.unlock_times, 0..) |timestamp, bit| {
                if (timestamp != 0) block.unlock_times[bit] = timestamp;
            }
        }
    }
    return count;
}

export fn CR_Shutdown() callconv(.c) void {
    initialized.store(false, .release);
    stopPipeServer();
    if (real) |api| {
        api.shutdown();
        _ = kernel32.FreeLibrary(api.module);
        real = null;
    }
}

fn loadRealApi(steam_path_z: [*:0]const u8) !RealApi {
    const allocator = std.heap.page_allocator;
    const steam_path = std.mem.span(steam_path_z);
    const separator = if (steam_path.len > 0 and (steam_path[steam_path.len - 1] == '\\' or steam_path[steam_path.len - 1] == '/')) "" else "\\";
    const dll_path = try std.fmt.allocPrint(allocator, "{s}{s}cloud_redirect.dll", .{ steam_path, separator });
    defer allocator.free(dll_path);
    const wide_path = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, dll_path);
    defer allocator.free(wide_path);
    const module = kernel32.LoadLibraryW(wide_path) orelse return error.CloudRedirectLoadFailed;
    errdefer _ = kernel32.FreeLibrary(module);
    return .{
        .module = module,
        .init = try requiredSymbol(module, *const fn ([*:0]const u8, NotifyFn) callconv(.c) bool, "CR_InitCloudSave"),
        .handle_rpc = try requiredSymbol(module, *const fn ([*:0]const u8, u32, u32, ?[*]const u8, u32, ?[*]u8, u32, *u32, *i32) callconv(.c) bool, "CR_HandleCloudRpc"),
        .add_app = optionalSymbol(module, *const fn (u32) callconv(.c) void, "CR_AddApp"),
        .remove_app = optionalSymbol(module, *const fn (u32) callconv(.c) void, "CR_RemoveApp"),
        .is_app = try requiredSymbol(module, *const fn (u32) callconv(.c) bool, "CR_IsApp"),
        .set_account_id = optionalSymbol(module, *const fn (u32) callconv(.c) void, "CR_SetAccountId"),
        .set_apps = try requiredSymbol(module, *const fn (?[*]const u32, u32) callconv(.c) void, "CR_SetApps"),
        .drain_playtime_updates = optionalSymbol(module, *const fn () callconv(.c) void, "CR_DrainPlaytimeUpdates"),
        .shutdown = try requiredSymbol(module, *const fn () callconv(.c) void, "CR_Shutdown"),
        .install_vtable_hooks = optionalSymbol(module, *const fn () callconv(.c) bool, "CR_InstallVtableHooks"),
        .enable_stats_sync = optionalSymbol(module, *const fn (bool, bool) callconv(.c) void, "CR_EnableStatsSync"),
        .notify_app_running = optionalSymbol(module, *const fn (u32, bool) callconv(.c) void, "CR_NotifyAppRunning"),
        .notify_stats_stored = optionalSymbol(module, *const fn (u32) callconv(.c) void, "CR_NotifyStatsStored"),
        .notify_stats_stored_from = optionalSymbol(module, *const fn (u32, u32) callconv(.c) void, "CR_NotifyStatsStoredFrom"),
        .get_playtime = optionalSymbol(module, *const fn (u32, *PlaytimeInfo) callconv(.c) bool, "CR_GetPlaytime"),
        .get_achievements = optionalSymbol(module, *const fn (u32, [*]AchievementBlock, u32) callconv(.c) u32, "CR_GetAchievements"),
    };
}

fn requiredSymbol(module: windows.HMODULE, comptime Function: type, name: [:0]const u8) !Function {
    return optionalSymbol(module, Function, name) orelse error.CloudRedirectExportMissing;
}

fn optionalSymbol(module: windows.HMODULE, comptime Function: type, name: [:0]const u8) ?Function {
    const address = kernel32.GetProcAddress(module, name.ptr) orelse return null;
    return @ptrCast(address);
}

fn servePipe() void {
    while (!stopping.load(.acquire)) {
        const pipe = kernel32.CreateNamedPipeW(
            pipe_name_w,
            0x00000003,
            0x00000008,
            1,
            @sizeOf(Response),
            @sizeOf(Request),
            0,
            null,
        );
        if (pipe == windows.INVALID_HANDLE_VALUE) return;
        defer _ = kernel32.CloseHandle(pipe);
        const connected = kernel32.ConnectNamedPipe(pipe, null).toBool() or kernel32.GetLastError() == 535;
        if (!connected) continue;
        if (stopping.load(.acquire)) return;

        var request: Request = undefined;
        var read: u32 = 0;
        var response = Response{ .status = @intFromEnum(Status.invalid_request) };
        if (kernel32.ReadFile(pipe, &request, @sizeOf(Request), &read, null).toBool() and read == @sizeOf(Request))
            response.status = @intFromEnum(handleRequest(request));
        var written: u32 = 0;
        _ = kernel32.WriteFile(pipe, &response, @sizeOf(Response), &written, null);
        _ = kernel32.FlushFileBuffers(pipe);
        _ = kernel32.DisconnectNamedPipe(pipe);
    }
}

fn handleRequest(request: Request) Status {
    if (request.magic != protocol.protocol_magic or request.version != protocol.protocol_version) return .invalid_request;
    const command: Command = switch (request.command) {
        0 => .ping,
        1 => .capture_native_stats,
        else => return .invalid_request,
    };
    if (command == .ping) return if (initialized.load(.acquire)) .ok else .cloud_redirect_unavailable;
    if (request.app_id == 0 or request.bit >= 32) return .invalid_request;
    if (!initialized.load(.acquire)) return .cloud_redirect_unavailable;
    if (!isManagedApp(request.app_id)) return .app_not_managed;
    if (real) |api| if (api.notify_stats_stored) |notify| notify(request.app_id);
    putOverlay(request.app_id, request.stat_id, @intCast(request.bit), request.unlock_time);
    return .ok;
}

fn addManagedApp(app_id: u32) void {
    lockState();
    defer state_mutex.unlock();
    for (managed_apps[0..managed_app_count]) |existing| if (existing == app_id) return;
    if (managed_app_count == managed_apps.len) return;
    managed_apps[managed_app_count] = app_id;
    managed_app_count += 1;
}

fn removeManagedApp(app_id: u32) void {
    lockState();
    defer state_mutex.unlock();
    for (managed_apps[0..managed_app_count], 0..) |existing, index| {
        if (existing != app_id) continue;
        managed_app_count -= 1;
        managed_apps[index] = managed_apps[managed_app_count];
        break;
    }
}

fn isManagedApp(app_id: u32) bool {
    lockState();
    defer state_mutex.unlock();
    for (managed_apps[0..managed_app_count]) |existing| if (existing == app_id) return true;
    return false;
}

fn putOverlay(app_id: u32, stat_id: u32, bit: u5, unlock_time: u32) void {
    lockState();
    defer state_mutex.unlock();
    var target: ?*AchievementBlock = null;
    for (overlays[0..overlay_count]) |*entry| {
        if (entry.app_id == app_id and entry.block.stat_id == stat_id) {
            target = &entry.block;
            break;
        }
    }
    if (target == null) {
        if (overlay_count == overlays.len) return;
        overlays[overlay_count] = .{ .app_id = app_id, .block = std.mem.zeroes(AchievementBlock) };
        overlays[overlay_count].block.stat_id = stat_id;
        target = &overlays[overlay_count].block;
        overlay_count += 1;
    }
    if (target) |block| {
        block.bits |= @as(u32, 1) << bit;
        block.unlock_times[bit] = unlock_time;
    }
}

fn lockState() void {
    while (!state_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn stopPipeServer() void {
    const thread = server_thread orelse return;
    stopping.store(true, .release);
    const wake = kernel32.CreateFileW(pipe_name_w, 0xC0000000, 0, null, 3, 0, null);
    if (wake != windows.INVALID_HANDLE_VALUE) _ = kernel32.CloseHandle(wake);
    thread.join();
    server_thread = null;
}

const kernel32 = struct {
    extern "kernel32" fn LoadLibraryW(path: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn FreeLibrary(module: windows.HMODULE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetProcAddress(module: windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: u32, pipe_mode: u32, max_instances: u32, out_buffer_size: u32, in_buffer_size: u32, timeout: u32, security: ?*anyopaque) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn ConnectNamedPipe(pipe: windows.HANDLE, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn DisconnectNamedPipe(pipe: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, creation: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    extern "kernel32" fn ReadFile(handle: windows.HANDLE, buffer: *anyopaque, count: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn WriteFile(handle: windows.HANDLE, buffer: *const anyopaque, count: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn FlushFileBuffers(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
};
