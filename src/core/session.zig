const std = @import("std");
const ProviderKind = @import("event.zig").ProviderKind;

pub const SessionState = enum {
    discovering,
    resolving_providers,
    loading_providers,
    watching,
    finished,
};

pub const GameIdentity = struct {
    pid: ?u32 = null,
    app_id: ?u32 = null,
    name: ?[]const u8 = null,
    executable_path: ?[]const u8 = null,
    install_dir: ?[]const u8 = null,
};

pub const ProviderInstance = struct {
    kind: ProviderKind,
    confidence: u8,
    active: bool = false,
};

pub const GameSession = struct {
    identity: GameIdentity,
    state: SessionState = .discovering,
    providers: std.ArrayList(ProviderInstance) = .empty,

    pub fn deinit(self: *GameSession, allocator: std.mem.Allocator) void {
        self.providers.deinit(allocator);
        self.* = undefined;
    }

    pub fn transition(self: *GameSession, next: SessionState) !void {
        const valid = switch (self.state) {
            .discovering => next == .resolving_providers or next == .finished,
            .resolving_providers => next == .loading_providers or next == .finished,
            .loading_providers => next == .watching or next == .finished,
            .watching => next == .finished,
            .finished => false,
        };
        if (!valid) return error.InvalidSessionTransition;
        self.state = next;
    }
};

test "GameSession only accepts forward state transitions" {
    var session = GameSession{ .identity = .{ .app_id = 42 } };
    defer session.deinit(std.testing.allocator);
    try session.transition(.resolving_providers);
    try session.transition(.loading_providers);
    try session.transition(.watching);
    try std.testing.expectError(error.InvalidSessionTransition, session.transition(.discovering));
    try session.transition(.finished);
}
