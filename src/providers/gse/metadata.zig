const std = @import("std");
const metadata = @import("../../core/metadata.zig");

pub fn loadFile(catalog: *metadata.Catalog, io: std.Io, path: []const u8, language: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, catalog.allocator, .limited(32 * 1024 * 1024));
    defer catalog.allocator.free(bytes);
    try parseInto(catalog, bytes, language);
}

pub fn parseInto(catalog: *metadata.Catalog, bytes: []const u8, language: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, catalog.allocator, bytes, .{});
    defer parsed.deinit();
    const entries = switch (parsed.value) {
        .array => |array| array,
        else => return error.InvalidAchievementSchema,
    };
    for (entries.items) |entry| {
        const object = switch (entry) {
            .object => |object| object,
            else => continue,
        };
        const api_name = stringValue(object.get("name"), language) orelse continue;
        const display_name = stringValue(object.get("displayName"), language) orelse api_name;
        const description = stringValue(object.get("description"), language) orelse "";
        const icon = stringValue(object.get("icon"), language) orelse "";
        const hidden = if (object.get("hidden")) |value| truthy(value) else false;
        const owned_api_name = try catalog.allocator.dupe(u8, api_name);
        errdefer catalog.allocator.free(owned_api_name);
        try catalog.put(.{
            .api_name = owned_api_name,
            .name = try catalog.allocator.dupe(u8, display_name),
            .description = try catalog.allocator.dupe(u8, description),
            .icon = try catalog.allocator.dupe(u8, icon),
            .hidden = hidden,
        });
    }
}

fn stringValue(value: ?std.json.Value, language: []const u8) ?[]const u8 {
    const item = value orelse return null;
    return switch (item) {
        .string => |string| string,
        .object => |object| if (object.get(language)) |localized| switch (localized) {
            .string => |string| string,
            else => null,
        } else if (object.get("english")) |english| switch (english) {
            .string => |string| string,
            else => null,
        } else null,
        else => null,
    };
}

fn truthy(value: std.json.Value) bool {
    return switch (value) {
        .bool => |item| item,
        .integer => |item| item != 0,
        .string => |item| std.mem.eql(u8, item, "1") or std.ascii.eqlIgnoreCase(item, "true"),
        else => false,
    };
}

test "parse GSE schema metadata with localization" {
    var catalog = metadata.Catalog.init(std.testing.allocator);
    defer catalog.deinit();
    try parseInto(&catalog,
        \\[
        \\  {
        \\    "name": "ACH_BOSS",
        \\    "displayName": {"english":"Boss Down","brazilian":"Chefe derrotado"},
        \\    "description": "Win the fight",
        \\    "icon": "images/boss.png",
        \\    "hidden": "1"
        \\  }
        \\]
    , "brazilian");
    const achievement = catalog.get("ACH_BOSS").?;
    try std.testing.expectEqualStrings("Chefe derrotado", achievement.name);
    try std.testing.expect(achievement.hidden);
}
