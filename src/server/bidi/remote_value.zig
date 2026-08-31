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
// https://w3c.github.io/webdriver-bidi/#type-script-RemoteValue

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../browser/js/js.zig");
const Frame = @import("../../browser/Frame.zig");
const Node = @import("../../browser/webapi/Node.zig");
const Window = @import("../../browser/webapi/Window.zig");
const NodeList = @import("../../browser/webapi/collections/NodeList.zig");
const HTMLCollection = @import("../../browser/webapi/collections/HTMLCollection.zig");
const NodeRegistry = @import("../../NodeRegistry.zig");

const BiDi = @import("BiDi.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const Remote = struct {
    body: Body,

    // Only set when the command asked for resultOwnership: "root".
    handle: ?[]const u8 = null,

    pub fn jsonStringify(self: *const Remote, w: anytype) error{WriteFailed}!void {
        try w.beginObject();

        try w.objectField("type");
        try w.write(self.body.typeName());

        switch (self.body) {
            .undefined, .null, .other => {},
            .boolean => |v| {
                try w.objectField("value");
                try w.write(v);
            },
            .string, .bigint, .date => |v| {
                try w.objectField("value");
                try w.write(v);
            },
            .regexp => |v| {
                try w.objectField("value");
                try w.write(v);
            },
            .number => |v| {
                try w.objectField("value");
                switch (v) {
                    .special => |s| try w.write(s),
                    .integer => |i| try w.write(i),
                    .float => |f| try w.write(f),
                }
            },
            .array, .nodelist, .htmlcollection => |items| {
                try w.objectField("value");
                try w.beginArray();
                for (items) |*item| {
                    try item.jsonStringify(w);
                }
                try w.endArray();
            },
            .object => |properties| {
                // An object's value is a list of [key, value] pairs, not a
                // JSON object: BiDi keys aren't necessarily strings.
                try w.objectField("value");
                try w.beginArray();
                for (properties) |*property| {
                    try w.beginArray();
                    try w.write(property.name);
                    try property.value.jsonStringify(w);
                    try w.endArray();
                }
                try w.endArray();
            },
            .node => |*v| try v.writeNode(w),
        }

        if (self.handle) |handle| {
            try w.objectField("handle");
            try w.write(handle);
        }

        try w.endObject();
    }

    const Body = union(enum) {
        undefined,
        null,
        boolean: bool,
        number: Number,
        string: []const u8,
        bigint: []const u8,
        date: []const u8,
        regexp: RegExp,
        array: []const Remote,
        nodelist: []const Remote,
        htmlcollection: []const Remote,
        object: []const Property,
        node: NodeValue,
        other: []const u8,

        fn typeName(self: *const Body) []const u8 {
            return switch (self.*) {
                .other => |name| name,
                else => @tagName(self.*),
            };
        }
    };
};

const Number = union(enum) {
    float: f64,
    integer: i64,
    special: enum { NaN, Infinity, @"-Infinity", @"-0" },

    fn from(value: f64) Number {
        if (std.math.isNan(value)) {
            return .{ .special = .NaN };
        }
        if (std.math.isPositiveInf(value)) {
            return .{ .special = .Infinity };
        }
        if (std.math.isNegativeInf(value)) {
            return .{ .special = .@"-Infinity" };
        }
        if (value == 0 and std.math.signbit(value)) {
            return .{ .special = .@"-0" };
        }

        const max_safe_integer = 9007199254740991;
        if (@trunc(value) == value and @abs(value) <= max_safe_integer) {
            // Whole numbers go out as JSON integers, avoids 5e0 for 5.0
            return .{ .integer = @intFromFloat(value) };
        }
        return .{ .float = value };
    }
};

pub const Property = struct {
    name: []const u8,
    value: Remote,
};

pub const RegExp = struct {
    flags: []const u8,
    pattern: []const u8,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const NodeValue = struct {
    node_type: u8,
    shared_id: []const u8,
    child_node_count: usize,
    local_name: ?[]const u8 = null,
    namespace_uri: ?[]const u8 = null,
    node_value: ?[]const u8 = null,
    attributes: ?[]const Attribute = null,
    children: ?[]const Remote = null,

    fn writeNode(node: *const NodeValue, w: anytype) error{WriteFailed}!void {
        try w.objectField("sharedId");
        try w.write(node.shared_id);

        try w.objectField("value");
        try w.beginObject();

        try w.objectField("nodeType");
        try w.write(node.node_type);

        try w.objectField("childNodeCount");
        try w.write(node.child_node_count);

        if (node.local_name) |v| {
            try w.objectField("localName");
            try w.write(v);
        }
        if (node.namespace_uri) |v| {
            try w.objectField("namespaceURI");
            try w.write(v);
        }
        if (node.node_value) |v| {
            try w.objectField("nodeValue");
            try w.write(v);
        }
        if (node.attributes) |attributes| {
            try w.objectField("attributes");
            try w.beginObject();
            for (attributes) |attribute| {
                try w.objectField(attribute.name);
                try w.write(attribute.value);
            }
            try w.endObject();
        }
        if (node.children) |children| {
            try w.objectField("children");
            try w.beginArray();
            for (children) |*child| {
                try child.jsonStringify(w);
            }
            try w.endArray();
        }

        try w.endObject();
    }
};

pub const Handles = struct {
    next_id: u32 = 1,
    allocator: Allocator,
    // id => global,the id is the handleId that client can send back
    map: std.AutoHashMapUnmanaged(u32, js.Value.Global) = .empty,

    pub fn deinit(self: *Handles) void {
        self.releaseAll();
        self.map.deinit(self.allocator);
    }

    pub fn releaseAll(self: *Handles) void {
        var it = self.map.valueIterator();
        while (it.next()) |global| {
            global.deinit();
        }
        self.map.clearRetainingCapacity();
    }

    pub fn add(self: *Handles, value: js.Value) !u32 {
        const global = try value.persist();
        errdefer global.deinit();

        const id = self.next_id;
        try self.map.putNoClobber(self.allocator, id, global);
        self.next_id = id + 1;
        return id;
    }

    pub fn get(self: *const Handles, id: u32) ?js.Value.Global {
        return self.map.get(id);
    }

    pub fn release(self: *Handles, id: u32) void {
        const entry = self.map.fetchRemove(id) orelse return;
        entry.value.deinit();
    }
};

// input parameter that we JSON parse
pub const SerializationOptions = struct {
    maxDomDepth: ?u32 = 0,
    maxObjectDepth: ?u32 = null,
    includeShadowTree: enum { none, open, all } = .none,

    pub fn options(self: *const SerializationOptions, own_root: bool) Serializer.Options {
        return .{
            .own_root = own_root,
            .max_dom_depth = self.maxDomDepth,
            .max_object_depth = self.maxObjectDepth,
        };
    }
};

pub const Serializer = struct {
    arena: Allocator,
    frame: *Frame,
    local: *const js.Local,
    registry: *NodeRegistry,
    handles: *Handles,
    opts: Options,

    // The containers we're currently inside, so a cycle collapses to the bare
    // type instead of recursing forever (maxObjectDepth defaults to unlimited).
    // Locals, not globals: everything happens inside the caller's scope.
    seen: std.ArrayList(js.Object) = .empty,

    pub const Options = struct {
        // by default, a node serializes without its children
        max_dom_depth: ?u32 = 0,

        // but an object serializes without limit (all the way down)
        max_object_depth: ?u32 = null,

        // when resultOwnership == "root", we'll persist the value in our handles lookup
        own_root: bool = false,
    };

    pub fn init(bidi: *BiDi, arena: Allocator, frame: *Frame, local: *const js.Local, opts: Options) Serializer {
        return .{
            .frame = frame,
            .local = local,
            .arena = arena,
            .handles = &bidi.handles,
            .registry = &bidi.node_registry,
            .opts = opts,
        };
    }

    pub fn run(self: *Serializer, value: js.Value) !Remote {
        return self.remote(value, 0, self.opts.own_root);
    }

    // A node reached without going through JS (browsingContext.locateNodes).
    pub fn domNode(self: *Serializer, dom_node: *Node) !Remote {
        return .{ .body = .{ .node = try self.node(dom_node, 0) } };
    }

    const Error = error{
        OutOfMemory,
        InvalidArgument,
        TypeError,
        JsException,
        ExecutionTerminated,
        MethodNotFound,
        DeadFunctionHandle,
    };

    fn remote(self: *Serializer, value: js.Value, depth: u32, own: bool) Error!Remote {
        var handle_id: ?u32 = null;
        // The reply carries the handle; if serializing the body throws (a
        // throwing accessor, a Proxy trap) the client never learns it, so
        // don't keep the global alive.
        errdefer if (handle_id) |id| self.handles.release(id);

        // Symbols have identity, so the spec lets them carry a handle too.
        const handle: ?[]const u8 = if (own and (value.isObject() or value.isSymbol())) blk: {
            const id = try self.handles.add(value);
            handle_id = id;
            break :blk try std.fmt.allocPrint(self.arena, "{d}", .{id});
        } else null;

        return .{ .handle = handle, .body = try self.body(value, depth) };
    }

    // Ordered by how often each comes back from a driver: primitives, then
    // nodes and arrays, with the exotics probed last so a plain object doesn't
    // pay for them.
    fn body(self: *Serializer, value: js.Value, depth: u32) !Remote.Body {
        if (value.isUndefined()) {
            return .undefined;
        }
        if (value.isString() != null) {
            return .{ .string = try value.toStringSliceWithAlloc(self.arena) };
        }
        if (value.isNumber()) {
            return .{ .number = .from(try value.toF64()) };
        }
        if (value.isBoolean()) {
            return .{ .boolean = value.toBool() };
        }
        if (value.isNull()) {
            return .null;
        }
        if (value.isBigInt()) {
            return .{ .bigint = try value.toStringSliceWithAlloc(self.arena) };
        }
        if (value.isSymbol()) {
            return .{ .other = "symbol" };
        }

        if (value.isObject() == false) {
            // Should not be possible, we've exhausted every primitive. But,
            // let's be defensive here.
            log.warn(.bidi, "unexpected value type", .{});
            return .{ .other = "object" };
        }

        if (value.taggedOpaque()) |tao| {
            return self.platform(tao, depth);
        }

        const object = value.toObject();
        if (value.isArray()) {
            if (self.isTooDeep(depth) or self.isSeen(object)) {
                return .{ .other = "array" };
            }
            return .{ .array = try self.items(value.toArray(), object, depth) };
        }

        if (value.isFunction()) {
            return .{ .other = "function" };
        }
        if (value.isPromise()) {
            return .{ .other = "promise" };
        }
        if (value.isNativeError()) {
            return .{ .other = "error" };
        }
        if (value.isDate()) {
            return .{ .date = try self.date(value) };
        }
        if (value.isRegExp()) {
            return .{ .regexp = .{
                .pattern = try (try object.get("source")).toStringSliceWithAlloc(self.arena),
                .flags = try (try object.get("flags")).toStringSliceWithAlloc(self.arena),
            } };
        }
        if (value.isTypedArray()) {
            return .{ .other = "typedarray" };
        }
        if (value.isArrayBuffer()) {
            return .{ .other = "arraybuffer" };
        }
        if (bareType(value)) |name| {
            return .{ .other = name };
        }

        if (self.isTooDeep(depth) or self.isSeen(object)) {
            return .{ .other = "object" };
        }
        return .{ .object = try self.properties(object, depth) };
    }

    // One of our objects. The spec only cares about four, the rest are opaque.
    fn platform(self: *Serializer, tao: *const js.TaggedOpaque, depth: u32) !Remote.Body {
        if (tao.as(Node)) |dom_node| {
            return .{ .node = try self.node(dom_node, 0) };
        }

        if (tao.as(Window)) |_| {
            return .{ .other = "window" };
        }

        if (tao.as(NodeList)) |list| {
            if (self.isTooDeep(depth)) {
                return .{ .other = "nodelist" };
            }
            const frame = self.frame;
            const nodes = try self.arena.alloc(Remote, try list.length(frame));
            for (nodes, 0..) |*item, i| {
                const dom_node = (try list.getAtIndex(i, frame)) orelse unreachable;
                item.* = .{ .body = .{ .node = try self.node(dom_node, 0) } };
            }
            return .{ .nodelist = nodes };
        }

        if (tao.as(HTMLCollection)) |collection| {
            if (self.isTooDeep(depth)) {
                return .{ .other = "htmlcollection" };
            }
            const frame = self.frame;
            const nodes = try self.arena.alloc(Remote, collection.length(frame));
            for (nodes, 0..) |*item, i| {
                const element = collection.getAtIndex(i, frame) orelse unreachable;
                item.* = .{ .body = .{ .node = try self.node(element.asNode(), 0) } };
            }
            return .{ .htmlcollection = nodes };
        }

        return .{ .other = "object" };
    }

    fn items(self: *Serializer, array: js.Array, object: js.Object, depth: u32) ![]const Remote {
        try self.see(object);
        defer self.unsee();

        const next_depth = depth + 1;
        const values = try self.arena.alloc(Remote, array.len());
        for (values, 0..) |*value, i| {
            value.* = try self.remote(try array.get(@intCast(i)), next_depth, false);
        }
        return values;
    }

    fn properties(self: *Serializer, object: js.Object, depth: u32) ![]const Property {
        try self.see(object);
        defer self.unsee();

        const next_depth = depth + 1;
        var it = try object.iterator();
        var list: std.ArrayList(Property) = try .initCapacity(self.arena, it.count);
        while (try it.next()) |entry| {
            list.appendAssumeCapacity(.{
                .name = try self.arena.dupe(u8, entry.name),
                .value = try self.remote(entry.value, next_depth, false),
            });
        }
        return list.items;
    }

    fn node(self: *Serializer, dom_node: *Node, dom_depth: u32) !NodeValue {
        const arena = self.arena;
        const registered = try self.registry.register(dom_node);

        var value: NodeValue = .{
            .shared_id = try std.fmt.allocPrint(arena, "{d}", .{registered.id}),
            .node_type = dom_node.getNodeType(),
            .child_node_count = dom_node.getChildrenCount(),
        };

        if (dom_node.is(Node.Element)) |element| {
            value.local_name = element.getLocalName();
            value.namespace_uri = element.getNamespaceURI();

            const entries = element.attributeEntries();
            const attributes = try arena.alloc(Attribute, entries.len);
            for (entries, attributes) |*entry, *attribute| {
                attribute.* = .{ .name = entry.name(), .value = entry.value() };
            }
            value.attributes = attributes;
        } else if (dom_node.getNodeValue()) |node_value| {
            value.node_value = try arena.dupe(u8, node_value.str());
        }

        // Unlike maxObjectDepth, maxDomDepth counts down from the node being
        // serialized, so the default of 0 still yields the node's own
        // properties — just no children.
        const include_children = if (self.opts.max_dom_depth) |max| dom_depth < max else true;
        if (include_children) {
            var children: std.ArrayList(Remote) = .empty;
            var it = dom_node.childrenIterator();
            while (it.next()) |child| {
                try children.append(arena, .{ .body = .{ .node = try self.node(child, dom_depth + 1) } });
            }
            value.children = children.items;
        }

        return value;
    }

    fn date(self: *Serializer, value: js.Value) ![]const u8 {
        const ms = value.dateValue();
        if (std.math.isNan(ms)) {
            return "Invalid Date";
        }

        if (lp.datetime.DateTime.fromUnix(@intFromFloat(ms), .milliseconds)) |dt| {
            var buf: [28]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            dt.formatMillis(&w) catch unreachable;
            return self.arena.dupe(u8, w.buffered());
        } else |_| {}

        const iso = try value.toObject().callMethod(js.Value, "toISOString", .{});
        return iso.toStringSliceWithAlloc(self.arena);
    }

    fn isSeen(self: *const Serializer, object: js.Object) bool {
        const candidate = object.toValue();
        for (self.seen.items) |ancestor| {
            if (ancestor.toValue().strictEquals(candidate)) {
                return true;
            }
        }
        return false;
    }

    fn see(self: *Serializer, object: js.Object) !void {
        try self.seen.append(self.arena, object);
    }

    fn unsee(self: *Serializer) void {
        _ = self.seen.pop();
    }

    fn isTooDeep(self: *const Serializer, depth: u32) bool {
        return depth >= (self.opts.max_object_depth orelse return false);
    }
};

// Some of these we should serialize fully, but we don't have anything that
// needs them right now.
fn bareType(value: js.Value) ?[]const u8 {
    if (value.isMap()) {
        return "map";
    }

    if (value.isSet()) {
        return "set";
    }

    if (value.isWeakMap()) {
        return "weakmap";
    }

    if (value.isWeakSet()) {
        return "weakset";
    }

    if (value.isProxy()) {
        return "proxy";
    }

    if (value.isGeneratorObject()) {
        return "generator";
    }

    return null;
}

pub const LocalError = error{
    NoSuchNode,
    NoSuchHandle,
    UnsupportedLocalValue,
};

// script.LocalValue -> JS, for callFunction's `arguments` and `this`.
pub fn toJs(
    local: *const js.Local,
    handles: *const Handles,
    registry: *const NodeRegistry,
    value: std.json.Value,
) !js.Value {
    const fields = switch (value) {
        .object => |o| o,
        else => return error.UnsupportedLocalValue,
    };

    if (fields.get("handle")) |handle| {
        const id = parseId(u32, handle) orelse return error.NoSuchHandle;
        const global = handles.get(id) orelse return error.NoSuchHandle;
        return global.local(local);
    }

    if (fields.get("sharedId")) |shared_id| {
        const node = try nodeFromSharedId(registry, shared_id);
        return local.zigValueToJs(node, .{});
    }

    const name = switch (fields.get("type") orelse return error.UnsupportedLocalValue) {
        .string => |s| s,
        else => return error.UnsupportedLocalValue,
    };
    const tag = std.meta.stringToEnum(enum {
        undefined,
        null,
        string,
        number,
        boolean,
        bigint,
        array,
        object,
    }, name) orelse return error.UnsupportedLocalValue;

    const payload = fields.get("value") orelse .null;
    switch (tag) {
        .undefined => return local.zigValueToJs({}, .{}),
        .null => return local.zigValueToJs(null, .{}),
        .string => return local.zigValueToJs(switch (payload) {
            .string => |s| s,
            else => return error.UnsupportedLocalValue,
        }, .{}),
        .boolean => return local.zigValueToJs(switch (payload) {
            .bool => |b| b,
            else => return error.UnsupportedLocalValue,
        }, .{}),
        .number => return local.newNumber(switch (payload) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .string => |s| specialNumber(s) orelse return error.UnsupportedLocalValue,
            else => return error.UnsupportedLocalValue,
        }),
        // A bigint's value is its decimal digits as a string.
        .bigint => {
            const digits = switch (payload) {
                .string => |s| s,
                else => return error.UnsupportedLocalValue,
            };
            return local.newBigInt(digits) catch return error.UnsupportedLocalValue;
        },
        .array => {
            const entries = switch (payload) {
                .array => |a| a.items,
                else => return error.UnsupportedLocalValue,
            };
            var array = local.newArray(@intCast(entries.len));
            for (entries, 0..) |entry, i| {
                const item = try toJs(local, handles, registry, entry);
                if (try array.set(@intCast(i), item, .{}) == false) {
                    return error.UnsupportedLocalValue;
                }
            }
            return array.toValue();
        },
        // An object's value is a list of [key, value] pairs.
        .object => {
            const entries = switch (payload) {
                .array => |a| a.items,
                else => return error.UnsupportedLocalValue,
            };
            const object = local.newObject();
            for (entries) |entry| {
                const pair = switch (entry) {
                    .array => |p| p.items,
                    else => return error.UnsupportedLocalValue,
                };
                if (pair.len != 2) {
                    return error.UnsupportedLocalValue;
                }
                const key = objectKey(pair[0]) orelse return error.UnsupportedLocalValue;
                const item = try toJs(local, handles, registry, pair[1]);
                if (try object.set(key, item, .{}) == false) {
                    return error.UnsupportedLocalValue;
                }
            }
            return object.toValue();
        },
    }
}

fn objectKey(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .string => |s| return s,
        .object => |fields| {
            // {"type": "string", "value": "over 9000"}  is supported
            const name = switch (fields.get("type") orelse return null) {
                .string => |s| s,
                else => return null,
            };
            if (std.mem.eql(u8, name, "string") == false) {
                return null;
            }
            return switch (fields.get("value") orelse return null) {
                .string => |s| s,
                else => null,
            };
        },
        else => return null,
    }
}

pub fn nodeFromSharedId(registry: *const NodeRegistry, shared_id: std.json.Value) error{NoSuchNode}!*Node {
    const id = parseId(NodeRegistry.Id, shared_id) orelse return error.NoSuchNode;
    const node = registry.lookup_by_id.get(id) orelse return error.NoSuchNode;
    return node.dom;
}

fn parseId(comptime T: type, value: std.json.Value) ?T {
    const str = switch (value) {
        .string => |s| s,
        else => return null,
    };
    return std.fmt.parseInt(T, str, 10) catch null;
}

fn specialNumber(name: []const u8) ?f64 {
    if (std.mem.eql(u8, name, "NaN")) {
        return std.math.nan(f64);
    }

    if (std.mem.eql(u8, name, "Infinity")) {
        return std.math.inf(f64);
    }

    if (std.mem.eql(u8, name, "-Infinity")) {
        return -std.math.inf(f64);
    }

    if (std.mem.eql(u8, name, "-0")) {
        return -0.0;
    }

    return null;
}
