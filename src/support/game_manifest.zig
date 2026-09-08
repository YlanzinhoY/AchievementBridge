const std = @import("std");
const discovery = @import("../providers/gse/discovery.zig");

pub const schema_version: u32 = 1;

pub const Capabilities = struct {
    detect: bool,
    monitor: bool,
    map_to_steam: bool,
    sync_to_steam: bool,
    popup: bool,
};

pub const Manifest = struct {
    schema_version: u32 = schema_version,
    steam_app_id: u32,
    game: []const u8,
    game_directory: []const u8,
    provider: []const u8,
    provider_product_id: ?u32 = null,
    source_state: ?[]const u8 = null,
    mapping: []const u8,
    catalog_count: usize,
    prepared_at: i64,
    capabilities: Capabilities,
};

pub const Loaded = struct {
    parsed: std.json.Parsed(Manifest),

    pub fn value(self: *const Loaded) *const Manifest {
        return &self.parsed.value;
    }

    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

pub fn save(allocator: std.mem.Allocator, io: std.Io, root: []const u8, value: Manifest) ![]u8 {
    try validate(value);
    const output_path = try manifestPath(allocator, root, value.steam_app_id);
    errdefer allocator.free(output_path);
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try writeAtomic(io, output_path, bytes);
    return output_path;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, root: []const u8, app_id: u32) !?Loaded {
    const input_path = try manifestPath(allocator, root, app_id);
    defer allocator.free(input_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();
    try validate(parsed.value);
    return .{ .parsed = parsed };
}

pub fn resolveSteamAppId(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    provider: []const u8,
    product_id: u32,
) !?u32 {
    const games_root = try std.fs.path.join(allocator, &.{ root, "games" });
    defer allocator.free(games_root);
    var dir = std.Io.Dir.cwd().openDir(io, games_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const app_id = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        var loaded = (try load(allocator, io, root, app_id)) orelse continue;
        defer loaded.deinit();
        const manifest = loaded.value();
        if (!std.ascii.eqlIgnoreCase(manifest.provider, provider)) continue;
        if (manifest.provider_product_id == product_id) return manifest.steam_app_id;
        const detected = try readUplayProductId(allocator, io, manifest.game_directory);
        if (detected == product_id) return manifest.steam_app_id;
    }
    return null;
}

pub fn readUplayProductId(allocator: std.mem.Allocator, io: std.Io, game_directory: []const u8) !?u32 {
    const names = [_][]const u8{ "upc_r2.log", "uplay_r2.log" };
    for (names) |name| {
        const path = try std.fs.path.join(allocator, &.{ game_directory, name });
        defer allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(bytes);
        if (parseUplayProductId(bytes)) |product_id| return product_id;
    }
    return null;
}

pub fn findSourceState(
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    product_id: u32,
) !?[]u8 {
    var id_buffer: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buffer, "{d}", .{product_id});
    for (roots) |root| {
        const path = try std.fs.path.join(allocator, &.{ root, id, "achievements.json" });
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            allocator.free(path);
            continue;
        };
        return path;
    }
    return null;
}

/// Learns the provider identity created after support preparation. This lets a
/// completed session be correlated even after the game exits. Ambiguous
/// candidates are deliberately rejected instead of guessing.
pub fn findRecentUnclaimedUplayProductId(
    allocator: std.mem.Allocator,
    io: std.Io,
    support_root: []const u8,
    roots: []const []const u8,
    steam_app_id: u32,
    prepared_at: i64,
) !?u32 {
    var candidates = try discovery.discover(allocator, io, roots);
    defer candidates.deinit();
    const prepared_ns = @as(i128, prepared_at) * std.time.ns_per_s;
    var selected: ?u32 = null;
    for (candidates.items.items) |candidate| {
        const stat = std.Io.Dir.cwd().statFile(io, candidate.state_file, .{}) catch continue;
        if (@as(i128, stat.mtime.nanoseconds) < prepared_ns) continue;
        const owner = try resolveSteamAppId(allocator, io, support_root, "uplay_r2", candidate.app_id);
        if (owner != null and owner.? != steam_app_id) continue;
        if (selected) |existing| {
            if (existing != candidate.app_id) return null;
        } else {
            selected = candidate.app_id;
        }
    }
    return selected;
}

pub fn manifestPath(allocator: std.mem.Allocator, root: []const u8, app_id: u32) ![]u8 {
    const id = try std.fmt.allocPrint(allocator, "{d}", .{app_id});
    defer allocator.free(id);
    return std.fs.path.join(allocator, &.{ root, "games", id, "support.json" });
}

pub fn parseUplayProductId(bytes: []const u8) ?u32 {
    const marker = "appid (";
    var offset: usize = 0;
    var result: ?u32 = null;
    while (std.mem.indexOfPos(u8, bytes, offset, marker)) |found| {
        const start = found + marker.len;
        const end = std.mem.indexOfScalarPos(u8, bytes, start, ')') orelse break;
        result = std.fmt.parseInt(u32, bytes[start..end], 10) catch result;
        offset = end + 1;
    }
    return result;
}

fn validate(value: Manifest) !void {
    if (value.schema_version != schema_version) return error.UnsupportedSupportManifestVersion;
    if (value.steam_app_id == 0 or value.catalog_count == 0 or value.prepared_at <= 0) return error.InvalidSupportManifest;
    if (value.game.len == 0 or value.game_directory.len == 0 or value.provider.len == 0 or value.mapping.len == 0)
        return error.InvalidSupportManifest;
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.replace(io);
}

test "Uplay product id is learned from the latest init line" {
    const log =
        "[10:00:00][INFO] UPC_Init -> inVersion (1), appid (66088)\n" ++
        "[10:01:00][INFO] UPC_Init -> inVersion (1), appid (77777)\n";
    try std.testing.expectEqual(@as(?u32, 77777), parseUplayProductId(log));
}

test "support manifest round trips" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "support" });
    defer allocator.free(root);
    const output_path = try save(allocator, std.testing.io, root, .{
        .steam_app_id = 2842040,
        .game = "Example",
        .game_directory = "C:\\Games\\Example",
        .provider = "uplay_r2",
        .provider_product_id = null,
        .mapping = "numeric_suffix",
        .catalog_count = 59,
        .prepared_at = 1,
        .capabilities = .{ .detect = true, .monitor = true, .map_to_steam = true, .sync_to_steam = false, .popup = true },
    });
    defer allocator.free(output_path);
    var loaded = (try load(allocator, std.testing.io, root, 2842040)).?;
    defer loaded.deinit();
    try std.testing.expectEqualStrings("uplay_r2", loaded.value().provider);
    try std.testing.expectEqual(@as(usize, 59), loaded.value().catalog_count);
}

test "recent Uplay state is associated without stealing another manifest" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer allocator.free(root);
    const support_root = try std.fs.path.join(allocator, &.{ root, "support" });
    defer allocator.free(support_root);
    const saves_root = try std.fs.path.join(allocator, &.{ root, "saves" });
    defer allocator.free(saves_root);
    for ([_][]const u8{ "66088", "64181" }) |product_id| {
        const directory = try std.fs.path.join(allocator, &.{ saves_root, product_id });
        defer allocator.free(directory);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, directory);
        const state_path = try std.fs.path.join(allocator, &.{ directory, "achievements.json" });
        defer allocator.free(state_path);
        var state_file = try std.Io.Dir.cwd().createFile(std.testing.io, state_path, .{});
        try state_file.writePositionalAll(std.testing.io, "{}", 0);
        state_file.close(std.testing.io);
    }
    const owner_path = try save(allocator, std.testing.io, support_root, .{
        .steam_app_id = 3751950,
        .game = "Black Flag",
        .game_directory = root,
        .provider = "uplay_r2",
        .provider_product_id = 66088,
        .mapping = "numeric_suffix",
        .catalog_count = 49,
        .prepared_at = 1,
        .capabilities = .{ .detect = true, .monitor = true, .map_to_steam = true, .sync_to_steam = true, .popup = true },
    });
    defer allocator.free(owner_path);
    const detected = try findRecentUnclaimedUplayProductId(
        allocator,
        std.testing.io,
        support_root,
        &.{saves_root},
        2842040,
        1,
    );
    try std.testing.expectEqual(@as(?u32, 64181), detected);
}
