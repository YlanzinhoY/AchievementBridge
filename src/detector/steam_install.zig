const std = @import("std");
const builtin = @import("builtin");

pub const InstalledApp = struct {
    app_id: u32,
    name: []u8,
    install_dir: []u8,
    library_root: []u8,

    fn deinit(self: *InstalledApp, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.install_dir);
        allocator.free(self.library_root);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    steam_root: []u8,
    apps: std.ArrayList(InstalledApp) = .empty,

    pub fn deinit(self: *Catalog) void {
        for (self.apps.items) |*app| app.deinit(self.allocator);
        self.apps.deinit(self.allocator);
        self.allocator.free(self.steam_root);
        self.* = undefined;
    }

    pub fn findByAppId(self: *const Catalog, app_id: u32) ?*const InstalledApp {
        for (self.apps.items) |*app| if (app.app_id == app_id) return app;
        return null;
    }

    pub fn findByInstallDir(self: *const Catalog, game_dir: []const u8) ?*const InstalledApp {
        for (self.apps.items) |*app| {
            if (std.ascii.eqlIgnoreCase(normalizeEnd(app.install_dir), normalizeEnd(game_dir))) return app;
        }
        return null;
    }
};

pub fn discover(allocator: std.mem.Allocator, io: std.Io, steam_root: []const u8) !Catalog {
    var catalog = Catalog{
        .allocator = allocator,
        .steam_root = try allocator.dupe(u8, steam_root),
    };
    errdefer catalog.deinit();

    var libraries: std.ArrayList([]u8) = .empty;
    defer {
        for (libraries.items) |library| allocator.free(library);
        libraries.deinit(allocator);
    }
    try appendUniquePath(allocator, &libraries, steam_root);

    const library_file = try std.fs.path.join(allocator, &.{ steam_root, "steamapps", "libraryfolders.vdf" });
    defer allocator.free(library_file);
    if (std.Io.Dir.cwd().readFileAlloc(io, library_file, allocator, .limited(4 * 1024 * 1024))) |bytes| {
        defer allocator.free(bytes);
        var values = try extractAllValues(allocator, bytes, "path");
        defer {
            for (values.items) |value| allocator.free(value);
            values.deinit(allocator);
        }
        for (values.items) |value| try appendUniquePath(allocator, &libraries, value);
    } else |_| {}

    for (libraries.items) |library| try scanLibrary(allocator, io, library, &catalog);
    std.mem.sort(InstalledApp, catalog.apps.items, {}, struct {
        fn lessThan(_: void, a: InstalledApp, b: InstalledApp) bool {
            return a.app_id < b.app_id;
        }
    }.lessThan);
    return catalog;
}

fn scanLibrary(allocator: std.mem.Allocator, io: std.Io, library: []const u8, catalog: *Catalog) !void {
    const steamapps_path = try std.fs.path.join(allocator, &.{ library, "steamapps" });
    defer allocator.free(steamapps_path);
    var steamapps = std.Io.Dir.cwd().openDir(io, steamapps_path, .{ .iterate = true }) catch return;
    defer steamapps.close(io);
    var iterator = steamapps.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "appmanifest_") or !std.mem.endsWith(u8, entry.name, ".acf")) continue;
        const manifest_path = try std.fs.path.join(allocator, &.{ steamapps_path, entry.name });
        defer allocator.free(manifest_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(4 * 1024 * 1024)) catch continue;
        defer allocator.free(bytes);

        const appid_text = (try extractValue(allocator, bytes, "appid")) orelse continue;
        defer allocator.free(appid_text);
        const app_id = std.fmt.parseInt(u32, appid_text, 10) catch continue;
        if (catalog.findByAppId(app_id) != null) continue;
        const name = (try extractValue(allocator, bytes, "name")) orelse try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        const install_name = (try extractValue(allocator, bytes, "installdir")) orelse {
            allocator.free(name);
            continue;
        };
        defer allocator.free(install_name);
        const install_dir = try std.fs.path.join(allocator, &.{ library, "steamapps", "common", install_name });
        errdefer allocator.free(install_dir);
        try catalog.apps.append(allocator, .{
            .app_id = app_id,
            .name = name,
            .install_dir = install_dir,
            .library_root = try allocator.dupe(u8, library),
        });
    }
}

pub fn findSteamRoot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (builtin.os.tag == .windows) {
        if (readRegistrySteamPath(allocator)) |path| return path else |_| {}
    }
    const candidates = [_][]const u8{
        "C:\\Program Files (x86)\\Steam",
        "C:\\Program Files\\Steam",
        "C:\\Steam",
    };
    for (candidates) |candidate| {
        const steam_exe = try std.fs.path.join(allocator, &.{ candidate, "steam.exe" });
        defer allocator.free(steam_exe);
        std.Io.Dir.cwd().access(io, steam_exe, .{}) catch continue;
        return allocator.dupe(u8, candidate);
    }
    return error.SteamNotFound;
}

fn readRegistrySteamPath(allocator: std.mem.Allocator) ![]u8 {
    const windows = std.os.windows;
    const advapi32 = struct {
        extern "advapi32" fn RegGetValueW(
            hkey: windows.HKEY,
            sub_key: [*:0]const u16,
            value: [*:0]const u16,
            flags: u32,
            value_type: ?*u32,
            data: ?*anyopaque,
            data_size: *u32,
        ) callconv(.winapi) windows.LSTATUS;
    };
    var buffer: [std.fs.max_path_bytes]u16 = undefined;
    var byte_count: u32 = @intCast(buffer.len * @sizeOf(u16));
    const status = advapi32.RegGetValueW(
        windows.HKEY_CURRENT_USER,
        std.unicode.utf8ToUtf16LeStringLiteral("Software\\Valve\\Steam"),
        std.unicode.utf8ToUtf16LeStringLiteral("SteamPath"),
        0x00000002,
        null,
        &buffer,
        &byte_count,
    );
    if (status != 0) return error.SteamNotFound;
    const units = byte_count / @sizeOf(u16);
    const slice = buffer[0..if (units > 0 and buffer[units - 1] == 0) units - 1 else units];
    return std.unicode.wtf16LeToWtf8Alloc(allocator, slice);
}

const Tokenizer = struct {
    bytes: []const u8,
    index: usize = 0,

    fn nextString(self: *Tokenizer) ?[]const u8 {
        while (self.index < self.bytes.len) : (self.index += 1) {
            if (self.bytes[self.index] == '/') {
                if (self.index + 1 < self.bytes.len and self.bytes[self.index + 1] == '/') {
                    self.index += 2;
                    while (self.index < self.bytes.len and self.bytes[self.index] != '\n') self.index += 1;
                }
                continue;
            }
            if (self.bytes[self.index] != '"') continue;
            const start = self.index + 1;
            self.index = start;
            var escaped = false;
            while (self.index < self.bytes.len) : (self.index += 1) {
                const char = self.bytes[self.index];
                if (!escaped and char == '"') {
                    const value = self.bytes[start..self.index];
                    self.index += 1;
                    return value;
                }
                if (!escaped and char == '\\') {
                    escaped = true;
                } else {
                    escaped = false;
                }
            }
            return null;
        }
        return null;
    }
};

fn extractValue(allocator: std.mem.Allocator, bytes: []const u8, wanted_key: []const u8) !?[]u8 {
    var tokenizer = Tokenizer{ .bytes = bytes };
    while (tokenizer.nextString()) |key| {
        if (std.ascii.eqlIgnoreCase(key, wanted_key)) {
            const value = tokenizer.nextString() orelse return null;
            return try decode(allocator, value);
        }
    }
    return null;
}

fn extractAllValues(allocator: std.mem.Allocator, bytes: []const u8, wanted_key: []const u8) !std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |value| allocator.free(value);
        result.deinit(allocator);
    }
    var tokenizer = Tokenizer{ .bytes = bytes };
    while (tokenizer.nextString()) |key| {
        if (std.ascii.eqlIgnoreCase(key, wanted_key)) {
            const value = tokenizer.nextString() orelse break;
            try result.append(allocator, try decode(allocator, value));
        }
    }
    return result;
}

fn decode(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        if (encoded[index] == '\\' and index + 1 < encoded.len and (encoded[index + 1] == '\\' or encoded[index + 1] == '"')) index += 1;
        try result.append(allocator, encoded[index]);
    }
    return result.toOwnedSlice(allocator);
}

fn appendUniquePath(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8), path: []const u8) !void {
    for (paths.items) |existing| if (std.ascii.eqlIgnoreCase(normalizeEnd(existing), normalizeEnd(path))) return;
    try paths.append(allocator, try allocator.dupe(u8, path));
}

fn normalizeEnd(path: []const u8) []const u8 {
    return std.mem.trimEnd(u8, path, "\\/");
}

test "parse Valve key values and escaped library paths" {
    const source =
        \\"libraryfolders"
        \\{
        \\  "1" { "path" "D:\\SteamLibrary" }
        \\  "2" { "path" "E:\\Games" }
        \\}
    ;
    var values = try extractAllValues(std.testing.allocator, source, "path");
    defer {
        for (values.items) |value| std.testing.allocator.free(value);
        values.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expectEqualStrings("D:\\SteamLibrary", values.items[0]);
    try std.testing.expectEqualStrings("E:\\Games", values.items[1]);
}

test "parse appmanifest fields" {
    const manifest =
        \\"AppState"
        \\{
        \\  "appid" "1145350"
        \\  "name" "Hades II"
        \\  "installdir" "Hades II"
        \\}
    ;
    const appid = (try extractValue(std.testing.allocator, manifest, "appid")).?;
    defer std.testing.allocator.free(appid);
    try std.testing.expectEqualStrings("1145350", appid);
}
