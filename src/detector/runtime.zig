const std = @import("std");

pub const RuntimeKind = enum {
    steamworks,
    gse_compatible,
    rune_compatible,
    ubisoft_connect,
    uplay_r2,
    epic_eos,
    gog_galaxy,
};

pub const DetectedRuntime = struct {
    kind: RuntimeKind,
    confidence: u8,
    evidence_count: u8,
};

pub const RuntimeReport = struct {
    allocator: std.mem.Allocator,
    runtimes: std.ArrayList(DetectedRuntime) = .empty,

    pub fn init(allocator: std.mem.Allocator) RuntimeReport {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RuntimeReport) void {
        self.runtimes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addEvidence(self: *RuntimeReport, kind: RuntimeKind, score: u8) !void {
        for (self.runtimes.items) |*runtime| {
            if (runtime.kind != kind) continue;
            runtime.confidence = @min(100, @as(u16, runtime.confidence) + score);
            runtime.evidence_count +|= 1;
            return;
        }
        try self.runtimes.append(self.allocator, .{
            .kind = kind,
            .confidence = @min(100, score),
            .evidence_count = 1,
        });
    }

    pub fn sort(self: *RuntimeReport) void {
        std.mem.sort(DetectedRuntime, self.runtimes.items, {}, struct {
            fn lessThan(_: void, a: DetectedRuntime, b: DetectedRuntime) bool {
                return a.confidence > b.confidence;
            }
        }.lessThan);
    }
};

pub fn detect(allocator: std.mem.Allocator, io: std.Io, game_dir: []const u8) !RuntimeReport {
    var report = RuntimeReport.init(allocator);
    errdefer report.deinit();

    var dir = try std.Io.Dir.cwd().openDir(io, game_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory and entry.depth() >= 5) {
            walker.leave(io);
            continue;
        }
        if (entry.kind != .file) continue;
        const name = entry.basename;

        if (eql(name, "steam_api64.dll") or eql(name, "steam_api.dll")) {
            try report.addEvidence(.steamworks, 55);
        } else if (eql(name, "steam_appid.txt")) {
            try report.addEvidence(.steamworks, 20);
        } else if (eql(name, "configs.main.ini") or eql(name, "configs.user.ini") or eql(name, "configs.app.ini")) {
            try report.addEvidence(.gse_compatible, 32);
        } else if (eql(name, "force_account_name.txt") or eql(name, "local_save.txt")) {
            try report.addEvidence(.gse_compatible, 45);
        } else if (eql(name, "steam_emu.ini")) {
            try report.addEvidence(.rune_compatible, 70);
        } else if (eql(name, "steamclient64.dll")) {
            try report.addEvidence(.rune_compatible, 20);
        } else if (eql(name, "eossdk-win64-shipping.dll") or eql(name, "eossdk-win32-shipping.dll")) {
            try report.addEvidence(.epic_eos, 85);
        } else if (eql(name, "uplay_r2_loader64.dll") or eql(name, "uplay_r2_loader.dll")) {
            try report.addEvidence(.uplay_r2, 90);
        } else if (eql(name, "upc_r2_loader64.dll") or eql(name, "upc_r2_loader.dll")) {
            try report.addEvidence(.ubisoft_connect, 90);
        } else if (eql(name, "galaxy64.dll") or eql(name, "galaxy.dll")) {
            try report.addEvidence(.gog_galaxy, 85);
        }
    }

    // A Steam API DLL accompanied by GSE configuration is an emulated
    // Steamworks runtime. Keep Steamworks visible as an observed API, but make
    // the GSE provider the strongest achievement candidate.
    const has_gse = find(&report, .gse_compatible) != null;
    if (has_gse) {
        try report.addEvidence(.gse_compatible, 35);
        if (find(&report, .steamworks)) |steam| steam.confidence = @min(steam.confidence, 45);
    }
    if (find(&report, .rune_compatible)) |rune| {
        if (rune.confidence >= 70) {
            try report.addEvidence(.rune_compatible, 20);
            if (find(&report, .steamworks)) |steam| steam.confidence = @min(steam.confidence, 45);
        }
    }
    report.sort();
    return report;
}

pub fn hasDirectIndicator(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) bool {
    const indicators = [_][]const u8{
        "steam_api64.dll",
        "steam_api.dll",
        "EOSSDK-Win64-Shipping.dll",
        "EOSSDK-Win32-Shipping.dll",
        "uplay_r2_loader64.dll",
        "upc_r2_loader64.dll",
        "Galaxy64.dll",
    };
    for (indicators) |name| {
        const path = std.fs.path.join(allocator, &.{ directory, name }) catch return false;
        defer allocator.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return true;
    }
    const settings = std.fs.path.join(allocator, &.{ directory, "steam_settings" }) catch return false;
    defer allocator.free(settings);
    var dir = std.Io.Dir.cwd().openDir(io, settings, .{}) catch return false;
    dir.close(io);
    return true;
}

pub fn find(report: *RuntimeReport, kind: RuntimeKind) ?*DetectedRuntime {
    for (report.runtimes.items) |*runtime| if (runtime.kind == kind) return runtime;
    return null;
}

fn eql(name: []const u8, expected: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, expected);
}

test "evidence is accumulated and sorted" {
    var report = RuntimeReport.init(std.testing.allocator);
    defer report.deinit();
    try report.addEvidence(.steamworks, 20);
    try report.addEvidence(.gse_compatible, 60);
    try report.addEvidence(.steamworks, 25);
    report.sort();
    try std.testing.expectEqual(RuntimeKind.gse_compatible, report.runtimes.items[0].kind);
    try std.testing.expectEqual(@as(u8, 45), report.runtimes.items[1].confidence);
}
