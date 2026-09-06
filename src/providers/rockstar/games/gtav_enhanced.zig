const std = @import("std");
const builtin = @import("builtin");
const process_detector = @import("../../../detector/process.zig");

pub const app_id: u32 = 3_240_220;
pub const executable_name = "GTA5_Enhanced.exe";
pub const maximum_internal_id: usize = 77;
const maximum_list_entries: usize = maximum_internal_id + 1;
pub const UnlockSet = std.StaticBitSet(maximum_internal_id + 1);

const achievement_state_count_offset: usize = 0x605c;
const achievement_state_ids_offset: usize = 0x5f1c;
const scan_chunk_size: usize = 64 * 1024;
const scan_overlap: usize = 32;

// This is the stable beginning of the native wrapper that calls the game's
// achievement-state lookup. The RIP-relative operand immediately after this
// prefix points to the live Social Club achievement state. It is resolved at
// runtime so game updates may relocate the code without breaking the adapter.
const state_wrapper_prefix = [_]u8{
    0x56,
    0x48,
    0x83,
    0xec,
    0x20,
    0x48,
    0x89,
    0xce,
    0x48,
    0x8b,
    0x41,
    0x10,
    0x8b,
    0x10,
    0x48,
    0x8d,
    0x0d,
};
const state_displacement_offset = state_wrapper_prefix.len;
const state_next_instruction_offset = state_displacement_offset + @sizeOf(i32);
const state_wrapper_jump_offset = state_next_instruction_offset;
const state_wrapper_size = state_wrapper_jump_offset + 5;

// HAS_ACHIEVEMENT_BEEN_PASSED begins by reading the count at +0x605c and
// comparing the requested ID with the first entry at +0x5f1c. Other Rockstar
// systems use similar containers, so this second signature identifies the
// achievement query itself and prevents selecting one of those unrelated lists.
const query_prefix = [_]u8{ 0x44, 0x8b, 0x81, 0x5c, 0x60, 0x00, 0x00, 0x45, 0x85, 0xc0 };
const query_suffix_offset: usize = 12;
const query_suffix = [_]u8{ 0xb0, 0x01, 0x39, 0x91, 0x1c, 0x5f, 0x00, 0x00 };
const query_signature_size = query_suffix_offset + query_suffix.len;

pub const Sample = struct {
    pid: u32,
    just_attached: bool,
    unlocked: UnlockSet,
};

pub const Monitor = struct {
    allocator: std.mem.Allocator,
    attachment: ?Attachment = null,

    pub fn init(allocator: std.mem.Allocator) Monitor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Monitor) void {
        self.detach();
        self.* = undefined;
    }

    pub fn sample(self: *Monitor) !?Sample {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

        if (self.attachment) |*attachment| {
            if (attachment.isAlive()) {
                return .{
                    .pid = attachment.pid,
                    .just_attached = false,
                    .unlocked = try attachment.readUnlocked(),
                };
            }
            self.detach();
        }

        const pid = try findProcess(self.allocator) orelse return null;
        self.attachment = try Attachment.open(pid);
        errdefer self.detach();
        return .{
            .pid = pid,
            .just_attached = true,
            .unlocked = try self.attachment.?.readUnlocked(),
        };
    }

    fn detach(self: *Monitor) void {
        if (self.attachment) |*attachment| attachment.close();
        self.attachment = null;
    }
};

const Attachment = struct {
    pid: u32,
    handle: std.os.windows.HANDLE,
    state_address: usize,

    fn open(pid: u32) !Attachment {
        const handle = api.OpenProcess(
            process_query_information | process_vm_read,
            .FALSE,
            pid,
        ) orelse return error.ProcessAccessDenied;
        errdefer std.os.windows.CloseHandle(handle);

        const module = try findMainModule(pid);
        const state_address = try findAchievementState(handle, module.base_address, module.image_size);
        return .{
            .pid = pid,
            .handle = handle,
            .state_address = state_address,
        };
    }

    fn close(self: *Attachment) void {
        std.os.windows.CloseHandle(self.handle);
        self.* = undefined;
    }

    fn isAlive(self: *const Attachment) bool {
        var exit_code: std.os.windows.DWORD = 0;
        if (!api.GetExitCodeProcess(self.handle, &exit_code).toBool()) return false;
        return exit_code == still_active;
    }

    fn readUnlocked(self: *const Attachment) !UnlockSet {
        return readAchievementSet(self.handle, self.state_address);
    }
};

const MainModule = struct {
    base_address: usize,
    image_size: usize,
};

const api = struct {
    const ModuleEntry32W = extern struct {
        size: std.os.windows.DWORD,
        module_id: std.os.windows.DWORD,
        process_id: std.os.windows.DWORD,
        global_usage: std.os.windows.DWORD,
        process_usage: std.os.windows.DWORD,
        base_address: ?*u8,
        image_size: std.os.windows.DWORD,
        module_handle: std.os.windows.HMODULE,
        module_name: [256]std.os.windows.WCHAR,
        executable_path: [std.os.windows.MAX_PATH]std.os.windows.WCHAR,
    };

    extern "kernel32" fn CreateToolhelp32Snapshot(flags: std.os.windows.DWORD, process_id: std.os.windows.DWORD) callconv(.winapi) std.os.windows.HANDLE;
    extern "kernel32" fn Module32FirstW(snapshot: std.os.windows.HANDLE, entry: *ModuleEntry32W) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn Module32NextW(snapshot: std.os.windows.HANDLE, entry: *ModuleEntry32W) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn OpenProcess(access: std.os.windows.DWORD, inherit: std.os.windows.BOOL, process_id: std.os.windows.DWORD) callconv(.winapi) ?std.os.windows.HANDLE;
    extern "kernel32" fn ReadProcessMemory(process: std.os.windows.HANDLE, address: ?*const anyopaque, buffer: ?*anyopaque, size: usize, bytes_read: *usize) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn GetExitCodeProcess(process: std.os.windows.HANDLE, exit_code: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
};

const process_query_information: std.os.windows.DWORD = 0x0400;
const process_vm_read: std.os.windows.DWORD = 0x0010;
const snapshot_modules: std.os.windows.DWORD = 0x00000008;
const snapshot_modules_32: std.os.windows.DWORD = 0x00000010;
const still_active: std.os.windows.DWORD = 259;

fn findProcess(allocator: std.mem.Allocator) !?u32 {
    var processes = try process_detector.enumerate(allocator);
    defer processes.deinit();
    for (processes.items.items) |process| {
        if (std.ascii.eqlIgnoreCase(process.name, executable_name)) return process.pid;
    }
    return null;
}

fn findMainModule(pid: u32) !MainModule {
    const snapshot_handle = api.CreateToolhelp32Snapshot(snapshot_modules | snapshot_modules_32, pid);
    if (snapshot_handle == std.os.windows.INVALID_HANDLE_VALUE) return error.ModuleSnapshotFailed;
    defer std.os.windows.CloseHandle(snapshot_handle);

    var entry: api.ModuleEntry32W = undefined;
    entry.size = @sizeOf(api.ModuleEntry32W);
    if (!api.Module32FirstW(snapshot_handle, &entry).toBool()) return error.MainModuleUnavailable;
    while (true) {
        const name_length = std.mem.indexOfScalar(u16, &entry.module_name, 0) orelse entry.module_name.len;
        var name_buffer: [std.os.windows.MAX_PATH]u8 = undefined;
        const written = std.unicode.wtf16LeToWtf8(&name_buffer, entry.module_name[0..name_length]);
        const name = name_buffer[0..written];
        if (std.ascii.eqlIgnoreCase(name, executable_name)) {
            return .{
                .base_address = @intFromPtr(entry.base_address orelse return error.MainModuleUnavailable),
                .image_size = entry.image_size,
            };
        }
        if (!api.Module32NextW(snapshot_handle, &entry).toBool()) break;
    }
    return error.MainModuleUnavailable;
}

fn findAchievementState(handle: std.os.windows.HANDLE, module_base: usize, module_size: usize) !usize {
    const query_address = try findAchievementQuery(handle, module_base, module_size);
    var buffer: [scan_chunk_size + scan_overlap]u8 = undefined;
    var offset: usize = 0;
    var found: ?usize = null;

    while (offset < module_size) : (offset += scan_chunk_size) {
        const remaining = module_size - offset;
        const amount = @min(buffer.len, remaining);
        readExact(handle, module_base + offset, buffer[0..amount]) catch continue;
        const chunk = buffer[0..amount];
        var cursor: usize = 0;
        while (cursor + state_wrapper_size <= chunk.len) : (cursor += 1) {
            if (!std.mem.eql(u8, chunk[cursor .. cursor + state_wrapper_prefix.len], &state_wrapper_prefix)) continue;
            if (chunk[cursor + state_wrapper_jump_offset] != 0xe9) continue;

            const wrapper_address = module_base + offset + cursor;
            const handler_address = decodeRelativeTarget(
                wrapper_address + state_wrapper_jump_offset,
                chunk[cursor + state_wrapper_jump_offset .. cursor + state_wrapper_size],
                0xe9,
            ) catch continue;
            if (!handlerCallsQuery(handle, handler_address, query_address)) continue;
            const state_address = decodeStateAddress(wrapper_address, chunk[cursor..]) catch continue;
            _ = readAchievementSet(handle, state_address) catch continue;
            if (found != null and found.? != state_address) return error.AmbiguousAchievementState;
            found = state_address;
        }
    }
    return found orelse error.AchievementStateSignatureNotFound;
}

fn findAchievementQuery(handle: std.os.windows.HANDLE, module_base: usize, module_size: usize) !usize {
    var buffer: [scan_chunk_size + scan_overlap]u8 = undefined;
    var offset: usize = 0;
    var found: ?usize = null;
    while (offset < module_size) : (offset += scan_chunk_size) {
        const amount = @min(buffer.len, module_size - offset);
        readExact(handle, module_base + offset, buffer[0..amount]) catch continue;
        const chunk = buffer[0..amount];
        var cursor: usize = 0;
        while (cursor + query_signature_size <= chunk.len) : (cursor += 1) {
            if (!std.mem.eql(u8, chunk[cursor .. cursor + query_prefix.len], &query_prefix)) continue;
            if (!std.mem.eql(
                u8,
                chunk[cursor + query_suffix_offset .. cursor + query_signature_size],
                &query_suffix,
            )) continue;
            const address = module_base + offset + cursor;
            if (found != null and found.? != address) return error.AmbiguousAchievementQuery;
            found = address;
        }
    }
    return found orelse error.AchievementQuerySignatureNotFound;
}

fn handlerCallsQuery(handle: std.os.windows.HANDLE, handler_address: usize, query_address: usize) bool {
    var code: [96]u8 = undefined;
    readExact(handle, handler_address, &code) catch return false;
    var offset: usize = 0;
    while (offset + 5 <= code.len) : (offset += 1) {
        if (code[offset] != 0xe8) continue;
        const target = decodeRelativeTarget(handler_address + offset, code[offset .. offset + 5], 0xe8) catch continue;
        if (target == query_address) return true;
    }
    return false;
}

fn decodeStateAddress(wrapper_address: usize, wrapper: []const u8) !usize {
    if (wrapper.len <= state_wrapper_jump_offset) return error.InvalidAchievementStateSignature;
    if (!std.mem.eql(u8, wrapper[0..state_wrapper_prefix.len], &state_wrapper_prefix)) return error.InvalidAchievementStateSignature;
    if (wrapper[state_wrapper_jump_offset] != 0xe9) return error.InvalidAchievementStateSignature;
    const displacement = std.mem.readInt(i32, wrapper[state_displacement_offset..state_next_instruction_offset], .little);
    const target = @as(i128, @intCast(wrapper_address + state_next_instruction_offset)) + displacement;
    if (target <= 0 or target > std.math.maxInt(usize)) return error.InvalidAchievementStateAddress;
    return @intCast(target);
}

fn decodeRelativeTarget(instruction_address: usize, instruction: []const u8, opcode: u8) !usize {
    if (instruction.len < 5 or instruction[0] != opcode) return error.InvalidRelativeInstruction;
    var displacement_bytes: [4]u8 = undefined;
    @memcpy(&displacement_bytes, instruction[1..5]);
    const displacement = std.mem.readInt(i32, &displacement_bytes, .little);
    const target = @as(i128, @intCast(instruction_address + 5)) + displacement;
    if (target <= 0 or target > std.math.maxInt(usize)) return error.InvalidRelativeTarget;
    return @intCast(target);
}

fn readAchievementSet(handle: std.os.windows.HANDLE, state_address: usize) !UnlockSet {
    var count_bytes: [4]u8 = undefined;
    try readExact(handle, state_address + achievement_state_count_offset, &count_bytes);
    const count = std.mem.readInt(u32, &count_bytes, .little);
    if (count > maximum_list_entries) return error.InvalidAchievementCount;

    var result = UnlockSet.initEmpty();
    if (count == 0) return result;
    var id_bytes: [maximum_list_entries * @sizeOf(u32)]u8 = undefined;
    const used = id_bytes[0 .. @as(usize, count) * @sizeOf(u32)];
    try readExact(handle, state_address + achievement_state_ids_offset, used);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const start = index * @sizeOf(u32);
        var current_id_bytes: [@sizeOf(u32)]u8 = undefined;
        @memcpy(&current_id_bytes, used[start .. start + @sizeOf(u32)]);
        const internal_id = std.mem.readInt(u32, &current_id_bytes, .little);
        if (internal_id > maximum_internal_id) return error.InvalidAchievementId;
        if (result.isSet(internal_id)) return error.DuplicateAchievementId;
        result.set(internal_id);
    }
    return result;
}

fn readExact(handle: std.os.windows.HANDLE, address: usize, destination: []u8) !void {
    var bytes_read: usize = 0;
    if (!api.ReadProcessMemory(
        handle,
        @ptrFromInt(address),
        destination.ptr,
        destination.len,
        &bytes_read,
    ).toBool() or bytes_read != destination.len) return error.ProcessMemoryReadFailed;
}

// Social Club reserves ID 0 for the console platinum trophy. The Enhanced PC
// build exposes IDs 1-77, which map to these Steamworks API names.
pub fn steamAchievement(internal_id: usize) ?[]const u8 {
    return switch (internal_id) {
        1 => "ACH00",
        2 => "ACH01",
        3 => "ACH02",
        4 => "ACH03",
        5 => "ACH04",
        6 => "ACH05",
        7 => "ACH06",
        8 => "ACH42",
        9 => "ACH07",
        10 => "ACH08",
        11 => "ACH09",
        12 => "ACH10",
        13 => "ACH11",
        14 => "ACH50",
        15 => "ACH12",
        16 => "ACH13",
        17 => "ACH14",
        18 => "ACH15",
        19 => "ACH16",
        20 => "ACH17",
        21 => "ACH18",
        22 => "ACH19",
        23 => "ACH20",
        24 => "ACH21",
        25 => "ACH22",
        26 => "ACH23",
        27 => "ACH24",
        28 => "ACH25",
        29 => "ACH26",
        30 => "ACH27",
        31 => "ACH28",
        32 => "ACH29",
        33 => "ACH30",
        34 => "ACH31",
        35 => "ACH32",
        36 => "ACH33",
        37 => "ACH34",
        38 => "ACH35",
        39 => "ACH36",
        40 => "ACH38",
        41 => "ACH39",
        42 => "ACH40",
        43 => "ACH41",
        44 => "ACH43",
        45 => "ACH45",
        46 => "ACH46",
        47 => "ACH47",
        48 => "ACH48",
        49 => "ACH49",
        50 => "ACH51",
        51 => "ACHH1",
        52 => "ACHH2",
        53 => "ACHH3",
        54 => "ACHH4",
        55 => "ACHH5",
        56 => "ACHH6",
        57 => "ACHH7",
        58 => "ACHH8",
        59 => "ACHH10",
        60 => "ACHH11",
        61 => "ACHR2",
        62 => "ACHR3",
        63 => "ACHR4",
        64 => "ACHR5",
        65 => "ACHR6",
        66 => "ACHR7",
        67 => "ACHR8",
        68 => "ACHR9",
        69 => "ACHR10",
        70 => "ACHGO1",
        71 => "ACHGO2",
        72 => "ACHGO3",
        73 => "ACHGO4",
        74 => "ACHGO5",
        75 => "ACHGO6",
        76 => "ACHGO7",
        77 => "ACHGO8",
        else => null,
    };
}

pub fn internalAchievement(api_name: []const u8) ?usize {
    for (1..maximum_internal_id + 1) |internal_id| {
        const candidate = steamAchievement(internal_id) orelse continue;
        if (std.ascii.eqlIgnoreCase(candidate, api_name)) return internal_id;
    }
    return null;
}

test "GTA V Enhanced maps every Social Club PC achievement" {
    var names = std.StringHashMap(void).init(std.testing.allocator);
    defer names.deinit();
    for (1..maximum_internal_id + 1) |internal_id| {
        const api_name = steamAchievement(internal_id) orelse return error.MissingAchievementMapping;
        try std.testing.expect(!names.contains(api_name));
        try names.put(api_name, {});
        try std.testing.expectEqual(internal_id, internalAchievement(api_name).?);
    }
    try std.testing.expectEqual(maximum_internal_id, names.count());
    try std.testing.expectEqualStrings("ACH00", steamAchievement(1).?);
    try std.testing.expectEqualStrings("ACH26", steamAchievement(29).?);
    try std.testing.expect(steamAchievement(0) == null);
}

test "GTA V Enhanced resolves its RIP-relative state pointer" {
    var wrapper = [_]u8{0} ** 22;
    @memcpy(wrapper[0..state_wrapper_prefix.len], &state_wrapper_prefix);
    std.mem.writeInt(i32, wrapper[state_displacement_offset..state_next_instruction_offset], -0x1000, .little);
    wrapper[state_wrapper_jump_offset] = 0xe9;
    try std.testing.expectEqual(@as(usize, 0x400000 + state_next_instruction_offset - 0x1000), try decodeStateAddress(0x400000, &wrapper));
}
