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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const Factory = @import("../Factory.zig");
const EventManager = @import("../EventManager.zig");

const Node = @import("Node.zig");
const Event = @import("Event.zig");
const Screen = @import("Screen.zig");
const Worker = @import("Worker.zig");
const Window = @import("Window.zig");
const FileReader = @import("FileReader.zig");
const AbortSignal = @import("AbortSignal.zig");
const MessagePort = @import("MessagePort.zig");
const Performance = @import("Performance.zig");
const Notification = @import("Notification.zig");
const SharedWorker = @import("SharedWorker.zig");
const VisualViewport = @import("VisualViewport.zig");
const BroadcastChannel = @import("BroadcastChannel.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");

const WebSocket = @import("net/WebSocket.zig");
const EventSource = @import("net/EventSource.zig");
const CookieStore = @import("storage/CookieStore.zig");
const IDBRequest = @import("storage/idb/IDBRequest.zig");
const IDBDatabase = @import("storage/idb/IDBDatabase.zig");
const IDBTransaction = @import("storage/idb/IDBTransaction.zig");

const FontFaceSet = @import("css/FontFaceSet.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");

const TextTrackCue = @import("media/TextTrackCue.zig");

const Navigation = @import("navigation/Navigation.zig");
const NavigationHistoryEntry = @import("navigation/NavigationHistoryEntry.zig");
const XMLHttpRequestEventTarget = @import("net/XMLHttpRequestEventTarget.zig");

const RegisterOptions = EventManager.RegisterOptions;

const EventTarget = @This();

pub const _prototype_root = true;

// `global_event_handlers.Key` reuses the low 3 bits of an EventTarget pointer,
// so the type has to stay 8-byte aligned even though the tag is a single byte.
// This costs nothing in a chain: EventTarget is always at offset 0 and every
// subtype that follows it is itself 8-aligned.
_type: Type align(8),

pub const Type = enum(u8) {
    abort_signal,
    broadcast_channel,
    cookie_store,
    event_source,
    file_reader,
    font_face_set,
    generic,
    idb_database,
    idb_request,
    idb_transaction,
    media_query_list,
    message_port,
    navigation,
    navigation_history_entry,
    node,
    notification,
    performance,
    screen,
    screen_orientation,
    shared_worker,
    text_track_cue,
    visual_viewport,
    websocket,
    window,
    worker,
    worker_global_scope,
    xhr,
};

// `.generic` maps to EventTarget itself: a standalone `new EventTarget()` has
// no chain member of its own.
pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .abort_signal => AbortSignal,
        .broadcast_channel => BroadcastChannel,
        .cookie_store => CookieStore,
        .event_source => EventSource,
        .file_reader => FileReader,
        .font_face_set => FontFaceSet,
        .generic => EventTarget,
        .idb_database => IDBDatabase,
        .idb_request => IDBRequest,
        .idb_transaction => IDBTransaction,
        .media_query_list => MediaQueryList,
        .message_port => MessagePort,
        .navigation => Navigation,
        .navigation_history_entry => NavigationHistoryEntry,
        .node => Node,
        .notification => Notification,
        .performance => Performance,
        .screen => Screen,
        .screen_orientation => Screen.Orientation,
        .shared_worker => SharedWorker,
        .text_track_cue => TextTrackCue,
        .visual_viewport => VisualViewport,
        .websocket => WebSocket,
        .window => Window,
        .worker => Worker,
        .worker_global_scope => WorkerGlobalScope,
        .xhr => XMLHttpRequestEventTarget,
    };
}

pub fn subtype(self: *const EventTarget, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, EventTarget);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

// Returns the target as a more specific type, or null if it isn't a `T`.
pub fn is(self: *EventTarget, comptime T: type) ?*T {
    switch (self._type) {
        .generic => {},
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    return null;
}

pub fn as(self: *EventTarget, comptime T: type) *T {
    return self.is(T).?;
}

pub fn init(page: *Page) !*EventTarget {
    return page.factory.create(EventTarget{
        ._type = .generic,
    });
}

pub fn dispatchEvent(self: *EventTarget, event: *Event, exec: *js.Execution) !bool {
    if (event._event_phase != .none) {
        return error.InvalidStateError;
    }

    if (!event._initialized) {
        return error.InvalidStateError;
    }
    event._is_trusted = false;

    switch (exec.js.global) {
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
    options: Options,

    // The signal is kept as a raw js.Value so that an explicit null (or any
    // non-AbortSignal value) can be told apart from an absent or undefined
    // member, and rejected with a TypeError per the dictionary conversion.
    // passive is optional so that an absent (or undefined) member falls back
    // to the type- and target-dependent default passive value.
    const Options = struct {
        capture: bool = false,
        once: bool = false,
        passive: ?bool = null,
        signal: ?js.Value = null,
    };
};

// The DOM spec's "default passive value": listeners for the scroll-blocking
// event types are passive by default on the window, the document, and the
// html and body elements.
fn defaultPassiveValue(self: *EventTarget, typ: []const u8) bool {
    const scroll_blocking_event_types = std.StaticStringMap(void).initComptime(.{
        .{ "touchstart", {} },
        .{ "touchmove", {} },
        .{ "wheel", {} },
        .{ "mousewheel", {} },
    });
    if (scroll_blocking_event_types.has(typ) == false) {
        return false;
    }

    switch (self._type) {
        .window => return true,
        .node => {
            const Element = @import("Element.zig");
            const n = self.subtype(Node);
            if (n._type == .document) {
                return true;
            }
            const element = n.is(Element) orelse return false;
            return switch (element.getTag()) {
                .html, .body => true,
                else => false,
            };
        },
        else => return false,
    }
}

pub const EventListenerCallback = union(enum) {
    function: js.Function,
    object: js.Object,
};
pub fn addEventListener(self: *EventTarget, typ: []const u8, callback_: js.Nullable(EventListenerCallback), opts_: ?AddEventListenerOptions, exec: *js.Execution) !void {
    // Convert the options before the null-callback early return: per spec,
    // the dictionary conversion throws even when the callback is null.
    const options = blk: {
        const o = opts_ orelse break :blk RegisterOptions{ .passive = self.defaultPassiveValue(typ) };
        break :blk switch (o) {
            .options => |opts| RegisterOptions{
                .once = opts.once,
                .capture = opts.capture,
                .passive = opts.passive orelse self.defaultPassiveValue(typ),
                .signal = signal: {
                    const signal = opts.signal orelse break :signal null;
                    if (signal.isUndefined()) {
                        break :signal null;
                    }
                    break :signal try signal.toZig(*AbortSignal);
                },
            },
            .capture => |capture| RegisterOptions{ .capture = capture, .passive = self.defaultPassiveValue(typ) },
        };
    };

    const callback = callback_.value orelse return;

    const em_callback: EventManager.Callback = switch (callback) {
        .object => |obj| .{ .object = obj },
        .function => |func| .{ .function = func },
    };

    return exec.registerListener(self, typ, em_callback, options);
}

const RemoveEventListenerOptions = union(enum) {
    capture: bool,
    options: Options,

    const Options = struct {
        capture: bool = false,
    };
};
pub fn removeEventListener(self: *EventTarget, typ: []const u8, callback_: js.Nullable(EventListenerCallback), opts_: ?RemoveEventListenerOptions, exec: *js.Execution) !void {
    const callback = callback_.value orelse return;

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

    exec.removeListener(self, typ, em_callback, use_capture);
}

pub fn format(self: *EventTarget, writer: *std.Io.Writer) !void {
    return switch (self._type) {
        .node => self.subtype(Node).format(writer),
        .generic => writer.writeAll("<EventTarget>"),
        .window => writer.writeAll("<Window>"),
        .worker => writer.writeAll("<Worker>"),
        .shared_worker => writer.writeAll("<SharedWorker>"),
        .worker_global_scope => writer.writeAll("<WorkerGlobalScope>"),
        .xhr => writer.writeAll("<XMLHttpRequestEventTarget>"),
        .abort_signal => writer.writeAll("<AbortSignal>"),
        .media_query_list => writer.writeAll("<MediaQueryList>"),
        .message_port => writer.writeAll("<MessagePort>"),
        .broadcast_channel => writer.writeAll("<BroadcastChannel>"),
        .text_track_cue => writer.writeAll("<TextTrackCue>"),
        .navigation => writer.writeAll("<Navigation>"),
        .screen => writer.writeAll("<Screen>"),
        .screen_orientation => writer.writeAll("<ScreenOrientation>"),
        .visual_viewport => writer.writeAll("<VisualViewport>"),
        .file_reader => writer.writeAll("<FileReader>"),
        .font_face_set => writer.writeAll("<FontFaceSet>"),
        .websocket => writer.writeAll("<WebSocket>"),
        .event_source => writer.writeAll("<EventSource>"),
        .cookie_store => writer.writeAll("<CookieStore>"),
        .idb_request => writer.writeAll("<IDBRequest>"),
        .idb_database => writer.writeAll("<IDBDatabase>"),
        .idb_transaction => writer.writeAll("<IDBTransaction>"),
        .notification => writer.writeAll("<Notification>"),
        .navigation_history_entry => writer.writeAll("<NavigationHistoryEntry>"),
    };
}

pub fn toString(self: *EventTarget) []const u8 {
    return switch (self._type) {
        .abort_signal => return "[object AbortSignal]",
        .broadcast_channel => return "[object BroadcastChannel]",
        .cookie_store => return "[object CookieStore]",
        .event_source => return "[object EventSource]",
        .file_reader => return "[object FileReader]",
        .font_face_set => return "[object FontFaceSet]",
        .generic => return "[object EventTarget]",
        .idb_database => return "[object IDBDatabase]",
        .idb_request => return "[object IDBRequest]",
        .idb_transaction => return "[object IDBTransaction]",
        .media_query_list => return "[object MediaQueryList]",
        .message_port => return "[object MessagePort]",
        .navigation => return "[object Navigation]",
        .navigation_history_entry => return "[object NavigationHistoryEntry]",
        .node => return "[object Node]",
        .notification => return "[object Notification]",
        .performance => return "[object Performance]",
        .screen => return "[object Screen]",
        .screen_orientation => return "[object ScreenOrientation]",
        .shared_worker => return "[object SharedWorker]",
        .text_track_cue => return "[object TextTrackCue]",
        .visual_viewport => return "[object VisualViewport]",
        .websocket => return "[object WebSocket]",
        .window => return "[object Window]",
        .worker => return "[object Worker]",
        .worker_global_scope => return "[object WorkerGlobalScope]",
        .xhr => return "[object XMLHttpRequestEventTarget]",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EventTarget);

    pub const Meta = struct {
        pub const name = "EventTarget";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(EventTarget.init, .{});
    pub const dispatchEvent = bridge.function(EventTarget.dispatchEvent, .{});
    pub const addEventListener = bridge.function(EventTarget.addEventListener, .{});
    pub const removeEventListener = bridge.function(EventTarget.removeEventListener, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: EventTarget" {
    testing.silenceLog(&.{ .js, .event });

    // we create thousands of these per frame. Nothing should bloat it.
    // The tag is 1 byte; the rest is the align(8) that `Key.fuse` depends on.
    try testing.expectEqual(8, @sizeOf(EventTarget));
    try testing.expectEqual(8, @alignOf(EventTarget));
    try testing.htmlRunner("events.html", .{});
}
