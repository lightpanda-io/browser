const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const telemetry = @import("telemetry.zig");
const RunMode = @import("../app.zig").RunMode;

const log = std.log.scoped(.telemetry);
const URL = "https://lightpanda.io/browser-stats";

pub const LightPanda = struct {
    uri: std.Uri,
    pending: List,
    running: bool,
    thread: ?std.Thread,
    allocator: Allocator,
    mutex: std.Thread.Mutex,
    cond: Thread.Condition,
    node_pool: std.heap.MemoryPool(List.Node),

    const List = std.DoublyLinkedList(LightPandaEvent);

    pub fn init(allocator: Allocator) !LightPanda {
        return .{
            .cond = .{},
            .mutex = .{},
            .pending = .{},
            .thread = null,
            .running = true,
            .allocator = allocator,
            .uri = std.Uri.parse(URL) catch unreachable,
            .node_pool = std.heap.MemoryPool(List.Node).init(allocator),
        };
    }

    pub fn deinit(self: *LightPanda) void {
        if (self.thread) |*thread| {
            self.mutex.lock();
            self.running = false;
            self.mutex.unlock();
            self.cond.signal();
            thread.join();
        }
        self.node_pool.deinit();
    }

    pub fn send(self: *LightPanda, iid: ?[]const u8, run_mode: RunMode, raw_event: telemetry.Event) !void {
        const event = LightPandaEvent{
            .iid = iid,
            .driver = if (std.meta.activeTag(raw_event) == .navigate) "cdp" else null,
            .mode = run_mode,
            .os = builtin.os.tag,
            .arch = builtin.cpu.arch,
            .version = build_info.git_commit,
            .event = @tagName(std.meta.activeTag(raw_event)),
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.thread == null) {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        const node = try self.node_pool.create();
        errdefer self.node_pool.destroy(node);
        node.data = event;
        self.pending.append(node);
        self.cond.signal();
    }

    fn run(self: *LightPanda) void {
        var arr: std.ArrayListUnmanaged(u8) = .{};
        var client = std.http.Client{ .allocator = self.allocator };

        defer {
            arr.deinit(self.allocator);
            client.deinit();
        }

        self.mutex.lock();
        while (true) {
            while (self.pending.popFirst()) |node| {
                self.mutex.unlock();
                self.postEvent(&node.data, &client, &arr) catch |err| {
                    log.warn("Telementry reporting error: {}", .{err});
                };
                self.mutex.lock();
                self.node_pool.destroy(node);
            }
            if (self.running == false) {
                return;
            }
            self.cond.wait(&self.mutex);
        }
    }

    fn postEvent(self: *const LightPanda, event: *const LightPandaEvent, client: *std.http.Client, arr: *std.ArrayListUnmanaged(u8)) !void {
        defer arr.clearRetainingCapacity();
        try std.json.stringify(event, .{ .emit_null_optional_fields = false }, arr.writer(self.allocator));

        var response_header_buffer: [2048]u8 = undefined;

        const result = try client.fetch(.{
            .method = .POST,
            .payload = arr.items,
            .response_storage = .ignore,
            .location = .{ .uri = self.uri },
            .server_header_buffer = &response_header_buffer,
        });
        if (result.status != .ok) {
            log.warn("server error status: {}", .{result.status});
        }
    }
};

const LightPandaEvent = struct {
    iid: ?[]const u8,
    mode: RunMode,
    driver: ?[]const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    version: []const u8,
    event: []const u8,
};
