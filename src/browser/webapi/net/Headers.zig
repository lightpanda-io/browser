const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Mime = @import("../../Mime.zig");

const KeyValueList = @import("../KeyValueList.zig");

const log = lp.log;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const Headers = @This();

pub fn registerTypes() []const type {
    return &.{
        Headers,
        KeyIterator,
        ValueIterator,
        EntryIterator,
    };
}

_list: KeyValueList,
_guard: Guard = .none,

// What mutation JS can make
pub const Guard = enum {
    none, // don't block anything
    request, // block forbidden request headers
    request_no_cors, // block anything but the no-cors safelist
    response, // block forbidden response headers
    immutable, // block everythig
};

pub const InitOpts = union(enum) {
    obj: *Headers,
    strings: []const [2][]const u8,
    js_obj: js.Object,
};

pub fn init(opts_: ?InitOpts, exec: *const Execution) !*Headers {
    return initGuarded(opts_, .none, exec);
}

pub fn initGuarded(opts_: ?InitOpts, guard: Guard, exec: *const Execution) !*Headers {
    var list = blk: {
        const opts = opts_ orelse break :blk KeyValueList.init();
        switch (opts) {
            .obj => |obj| break :blk try KeyValueList.copy(exec.arena, obj._list),
            .js_obj => |js_obj| {
                var list = try KeyValueList.fromJsObject(exec.arena, js_obj, normalizeHeaderName, exec.buf);
                try validateAndNormalize(&list);
                break :blk list;
            },
            .strings => |kvs| {
                var list = try KeyValueList.fromArray(exec.arena, kvs, normalizeHeaderName, exec.buf);
                try validateAndNormalize(&list);
                break :blk list;
            },
        }
    };

    if (guard == .response) {
        // easier to use the KVL's creation upfront and then strip these out
        list.delete("set-cookie", null);
        list.delete("set-cookie2", null);
    }

    const self = try exec._factory.create(Headers{
        ._list = list,
        ._guard = guard,
    });

    if (guard == .request or guard == .request_no_cors) {
        var i: usize = 0;
        const list_entries = &self._list._entries;
        while (i < list_entries.items.len) {
            const entry = &list_entries.items[i];
            if (try self.checkGuard(entry.name.str(), entry.value.str()) == .ignore) {
                _ = list_entries.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    return self;
}

pub fn isForbiddenResponseHeaderName(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "set-cookie")) {
        return true;
    }

    if (std.ascii.eqlIgnoreCase(name, "set-cookie2")) {
        // yup, this is a real, never used / deprecated, header
        return true;
    }

    return false;
}

const Mutation = enum { proceed, ignore };

fn checkGuard(self: *const Headers, name: []const u8, value: ?[]const u8) !Mutation {
    const allowed = switch (self._guard) {
        .none => true,
        .immutable => return error.TypeError,
        .request => isForbiddenRequestHeader(name, value orelse "") == false,
        .request_no_cors => if (value) |v|
            isNoCorsSafelistedRequestHeader(name, v)
        else
            isNoCorsSafelistedRequestHeaderName(name) or isPrivilegedNoCorsRequestHeaderName(name),
        .response => isForbiddenResponseHeaderName(name) == false,
    };
    return if (allowed) .proceed else .ignore;
}

// https://fetch.spec.whatwg.org/#forbidden-request-header
fn isForbiddenRequestHeader(name: []const u8, value: []const u8) bool {
    const Set = std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase);
    const forbidden = Set.initComptime(.{
        .{"accept-charset"},                 .{"accept-encoding"},
        .{"access-control-request-headers"}, .{"access-control-request-method"},
        .{"connection"},                     .{"content-length"},
        .{"cookie"},                         .{"cookie2"},
        .{"date"},                           .{"dnt"},
        .{"expect"},                         .{"host"},
        .{"keep-alive"},                     .{"origin"},
        .{"referer"},                        .{"set-cookie"},
        .{"te"},                             .{"trailer"},
        .{"transfer-encoding"},              .{"upgrade"},
        .{"via"},
    });
    if (forbidden.has(name)) {
        return true;
    }

    if (std.ascii.startsWithIgnoreCase(name, "proxy-") or std.ascii.startsWithIgnoreCase(name, "sec-")) {
        return true;
    }

    const Overrides = std.StaticStringMapWithEql(void, std.static_string_map.eqlAsciiIgnoreCase);
    const overrides = Overrides.initComptime(.{
        .{"x-http-method"}, .{"x-http-method-override"}, .{"x-method-override"},
    });
    if (overrides.has(name) == false) {
        return false;
    }

    // value is a method override list.
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |part| {
        const method = std.mem.trim(u8, part, &Mime.HTTP_WHITESPACE);
        if (std.ascii.eqlIgnoreCase(method, "connect")) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(method, "trace")) {
            return true;
        }
        if (std.ascii.eqlIgnoreCase(method, "track")) {
            return true;
        }
    }
    return false;
}

// https://fetch.spec.whatwg.org/#no-cors-safelisted-request-header-name
fn isNoCorsSafelistedRequestHeaderName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "accept") or
        std.ascii.eqlIgnoreCase(name, "accept-language") or
        std.ascii.eqlIgnoreCase(name, "content-language") or
        std.ascii.eqlIgnoreCase(name, "content-type");
}

// https://fetch.spec.whatwg.org/#privileged-no-cors-request-header-name
fn isPrivilegedNoCorsRequestHeaderName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "range") or std.ascii.eqlIgnoreCase(name, "authorization");
}

// https://fetch.spec.whatwg.org/#no-cors-safelisted-request-header
fn isNoCorsSafelistedRequestHeader(name: []const u8, value: []const u8) bool {
    if (value.len > 128) {
        return false;
    }

    if (std.ascii.eqlIgnoreCase(name, "accept")) {
        return hasCorsUnsafeByte(value) == false;
    }

    if (std.ascii.eqlIgnoreCase(name, "accept-language") or std.ascii.eqlIgnoreCase(name, "content-language")) {
        for (value) |c| switch (c) {
            '0'...'9', 'A'...'Z', 'a'...'z', ' ', '*', ',', '-', '.', ';', '=' => {},
            else => return false,
        };
        return true;
    }

    if (std.ascii.eqlIgnoreCase(name, "content-type") == false) {
        return false;
    }

    if (hasCorsUnsafeByte(value)) {
        return false;
    }

    // Only the essence matters, and only these three are safelisted. Anything
    // that doesn't parse as a mime type can't match one of them.
    const essence = std.mem.trim(u8, std.mem.sliceTo(value, ';'), &Mime.HTTP_WHITESPACE);
    return std.ascii.eqlIgnoreCase(essence, "application/x-www-form-urlencoded") or
        std.ascii.eqlIgnoreCase(essence, "multipart/form-data") or
        std.ascii.eqlIgnoreCase(essence, "text/plain");
}

// https://fetch.spec.whatwg.org/#cors-unsafe-request-header-byte
fn hasCorsUnsafeByte(value: []const u8) bool {
    for (value) |c| switch (c) {
        0x00...0x08, 0x0a...0x1f => return true,
        '"', '(', ')', ':', '<', '>', '?', '@', '[', '\\', ']', '{', '}', 0x7f => return true,
        else => {},
    };
    return false;
}

pub fn append(self: *Headers, name: []const u8, value: []const u8, exec: *const Execution) !void {
    const normalized_name = try validateAndNormalizeName(name, exec);
    const normalized_value = try normalizeValue(value, exec);

    // The guard sees the combined value, since that's what a get would return
    // once this append lands.
    const combined = if (self._guard == .request_no_cors) blk: {
        const existing = try self.get(normalized_name, exec) orelse break :blk normalized_value;
        break :blk try std.mem.join(exec.local_arena, ", ", &.{ existing, normalized_value });
    } else normalized_value;

    if (try self.checkGuard(normalized_name, combined) == .ignore) {
        return;
    }
    try self._list.append(exec.arena, normalized_name, normalized_value);
}

pub fn delete(self: *Headers, name: []const u8, exec: *const Execution) !void {
    const normalized_name = try validateAndNormalizeName(name, exec);
    if (try self.checkGuard(normalized_name, null) == .ignore) {
        return;
    }
    self._list.delete(normalized_name, null);
}

pub fn get(self: *const Headers, name: []const u8, exec: *const Execution) !?[]const u8 {
    const normalized_name = try validateAndNormalizeName(name, exec);
    const all_values = try self._list.getAll(exec.local_arena, normalized_name);

    if (all_values.len == 0) {
        return null;
    }
    if (all_values.len == 1) {
        return all_values[0];
    }
    return try std.mem.join(exec.local_arena, ", ", all_values);
}

pub fn getSetCookie(self: *const Headers, exec: *const Execution) ![]const []const u8 {
    return self._list.getAll(exec.local_arena, "set-cookie");
}

pub fn has(self: *const Headers, name: []const u8, exec: *const Execution) !bool {
    const normalized_name = try validateAndNormalizeName(name, exec);
    return self._list.has(normalized_name, null);
}

pub fn set(self: *Headers, name: []const u8, value_: []const u8, exec: *const Execution) !void {
    const normalized_name = try validateAndNormalizeName(name, exec);
    const value = try normalizeValue(value_, exec);
    if (try self.checkGuard(normalized_name, value) == .ignore) {
        return;
    }
    try self._list.set(exec.arena, normalized_name, value);
}

pub fn keys(self: *Headers, exec: *const js.Execution) !*KeyIterator {
    return KeyIterator.init(.{ .headers = self }, exec);
}

pub fn values(self: *Headers, exec: *const js.Execution) !*ValueIterator {
    return ValueIterator.init(.{ .headers = self }, exec);
}

pub fn entries(self: *Headers, exec: *const js.Execution) !*EntryIterator {
    return EntryIterator.init(.{ .headers = self }, exec);
}

pub fn forEach(self: *Headers, cb_: js.Function, js_this_: ?js.Object, exec: *const Execution) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    var it = Iterator{ .headers = self };
    while (try it.next(exec)) |entry| {
        var caught: js.TryCatch.Caught = .{};
        cb.tryCall(void, .{ entry.@"1", entry.@"0", self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "headers" });
        };
    }
}

// This is pretty brutal, but we need to sortAndCombine on each iteration in order
// to pick up any mutations. I'd be tempted to add a _generation: u32 to avoid
// needlessly doing this but (a) headers tend to be small and (b) not iterated
// that much..PLUS, we'd have to persist the view, and what memory would own that?
pub const Iterator = struct {
    index: u32 = 0,
    headers: *Headers,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn next(self: *Iterator, exec: *const Execution) !?Iterator.Entry {
        const view = try self.headers.sortAndCombine(exec.local_arena);
        const index = self.index;
        if (index >= view.len) {
            return null;
        }
        self.index = index + 1;
        return view[index];
    }
};

fn sortAndCombine(self: *const Headers, arena: Allocator) ![]Iterator.Entry {
    var out: std.ArrayList(Iterator.Entry) = try .initCapacity(arena, self._list._entries.items.len);
    for (self._list._entries.items) |*entry| {
        if (entry.name.eql(comptime .wrap("set-cookie")) == false) {
            // everything except set-cookie is concatenated together
            if (findEntry(out.items, entry.name)) |existing| {
                existing.@"1" = try std.mem.concat(arena, u8, &.{ existing.@"1", ", ", entry.value.str() });
                continue;
            }
        }
        out.appendAssumeCapacity(.{ entry.name.str(), entry.value.str() });
    }

    std.sort.insertion(Iterator.Entry, out.items, {}, struct {
        fn compare(_: void, a: Iterator.Entry, b: Iterator.Entry) bool {
            return std.mem.order(u8, a.@"0", b.@"0") == .lt;
        }
    }.compare);

    return out.items;
}

fn findEntry(view: []Iterator.Entry, name: lp.String) ?*Iterator.Entry {
    for (view) |*entry| {
        if (name.eqlSlice(entry.@"0")) {
            return entry;
        }
    }
    return null;
}

const GenericIterator = @import("../collections/iterator.zig").Entry;
pub const KeyIterator = GenericIterator(Iterator, "0");
pub const ValueIterator = GenericIterator(Iterator, "1");
pub const EntryIterator = GenericIterator(Iterator, null);

const HttpClient = @import("../../../network/HttpClient.zig");
pub fn populateRequestHeaders(self: *Headers, transfer: *HttpClient.Transfer) !void {
    for (self._list._entries.items) |entry| {
        try transfer.appendHeader(entry.name.str(), entry.value.str(), .{ .source = .author });
    }
}

fn validateAndNormalizeName(name: []const u8, exec: *const Execution) ![]const u8 {
    if (Mime.isHttpToken(name) == false) {
        return exec.js.typeError("Invalid header name");
    }
    return normalizeHeaderName(name, exec.buf);
}

fn normalizeHeaderName(name: []const u8, buf: []u8) []const u8 {
    if (name.len > buf.len) {
        return name;
    }
    return std.ascii.lowerString(buf, name);
}

fn normalizeValue(value: []const u8, exec: *const Execution) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, &Mime.HTTP_WHITESPACE);
    if (Mime.isHttpHeaderValue(trimmed) == false) {
        return exec.js.typeError("Invalid header value");
    }
    return trimmed;
}

/// Validate names and normalize/validate values for a script-provided header
/// init, trimming values in place. The trim is allocation-free (see
/// `String.trim`), so an untrimmed value keeps its original storage.
fn validateAndNormalize(list: *KeyValueList) !void {
    for (list._entries.items) |*entry| {
        // A valid header name is exactly a non-empty HTTP token.
        if (Mime.isHttpToken(entry.name.str()) == false) {
            return error.TypeError;
        }
        // A valid header value is a byte string without NUL, LF or CR.
        const trimmed = entry.value.trim(&Mime.HTTP_WHITESPACE);
        if (Mime.isHttpHeaderValue(trimmed.str()) == false) {
            return error.TypeError;
        }
        entry.value = trimmed;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Headers);

    pub const Meta = struct {
        pub const name = "Headers";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(Headers.init, .{});
    pub const append = bridge.function(Headers.append, .{});
    pub const delete = bridge.function(Headers.delete, .{});
    pub const get = bridge.function(Headers.get, .{});
    pub const getSetCookie = bridge.function(Headers.getSetCookie, .{});
    pub const has = bridge.function(Headers.has, .{});
    pub const set = bridge.function(Headers.set, .{});
    pub const keys = bridge.function(Headers.keys, .{});
    pub const values = bridge.function(Headers.values, .{});
    pub const entries = bridge.function(Headers.entries, .{});
    pub const symbol_iterator = bridge.iterator(Headers.entries, .{});
    pub const forEach = bridge.function(Headers.forEach, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Headers" {
    try testing.htmlRunner("net/headers.html", .{});
}
