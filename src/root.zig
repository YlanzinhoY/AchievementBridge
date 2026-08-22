pub const event = @import("core/event.zig");
pub const journal = @import("core/journal.zig");
pub const session = @import("core/session.zig");
pub const metadata = @import("core/metadata.zig");
pub const mapper = @import("core/mapper.zig");
pub const provider = @import("providers/provider.zig");
pub const detector = struct {
    pub const runtime = @import("detector/runtime.zig");
    pub const steam_install = @import("detector/steam_install.zig");
    pub const process = @import("detector/process.zig");
};
pub const resolver = @import("resolver/provider_resolver.zig");
pub const host = struct {
    pub const session_monitor = @import("host/session_monitor.zig");
};
pub const registry = struct {
    pub const manifest = @import("registry/manifest.zig");
    pub const cache = @import("registry/cache.zig");
};
pub const notifications = struct {
    pub const windows = @import("notifications/windows.zig");
};

pub const local = struct {
    pub const store = @import("local/store.zig");
};
pub const steam = struct {
    pub const adapter = @import("steam/adapter.zig");
    pub const client = @import("steam/client.zig");
    pub const user_stats = @import("steam/user_stats.zig");
    pub const vtable = @import("steam/vtable.zig");
    pub const metadata = @import("steam/metadata.zig");
};
pub const gse = struct {
    pub const snapshot = @import("providers/gse/snapshot.zig");
    pub const discovery = @import("providers/gse/discovery.zig");
    pub const watcher = @import("providers/gse/watcher.zig");
    pub const metadata = @import("providers/gse/metadata.zig");
};

pub const providers = struct {
    pub const steam = struct {
        pub const watcher = @import("providers/steam/watcher.zig");
    };
    pub const ubisoft = struct {
        pub const spool = @import("providers/ubisoft/spool.zig");
        pub const discovery = @import("providers/ubisoft/discovery.zig");
        pub const watcher = @import("providers/ubisoft/watcher.zig");
    };
    pub const uplay_r2 = struct {
        pub const diagnostic = @import("providers/uplay_r2/diagnostic.zig");
        pub const schema = @import("providers/uplay_r2/schema.zig");
        pub const watcher = @import("providers/uplay_r2/watcher.zig");
    };
};

test {
    _ = event;
    _ = journal;
    _ = session;
    _ = metadata;
    _ = mapper;
    _ = provider;
    _ = detector.runtime;
    _ = detector.steam_install;
    _ = detector.process;
    _ = resolver;
    _ = host.session_monitor;
    _ = registry.manifest;
    _ = registry.cache;
    _ = notifications.windows;
    _ = local.store;
    _ = steam.adapter;
    _ = steam.client;
    _ = steam.user_stats;
    _ = steam.vtable;
    _ = steam.metadata;
    _ = gse.snapshot;
    _ = gse.discovery;
    _ = gse.watcher;
    _ = gse.metadata;
    _ = providers.ubisoft.spool;
    _ = providers.ubisoft.discovery;
    _ = providers.ubisoft.watcher;
    _ = providers.uplay_r2.diagnostic;
    _ = providers.uplay_r2.schema;
    _ = providers.uplay_r2.watcher;
}
