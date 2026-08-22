const std = @import("std");
const manifest = @import("manifest.zig");

const ActiveVersion = struct {
    current: []const u8,
    previous: ?[]const u8 = null,
};

pub fn installVerified(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_root: []const u8,
    release: manifest.ProviderRelease,
    bytes: []const u8,
) ![]u8 {
    try manifest.verifyArtifact(release, bytes);
    if (!safePathSegment(release.id) or !safePathSegment(release.version)) return error.InvalidCachePath;
    const provider_path = try providerPath(allocator, cache_root, release.id, release.version);
    errdefer allocator.free(provider_path);
    try writeAtomic(io, provider_path, bytes);
    try activate(allocator, io, cache_root, release.id, release.version);
    return provider_path;
}

pub fn rollback(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_root: []const u8,
    provider_id: []const u8,
) ![]u8 {
    if (!safePathSegment(provider_id)) return error.InvalidCachePath;
    const state_path = try activePath(allocator, cache_root, provider_id);
    defer allocator.free(state_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, state_path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(ActiveVersion, allocator, bytes, .{});
    defer parsed.deinit();
    const previous = parsed.value.previous orelse return error.NoRollbackVersion;
    if (!safePathSegment(previous)) return error.InvalidCachePath;
    const previous_path = try providerPath(allocator, cache_root, provider_id, previous);
    errdefer allocator.free(previous_path);
    std.Io.Dir.cwd().access(io, previous_path, .{}) catch return error.RollbackArtifactMissing;
    const next_state = ActiveVersion{ .current = previous, .previous = parsed.value.current };
    const next_json = try std.json.Stringify.valueAlloc(allocator, next_state, .{});
    defer allocator.free(next_json);
    try writeAtomic(io, state_path, next_json);
    return previous_path;
}

fn activate(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_root: []const u8,
    provider_id: []const u8,
    version: []const u8,
) !void {
    const state_path = try activePath(allocator, cache_root, provider_id);
    defer allocator.free(state_path);
    var previous_version: ?[]u8 = null;
    defer if (previous_version) |value| allocator.free(value);
    if (std.Io.Dir.cwd().readFileAlloc(io, state_path, allocator, .limited(64 * 1024))) |bytes| {
        defer allocator.free(bytes);
        var parsed = std.json.parseFromSlice(ActiveVersion, allocator, bytes, .{}) catch null;
        if (parsed) |*state| {
            defer state.deinit();
            if (!std.mem.eql(u8, state.value.current, version)) previous_version = try allocator.dupe(u8, state.value.current);
        }
    } else |_| {}
    const state = ActiveVersion{ .current = version, .previous = previous_version };
    const json = try std.json.Stringify.valueAlloc(allocator, state, .{});
    defer allocator.free(json);
    try writeAtomic(io, state_path, json);
}

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writePositionalAll(io, bytes, 0);
    try atomic.replace(io);
}

fn providerPath(allocator: std.mem.Allocator, root: []const u8, id: []const u8, version: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "providers", id, version, "provider.dll" });
}

fn activePath(allocator: std.mem.Allocator, root: []const u8, id: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "providers", id, "active.json" });
}

fn safePathSegment(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-' and character != '.' and character != '+') return false;
    return !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

test "verified cache installs atomically and rolls back" {
    const Ed25519 = std.crypto.sign.Ed25519;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache_root = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "registry" });
    defer allocator.free(cache_root);
    const publisher = try Ed25519.KeyPair.generateDeterministic([_]u8{0x33} ** Ed25519.KeyPair.seed_length);
    const public_hex = std.fmt.bytesToHex(publisher.public_key.toBytes(), .lower);

    const first = "first provider";
    var first_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(first, &first_digest, .{});
    const first_digest_hex = std.fmt.bytesToHex(first_digest, .lower);
    const first_sig = try publisher.sign(first, null);
    const first_sig_hex = std.fmt.bytesToHex(first_sig.toBytes(), .lower);
    const first_release = manifest.ProviderRelease{
        .id = "gse",
        .version = "1.0.0",
        .os = "windows",
        .arch = "x86_64",
        .url = "https://example.invalid/1",
        .sha256 = &first_digest_hex,
        .publisher_public_key = &public_hex,
        .signature = &first_sig_hex,
        .trust = .official,
    };
    const first_path = try installVerified(allocator, std.testing.io, cache_root, first_release, first);
    defer allocator.free(first_path);

    const second = "second provider";
    var second_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(second, &second_digest, .{});
    const second_digest_hex = std.fmt.bytesToHex(second_digest, .lower);
    const second_sig = try publisher.sign(second, null);
    const second_sig_hex = std.fmt.bytesToHex(second_sig.toBytes(), .lower);
    var second_release = first_release;
    second_release.version = "2.0.0";
    second_release.sha256 = &second_digest_hex;
    second_release.signature = &second_sig_hex;
    const second_path = try installVerified(allocator, std.testing.io, cache_root, second_release, second);
    defer allocator.free(second_path);

    const restored_path = try rollback(allocator, std.testing.io, cache_root, "gse");
    defer allocator.free(restored_path);
    try std.testing.expectEqualStrings(first_path, restored_path);
    const restored = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, restored_path, allocator, .limited(1024));
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(first, restored);
}
