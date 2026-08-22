const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Trust = enum {
    official,
    verified_community,
    unverified,
};

pub const ProviderRelease = struct {
    id: []const u8,
    version: []const u8,
    os: []const u8,
    arch: []const u8,
    url: []const u8,
    sha256: []const u8,
    publisher_public_key: []const u8,
    signature: []const u8,
    trust: Trust,
};

pub const Manifest = struct {
    schema_version: u32,
    generated_at: i64,
    providers: []const ProviderRelease,
};

const Envelope = struct {
    payload: []const u8,
    signature: []const u8,
};

pub const VerifiedManifest = struct {
    parsed: std.json.Parsed(Manifest),

    pub fn value(self: *const VerifiedManifest) *const Manifest {
        return &self.parsed.value;
    }

    pub fn deinit(self: *VerifiedManifest) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

/// Verify the registry envelope before parsing or trusting any provider metadata. The signature is
/// over the exact UTF-8 payload bytes, avoiding ambiguous JSON canonicalization rules.
pub fn verifySignedManifest(
    allocator: std.mem.Allocator,
    envelope_bytes: []const u8,
    root_public_key_bytes: [Ed25519.PublicKey.encoded_length]u8,
) !VerifiedManifest {
    var envelope = try std.json.parseFromSlice(Envelope, allocator, envelope_bytes, .{});
    defer envelope.deinit();
    const signature = try decodeSignature(envelope.value.signature);
    const public_key = try Ed25519.PublicKey.fromBytes(root_public_key_bytes);
    try signature.verifyStrict(envelope.value.payload, public_key);

    var parsed = try std.json.parseFromSlice(Manifest, allocator, envelope.value.payload, .{
        .ignore_unknown_fields = false,
    });
    errdefer parsed.deinit();
    try validateManifest(&parsed.value);
    return .{ .parsed = parsed };
}

pub fn verifyArtifact(release: ProviderRelease, bytes: []const u8) !void {
    var expected_digest: [Sha256.digest_length]u8 = undefined;
    if (release.sha256.len != expected_digest.len * 2) return error.InvalidSha256;
    _ = std.fmt.hexToBytes(&expected_digest, release.sha256) catch return error.InvalidSha256;
    var actual_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &actual_digest, .{});
    if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, expected_digest, actual_digest)) return error.HashMismatch;

    var publisher_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    if (release.publisher_public_key.len != publisher_bytes.len * 2) return error.InvalidPublicKey;
    _ = std.fmt.hexToBytes(&publisher_bytes, release.publisher_public_key) catch return error.InvalidPublicKey;
    const publisher = Ed25519.PublicKey.fromBytes(publisher_bytes) catch return error.InvalidPublicKey;
    const signature = try decodeSignature(release.signature);
    signature.verifyStrict(bytes, publisher) catch return error.ArtifactSignatureInvalid;
}

pub fn mayAutoInstall(trust: Trust, verified_community_enabled: bool) bool {
    return switch (trust) {
        .official => true,
        .verified_community => verified_community_enabled,
        .unverified => false,
    };
}

fn validateManifest(manifest: *const Manifest) !void {
    if (manifest.schema_version != 1) return error.UnsupportedManifestVersion;
    if (manifest.generated_at <= 0) return error.InvalidGeneratedAt;
    for (manifest.providers) |release| {
        if (!safeIdentifier(release.id) or !safeVersion(release.version)) return error.InvalidProviderIdentity;
        if (!std.mem.eql(u8, release.os, "windows")) return error.UnsupportedProviderOs;
        if (!std.mem.eql(u8, release.arch, "x86_64")) return error.UnsupportedProviderArchitecture;
        if (!std.mem.startsWith(u8, release.url, "https://")) return error.InsecureProviderUrl;
        if (release.sha256.len != Sha256.digest_length * 2) return error.InvalidSha256;
        if (release.publisher_public_key.len != Ed25519.PublicKey.encoded_length * 2) return error.InvalidPublicKey;
        if (release.signature.len != Ed25519.Signature.encoded_length * 2) return error.InvalidSignature;
    }
}

fn decodeSignature(hex: []const u8) !Ed25519.Signature {
    var bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    if (hex.len != bytes.len * 2) return error.InvalidSignature;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidSignature;
    return Ed25519.Signature.fromBytes(bytes);
}

fn safeIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') return false;
    return true;
}

fn safeVersion(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |character| if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '-' and character != '+') return false;
    return true;
}

test "signed registry verifies manifest and provider artifact" {
    const allocator = std.testing.allocator;
    const root_key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x42} ** Ed25519.KeyPair.seed_length);
    const publisher_key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x24} ** Ed25519.KeyPair.seed_length);
    const artifact = "provider binary";
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(artifact, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const publisher_hex = std.fmt.bytesToHex(publisher_key_pair.public_key.toBytes(), .lower);
    const artifact_signature = try publisher_key_pair.sign(artifact, null);
    const artifact_signature_hex = std.fmt.bytesToHex(artifact_signature.toBytes(), .lower);
    const payload = try std.fmt.allocPrint(allocator,
        \\{{"schema_version":1,"generated_at":1700000000,"providers":[{{"id":"gse","version":"1.0.0","os":"windows","arch":"x86_64","url":"https://example.invalid/gse.dll","sha256":"{s}","publisher_public_key":"{s}","signature":"{s}","trust":"official"}}]}}
    , .{ &digest_hex, &publisher_hex, &artifact_signature_hex });
    defer allocator.free(payload);
    const root_signature = try root_key_pair.sign(payload, null);
    const root_signature_hex = std.fmt.bytesToHex(root_signature.toBytes(), .lower);
    const envelope = try std.json.Stringify.valueAlloc(allocator, .{ .payload = payload, .signature = &root_signature_hex }, .{});
    defer allocator.free(envelope);

    var verified = try verifySignedManifest(allocator, envelope, root_key_pair.public_key.toBytes());
    defer verified.deinit();
    try std.testing.expectEqual(@as(usize, 1), verified.value().providers.len);
    try verifyArtifact(verified.value().providers[0], artifact);
    try std.testing.expectError(error.HashMismatch, verifyArtifact(verified.value().providers[0], "tampered"));
    try std.testing.expect(mayAutoInstall(.official, false));
    try std.testing.expect(!mayAutoInstall(.unverified, true));
}

test "manifest signature rejects modified payload" {
    const allocator = std.testing.allocator;
    const key_pair = try Ed25519.KeyPair.generateDeterministic([_]u8{0x11} ** Ed25519.KeyPair.seed_length);
    const signature = try key_pair.sign("original", null);
    const signature_hex = std.fmt.bytesToHex(signature.toBytes(), .lower);
    const envelope = try std.json.Stringify.valueAlloc(allocator, .{ .payload = "modified", .signature = &signature_hex }, .{});
    defer allocator.free(envelope);
    try std.testing.expectError(error.SignatureVerificationFailed, verifySignedManifest(allocator, envelope, key_pair.public_key.toBytes()));
}
