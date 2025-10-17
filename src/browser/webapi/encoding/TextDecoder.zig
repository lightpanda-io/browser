const std = @import("std");
const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const Allocator = std.mem.Allocator;

const TextDecoder = @This();

_fatal: bool,
_ignore_bom: bool,
_arena: Allocator,
_stream: std.ArrayListUnmanaged(u8),

const Label = enum {
    utf8,
    @"utf-8",
    @"unicode-1-1-utf-8",
};

const InitOpts = struct {
    fatal: bool = false,
    ignoreBOM: bool = false,
};

pub fn init(label_: ?[]const u8, opts_: ?InitOpts, page: *Page) !*TextDecoder {
    if (label_) |label| {
        _ = std.meta.stringToEnum(Label, label) orelse return error.RangeError;
    }

    const opts = opts_ orelse InitOpts{};
    return page._factory.create(TextDecoder{
        ._arena = page.arena,
        ._stream = .empty,
        ._fatal = opts.fatal,
        ._ignore_bom = opts.ignoreBOM,
    });
}

pub fn getEncoding(_: *const TextDecoder) []const u8 {
    return "utf-8";
}

pub fn getIgnoreBOM(self: *const TextDecoder) bool {
    return self._ignore_bom;
}

pub fn getFatal(self: *const TextDecoder) bool {
    return self._fatal;
}

const DecodeOpts = struct {
    stream: bool = false,
};
pub fn decode(self: *TextDecoder, input_: ?[]const u8, opts_: ?DecodeOpts) ![]const u8 {
    var input = input_ orelse return "";
    const opts: DecodeOpts = opts_ orelse .{};

    if (self._stream.items.len > 0) {
        try self._stream.appendSlice(self._arena, input);
        input = self._stream.items;
    }

    if (self._fatal and !std.unicode.utf8ValidateSlice(input)) {
        if (opts.stream) {
            if (self._stream.items.len == 0) {
                try self._stream.appendSlice(self._arena, input);
            }
            return "";
        }
        return error.InvalidUtf8;
    }

    self._stream.clearRetainingCapacity();
    if (self._ignore_bom == false and std.mem.startsWith(u8, input, &.{ 0xEF, 0xBB, 0xBF })) {
        return input[3..];
    }

    return input;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextDecoder);

    pub const Meta = struct {
        pub const name = "TextDecoder";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };

    pub const constructor = bridge.constructor(TextDecoder.init, .{});
    pub const decode = bridge.function(TextDecoder.decode, .{});
    pub const encoding = bridge.accessor(TextDecoder.getEncoding, null, .{});
    pub const fatal = bridge.accessor(TextDecoder.getFatal, null, .{});
    pub const ignoreBOM = bridge.accessor(TextDecoder.getIgnoreBOM, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextDecoder" {
    try testing.htmlRunner("encoding/text_decoder.html", .{});
}
