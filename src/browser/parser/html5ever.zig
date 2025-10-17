const ParsedNode = @import("Parser.zig").ParsedNode;

pub extern "c" fn html5ever_parse_document(
    html: [*c]const u8,
    len: usize,
    doc: *anyopaque,
    ctx: *anyopaque,
    createElementCallback: *const fn (ctx: *anyopaque, data: *anyopaque, QualName, AttributeIterator) callconv(.c) ?*anyopaque,
    elemNameCallback: *const fn (node_ref: *anyopaque) callconv(.c) *anyopaque,
    appendCallback: *const fn (ctx: *anyopaque, parent_ref: *anyopaque, NodeOrText) callconv(.c) void,
    parseErrorCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) void,
    popCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void,
    createCommentCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) ?*anyopaque,
    appendDoctypeToDocument: *const fn (ctx: *anyopaque, StringSlice, StringSlice, StringSlice) callconv(.c) void,
) void;

pub extern "c" fn html5ever_parse_fragment(
    html: [*c]const u8,
    len: usize,
    doc: *anyopaque,
    ctx: *anyopaque,
    createElementCallback: *const fn (ctx: *anyopaque, data: *anyopaque, QualName, AttributeIterator) callconv(.c) ?*anyopaque,
    elemNameCallback: *const fn (node_ref: *anyopaque) callconv(.c) *anyopaque,
    appendCallback: *const fn (ctx: *anyopaque, parent_ref: *anyopaque, NodeOrText) callconv(.c) void,
    parseErrorCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) void,
    popCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void,
    createCommentCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) ?*anyopaque,
    appendDoctypeToDocument: *const fn (ctx: *anyopaque, StringSlice, StringSlice, StringSlice) callconv(.c) void,
) void;

pub extern "c" fn html5ever_attribute_iterator_next(ctx: *anyopaque) Nullable(Attribute);
pub extern "c" fn html5ever_attribute_iterator_count(ctx: *anyopaque) usize;

pub extern "c" fn html5ever_get_memory_usage() MemoryUsage;

pub const MemoryUsage = extern struct {
    resident: usize,
    allocated: usize,
};

// Streaming parser API
pub extern "c" fn html5ever_streaming_parser_create(
    doc: *anyopaque,
    ctx: *anyopaque,
    createElementCallback: *const fn (ctx: *anyopaque, data: *anyopaque, QualName, AttributeIterator) callconv(.c) ?*anyopaque,
    elemNameCallback: *const fn (node_ref: *anyopaque) callconv(.c) *anyopaque,
    appendCallback: *const fn (ctx: *anyopaque, parent_ref: *anyopaque, NodeOrText) callconv(.c) void,
    parseErrorCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) void,
    popCallback: *const fn (ctx: *anyopaque, node_ref: *anyopaque) callconv(.c) void,
    createCommentCallback: *const fn (ctx: *anyopaque, StringSlice) callconv(.c) ?*anyopaque,
    appendDoctypeToDocument: *const fn (ctx: *anyopaque, StringSlice, StringSlice, StringSlice) callconv(.c) void,
) ?*anyopaque;

pub extern "c" fn html5ever_streaming_parser_feed(
    parser: *anyopaque,
    html: [*c]const u8,
    len: usize,
) void;

pub extern "c" fn html5ever_streaming_parser_finish(
    parser: *anyopaque,
) void;

pub extern "c" fn html5ever_streaming_parser_destroy(
    parser: *anyopaque,
) void;

pub fn Nullable(comptime T: type) type {
    return extern struct {
        tag: u8,
        value: T,

        pub fn unwrap(self: @This()) ?T {
            return if (self.tag == 0) null else self.value;
        }

        pub fn none() @This() {
            return .{ .tag = 0, .value = undefined };
        }
    };
}

pub const StringSlice = Slice(u8);
pub fn Slice(comptime T: type) type {
    return extern struct {
        ptr: [*]const T,
        len: usize,

        pub fn slice(self: @This()) []const T {
            return self.ptr[0..self.len];
        }
    };
}

pub const QualName = extern struct {
    prefix: Nullable(StringSlice),
    ns: StringSlice,
    local: StringSlice,
};

pub const Attribute = extern struct {
    name: QualName,
    value: StringSlice,
};

pub const AttributeIterator = extern struct {
    iter: *anyopaque,

    pub fn next(self: AttributeIterator) ?Attribute {
        return html5ever_attribute_iterator_next(self.iter).unwrap();
    }

    pub fn count(self: AttributeIterator) usize {
        return html5ever_attribute_iterator_count(self.iter);
    }
};

pub const NodeOrText = extern struct {
    tag: u8,
    node: *anyopaque,
    text: StringSlice,

    pub fn toUnion(self: NodeOrText) Union {
        if (self.tag == 0) {
            return .{ .node = @ptrCast(@alignCast(self.node)) };
        }
        return .{ .text = self.text.slice() };
    }

    const Union = union(enum) {
        node: *ParsedNode,
        text: []const u8,
    };
};
