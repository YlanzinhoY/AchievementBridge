const std = @import("std");

pub const Report = struct {
    loader_found: bool,
    config_found: bool,
    schema_found: bool,
    achievements_enabled: bool,

    pub fn ready(self: Report) bool {
        return self.loader_found and self.config_found and self.schema_found and self.achievements_enabled;
    }
};

const loader_names = [_][]const u8{ "upc_r2_loader.dll", "upc_r2_loader64.dll", "uplay_r2_loader.dll", "uplay_r2_loader64.dll" };
const ini_names = [_][]const u8{ "upc_r2.ini", "uplay_r2.ini" };

pub fn diagnose(allocator: std.mem.Allocator, io: std.Io, game_dir: []const u8) !Report {
    var loader_found = false;
    for (loader_names) |name| {
        const path = try std.fs.path.join(allocator, &.{ game_dir, name });
        defer allocator.free(path);
        if (exists(io, path)) loader_found = true;
    }
    var config_path: ?[]u8 = null;
    defer if (config_path) |path| allocator.free(path);
    for (ini_names) |name| {
        const path = try std.fs.path.join(allocator, &.{ game_dir, name });
        if (exists(io, path)) {
            config_path = path;
            break;
        }
        allocator.free(path);
    }
    var achievements_enabled = false;
    if (config_path) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(bytes);
        achievements_enabled = settingEnabled(bytes, "Achievements");
    }
    const schema_path = try std.fs.path.join(allocator, &.{ game_dir, "achievements_schema.json" });
    defer allocator.free(schema_path);
    return .{
        .loader_found = loader_found,
        .config_found = config_path != null,
        .schema_found = exists(io, schema_path),
        .achievements_enabled = achievements_enabled,
    };
}

fn settingEnabled(bytes: []const u8, wanted: []const u8) bool {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        if (!std.ascii.eqlIgnoreCase(key, wanted)) continue;
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");
        return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
    }
    return false;
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "diagnostic parses achievement setting without exposing unrelated settings" {
    try std.testing.expect(settingEnabled("[Settings]\nUsername=x\nAchievements = 1\n", "Achievements"));
    try std.testing.expect(!settingEnabled("Achievements = 0\n", "Achievements"));
}
