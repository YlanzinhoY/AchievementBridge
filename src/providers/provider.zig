const event = @import("../core/event.zig");

pub const Capabilities = struct {
    realtime_events: bool = false,
    snapshots: bool = false,
    progress: bool = false,
    timestamps: bool = false,
    metadata: bool = false,
};

pub const Descriptor = struct {
    kind: event.ProviderKind,
    name: []const u8,
    version: []const u8,
    capabilities: Capabilities,
};

pub const gse = Descriptor{
    .kind = .gse,
    .name = "GSE",
    .version = "0.1.0",
    .capabilities = .{
        .realtime_events = true,
        .snapshots = true,
        .timestamps = true,
        .metadata = true,
    },
};

pub const steam = Descriptor{
    .kind = .steam,
    .name = "Steam",
    .version = "0.1.0",
    .capabilities = .{
        .snapshots = true,
        .timestamps = true,
        .metadata = true,
    },
};

pub const rune = Descriptor{
    .kind = .rune,
    .name = "RUNE",
    .version = "0.1.0",
    .capabilities = .{
        .realtime_events = true,
        .snapshots = true,
        .progress = true,
        .timestamps = true,
    },
};

pub const rockstar = Descriptor{
    .kind = .rockstar,
    .name = "Rockstar Social Club",
    .version = "0.1.5",
    .capabilities = .{
        .realtime_events = true,
        .snapshots = true,
        .timestamps = true,
        .metadata = true,
    },
};

pub const ubisoft = Descriptor{
    .kind = .ubisoft,
    .name = "Ubisoft Connect",
    .version = "0.1.0",
    .capabilities = .{
        .realtime_events = true,
        .snapshots = true,
        .timestamps = true,
    },
};

pub const uplay_r2 = Descriptor{
    .kind = .uplay_r2,
    .name = "Uplay R2-compatible",
    .version = "0.1.0",
    .capabilities = .{
        .realtime_events = true,
        .snapshots = true,
        .timestamps = true,
    },
};
