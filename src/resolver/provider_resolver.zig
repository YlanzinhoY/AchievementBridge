const std = @import("std");
const ProviderKind = @import("../core/event.zig").ProviderKind;
const runtime = @import("../detector/runtime.zig");

pub const Candidate = struct {
    provider: ProviderKind,
    confidence: u8,
};

pub fn resolve(
    allocator: std.mem.Allocator,
    report: *const runtime.RuntimeReport,
) ![]Candidate {
    var result: std.ArrayList(Candidate) = .empty;
    errdefer result.deinit(allocator);
    for (report.runtimes.items) |detected| {
        const provider: ProviderKind = switch (detected.kind) {
            .steamworks => .steam,
            .gse_compatible => .gse,
            .rune_compatible => .rune,
            .rockstar_social_club => .rockstar,
            .ubisoft_connect => .ubisoft,
            .uplay_r2 => .uplay_r2,
            .epic_eos => .epic,
            .gog_galaxy => .gog,
        };
        if (detected.confidence >= 25) try result.append(allocator, .{
            .provider = provider,
            .confidence = detected.confidence,
        });
    }
    return result.toOwnedSlice(allocator);
}

test "resolver keeps multiple providers" {
    var report = runtime.RuntimeReport.init(std.testing.allocator);
    defer report.deinit();
    try report.addEvidence(.steamworks, 40);
    try report.addEvidence(.ubisoft_connect, 90);
    report.sort();
    const candidates = try resolve(std.testing.allocator, &report);
    defer std.testing.allocator.free(candidates);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectEqual(ProviderKind.ubisoft, candidates[0].provider);
    try std.testing.expectEqual(ProviderKind.steam, candidates[1].provider);
}
