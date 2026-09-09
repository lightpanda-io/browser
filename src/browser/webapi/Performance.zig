// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Factory = @import("../Factory.zig");
const Scheduler = @import("../js/Scheduler.zig");

const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const EventCounts = @import("EventCounts.zig");
const PerformanceObserver = @import("PerformanceObserver.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

// https://w3c.github.io/resource-timing/#dfn-resource-timing-buffer-size-limit
const DEFAULT_RESOURCE_BUFFER_SIZE = 250;

const BUFFER_FULL = "resourcetimingbufferfull";

pub fn registerTypes() []const type {
    return &.{ Performance, Entry, Mark, Measure, ResourceTiming, PerformanceTiming, PerformanceNavigation };
}

const Performance = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,
_time_origin: u64,
_arena: Allocator,
_factory: *Factory,
// Marks and measures. Kept in startTime order (see insertOrdered), as the
// getters must return them.
_entries: std.ArrayList(*Entry) = .empty,
// resources has its own cap, so it's split from entries (it's also potentially
// polled more)
_resources: std.ArrayList(*Entry) = .empty,
_timing: PerformanceTiming = .{},
_navigation: PerformanceNavigation = .{},
_event_counts: EventCounts = .{},
_resource_buffer_size: u32 = DEFAULT_RESOURCE_BUFFER_SIZE,
_buffer_full_pending: bool = false,
_on_buffer_full: ?js.Function.Global = null,

// The owner's task scheduler and its main-world Execution, both set by the
// owner once its JS context exists (Frame builds the Window, and thus this,
// before the context) - see attach. Never taken from a caller's Execution: an
// isolated-world or cross-frame caller's context can be destroyed while we
// live on.
_exec: *Execution = undefined,
_scheduler: *Scheduler = undefined,

// PerformanceObserver infrastructure. Lives here (rather than on the owning
// Frame/WorkerGlobalScope) so that both contexts get observers for free.
_observers: std.ArrayList(*PerformanceObserver) = .empty,
_delivery_scheduled: bool = false,
_delivering: bool = false,

/// Get high-resolution timestamp in microseconds, rounded to 5μs increments
/// to match browser behavior (prevents fingerprinting)
pub fn highResTimestamp() u64 {
    const micros = lp.datetime.microTimestamp(.boot);
    // Round to nearest 5 microseconds (like Firefox default)
    const rounded = @divTrunc(micros + 2, 5) * 5;
    return rounded;
}

pub fn init(factory: *Factory, arena: Allocator) !*Performance {
    return factory.eventTarget(Performance{
        ._proto = undefined,
        ._arena = arena,
        ._factory = factory,
        ._time_origin = highResTimestamp(),
    });
}

pub fn attach(self: *Performance, ctx: *js.Context) void {
    self._exec = &ctx.execution;
    self._scheduler = &ctx.scheduler;
}

pub fn asEventTarget(self: *Performance) *EventTarget {
    return self._proto;
}

pub fn getTiming(self: *Performance) *PerformanceTiming {
    return &self._timing;
}

pub fn now(self: *const Performance) f64 {
    const current = highResTimestamp();
    const elapsed = current - self._time_origin;
    // Return as milliseconds with microsecond precision
    return @as(f64, @floatFromInt(elapsed)) / 1000.0;
}

pub fn getTimeOrigin(self: *const Performance) f64 {
    // Return as milliseconds
    return @as(f64, @floatFromInt(self._time_origin)) / 1000.0;
}

pub fn getNavigation(self: *Performance) *PerformanceNavigation {
    return &self._navigation;
}

pub fn getEventCounts(self: *Performance) *EventCounts {
    return &self._event_counts;
}

pub fn mark(
    self: *Performance,
    name: []const u8,
    _options: ?Mark.Options,
    exec: *const Execution,
) !*Mark {
    const opts = _options orelse Mark.Options{};
    const start_time = opts.startTime orelse self.now();
    const m = try Mark.init(name, opts.detail, start_time, exec);
    try self.insertOrdered(&self._entries, m._proto);
    try self.notifyObservers(m._proto);
    return m;
}

const MeasureOptionsOrStartMark = union(enum) {
    measure_options: Measure.Options,
    start_mark: []const u8,
};

pub fn measure(
    self: *Performance,
    name: []const u8,
    maybe_options_or_start: ?MeasureOptionsOrStartMark,
    maybe_end_mark: ?[]const u8,
    exec: *const Execution,
) !*Measure {
    if (maybe_options_or_start) |options_or_start| switch (options_or_start) {
        .measure_options => |options| {
            // Get start timestamp.
            const start_timestamp = blk: {
                if (options.start) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk 0.0;
            };

            // Get end timestamp.
            const end_timestamp = blk: {
                if (options.end) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                options.detail,
                start_timestamp,
                end_timestamp,
                options.duration,
                exec,
            );
            try self.insertOrdered(&self._entries, m._proto);
            try self.notifyObservers(m._proto);
            return m;
        },
        .start_mark => |start_mark| {
            // Get start timestamp.
            const start_timestamp = try self.getMarkTime(start_mark);
            // Get end timestamp.
            const end_timestamp = blk: {
                if (maybe_end_mark) |mark_name| {
                    break :blk try self.getMarkTime(mark_name);
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                null,
                start_timestamp,
                end_timestamp,
                null,
                exec,
            );
            try self.insertOrdered(&self._entries, m._proto);
            try self.notifyObservers(m._proto);
            return m;
        },
    };

    const m = try Measure.init(name, null, 0.0, self.now(), null, exec);
    try self.insertOrdered(&self._entries, m._proto);
    try self.notifyObservers(m._proto);
    return m;
}

pub fn clearMarks(self: *Performance, mark_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .mark and (mark_name == null or std.mem.eql(u8, entry._name, mark_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn clearMeasures(self: *Performance, measure_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .measure and (measure_name == null or std.mem.eql(u8, entry._name, measure_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn setResourceTimingBufferSize(self: *Performance, max_size: u32) void {
    self._resource_buffer_size = max_size;
}

pub fn clearResourceTimings(self: *Performance) void {
    self._resources.clearRetainingCapacity();
}

// All times are microseconds
pub const ResourceInfo = struct {
    name: []const u8,
    initiator: []const u8, // static string
    protocol: []const u8, // static string
    start: u64,
    redirect_start: u64, // 0 when the fetch wasn't redirected.
    redirect_end: u64,
    fetch_start: u64,
    dns_start: u64,
    dns_end: u64,
    connect_start: u64,
    connect_end: u64,
    secure_start: u64, // 0 unless the final hop was https.
    request_start: u64,
    response_start: u64,
    response_end: u64,
    transfer_size: u64,
    encoded_body_size: u64,
    decoded_body_size: u64,
    status: u16,
    content_type: []const u8, // unsafe to reference past the function call
    content_encoding: []const u8, // unsafe to reference past the function call
    from_cache: bool,
    // Every response in the chain was same-origin or carried a matching
    // Timing-Allow-Origin.
    timing_allow: bool,
};

pub fn addResource(self: *Performance, info: ResourceInfo) !void {
    const buffer_full = self._resources.items.len >= self._resource_buffer_size;
    if (buffer_full) {
        try self.scheduleBufferFull();
        if (self.hasObserverFor(.resource) == false) {
            return;
        }
    }

    const arena = self._arena;
    const allow = info.timing_allow;
    const redirected = allow and info.redirect_start != 0; // redirects only show with a TAO

    const start_time = self.relative(info.start);
    const response_end = self.relative(info.response_end);

    const rt = try self._factory.chained(.{
        Entry{
            ._start_time = start_time,
            ._duration = @max(response_end - start_time, 0),
            ._name = try arena.dupe(u8, info.name),
            ._type = undefined,
        },
        ResourceTiming{
            ._proto = undefined,
            ._initiator_type = info.initiator,
            ._next_hop_protocol = if (allow) info.protocol else "",
            ._delivery_type = if (allow and info.from_cache) "cache" else "",
            ._redirect_start = if (redirected) start_time else 0,
            ._redirect_end = if (redirected) self.relative(info.redirect_end) else 0,
            ._fetch_start = if (redirected) self.relative(info.fetch_start) else start_time,
            ._domain_lookup_start = self.gated(allow, info.dns_start),
            ._domain_lookup_end = self.gated(allow, info.dns_end),
            ._connect_start = self.gated(allow, info.connect_start),
            ._connect_end = self.gated(allow, info.connect_end),
            ._secure_connection_start = self.gated(allow, info.secure_start),
            ._request_start = self.gated(allow, info.request_start),
            ._response_start = self.gated(allow, info.response_start),
            ._response_end = response_end,
            ._transfer_size = if (allow) info.transfer_size else 0,
            ._encoded_body_size = if (allow) info.encoded_body_size else 0,
            ._decoded_body_size = if (allow) info.decoded_body_size else 0,
            ._response_status = if (allow) info.status else 0,
            ._content_type = if (allow) minimizeMimeType(info.content_type) else "",
            ._content_encoding = if (allow) contentEncoding(info.content_encoding) else "",
        },
    });
    rt._proto._type = .{ .resource = rt };
    // Observers see every entry; only the buffer has a cap.
    try self.notifyObservers(rt._proto);
    if (!buffer_full) {
        try self.insertOrdered(&self._resources, rt._proto);
    }
}

fn gated(self: *const Performance, allow: bool, micros: u64) f64 {
    return if (allow) self.relative(micros) else 0;
}

// https://mimesniff.spec.whatwg.org/#minimize-a-supported-mime-type
fn minimizeMimeType(header: []const u8) []const u8 {
    var buf: [255]u8 = undefined;
    const raw = std.mem.trim(u8, header[0 .. std.mem.indexOfScalar(u8, header, ';') orelse header.len], " \t");
    if (raw.len > buf.len) {
        return "";
    }
    const essence = std.ascii.lowerString(&buf, raw);
    if (javascript_mime_types.has(essence)) {
        return "text/javascript";
    }
    if (std.mem.eql(u8, essence, "application/json") or std.mem.eql(u8, essence, "text/json") or std.mem.endsWith(u8, essence, "+json")) {
        return "application/json";
    }
    if (std.mem.eql(u8, essence, "image/svg+xml")) {
        return "image/svg+xml";
    }
    if (std.mem.eql(u8, essence, "application/xml") or std.mem.eql(u8, essence, "text/xml") or std.mem.endsWith(u8, essence, "+xml")) {
        return "application/xml";
    }
    if (supported_mime_types.getIndex(essence)) |i| {
        return supported_mime_types.keys()[i];
    }
    return "";
}

// https://mimesniff.spec.whatwg.org/#javascript-mime-type
const javascript_mime_types = std.StaticStringMap(void).initComptime(.{
    .{ "application/ecmascript", {} },
    .{ "application/javascript", {} },
    .{ "application/x-ecmascript", {} },
    .{ "application/x-javascript", {} },
    .{ "text/ecmascript", {} },
    .{ "text/javascript", {} },
    .{ "text/javascript1.0", {} },
    .{ "text/javascript1.1", {} },
    .{ "text/javascript1.2", {} },
    .{ "text/javascript1.3", {} },
    .{ "text/javascript1.4", {} },
    .{ "text/javascript1.5", {} },
    .{ "text/jscript", {} },
    .{ "text/livescript", {} },
    .{ "text/x-ecmascript", {} },
    .{ "text/x-javascript", {} },
});

// What a browser renders or decodes, beyond the JS/JSON/XML families
// handled above.
const supported_mime_types = std.StaticStringMap(void).initComptime(.{
    .{ "text/html", {} },
    .{ "text/plain", {} },
    .{ "text/css", {} },
    .{ "text/csv", {} },
    .{ "text/vtt", {} },
    .{ "application/pdf", {} },
    .{ "application/octet-stream", {} },
    .{ "image/png", {} },
    .{ "image/apng", {} },
    .{ "image/jpeg", {} },
    .{ "image/jpg", {} },
    .{ "image/pjpeg", {} },
    .{ "image/gif", {} },
    .{ "image/webp", {} },
    .{ "image/avif", {} },
    .{ "image/bmp", {} },
    .{ "image/x-icon", {} },
    .{ "image/vnd.microsoft.icon", {} },
    .{ "font/woff", {} },
    .{ "font/woff2", {} },
    .{ "font/ttf", {} },
    .{ "font/otf", {} },
    .{ "audio/mpeg", {} },
    .{ "audio/mp4", {} },
    .{ "audio/ogg", {} },
    .{ "audio/wav", {} },
    .{ "audio/webm", {} },
    .{ "video/mp4", {} },
    .{ "video/webm", {} },
    .{ "video/ogg", {} },
});

// https://w3c.github.io/resource-timing/#dom-performanceresourcetiming-contentencoding
// A single registered coding is named; anything else is "@unknown", more
// than one is "multiple", none is "".
fn contentEncoding(header: []const u8) []const u8 {
    if (header.len == 0) {
        return "";
    }
    if (std.mem.indexOfScalar(u8, header, ',') != null) {
        return "multiple";
    }
    var buf: [8]u8 = undefined;
    const value = std.mem.trim(u8, header, " \t");
    if (value.len > buf.len) {
        return "@unknown";
    }
    return content_encodings.get(std.ascii.lowerString(&buf, value)) orelse "@unknown";
}

const content_encodings = std.StaticStringMap([]const u8).initComptime(.{
    .{ "br", "br" },
    .{ "dcb", "dcb" },
    .{ "dcz", "dcz" },
    .{ "deflate", "deflate" },
    .{ "gzip", "gzip" },
    .{ "zstd", "zstd" },
});

pub fn getEntries(self: *const Performance, exec: *const Execution) ![]const *Entry {
    return mergeOrdered(exec.local_arena, self._entries.items, self._resources.items);
}

pub fn getEntriesByType(self: *const Performance, entry_type: []const u8, exec: *const Execution) ![]const *Entry {
    const kind = Entry.Type.Enum.parse(entry_type) orelse return &.{};
    if (kind == .resource) {
        return self._resources.items;
    }
    return filterEntriesByType(exec.local_arena, self._entries.items, kind);
}

pub fn getEntriesByName(self: *const Performance, name: []const u8, entry_type: ?[]const u8, exec: *const Execution) ![]const *Entry {
    const arena = exec.local_arena;
    if (entry_type) |t| {
        const kind = Entry.Type.Enum.parse(t) orelse return &.{};
        const list = if (kind == .resource) self._resources.items else self._entries.items;
        return filterEntriesByName(arena, list, name, kind);
    }
    return mergeOrdered(
        arena,
        try filterEntriesByName(arena, self._entries.items, name, null),
        try filterEntriesByName(arena, self._resources.items, name, null),
    );
}

// Also used by PerformanceObserver
pub fn filterEntriesByType(arena: Allocator, list: []const *Entry, kind: Entry.Type.Enum) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;
    for (list) |entry| {
        if (entry._type == kind) {
            try result.append(arena, entry);
        }
    }
    return result.items;
}

// Also used by PerformanceObserver
pub fn filterEntriesByName(arena: Allocator, list: []const *Entry, name: []const u8, kind: ?Entry.Type.Enum) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;
    for (list) |entry| {
        if (!std.mem.eql(u8, entry._name, name)) {
            continue;
        }
        if (kind == null or entry._type == kind.?) {
            try result.append(arena, entry);
        }
    }
    return result.items;
}

fn getMarkTime(self: *const Performance, mark_name: []const u8) !f64 {
    for (self._entries.items) |entry| {
        if (entry._type == .mark and std.mem.eql(u8, entry._name, mark_name)) {
            return entry._start_time;
        }
    }

    // PerformanceTiming attribute names are valid start/end marks per the
    // W3C User Timing Level 2 spec. All are relative to navigationStart (= 0).
    // https://www.w3.org/TR/user-timing/#dom-performance-measure
    //
    // `navigationStart` is an equivalent to 0.
    // Others are dependant to request arrival, end of request etc, but we
    // return a dummy 0 value for now.
    const navigation_timing_marks = std.StaticStringMap(void).initComptime(.{
        .{ "navigationStart", {} },
        .{ "unloadEventStart", {} },
        .{ "unloadEventEnd", {} },
        .{ "redirectStart", {} },
        .{ "redirectEnd", {} },
        .{ "fetchStart", {} },
        .{ "domainLookupStart", {} },
        .{ "domainLookupEnd", {} },
        .{ "connectStart", {} },
        .{ "connectEnd", {} },
        .{ "secureConnectionStart", {} },
        .{ "requestStart", {} },
        .{ "responseStart", {} },
        .{ "responseEnd", {} },
        .{ "domLoading", {} },
        .{ "domInteractive", {} },
        .{ "domContentLoadedEventStart", {} },
        .{ "domContentLoadedEventEnd", {} },
        .{ "domComplete", {} },
        .{ "loadEventStart", {} },
        .{ "loadEventEnd", {} },
    });
    if (navigation_timing_marks.has(mark_name)) {
        return 0;
    }

    return error.SyntaxError; // Mark not found
}

pub fn registerObserver(self: *Performance, observer: *PerformanceObserver) !void {
    for (self._observers.items) |o| {
        if (o == observer) {
            return;
        }
    }
    return self._observers.append(self._arena, observer);
}

pub fn unregisterObserver(self: *Performance, observer: *PerformanceObserver) void {
    if (self._delivering) {
        return;
    }
    for (self._observers.items, 0..) |o, i| {
        if (o == observer) {
            _ = self._observers.swapRemove(i);
            return;
        }
    }
}

/// Append the entry to every interested observer's queue and schedule async
/// delivery. Does NOT fire the callbacks synchronously — that happens later
/// via the scheduled task.
fn notifyObservers(self: *Performance, entry: *Entry) !void {
    if (self._observers.items.len == 0) {
        return;
    }
    for (self._observers.items) |observer| {
        if (observer.interested(entry)) {
            observer._entries.append(observer._arena, entry) catch |err| {
                lp.log.err(.frame, "Performance.notifyObservers", .{ .err = err });
            };
        }
    }

    try self.scheduleDelivery();
}

fn hasObserverFor(self: *const Performance, kind: Entry.Type.Enum) bool {
    for (self._observers.items) |observer| {
        if (observer.interestedIn(kind)) {
            return true;
        }
    }
    return false;
}

// https://w3c.github.io/resource-timing/#dfn-fire-a-buffer-full-event
// The event is queued rather than fired inline: addResource runs from the
// HTTP layer, with no JS on the stack. We have no secondary buffer, so an
// entry that overflows is dropped instead of being copied back in by a
// handler that calls clearResourceTimings.
fn scheduleBufferFull(self: *Performance) !void {
    if (self._buffer_full_pending) {
        return;
    }
    if (self._exec.hasDirectListeners(self.asEventTarget(), BUFFER_FULL, self._on_buffer_full) == false) {
        return;
    }
    self._buffer_full_pending = true;

    return self._scheduler.add(
        self,
        struct {
            fn run(_self: *anyopaque) anyerror!?u32 {
                const perf: *Performance = @ptrCast(@alignCast(_self));
                perf._buffer_full_pending = false;

                const exec = perf._exec;
                const event = try Event.initTrusted(.wrap(BUFFER_FULL), .{}, exec.page);
                try exec.dispatch(perf.asEventTarget(), event, perf._on_buffer_full, .{
                    .context = "Performance.resourcetimingbufferfull",
                });
                return null;
            }
        }.run,
        0,
        .{ .name = "Performance.bufferFull" },
    );
}

// The property handler for a JS-side dispatchEvent (see EventManager.dispatch).
pub fn inlineHandler(self: *const Performance, typ: lp.String) ?js.Function.Global {
    if (typ.eql(.wrap(BUFFER_FULL))) return self._on_buffer_full;
    return null;
}

pub fn getOnResourceTimingBufferFull(self: *const Performance) ?js.Function.Global {
    return self._on_buffer_full;
}

pub fn setOnResourceTimingBufferFull(self: *Performance, cb: ?js.Function.Global) void {
    self._on_buffer_full = cb;
}

pub fn scheduleDelivery(self: *Performance) !void {
    if (self._delivery_scheduled) {
        return;
    }
    self._delivery_scheduled = true;

    return self._scheduler.add(
        self,
        struct {
            fn run(_self: *anyopaque) anyerror!?u32 {
                const perf: *Performance = @ptrCast(@alignCast(_self));
                perf._delivery_scheduled = false;
                perf._delivering = true;

                defer {
                    perf._delivering = false;
                    var observers = &perf._observers;
                    var i: usize = 0;
                    while (i < observers.items.len) {
                        if (observers.items[i]._interests == 0) {
                            // it was disconencted while we ran, dangerous to
                            // remove while running, remove it now.
                            _ = observers.swapRemove(i);
                        } else {
                            i += 1;
                        }
                    }
                }

                var i: usize = 0;
                while (i < perf._observers.items.len) : (i += 1) {
                    const observer = perf._observers.items[i];
                    if (observer.hasRecords()) {
                        try observer.dispatch();
                    }
                }
                return null;
            }
        }.run,
        0,
        .{ .name = "Performance.deliverObservers" },
    );
}

// Entries nearly always arrive in startTime order, so the slot is at (or near)
// the end.
fn insertOrdered(self: *Performance, list: *std.ArrayList(*Entry), entry: *Entry) !void {
    var i = list.items.len;
    while (i > 0 and list.items[i - 1]._start_time > entry._start_time) : (i -= 1) {}
    try list.insert(self._arena, i, entry);
}

// Merge two startTime-ordered lists into one.
fn mergeOrdered(arena: Allocator, a: []const *Entry, b: []const *Entry) ![]const *Entry {
    if (a.len == 0) {
        return b;
    }
    if (b.len == 0) {
        return a;
    }

    var i: usize = 0;
    var j: usize = 0;
    var k: usize = 0;
    const out = try arena.alloc(*Entry, a.len + b.len);
    while (i < a.len and j < b.len) : (k += 1) {
        if (b[j]._start_time < a[i]._start_time) {
            out[k] = b[j];
            j += 1;
        } else {
            out[k] = a[i];
            i += 1;
        }
    }
    @memcpy(out[k .. k + a.len - i], a[i..]);
    k += a.len - i;
    @memcpy(out[k..], b[j..]);
    return out;
}

// Milliseconds since the time origin, rounded like highResTimestamp
fn relative(self: *const Performance, micros: u64) f64 {
    if (micros == 0) {
        return 0;
    }
    const elapsed = micros -| self._time_origin;
    const rounded = @divTrunc(elapsed + 2, 5) * 5;
    return @as(f64, @floatFromInt(rounded)) / 1000.0;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Performance);

    pub const Meta = struct {
        pub const name = "Performance";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const now = bridge.function(Performance.now, .{});
    pub const mark = bridge.function(Performance.mark, .{});
    pub const measure = bridge.function(Performance.measure, .{});
    pub const clearMarks = bridge.function(Performance.clearMarks, .{});
    pub const clearMeasures = bridge.function(Performance.clearMeasures, .{});
    pub const setResourceTimingBufferSize = bridge.function(Performance.setResourceTimingBufferSize, .{});
    pub const clearResourceTimings = bridge.function(Performance.clearResourceTimings, .{});
    pub const getEntries = bridge.function(Performance.getEntries, .{});
    pub const getEntriesByType = bridge.function(Performance.getEntriesByType, .{});
    pub const getEntriesByName = bridge.function(Performance.getEntriesByName, .{});
    pub const timeOrigin = bridge.accessor(Performance.getTimeOrigin, null, .{});
    pub const timing = bridge.accessor(Performance.getTiming, null, .{ .exposed = .window });
    pub const navigation = bridge.accessor(Performance.getNavigation, null, .{ .exposed = .window });
    pub const eventCounts = bridge.accessor(Performance.getEventCounts, null, .{ .exposed = .window });
    pub const onresourcetimingbufferfull = bridge.accessor(Performance.getOnResourceTimingBufferFull, Performance.setOnResourceTimingBufferFull, .{});
};

pub const Entry = struct {
    _duration: f64 = 0.0,
    _type: Type,
    _name: []const u8,
    _start_time: f64 = 0.0,

    pub const Type = union(Enum) {
        element,
        event,
        first_input,
        @"largest-contentful-paint",
        @"layout-shift",
        @"long-animation-frame",
        longtask,
        measure: *Measure,
        navigation,
        paint,
        resource: *ResourceTiming,
        taskattribution,
        @"visibility-state",
        mark: *Mark,

        pub const Enum = enum(u8) {
            element = 1, // Changing this affect PerformanceObserver's behavior.
            event = 2,
            first_input = 3,
            @"largest-contentful-paint" = 4,
            @"layout-shift" = 5,
            @"long-animation-frame" = 6,
            longtask = 7,
            measure = 8,
            navigation = 9,
            paint = 10,
            resource = 11,
            taskattribution = 12,
            @"visibility-state" = 13,
            mark = 14,
            // If we ever have types more than 16, we have to update entry
            // table of PerformanceObserver too.

            // The JS entryType string, e.g. "resource"; null for a type we
            // don't know (the getters then return nothing).
            pub fn parse(entry_type: []const u8) ?Enum {
                return std.meta.stringToEnum(Enum, entry_type);
            }
        };
    };

    pub fn getDuration(self: *const Entry) f64 {
        return self._duration;
    }

    pub fn getEntryType(self: *const Entry) []const u8 {
        return switch (self._type) {
            else => |t| @tagName(t),
        };
    }

    pub fn getName(self: *const Entry) []const u8 {
        return self._name;
    }

    pub fn getStartTime(self: *const Entry) f64 {
        return self._start_time;
    }

    pub fn toJSON(self: *const Entry) struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
    } {
        return .{
            .name = self._name,
            .entryType = self.getEntryType(),
            .startTime = self._start_time,
            .duration = self._duration,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Entry);

        pub const Meta = struct {
            pub const name = "PerformanceEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(Entry.getName, null, .{});
        pub const duration = bridge.accessor(Entry.getDuration, null, .{});
        pub const entryType = bridge.accessor(Entry.getEntryType, null, .{});
        pub const startTime = bridge.accessor(Entry.getStartTime, null, .{});
        pub const toJSON = bridge.function(Entry.toJSON, .{});
    };
};

pub const Mark = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        startTime: ?f64 = null,
    };

    pub fn init(name: []const u8, maybe_detail: ?js.Value, start_time: f64, exec: *const Execution) !*Mark {
        if (start_time < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try exec._factory.chained(.{
            Entry{
                ._start_time = start_time,
                ._name = try exec.dupeString(name),
                ._type = undefined,
            },
            Mark{
                ._proto = undefined,
                ._detail = detail,
            },
        });
        m._proto._type = .{ .mark = m };
        return m;
    }

    pub fn getDetail(self: *const Mark) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Mark);

        pub const Meta = struct {
            pub const name = "PerformanceMark";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Mark.getDetail, null, .{});
    };
};

pub const Measure = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        duration: ?f64 = null,
        end: ?TimestampOrMark,
        start: ?TimestampOrMark,

        const TimestampOrMark = union(enum) {
            timestamp: f64,
            mark: []const u8,
        };
    };

    pub fn init(
        name: []const u8,
        maybe_detail: ?js.Value,
        start_timestamp: f64,
        end_timestamp: f64,
        maybe_duration: ?f64,
        exec: *const Execution,
    ) !*Measure {
        const duration = maybe_duration orelse (end_timestamp - start_timestamp);
        if (duration < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try exec._factory.chained(.{
            Entry{
                ._start_time = start_timestamp,
                ._duration = duration,
                ._name = try exec.dupeString(name),
                ._type = undefined,
            },
            Measure{
                ._proto = undefined,
                ._detail = detail,
            },
        });
        m._proto._type = .{ .measure = m };
        return m;
    }

    pub fn getDetail(self: *const Measure) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Measure);

        pub const Meta = struct {
            pub const name = "PerformanceMeasure";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Measure.getDetail, null, .{});
    };
};

/// PerformanceResourceTiming — one per fetch the HTTP client completed for
/// this document (or worker).
pub const ResourceTiming = struct {
    pub const Proto = Entry;

    _proto: *Entry,
    _initiator_type: []const u8,
    _next_hop_protocol: []const u8,
    _delivery_type: []const u8,
    _redirect_start: f64,
    _redirect_end: f64,
    _fetch_start: f64,
    _domain_lookup_start: f64,
    _domain_lookup_end: f64,
    _connect_start: f64,
    _connect_end: f64,
    _secure_connection_start: f64,
    _request_start: f64,
    _response_start: f64,
    _response_end: f64,
    _transfer_size: u64,
    _encoded_body_size: u64,
    _decoded_body_size: u64,
    _response_status: u16,
    _content_type: []const u8,
    _content_encoding: []const u8,

    pub fn getInitiatorType(self: *const ResourceTiming) []const u8 {
        return self._initiator_type;
    }

    pub fn getNextHopProtocol(self: *const ResourceTiming) []const u8 {
        return self._next_hop_protocol;
    }

    pub fn getDeliveryType(self: *const ResourceTiming) []const u8 {
        return self._delivery_type;
    }

    pub fn getWorkerStart(_: *const ResourceTiming) f64 {
        // @ServiceWorker
        return 0;
    }

    pub fn getRedirectStart(self: *const ResourceTiming) f64 {
        return self._redirect_start;
    }

    pub fn getRedirectEnd(self: *const ResourceTiming) f64 {
        return self._redirect_end;
    }

    pub fn getFetchStart(self: *const ResourceTiming) f64 {
        return self._fetch_start;
    }

    pub fn getDomainLookupStart(self: *const ResourceTiming) f64 {
        return self._domain_lookup_start;
    }

    pub fn getDomainLookupEnd(self: *const ResourceTiming) f64 {
        return self._domain_lookup_end;
    }

    pub fn getConnectStart(self: *const ResourceTiming) f64 {
        return self._connect_start;
    }

    pub fn getConnectEnd(self: *const ResourceTiming) f64 {
        return self._connect_end;
    }

    pub fn getSecureConnectionStart(self: *const ResourceTiming) f64 {
        return self._secure_connection_start;
    }

    pub fn getRequestStart(self: *const ResourceTiming) f64 {
        return self._request_start;
    }

    pub fn getResponseStart(self: *const ResourceTiming) f64 {
        return self._response_start;
    }

    pub fn getResponseEnd(self: *const ResourceTiming) f64 {
        return self._response_end;
    }

    pub fn getFirstInterimResponseStart(_: *const ResourceTiming) f64 {
        // 1xx are consumed by libcurl
        return 0;
    }

    pub fn getFinalResponseHeadersStart(self: *const ResourceTiming) f64 {
        return self._response_start;
    }

    pub fn getTransferSize(self: *const ResourceTiming) u64 {
        return self._transfer_size;
    }

    pub fn getEncodedBodySize(self: *const ResourceTiming) u64 {
        return self._encoded_body_size;
    }

    pub fn getDecodedBodySize(self: *const ResourceTiming) u64 {
        return self._decoded_body_size;
    }

    pub fn getResponseStatus(self: *const ResourceTiming) u16 {
        return self._response_status;
    }

    pub fn getContentType(self: *const ResourceTiming) []const u8 {
        return self._content_type;
    }

    pub fn getContentEncoding(self: *const ResourceTiming) []const u8 {
        return self._content_encoding;
    }

    pub fn toJSON(self: *const ResourceTiming) struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
        initiatorType: []const u8,
        nextHopProtocol: []const u8,
        deliveryType: []const u8,
        workerStart: f64,
        redirectStart: f64,
        redirectEnd: f64,
        fetchStart: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        connectStart: f64,
        connectEnd: f64,
        secureConnectionStart: f64,
        requestStart: f64,
        responseStart: f64,
        firstInterimResponseStart: f64,
        finalResponseHeadersStart: f64,
        responseEnd: f64,
        transferSize: u64,
        encodedBodySize: u64,
        decodedBodySize: u64,
        responseStatus: u16,
        contentType: []const u8,
        contentEncoding: []const u8,
    } {
        const entry = self._proto;
        return .{
            .name = entry._name,
            .entryType = entry.getEntryType(),
            .startTime = entry._start_time,
            .duration = entry._duration,
            .initiatorType = self._initiator_type,
            .nextHopProtocol = self._next_hop_protocol,
            .deliveryType = self._delivery_type,
            .workerStart = 0,
            .redirectStart = self._redirect_start,
            .redirectEnd = self._redirect_end,
            .fetchStart = self._fetch_start,
            .domainLookupStart = self._domain_lookup_start,
            .domainLookupEnd = self._domain_lookup_end,
            .connectStart = self._connect_start,
            .connectEnd = self._connect_end,
            .secureConnectionStart = self._secure_connection_start,
            .requestStart = self._request_start,
            .responseStart = self._response_start,
            .firstInterimResponseStart = 0,
            .finalResponseHeadersStart = self._response_start,
            .responseEnd = self._response_end,
            .transferSize = self._transfer_size,
            .encodedBodySize = self._encoded_body_size,
            .decodedBodySize = self._decoded_body_size,
            .responseStatus = self._response_status,
            .contentType = self._content_type,
            .contentEncoding = self._content_encoding,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResourceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceResourceTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const initiatorType = bridge.accessor(ResourceTiming.getInitiatorType, null, .{});
        pub const nextHopProtocol = bridge.accessor(ResourceTiming.getNextHopProtocol, null, .{});
        pub const deliveryType = bridge.accessor(ResourceTiming.getDeliveryType, null, .{});
        pub const workerStart = bridge.accessor(ResourceTiming.getWorkerStart, null, .{});
        pub const redirectStart = bridge.accessor(ResourceTiming.getRedirectStart, null, .{});
        pub const redirectEnd = bridge.accessor(ResourceTiming.getRedirectEnd, null, .{});
        pub const fetchStart = bridge.accessor(ResourceTiming.getFetchStart, null, .{});
        pub const domainLookupStart = bridge.accessor(ResourceTiming.getDomainLookupStart, null, .{});
        pub const domainLookupEnd = bridge.accessor(ResourceTiming.getDomainLookupEnd, null, .{});
        pub const connectStart = bridge.accessor(ResourceTiming.getConnectStart, null, .{});
        pub const connectEnd = bridge.accessor(ResourceTiming.getConnectEnd, null, .{});
        pub const secureConnectionStart = bridge.accessor(ResourceTiming.getSecureConnectionStart, null, .{});
        pub const requestStart = bridge.accessor(ResourceTiming.getRequestStart, null, .{});
        pub const responseStart = bridge.accessor(ResourceTiming.getResponseStart, null, .{});
        pub const firstInterimResponseStart = bridge.accessor(ResourceTiming.getFirstInterimResponseStart, null, .{});
        pub const finalResponseHeadersStart = bridge.accessor(ResourceTiming.getFinalResponseHeadersStart, null, .{});
        pub const responseEnd = bridge.accessor(ResourceTiming.getResponseEnd, null, .{});
        pub const transferSize = bridge.accessor(ResourceTiming.getTransferSize, null, .{});
        pub const encodedBodySize = bridge.accessor(ResourceTiming.getEncodedBodySize, null, .{});
        pub const decodedBodySize = bridge.accessor(ResourceTiming.getDecodedBodySize, null, .{});
        pub const responseStatus = bridge.accessor(ResourceTiming.getResponseStatus, null, .{});
        pub const contentType = bridge.accessor(ResourceTiming.getContentType, null, .{});
        pub const contentEncoding = bridge.accessor(ResourceTiming.getContentEncoding, null, .{});
        pub const toJSON = bridge.function(ResourceTiming.toJSON, .{});
    };
};

/// PerformanceTiming — Navigation Timing Level 1 (legacy, but widely used).
/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceTiming
/// All properties return 0 as stub values; the object must not be undefined
/// so that scripts accessing performance.timing.navigationStart don't crash.
pub const PerformanceTiming = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer collisions.
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const navigationStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const unloadEventStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const unloadEventEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const fetchStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const domainLookupStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const domainLookupEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const connectStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const connectEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const secureConnectionStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const requestStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const responseStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const responseEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const domLoading = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const domInteractive = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const domContentLoadedEventStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const domContentLoadedEventEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const domComplete = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const loadEventStart = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const loadEventEnd = bridge.property(0.0, .{ .template = false, .readonly = true });
    };
};

// PerformanceNavigation implements the Navigation Timing Level 1 API.
// https://www.w3.org/TR/navigation-timing/#sec-navigation-navigation-timing-interface
// Stub implementation — returns 0 for type (TYPE_NAVIGATE) and 0 for redirectCount.
pub const PerformanceNavigation = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer collisions.
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceNavigation);

        pub const Meta = struct {
            pub const name = "PerformanceNavigation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const @"type" = bridge.property(0.0, .{ .template = false, .readonly = true });
        pub const redirectCount = bridge.property(0.0, .{ .template = false, .readonly = true });
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Performance" {
    try testing.htmlRunner("performance.html", .{});
}

test "WebApi: Performance.resource_timing" {
    try testing.htmlRunner("performance_resource_timing.html", .{});
    try testing.htmlRunner("performance_resource_timing_buffer.html", .{});
    try testing.htmlRunner("performance_resource_timing_buffer_full.html", .{});
}

test "Performance: minimizeMimeType" {
    // The WPT table: /mimesniff/mime-types/resources/mime-types-minimized.json
    const cases = [_][2][]const u8{
        .{ "application/ecmascript", "text/javascript" },
        .{ "text/javascript1.5", "text/javascript" },
        .{ "text/jscript", "text/javascript" },
        .{ "text/json", "application/json" },
        .{ "application/ld+json", "application/json" },
        .{ "image/svg+xml", "image/svg+xml" },
        .{ " Text/HTML; charset=utf-8", "text/html" },
        .{ "APPLICATION/X-JAVASCRIPT;x=1", "text/javascript" },
        .{ "text/xml", "application/xml" },
        .{ "application/xhtml+xml", "application/xml" },
        .{ "image/png", "image/png" },
        .{ "text/html", "text/html" },
        .{ "font/woff2", "font/woff2" },
        .{ "image/jpe", "" },
        .{ "application/png", "" },
        .{ "random/png", "" },
        .{ "", "" },
    };
    for (cases) |case| {
        try testing.expectEqual(case[1], minimizeMimeType(case[0]));
    }
}

test "Performance: contentEncoding" {
    try testing.expectEqual("", contentEncoding(""));
    try testing.expectEqual("gzip", contentEncoding("gzip"));
    try testing.expectEqual("br", contentEncoding(" BR "));
    try testing.expectEqual("zstd", contentEncoding("zstd"));
    try testing.expectEqual("@unknown", contentEncoding("identity"));
    try testing.expectEqual("@unknown", contentEncoding("unrecognizedname"));
    try testing.expectEqual("multiple", contentEncoding("gzip, deflate,Apple"));
}
