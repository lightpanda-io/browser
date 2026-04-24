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
const EventManager = @import("../EventManager.zig");

const Event = @import("Event.zig");

const RegisterOptions = EventManager.RegisterOptions;

const EventTarget = @This();

pub const _prototype_root = true;
_type: Type,

pub const Type = union(enum) {
    generic: void,
    node: *@import("Node.zig"),
    window: *@import("Window.zig"),
    worker: *@import("Worker.zig"),
    worker_global_scope: *@import("WorkerGlobalScope.zig"),
    xhr: *@import("net/XMLHttpRequestEventTarget.zig"),
    abort_signal: *@import("AbortSignal.zig"),
    media_query_list: *@import("css/MediaQueryList.zig"),
    message_port: *@import("MessagePort.zig"),
    text_track_cue: *@import("media/TextTrackCue.zig"),
    navigation: *@import("navigation/Navigation.zig"),
    screen: *@import("Screen.zig"),
    screen_orientation: *@import("Screen.zig").Orientation,
    visual_viewport: *@import("VisualViewport.zig"),
    file_reader: *@import("FileReader.zig"),
    font_face_set: *@import("css/FontFaceSet.zig"),
    websocket: *@import("net/WebSocket.zig"),
};

pub fn init(page: *Page) !*EventTarget {
    return page.factory.create(EventTarget{
        ._type = .generic,
    });
}

pub fn dispatchEvent(self: *EventTarget, event: *Event, exec: *js.Execution) !bool {
    if (event._event_phase != .none) {
        return error.InvalidStateError;
    }
    event._is_trusted = false;

    switch (exec.context.global) {
        .frame => |frame| {
            event.acquireRef();
            defer _ = event.releaseRef(frame._page);
            try frame._event_manager.dispatch(self, event);
        },
        .worker => |wgs| try wgs.dispatch(self, event, null, .{}),
    }
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
pub fn addEventListener(self: *EventTarget, typ: []const u8, callback_: ?EventListenerCallback, opts_: ?AddEventListenerOptions, exec: *js.Execution) !void {
    const callback = callback_ orelse return;

    const em_callback: EventManager.Callback = switch (callback) {
        .object => |obj| .{ .object = obj },
        .function => |func| .{ .function = func },
    };

    const options = blk: {
        const o = opts_ orelse break :blk RegisterOptions{};
        break :blk switch (o) {
            .options => |opts| opts,
            .capture => |capture| RegisterOptions{ .capture = capture },
        };
    };

    switch (exec.context.global) {
        inline else => |g| _ = try g._event_manager.register(self, typ, em_callback, options),
    }
}

const RemoveEventListenerOptions = union(enum) {
    capture: bool,
    options: Options,

    const Options = struct {
        capture: bool = false,
    };
};
pub fn removeEventListener(self: *EventTarget, typ: []const u8, callback_: ?EventListenerCallback, opts_: ?RemoveEventListenerOptions, exec: *js.Execution) !void {
    const callback = callback_ orelse return;

    // For object callbacks, check if handleEvent exists
    if (callback == .object) {
        if (try callback.object.getFunction("handleEvent") == null) {
            return;
        }
    }

    const em_callback: EventManager.Callback = switch (callback) {
        .function => |func| .{ .function = func },
        .object => |obj| .{ .object = obj },
    };

    const use_capture = blk: {
        const o = opts_ orelse break :blk false;
        break :blk switch (o) {
            .capture => |capture| capture,
            .options => |opts| opts.capture,
        };
    };

    switch (exec.context.global) {
        inline else => |g| g._event_manager.remove(self, typ, em_callback, use_capture),
    }
}

pub fn format(self: *EventTarget, writer: *std.Io.Writer) !void {
    return switch (self._type) {
        .node => |n| n.format(writer),
        .generic => writer.writeAll("<EventTarget>"),
        .window => writer.writeAll("<Window>"),
        .worker => writer.writeAll("<Worker>"),
        .worker_global_scope => writer.writeAll("<WorkerGlobalScope>"),
        .xhr => writer.writeAll("<XMLHttpRequestEventTarget>"),
        .abort_signal => writer.writeAll("<AbortSignal>"),
        .media_query_list => writer.writeAll("<MediaQueryList>"),
        .message_port => writer.writeAll("<MessagePort>"),
        .text_track_cue => writer.writeAll("<TextTrackCue>"),
        .navigation => writer.writeAll("<Navigation>"),
        .screen => writer.writeAll("<Screen>"),
        .screen_orientation => writer.writeAll("<ScreenOrientation>"),
        .visual_viewport => writer.writeAll("<VisualViewport>"),
        .file_reader => writer.writeAll("<FileReader>"),
        .font_face_set => writer.writeAll("<FontFaceSet>"),
        .websocket => writer.writeAll("<WebSocket>"),
    };
}

pub fn toString(self: *EventTarget) []const u8 {
    return switch (self._type) {
        .node => return "[object Node]",
        .generic => return "[object EventTarget]",
        .window => return "[object Window]",
        .worker => return "[object Worker]",
        .worker_global_scope => return "[object WorkerGlobalScope]",
        .xhr => return "[object XMLHttpRequestEventTarget]",
        .abort_signal => return "[object AbortSignal]",
        .media_query_list => return "[object MediaQueryList]",
        .message_port => return "[object MessagePort]",
        .text_track_cue => return "[object TextTrackCue]",
        .navigation => return "[object Navigation]",
        .screen => return "[object Screen]",
        .screen_orientation => return "[object ScreenOrientation]",
        .visual_viewport => return "[object VisualViewport]",
        .file_reader => return "[object FileReader]",
        .font_face_set => return "[object FontFaceSet]",
        .websocket => return "[object WebSocket]",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EventTarget);

    pub const Meta = struct {
        pub const name = "EventTarget";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const enumerable = false;
    };

    pub const constructor = bridge.constructor(EventTarget.init, .{});
    pub const dispatchEvent = bridge.function(EventTarget.dispatchEvent, .{ .dom_exception = true });
    pub const addEventListener = bridge.function(EventTarget.addEventListener, .{});
    pub const removeEventListener = bridge.function(EventTarget.removeEventListener, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: EventTarget" {
    // we create thousands of these per frame. Nothing should bloat it.
    try testing.expectEqual(16, @sizeOf(EventTarget));
    try testing.htmlRunner("events.html", .{});
}
