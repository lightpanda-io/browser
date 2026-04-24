const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log;
const time = std.time;

const Config = @import("Config.zig");
const AdFilterModule = @import("network/AdFilter.zig");
const AdFilter = AdFilterModule.AdFilter;

const FetchError = error{
    InvalidUrl,
    FetchFailed,
};

pub const UpdateScheduler = struct {
    ad_filter: *AdFilter,
    config: *const Config,
    allocator: Allocator,
    update_interval: u32,
    last_update: i64, // timestamp in seconds

    // Thread management
    running: bool,
    stopping: bool,
    thread: ?std.Thread = null,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn init(allocator: Allocator, ad_filter: *AdFilter, config: *const Config) !UpdateScheduler {
        return UpdateScheduler{
            .ad_filter = ad_filter,
            .config = config,
            .allocator = allocator,
            .update_interval = config.adblockUpdateInterval(),
            .last_update = 0,
            .running = false,
            .stopping = false,
            .thread = null,
        };
    }

    pub fn start(self: *UpdateScheduler) !void {
        if (self.update_interval == 0) {
            log.info("Adblock auto-updates disabled", .{});
            return;
        }

        self.mutex.lock();
        if (self.running) {
            self.mutex.unlock();
            return;
        }

        self.stopping = false;
        self.running = true;
        self.mutex.unlock();

        self.thread = try std.Thread.spawn(.{}, UpdateScheduler.runLoop, .{self});
        log.info("Adblock update scheduler started (interval: {}s)", .{self.update_interval});
    }

    pub fn stop(self: *UpdateScheduler) void {
        self.mutex.lock();
        if (!self.running) {
            self.mutex.unlock();
            return;
        }

        self.stopping = true;
        self.running = false;

        // Wake up the background thread instantly if it is sleeping
        self.cond.signal();
        self.mutex.unlock();

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runLoop(self: *UpdateScheduler) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.running) {
            const timeout_ns = @as(u64, self.update_interval) * time.ns_per_s;

            // timedWait unlocks the mutex while sleeping, and relocks it before returning.
            _ = self.cond.timedWait(&self.mutex, timeout_ns) catch {};

            // If stop() was called during sleep, break out before doing work.
            if (self.stopping) break;

            // Drop the lock during the heavy I/O network tasks so we don't
            // block the main thread from interacting with the scheduler.
            self.mutex.unlock();

            self.performUpdate() catch |err| {
                log.err("Failed to update adblock filters: {}", .{err});
            };

            // Re-acquire the lock for the next loop iteration condition check.
            self.mutex.lock();
        }
    }

    fn performUpdate(self: *UpdateScheduler) !void {
        log.info("Updating adblock filter lists...", .{});

        const lists = self.config.adblockListsStr() orelse {
            log.warn("No filter lists configured", .{});
            return;
        };

        var iter = std.mem.splitScalar(u8, lists, ',');
        var contents: std.ArrayList([]const u8) = .{};
        defer {
            for (contents.items) |content| {
                self.allocator.free(content);
            }
            contents.deinit(self.allocator);
        }

        while (iter.next()) |list_url| {
            const trimmed = std.mem.trim(u8, list_url, " \t");
            if (trimmed.len == 0) continue;

            const content = self.fetchFilterList(trimmed) catch |err| {
                log.err("Failed to fetch filter list {s}: {}", .{ trimmed, err });
                continue;
            };

            log.debug("Successfully updated filter list: {s}", .{trimmed});
            try contents.append(self.allocator, content);
        }

        if (contents.items.len > 0) {
            try self.ad_filter.replaceFilterLists(contents.items);
            self.last_update = time.timestamp();
            log.info("Updated {} filter lists", .{contents.items.len});
        }
    }

    fn fetchFilterList(self: *UpdateScheduler, list_url: []const u8) FetchError![]u8 {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        _ = std.Uri.parse(list_url) catch return FetchError.InvalidUrl;

        var body = std.Io.Writer.Allocating.init(self.allocator);
        errdefer body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = list_url },
            .response_writer = &body.writer,
        }) catch return FetchError.FetchFailed;
        if (result.status != .ok) {
            return FetchError.FetchFailed;
        }

        return body.toOwnedSlice() catch return FetchError.FetchFailed;
    }

    pub fn forceUpdate(self: *UpdateScheduler) void {
        self.performUpdate() catch |err| {
            log.err("Force update failed: {}", .{err});
        };
    }

    pub fn deinit(self: *UpdateScheduler) void {
        self.stop();
    }
};
