const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const time = std.time;
const assert = std.debug.assert;

const Config = @import("Config.zig");
const AdFilterModule = @import("network/AdFilter.zig");
const AdFilter = AdFilterModule.AdFilter;

pub const UpdateScheduler = struct {
    ad_filter: *AdFilter,
    config: *const Config,
    allocator: Allocator,
    update_interval: u32,
    last_update: i64, // timestamp in seconds
    running: bool,
    thread: ?std.Thread = null,

    pub fn init(allocator: Allocator, ad_filter: *AdFilter, config: *const Config) !UpdateScheduler {
        return UpdateScheduler{
            .ad_filter = ad_filter,
            .config = config,
            .allocator = allocator,
            .update_interval = config.adblockUpdateInterval(),
            .last_update = 0,
            .running = false,
            .thread = null,
        };
    }

    pub fn start(self: *UpdateScheduler) !void {
        if (self.update_interval == 0) {
            log.info("Adblock auto-updates disabled", .{});
            return;
        }

        self.running = true;
        self.thread = try std.Thread.spawn(.{}, UpdateScheduler.runLoop, .{self});
        log.info("Adblock update scheduler started (interval: {}s)", .{self.update_interval});
    }

    pub fn stop(self: *UpdateScheduler) void {
        self.running = false;
        if (self.thread) |t| {
            t.join();
        }
    }

    fn runLoop(self: *UpdateScheduler) void {
        while (self.running) {
            // Sleep for the update interval
            std.Thread.sleep(time.ns_per_s * @as(u64, self.update_interval));

            if (!self.running) break;

            // Check if update is needed
            const now = time.timestamp();
            if (now - self.last_update < @as(i64, self.update_interval)) {
                continue;
            }

            // Perform update
            self.performUpdate() catch |err| {
                log.err("Failed to update adblock filters: {}", .{err});
            };
        }
    }

    fn performUpdate(self: *UpdateScheduler) !void {
        log.info("Updating adblock filter lists...", .{});

        // Fetch latest filter lists
        const lists = self.config.adblockListsStr() orelse {
            log.warn("No filter lists configured", .{});
            return;
        };

        var iter = std.mem.splitScalar(u8, lists, ',');
        var updated: usize = 0;

        while (iter.next()) |list_url| {
            const trimmed = std.mem.trim(u8, list_url, " \t");
            if (trimmed.len == 0) continue;

            // TODO: Fetch the filter list from URL
            // For now, we'll just log that we would fetch
            log.debug("Would fetch filter list: {s}", .{trimmed});

            // In real implementation:
            // 1. HTTP GET the filter list
            // 2. Parse with adblock-rust parser
            // 3. Swap engine atomically
            // 4. Update last_update timestamp

            updated += 1;
        }

        if (updated > 0) {
            self.last_update = time.timestamp();
            log.info("Updated {} filter lists", .{updated});
        }
    }

    // Force immediate update (can be called from CLI or signal handler)
    pub fn forceUpdate(self: *UpdateScheduler) void {
        self.performUpdate() catch |err| {
            log.err("Force update failed: {}", .{err});
        };
    }

    pub fn deinit(self: *UpdateScheduler) void {
        self.stop();
    }
};
