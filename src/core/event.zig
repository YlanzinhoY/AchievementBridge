pub const ProviderKind = enum {
    gse,
    rune,
    steam,
    ubisoft,
    uplay_r2,
    epic,
    gog,
    ea,
    xbox,
};

pub const AchievementEvent = struct {
    app_id: u32,
    source_id: []const u8,
    provider: ProviderKind = .gse,
    unlocked_at: i64,
    detected_at: i64,
    recovered: bool = false,
};
