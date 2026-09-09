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

    return exec._factory.create(Headers{
        ._list = list,
        ._guard = guard,
    });
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

fn checkGuard(self: *const Headers, name: []const u8) !Mutation {
    return switch (self._guard) {
        .none => .proceed,
        .immutable => error.TypeError,
        .response => if (isForbiddenResponseHeaderName(name)) .ignore else .proceed,
    };
}

pub fn append(self: *Headers, name: []const u8, value: []const u8, exec: *const Execution) !void {
    const normalized_name = try validateAndNormalizeName(name, exec);
    const normalized_value = try normalizeValue(value, exec);
    const mutation = try self.checkGuard(normalized_name);
    if (mutation == .ignore) {
        return;
    }
    try self._list.append(exec.arena, normalized_name, normalized_value);
}

pub fn delete(self: *Headers, name: []const u8, exec: *const Execution) !void {
    const normalized_name = try validateAndNormalizeName(name, exec);
    const mutation = try self.checkGuard(normalized_name);
    if (mutation == .ignore) {
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
    const mutation = try self.checkGuard(normalized_name);
    if (mutation == .ignore) {
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
