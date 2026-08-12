// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Lightweight fingerprint seed system inspired by CloakBrowser's
// `--fingerprint=<seed>` model: one seed → coherent hardware/GPU/screen
// identity. No Chromium patches — pure data for JS/WebGL stubs.

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("lightpanda");

/// OS identity reported to JS (navigator.platform / UA-CH platform).
pub const Platform = enum {
    windows,
    macos,
    linux,

    pub fn fromString(s: []const u8) ?Platform {
        if (std.ascii.eqlIgnoreCase(s, "windows") or std.ascii.eqlIgnoreCase(s, "win32")) return .windows;
        if (std.ascii.eqlIgnoreCase(s, "macos") or std.ascii.eqlIgnoreCase(s, "mac") or std.ascii.eqlIgnoreCase(s, "darwin")) return .macos;
        if (std.ascii.eqlIgnoreCase(s, "linux")) return .linux;
        return null;
    }

    pub fn navigatorPlatform(self: Platform) []const u8 {
        return switch (self) {
            .windows => "Win32",
            .macos => "MacIntel",
            .linux => "Linux x86_64",
        };
    }

    pub fn uaChPlatform(self: Platform) []const u8 {
        return switch (self) {
            .windows => "Windows",
            .macos => "macOS",
            .linux => "Linux",
        };
    }

    /// Host default (compile-time OS).
    pub fn host() Platform {
        return switch (builtin.os.tag) {
            .windows => .windows,
            .macos => .macos,
            else => .linux,
        };
    }
};

const Gpu = struct {
    vendor: []const u8,
    renderer: []const u8,
};

// Small pools — CloakBrowser-style variety without a huge table.
const win_gpus = [_]Gpu{
    .{ .vendor = "Google Inc. (NVIDIA)", .renderer = "ANGLE (NVIDIA, NVIDIA GeForce GTX 1660 SUPER Direct3D11 vs_5_0 ps_5_0, D3D11)" },
    .{ .vendor = "Google Inc. (NVIDIA)", .renderer = "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)" },
    .{ .vendor = "Google Inc. (Intel)", .renderer = "ANGLE (Intel, Intel(R) UHD Graphics 620 Direct3D11 vs_5_0 ps_5_0, D3D11)" },
    .{ .vendor = "Google Inc. (Intel)", .renderer = "ANGLE (Intel, Intel(R) UHD Graphics 630 Direct3D11 vs_5_0 ps_5_0, D3D11)" },
    .{ .vendor = "Google Inc. (AMD)", .renderer = "ANGLE (AMD, AMD Radeon RX 580 Series Direct3D11 vs_5_0 ps_5_0, D3D11)" },
};

const mac_gpus = [_]Gpu{
    .{ .vendor = "Google Inc. (Apple)", .renderer = "ANGLE (Apple, ANGLE Metal Renderer: Apple M1, Unspecified Version)" },
    .{ .vendor = "Google Inc. (Apple)", .renderer = "ANGLE (Apple, ANGLE Metal Renderer: Apple M2, Unspecified Version)" },
    .{ .vendor = "Google Inc. (Apple)", .renderer = "ANGLE (Apple, ANGLE Metal Renderer: Apple M3, Unspecified Version)" },
    .{ .vendor = "Intel Inc.", .renderer = "Intel(R) Iris(TM) Plus Graphics OpenGL Engine" },
};

const linux_gpus = [_]Gpu{
    .{ .vendor = "Google Inc. (NVIDIA)", .renderer = "ANGLE (NVIDIA, NVIDIA GeForce GTX 1660 SUPER/PCIe/SSE2)" },
    .{ .vendor = "Intel", .renderer = "Mesa Intel(R) UHD Graphics 620 (KBL GT2)" },
    .{ .vendor = "AMD", .renderer = "AMD Radeon RX 580 Series (radeonsi, polaris10, LLVM 15.0.7)" },
};

const ScreenSize = struct { w: u32, h: u32 };

const screens = [_]ScreenSize{
    .{ .w = 1920, .h = 1080 },
    .{ .w = 2560, .h = 1440 },
    .{ .w = 1366, .h = 768 },
    .{ .w = 1536, .h = 864 },
    .{ .w = 1440, .h = 900 },
    .{ .w = 1680, .h = 1050 },
    .{ .w = 1280, .h = 720 },
    .{ .w = 3840, .h = 2160 },
};

/// Coherent device identity derived from one seed (CloakBrowser model).
pub const Profile = struct {
    seed: u64,
    platform: Platform,
    hardware_concurrency: u32,
    device_memory_gb: f64,
    screen_width: u32,
    screen_height: u32,
    gpu_vendor: []const u8,
    gpu_renderer: []const u8,
    /// Mix into canvas / audio fingerprint paths for stability per seed.
    noise_seed: u64,

    /// Fixed non-stealth defaults (legacy Lightpanda values).
    pub const stock: Profile = .{
        .seed = 0,
        .platform = .host(),
        .hardware_concurrency = 4,
        .device_memory_gb = 8.0,
        .screen_width = 1920,
        .screen_height = 1080,
        .gpu_vendor = "Intel Inc.",
        .gpu_renderer = "Intel(R) UHD Graphics 620",
        .noise_seed = 0xcbf29ce484222325,
    };

    pub fn fromSeed(seed: u64, platform: Platform) Profile {
        var rng = splitmix64(seed);
        const hw_choices = [_]u32{ 4, 6, 8, 8, 12, 16 };
        const mem_choices = [_]f64{ 4.0, 8.0, 8.0, 8.0 };

        const hw = hw_choices[rng % hw_choices.len];
        rng = splitmix64(rng);
        const mem = mem_choices[rng % mem_choices.len];
        rng = splitmix64(rng);
        const scr = screens[rng % screens.len];
        rng = splitmix64(rng);

        const gpu = switch (platform) {
            .windows => win_gpus[rng % win_gpus.len],
            .macos => mac_gpus[rng % mac_gpus.len],
            .linux => linux_gpus[rng % linux_gpus.len],
        };
        rng = splitmix64(rng);

        return .{
            .seed = seed,
            .platform = platform,
            .hardware_concurrency = hw,
            .device_memory_gb = mem,
            .screen_width = scr.w,
            .screen_height = scr.h,
            .gpu_vendor = gpu.vendor,
            .gpu_renderer = gpu.renderer,
            .noise_seed = rng ^ 0x9e3779b97f4a7c15,
        };
    }

    pub fn random(platform: Platform) Profile {
        var seed: u64 = undefined;
        lp.io.random(std.mem.asBytes(&seed));
        // CloakBrowser uses 10000–99999 style seeds for readability; keep full u64 entropy.
        if (seed == 0) seed = 0xdeadbeefcafebabe;
        return fromSeed(seed, platform);
    }

    pub fn navigatorPlatform(self: *const Profile) []const u8 {
        return self.platform.navigatorPlatform();
    }
};

/// SplitMix64 — fast deterministic mixer (same spirit as seed-derived FPs).
fn splitmix64(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

const testing = @import("../testing.zig");

test "Fingerprint: same seed same profile" {
    const a = Profile.fromSeed(424242, .windows);
    const b = Profile.fromSeed(424242, .windows);
    try testing.expectEqual(a.hardware_concurrency, b.hardware_concurrency);
    try testing.expectEqual(a.device_memory_gb, b.device_memory_gb);
    try testing.expectEqual(a.screen_width, b.screen_width);
    try testing.expect(std.mem.eql(u8, a.gpu_vendor, b.gpu_vendor));
    try testing.expectEqual(a.noise_seed, b.noise_seed);
}

test "Fingerprint: different seeds differ" {
    const a = Profile.fromSeed(1, .windows);
    const b = Profile.fromSeed(2, .windows);
    // Extremely unlikely all equal across independent fields
    const same = a.hardware_concurrency == b.hardware_concurrency and
        a.screen_width == b.screen_width and
        a.noise_seed == b.noise_seed and
        std.mem.eql(u8, a.gpu_renderer, b.gpu_renderer);
    try testing.expect(!same);
}

test "Fingerprint: platform pools" {
    const w = Profile.fromSeed(99, .windows);
    const m = Profile.fromSeed(99, .macos);
    try testing.expect(std.mem.indexOf(u8, w.gpu_renderer, "ANGLE") != null or std.mem.indexOf(u8, w.gpu_vendor, "Google") != null or std.mem.indexOf(u8, w.gpu_vendor, "Intel") != null);
    try testing.expectString("MacIntel", m.navigatorPlatform());
    try testing.expectString("Win32", w.navigatorPlatform());
}
