const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;

const log = @import("../log.zig");
const App = @import("../app.zig").App;
const Http = @import("../http/Http.zig");
const telemetry = @import("telemetry.zig");

const URL = "https://telemetry.lightpanda.io";
const MAX_BATCH_SIZE = 20;

pub const LightPanda = struct {
    running: bool,
    thread: ?std.Thread,
    allocator: Allocator,
    mutex: std.Thread.Mutex,
    cond: Thread.Condition,
    connection: Http.Connection,
    pending: std.DoublyLinkedList,
    mem_pool: std.heap.MemoryPool(LightPandaEvent),

    pub fn init(app: *App) !LightPanda {
        const connection = try app.http.newConnection();
        errdefer connection.deinit();

        try connection.setURL(URL);
        try connection.setMethod(.POST);

        const allocator = app.allocator;
        return .{
            .cond = .{},
            .mutex = .{},
            .pending = .{},
            .thread = null,
            .running = true,
            .allocator = allocator,
            .connection = connection,
            .mem_pool = std.heap.MemoryPool(LightPandaEvent).init(allocator),
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
        self.mem_pool.deinit();
        self.connection.deinit();
    }

    pub fn send(self: *LightPanda, iid: ?[]const u8, run_mode: App.RunMode, raw_event: telemetry.Event) !void {
        const event = try self.mem_pool.create();
        event.* = .{
            .iid = iid,
            .mode = run_mode,
            .event = raw_event,
            .node = .{},
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.thread == null) {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        self.pending.append(&event.node);
        self.cond.signal();
    }

    fn run(self: *LightPanda) void {
        var aw = std.Io.Writer.Allocating.init(self.allocator);

        var batch: [MAX_BATCH_SIZE]*LightPandaEvent = undefined;
        self.mutex.lock();
        while (true) {
            while (self.pending.first != null) {
                const b = self.collectBatch(&batch);
                self.mutex.unlock();
                self.postEvent(b, &aw) catch |err| {
                    log.warn(.telemetry, "post error", .{ .err = err });
                };
                self.mutex.lock();
            }
            if (self.running == false) {
                return;
            }
            self.cond.wait(&self.mutex);
        }
    }

    fn postEvent(self: *LightPanda, events: []*LightPandaEvent, aw: *std.Io.Writer.Allocating) !void {
        defer for (events) |e| {
            self.mem_pool.destroy(e);
        };

        defer aw.clearRetainingCapacity();
        for (events) |event| {
            try std.json.Stringify.value(event, .{ .emit_null_optional_fields = false }, &aw.writer);
            try aw.writer.writeByte('\n');
        }

        try self.connection.setBody(aw.written());
        const status = try self.connection.request();

        if (status != 200) {
            log.warn(.telemetry, "server error", .{ .status = status });
        }
    }

    fn collectBatch(self: *LightPanda, into: []*LightPandaEvent) []*LightPandaEvent {
        var i: usize = 0;
        while (self.pending.popFirst()) |node| {
            into[i] = @fieldParentPtr("node", node);
            i += 1;
            if (i == MAX_BATCH_SIZE) {
                break;
            }
        }
        return into[0..i];
    }
};

const LightPandaEvent = struct {
    iid: ?[]const u8,
    mode: App.RunMode,
    event: telemetry.Event,
    node: std.DoublyLinkedList.Node,

    pub fn jsonStringify(self: *const LightPandaEvent, writer: anytype) !void {
        try writer.beginObject();

        try writer.objectField("iid");
        try writer.write(self.iid);

        try writer.objectField("mode");
        try writer.write(self.mode);

        try writer.objectField("os");
        try writer.write(builtin.os.tag);

        try writer.objectField("arch");
        try writer.write(builtin.cpu.arch);

        try writer.objectField("version");
        try writer.write(build_config.git_commit);

        try writer.objectField("event");
        try writer.write(@tagName(std.meta.activeTag(self.event)));

        inline for (@typeInfo(telemetry.Event).@"union".fields) |union_field| {
            if (self.event == @field(telemetry.Event, union_field.name)) {
                const inner = @field(self.event, union_field.name);
                const TI = @typeInfo(@TypeOf(inner));
                if (TI == .@"struct") {
                    inline for (TI.@"struct".fields) |field| {
                        try writer.objectField(field.name);
                        try writer.write(@field(inner, field.name));
                    }
                }
            }
        }

        try writer.endObject();
    }
};
