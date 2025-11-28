// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const RegisterOptions = @import("../EventManager.zig").RegisterOptions;

const Event = @import("Event.zig");

const EventTarget = @This();

const _prototype_root = true;
_type: Type,

pub const Type = union(enum) {
    node: *@import("Node.zig"),
    window: *@import("Window.zig"),
    xhr: *@import("net/XMLHttpRequestEventTarget.zig"),
    abort_signal: *@import("AbortSignal.zig"),
    media_query_list: *@import("css/MediaQueryList.zig"),
    message_port: *@import("MessagePort.zig"),
};

pub fn dispatchEvent(self: *EventTarget, event: *Event, page: *Page) !bool {
    try page._event_manager.dispatch(self, event);
    return !event._cancelable or !event._prevent_default;
}

const AddEventListenerOptions = union(enum) {
    capture: bool,
    options: RegisterOptions,
};

pub const EventListenerCallback = union(enum) {
    function: js.Function,
    object: js.Object,
};
pub fn addEventListener(self: *EventTarget, typ: []const u8, callback_: ?EventListenerCallback, opts_: ?AddEventListenerOptions, page: *Page) !void {
    const callback = callback_ orelse return;

    const actual_callback = switch (callback) {
        .function => |func| func,
        .object => |obj| (try obj.getFunction("handleEvent")) orelse return,
    };

    const options = blk: {
        const o = opts_ orelse break :blk RegisterOptions{};
        break :blk switch (o) {
            .options => |opts| opts,
            .capture => |capture| RegisterOptions{ .capture = capture },
        };
    };
    return page._event_manager.register(self, typ, actual_callback, options);
}

const RemoveEventListenerOptions = union(enum) {
    capture: bool,
    options: Options,

    const Options = struct {
        useCapture: bool = false,
    };
};
pub fn removeEventListener(self: *EventTarget, typ: []const u8, callback_: ?EventListenerCallback, opts_: ?RemoveEventListenerOptions, page: *Page) !void {
    const callback = callback_ orelse return;

    const actual_callback = switch (callback) {
        .function => |func| func,
        .object => |obj| (try obj.getFunction("handleEvent")) orelse return,
    };

    const use_capture = blk: {
        const o = opts_ orelse break :blk false;
        break :blk switch (o) {
            .capture => |capture| capture,
            .options => |opts| opts.useCapture,
        };
    };
    return page._event_manager.remove(self, typ, actual_callback, use_capture);
}

pub fn format(self: *EventTarget, writer: *std.Io.Writer) !void {
    return switch (self._type) {
        .node => |n| n.format(writer),
        .window => writer.writeAll("<window>"),
        .xhr => writer.writeAll("<XMLHttpRequestEventTarget>"),
        .abort_signal => writer.writeAll("<abort_signal>"),
        .media_query_list => writer.writeAll("<MediaQueryList>"),
        .message_port => writer.writeAll("<MessagePort>"),
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EventTarget);

    pub const Meta = struct {
        pub const name = "EventTarget";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const dispatchEvent = bridge.function(EventTarget.dispatchEvent, .{});
    pub const addEventListener = bridge.function(EventTarget.addEventListener, .{});
    pub const removeEventListener = bridge.function(EventTarget.removeEventListener, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: EventTarget" {
    // we create thousands of these per page. Nothing should bloat it.
    try testing.expectEqual(16, @sizeOf(EventTarget));

    try testing.htmlRunner("events.html", .{});
}
