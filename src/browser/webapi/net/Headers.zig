const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Mime = @import("../../Mime.zig");

const KeyValueList = @import("../KeyValueList.zig");

const log = lp.log;
const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const Headers = @This();

_list: KeyValueList,

pub const InitOpts = union(enum) {
    obj: *Headers,
    strings: []const [2][]const u8,
    js_obj: js.Object,
};

pub fn init(opts_: ?InitOpts, exec: *const Execution) !*Headers {
    const list = blk: {
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

    return exec._factory.create(Headers{
        ._list = list,
    });
}

pub fn append(self: *Headers, name: []const u8, value: []const u8, exec: *const Execution) !void {
    const normalized_name = normalizeHeaderName(name, exec.buf);
    try self._list.append(exec.arena, normalized_name, value);
}

pub fn delete(self: *Headers, name: []const u8, exec: *const Execution) void {
    const normalized_name = normalizeHeaderName(name, exec.buf);
    self._list.delete(normalized_name, null);
}

pub fn get(self: *const Headers, name: []const u8, exec: *const Execution) !?[]const u8 {
    const normalized_name = normalizeHeaderName(name, exec.buf);
    const all_values = try self._list.getAll(exec.call_arena, normalized_name);

    if (all_values.len == 0) {
        return null;
    }
    if (all_values.len == 1) {
        return all_values[0];
    }
    return try std.mem.join(exec.call_arena, ", ", all_values);
}

pub fn has(self: *const Headers, name: []const u8, exec: *const Execution) bool {
    const normalized_name = normalizeHeaderName(name, exec.buf);
    return self._list.has(normalized_name);
}

pub fn set(self: *Headers, name: []const u8, value: []const u8, exec: *const Execution) !void {
    const normalized_name = normalizeHeaderName(name, exec.buf);
    try self._list.set(exec.arena, normalized_name, value);
}

pub fn keys(self: *Headers, exec: *const js.Execution) !*KeyValueList.KeyIterator {
    return KeyValueList.KeyIterator.init(.{ .list = self, .kv = &self._list }, exec);
}

pub fn values(self: *Headers, exec: *const js.Execution) !*KeyValueList.ValueIterator {
    return KeyValueList.ValueIterator.init(.{ .list = self, .kv = &self._list }, exec);
}

pub fn entries(self: *Headers, exec: *const js.Execution) !*KeyValueList.EntryIterator {
    return KeyValueList.EntryIterator.init(.{ .list = self, .kv = &self._list }, exec);
}

pub fn forEach(self: *Headers, cb_: js.Function, js_this_: ?js.Object) !void {
    const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;

    for (self._list._entries.items) |entry| {
        var caught: js.TryCatch.Caught = undefined;
        cb.tryCall(void, .{ entry.value.str(), entry.name.str(), self }, &caught) catch {
            log.debug(.js, "forEach callback", .{ .caught = caught, .source = "headers" });
        };
    }
}

// TODO: do we really need 2 different header structs??
const http = @import("../../../network/http.zig");
pub fn populateHttpHeader(self: *Headers, allocator: Allocator, http_headers: *http.Headers) !void {
    for (self._list._entries.items) |entry| {
        const merged = try std.mem.concatWithSentinel(allocator, u8, &.{ entry.name.str(), ": ", entry.value.str() }, 0);
        try http_headers.add(merged);
    }
}

fn normalizeHeaderName(name: []const u8, buf: []u8) []const u8 {
    if (name.len > buf.len) {
        return name;
    }
    return std.ascii.lowerString(buf, name);
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
        const trimmed = entry.value.trim(&Mime.HTTP_WHITESPACE);
        try validateHeaderValue(trimmed.str());
        entry.value = trimmed;
    }
}

/// Validate an already-normalized header value. Returns `error.TypeError` —
/// surfaced to script as a JS TypeError — when it contains a code point above
/// U+00FF (not a valid byte string) or a 0x00/0x0A/0x0D byte.
/// https://fetch.spec.whatwg.org/#headers-class
fn validateHeaderValue(value: []const u8) error{TypeError}!void {
    var i: usize = 0;
    while (i < value.len) {
        const n = std.unicode.utf8ByteSequenceLength(value[i]) catch return error.TypeError;
        if (i + n > value.len) {
            return error.TypeError;
        }

        const cp = std.unicode.utf8Decode(value[i..][0..n]) catch return error.TypeError;

        if (cp > 0xFF or cp == 0x00 or cp == 0x0A or cp == 0x0D) {
            return error.TypeError;
        }
        i += n;
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
    pub const has = bridge.function(Headers.has, .{});
    pub const set = bridge.function(Headers.set, .{});
    pub const keys = bridge.function(Headers.keys, .{});
    pub const values = bridge.function(Headers.values, .{});
    pub const entries = bridge.function(Headers.entries, .{});
    pub const forEach = bridge.function(Headers.forEach, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: Headers" {
    try testing.htmlRunner("net/headers.html", .{});
}
