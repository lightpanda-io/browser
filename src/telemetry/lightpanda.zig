const std = @import("std");
const lp = @import("lightpanda");
const builtin = @import("builtin");
const build_config = @import("build_config");

const App = @import("../App.zig");
const Config = @import("../Config.zig");

const http = @import("../network/http.zig");
const Network = @import("../network/Network.zig");

const telemetry = @import("telemetry.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

const MAX_PENDING = 4096; // hard cap: drop + count beyond this (reported via buffer_overflow)
const RECLAIM_CAPACITY = 64; // reclaim the drain buffer once a burst grows it past this
const MAX_BODY_SIZE = 500 * 1024; // 500KB
const REQUEST_TIMEOUT_MS = 5000;
const URL = "https://telemetry.lightpanda.io/v2";

const LightPanda = @This();

allocator: Allocator,
network: *Network,

// Owned and used only by the sender thread; never touched by producers.
writer: std.Io.Writer.Allocating,

iid: ?[36]u8 = null,
run_mode: Config.RunMode = .serve,
interactive: bool = false,

// Per run id
sid: [16]u8,
proxy: bool,

// Header is sent before the first message, once sent, it isn't sent again
header_sent: bool = false,

// `mutex` guards the ring buffer (head/tail/dropped), `running`, and the lazy
// `thread` creation. The sender thread blocks on `cond` while idle.
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},

// The sender thread is spawned on the first event, so a process that emits no
// telemetry pays for none of this
thread: ?std.Thread = null,
running: bool = true,

// Pending events. Producers append under `mutex`; the sender thread swaps the
// whole list out in O(1) and drains it. The list grows from empty under load
// and is reclaimed afterward, so memory tracks actual queue depth and never
// pre-commits a fixed count × sizeOf(Event). Events must be self-contained
// (inline storage, no borrowed slices) since they outlive the send() call on
// the sender thread. Past MAX_PENDING (or on alloc failure) we drop and bump
// `dropped`, which is reported as a buffer_overflow event on the next
// successful POST and only cleared then — our signal that the cap is too low or
// the endpoint is failing.
pending: std.ArrayList(telemetry.Event) = .empty,
dropped: u32 = 0,

pub fn init(self: *LightPanda, app: *App, iid: ?[36]u8, run_mode: Config.RunMode, interactive: bool) !void {
    var raw_sid: [8]u8 = undefined;
    std.crypto.random.bytes(&raw_sid);

    self.* = .{
        .iid = iid,
        .run_mode = run_mode,
        .interactive = interactive,
        .sid = std.fmt.bytesToHex(raw_sid, .lower),
        .proxy = app.config.httpProxy() != null,
        .allocator = app.allocator,
        .network = &app.network,
        .writer = std.Io.Writer.Allocating.init(app.allocator),
    };
}

pub fn deinit(self: *LightPanda) void {
    if (self.thread) |thread| {
        self.mutex.lock();
        self.running = false;
        self.mutex.unlock();
        self.cond.signal();
        // The thread drains anything still queued before returning, so this is
        // also our graceful flush-on-shutdown. Bounded by REQUEST_TIMEOUT_MS.
        thread.join();
    }
    self.pending.deinit(self.allocator);
    self.writer.deinit();
}

pub fn send(self: *LightPanda, raw_event: telemetry.Event) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.thread == null) {
        // First event: bring the sender thread online. If it can't spawn, drop
        // the event rather than blocking the producer.
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            log.warn(.telemetry, "thread spawn", .{ .err = err });
            return;
        };
    }

    if (self.pending.items.len >= MAX_PENDING) {
        self.dropped +|= 1;
        return;
    }

    self.pending.append(self.allocator, raw_event) catch {
        // Allocation failure growing the queue: drop and count, same as a cap hit.
        self.dropped +|= 1;
        return;
    };
    self.cond.signal();
}

fn run(self: *LightPanda) void {
    // The connection is created, owned, and torn down entirely on this thread;
    // the network thread never sees it (Transport == .none).
    var conn = http.Connection.init(self.network.ca_blob, self.network.config, self.network.ip_filter) catch |err| {
        // Essentially OOM — the process is already in trouble. The thread
        // handle stays set so send() won't respawn; events drop at the cap.
        log.warn(.telemetry, "connection init", .{ .err = err });
        return;
    };
    defer conn.deinit();

    // Static for the lifetime of the connection.
    conn.setURL(URL) catch |err| return log.warn(.telemetry, "set url", .{ .err = err });
    conn.setMethod(.POST) catch |err| return log.warn(.telemetry, "set method", .{ .err = err });
    conn.setTimeout(REQUEST_TIMEOUT_MS) catch |err| return log.warn(.telemetry, "set timeout", .{ .err = err });

    // Consumer-owned buffer, swapped with `pending` each cycle: producers always
    // get an empty list back and we own the batch lock-free across the POST.
    var batch: std.ArrayList(telemetry.Event) = .empty;
    defer batch.deinit(self.allocator);

    self.mutex.lock();
    defer self.mutex.unlock();
    while (true) {
        while (self.pending.items.len == 0) {
            if (self.running == false) {
                return;
            }
            self.cond.wait(&self.mutex);
        }

        // Swap the batch out and release the lock for the (blocking) serialize +
        // POST so producers never wait on the network.
        std.mem.swap(std.ArrayList(telemetry.Event), &self.pending, &batch);
        const dropped = self.dropped;
        self.dropped = 0;
        self.mutex.unlock();

        var sent: usize = 0;
        self.postEvents(&conn, batch.items, dropped, &sent) catch |err| {
            log.warn(.telemetry, "postEvents", .{ .err = err, .events = batch.items.len, .dropped = dropped });
        };
        const lost: u32 = @intCast(batch.items.len - sent);

        // batch is owned by this thread and can be mutated without the lock
        if (batch.capacity > RECLAIM_CAPACITY) {
            batch.clearAndFree(self.allocator);
        } else {
            batch.clearRetainingCapacity();
        }

        self.mutex.lock();
        // Re-fold whatever didn't reach the wire back into `dropped`, so the next
        // successful POST still reports it — our only failure signal.
        self.dropped +|= lost;
        if (sent == 0) {
            // if nothing was sent, than we didn't get to send the buffer_overflow
            // message, so whatever was dropped is still dropped.
            self.dropped +|= dropped;
        }
    }
}

fn postEvents(self: *LightPanda, conn: *http.Connection, events: []const telemetry.Event, dropped: u32, sent: *usize) !void {
    if (self.header_sent == false) {
        _ = try self.writeHeader();
    }

    // The overflow report rides ahead of the first body; the rest of that body
    // and any subsequent ones are filled from `events` below.
    const has_overflow = dropped > 0;
    if (has_overflow) {
        _ = try self.writeEvent(.{ .buffer_overflow = .{ .dropped = dropped } });
    }

    var queued: usize = 0;
    for (events) |event| {
        if (try self.writeEvent(event) == false) {
            try self.flush(conn);
            sent.* += queued;
            queued = 0;

            // now re-write the message that didn't fit
            const fit = try self.writeEvent(event);
            if (comptime IS_DEBUG) {
                std.debug.assert(fit);
            }
            if (fit == false) {
                // we have a single event that can never be serialized. This
                // should never happen, but I'm not willing to crash on that
                // belief.
                continue;
            }
        }
        queued += 1;
    }

    if (self.writer.written().len != 0) {
        try self.flush(conn);
        sent.* += queued;
    }

    self.header_sent = true;
}

fn flush(self: *LightPanda, conn: *http.Connection) !void {
    self._flush(conn) catch |err| {
        log.warn(.telemetry, "flush", .{ .err = err, .size = self.writer.written().len });
        return err;
    };
}

fn _flush(self: *LightPanda, conn: *http.Connection) !void {
    defer self.writer.clearRetainingCapacity();

    try conn.setBody(self.writer.written());
    const status = try conn.perform();
    if (status != 200) {
        return error.ServerError;
    }
}

fn writeEvent(self: *LightPanda, event: telemetry.Event) !bool {
    return self.writeLine(&EventRow{ .sid = &self.sid, .event = event });
}

fn writeHeader(self: *LightPanda) !bool {
    const iid: ?[]const u8 = if (self.iid) |*id| id else null;
    return self.writeLine(&Header{
        .sid = &self.sid,
        .iid = iid,
        .mode = self.run_mode,
        .interactive = self.interactive,
        .proxy = self.proxy,
    });
}

fn writeLine(self: *LightPanda, value: anytype) !bool {
    const checkpoint = self.writer.written().len;

    try std.json.Stringify.value(value, .{}, &self.writer.writer);
    try self.writer.writer.writeByte('\n');

    if (self.writer.written().len > MAX_BODY_SIZE) {
        self.writer.shrinkRetainingCapacity(checkpoint);
        return false;
    }
    return true;
}

const Header = struct {
    sid: []const u8,
    iid: ?[]const u8,
    mode: Config.RunMode,
    interactive: bool,
    proxy: bool,

    pub fn jsonStringify(self: *const Header, writer: anytype) !void {
        try writer.beginObject();

        try writer.objectField("sid");
        try writer.write(self.sid);

        if (self.iid) |iid| {
            try writer.objectField("iid");
            try writer.write(iid);
        }

        try writer.objectField("mode");
        // Special case: when running agent mode in non-interactive, we send a
        // special running mode.
        if (self.mode == .agent and self.interactive == false) {
            try writer.write("agent_replay");
        } else {
            try writer.write(self.mode);
        }

        try writer.objectField("os");
        try writer.write(builtin.os.tag);

        try writer.objectField("arch");
        try writer.write(builtin.cpu.arch);

        try writer.objectField("version");
        try writer.write(build_config.version);

        try writer.objectField("proxy");
        try writer.write(self.proxy);

        try writer.endObject();
    }
};

const EventRow = struct {
    sid: []const u8,
    event: telemetry.Event,

    pub fn jsonStringify(self: *const EventRow, writer: anytype) !void {
        try writer.beginArray();
        try writer.write(self.sid);
        switch (self.event) {
            .run => try writer.write("run"),
            .navigate => |n| {
                try writer.write("nav");
                try writer.write(n.tls);
                try writer.write(n.context);
            },
            .buffer_overflow => |b| {
                try writer.write("bof");
                try writer.write(b.dropped);
            },
            .llm => |l| {
                try writer.write("llm");
                try writer.write(l.provider);
                try writer.write(l.model);
            },
        }
        try writer.endArray();
    }
};

const testing = @import("../testing.zig");

test "telemetry: event row wire format" {
    const Case = struct { event: telemetry.Event, expected: []const u8 };
    const cases = [_]Case{
        .{ .event = .{ .run = {} }, .expected = "[\"sid0\",\"run\"]" },
        .{
            .event = .{ .navigate = .{ .tls = true, .context = .page, .reason = .address_bar } },
            .expected = "[\"sid0\",\"navigate\",true,\"page\",\"address_bar\"]",
        },
        .{
            .event = .{ .navigate = .{ .tls = false, .context = .popup, .reason = .anchor } },
            .expected = "[\"sid0\",\"navigate\",false,\"popup\",\"anchor\"]",
        },
        .{
            .event = .{ .navigate = .{ .tls = true, .context = .iframe, .reason = .script } },
            .expected = "[\"sid0\",\"navigate\",true,\"iframe\",\"script\"]",
        },
        .{
            .event = .{ .buffer_overflow = .{ .dropped = 42 } },
            .expected = "[\"sid0\",\"buffer_overflow\",42]",
        },
        .{
            .event = .{ .llm = .{ .provider = "anthropic", .model = .wrap("claude") } },
            .expected = "[\"sid0\",\"llm\",\"anthropic\",\"claude\"]",
        },
        .{
            .event = .{ .llm = .{ .provider = "nollm", .model = null } },
            .expected = "[\"sid0\",\"llm\",\"nollm\",null]",
        },
    };

    for (cases) |case| {
        var w = std.Io.Writer.Allocating.init(testing.allocator);
        defer w.deinit();
        try std.json.Stringify.value(&EventRow{ .sid = "sid0", .event = case.event }, .{}, &w.writer);
        try testing.expectEqual(case.expected, w.written());
    }
}

test "telemetry: header wire format" {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();

    const header = Header{
        .sid = "sid0",
        .iid = "the-iid",
        .mode = .serve,
        .interactive = false,
        .proxy = true,
    };
    try std.json.Stringify.value(&header, .{}, &w.writer);

    const out = w.written();
    try testing.expectEqual(true, std.mem.startsWith(u8, out, "{\"sid\":\"sid0\",\"iid\":\"the-iid\",\"mode\":\"serve\","));
    try testing.expectEqual(true, std.mem.endsWith(u8, out, ",\"proxy\":true,\"driver\":\"cdp\"}"));
}
