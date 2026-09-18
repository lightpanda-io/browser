// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const js = @import("../../js/js.zig");
const v8 = js.v8;

const TextEncoder = @This();
_pad: bool = false,

pub fn init() TextEncoder {
    return .{};
}

pub fn encode(_: *const TextEncoder, v_: ?js.Value, exec: *const js.Execution) !js.Value {
    const local = exec.js.local.?;

    // The input is an optional USVString defaulting to "": undefined is the
    // default, anything else (null included) is stringified.
    const source = blk: {
        const v = v_ orelse break :blk local.newString("");
        if (v.isUndefined()) {
            break :blk local.newString("");
        }
        break :blk try v.toString();
    };

    const array = local.createTypedArray(.uint8, source.len());
    const slice = array.slice();
    _ = v8.v8__String__WriteUtf8(
        source.handle,
        source.local.isolate.handle,
        slice.ptr,
        slice.len,
        v8.WRITE_REPLACE_INVALID_UTF8,
        null,
    );

    return .{ .local = local, .handle = array.handle };
}

// https://encoding.spec.whatwg.org/#dom-textencoder-encodeinto
// `read` counts UTF-16 code units consumed from the source, `written` counts
// bytes written into the destination.
pub const EncodeIntoResult = struct {
    read: usize,
    written: usize,
};

pub fn encodeInto(_: *const TextEncoder, source_: js.Value, destination_: js.Value) !EncodeIntoResult {
    // The source is a USVString, so anything is stringified, as encode does.
    // Binding it as a []const u8 would instead hand us the raw bytes of a
    // typed array, which could even alias the destination.
    const source = try source_.toString();

    if (!destination_.isUint8Array()) {
        return error.InvalidArgument;
    }
    const dest = try destination_.toZig([]u8);

    // V8 encodes straight into the destination, never writing a partial
    // sequence, and replaces lone surrogates as the USVString conversion would.
    var read: usize = 0;
    const written = v8.v8__String__WriteUtf8(
        source.handle,
        source.local.isolate.handle,
        dest.ptr,
        dest.len,
        v8.WRITE_REPLACE_INVALID_UTF8,
        &read,
    );

    return .{ .read = read, .written = written };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextEncoder);

    pub const Meta = struct {
        pub const name = "TextEncoder";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(TextEncoder.init, .{});
    pub const encode = bridge.function(TextEncoder.encode, .{});
    pub const encodeInto = bridge.function(TextEncoder.encodeInto, .{});
    pub const encoding = bridge.property("utf-8", .{ .template = false });
};

const testing = @import("../../../testing.zig");
test "WebApi: TextEncoder" {
    try testing.htmlRunner("encoding/text_encoder.html", .{});
}
