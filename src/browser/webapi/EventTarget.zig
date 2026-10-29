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
const Frame = @import("../Frame.zig");
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
const Permissions = @import("Permissions.zig");
const Notification = @import("Notification.zig");
const PaymentRequest = @import("payment/PaymentRequest.zig");
const PaymentResponse = @import("payment/PaymentResponse.zig");
const SharedWorker = @import("SharedWorker.zig");
const ServiceWorker = @import("ServiceWorker.zig");
const ServiceWorkerContainer = @import("ServiceWorkerContainer.zig");
const ServiceWorkerRegistration = @import("ServiceWorkerRegistration.zig");
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

const TextTrack = @import("media/TextTrack.zig");
const TextTrackCue = @import("media/TextTrackCue.zig");
const TextTrackList = @import("media/TextTrackList.zig");

const Animation = @import("animation/Animation.zig");

const AudioNode = @import("webaudio/AudioNode.zig");
const BaseAudioContext = @import("webaudio/BaseAudioContext.zig");

const AudioDecoder = @import("webcodecs/AudioDecoder.zig");
const AudioEncoder = @import("webcodecs/AudioEncoder.zig");
const VideoDecoder = @import("webcodecs/VideoDecoder.zig");
const VideoEncoder = @import("webcodecs/VideoEncoder.zig");

const Navigation = @import("navigation/Navigation.zig");
const NavigationHistoryEntry = @import("navigation/NavigationHistoryEntry.zig");
const XMLHttpRequestEventTarget = @import("net/XMLHttpRequestEventTarget.zig");

const RegisterOptions = EventManager.RegisterOptions;

const EventTarget = @This();

pub const _prototype_root = true;

_type: Type,

pub const Type = enum(u8) {
    abort_signal,
    animation,
    audio_decoder,
    audio_encoder,
    audio_node,
    base_audio_context,
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
    payment_request,
    payment_response,
    performance,
    permission_status,
    screen,
    screen_orientation,
    service_worker,
    service_worker_container,
    service_worker_registration,
    shared_worker,
    text_track,
    text_track_cue,
    text_track_list,
    video_decoder,
    video_encoder,
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
        .animation => Animation,
        .audio_decoder => AudioDecoder,
        .audio_encoder => AudioEncoder,
        .audio_node => AudioNode,
        .base_audio_context => BaseAudioContext,
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
        .payment_request => PaymentRequest,
        .payment_response => PaymentResponse,
        .performance => Performance,
        .permission_status => Permissions.PermissionStatus,
        .screen => Screen,
        .screen_orientation => Screen.Orientation,
        .service_worker => ServiceWorker,
        .service_worker_container => ServiceWorkerContainer,
        .service_worker_registration => ServiceWorkerRegistration,
        .shared_worker => SharedWorker,
        .text_track => TextTrack,
        .text_track_cue => TextTrackCue,
        .text_track_list => TextTrackList,
        .video_decoder => VideoDecoder,
        .video_encoder => VideoEncoder,
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
        .frame => |caller| {
            // a Node's or Window's event disaptches in its own frame. It
            // doens't matter where dispatchEvent was called.
            const frame: *Frame = switch (self._type) {
                .node => self.subtype(Node).ownerFrame(caller) orelse caller,
                .window => blk: {
                    const window = self.subtype(Window);
                    break :blk if (window._closed) caller else window._frame;
                },
                else => caller,
            };
            event.acquireRef();
            defer _ = event.releaseRef(frame.page);
            try frame._event_manager.dispatch(self, event);
        },
        .worker => |wgs| try wgs.dispatch(self, event, .{}),
    }
    return !event._cancelable or !event._prevent_default;
}

pub const HandlerValue = union(enum) {
    func: js.Function.Global,
    anything: js.Value, // accept anything and when not callable, sets to null

    pub fn function(value: ?HandlerValue) ?js.Function.Global {
        return switch (value orelse return null) {
            .func => |func| func,
            .anything => null,
        };
    }
};

// Create a get and set accessor for on* handlers
pub fn handlerAccessor(comptime T: type, comptime typ: []const u8) js.bridge.Accessor {
    const H = struct {
        fn get(self: *T, exec: *js.Execution) ?js.Function.Global {
            return exec.getHandler(self.asEventTarget(), typ);
        }

        fn set(self: *T, value: ?HandlerValue, exec: *js.Execution) !void {
            return exec.setHandler(self.asEventTarget(), typ, HandlerValue.function(value));
        }
    };
    return js.Bridge(T).accessor(H.get, H.set, .{});
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

const EventListenerCallback = union(enum) {
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
        .service_worker => writer.writeAll("<ServiceWorker>"),
        .service_worker_container => writer.writeAll("<ServiceWorkerContainer>"),
        .service_worker_registration => writer.writeAll("<ServiceWorkerRegistration>"),
        .shared_worker => writer.writeAll("<SharedWorker>"),
        .worker_global_scope => writer.writeAll("<WorkerGlobalScope>"),
        .xhr => writer.writeAll("<XMLHttpRequestEventTarget>"),
        .abort_signal => writer.writeAll("<AbortSignal>"),
        .animation => writer.writeAll("<Animation>"),
        .audio_decoder => writer.writeAll("<AudioDecoder>"),
        .audio_encoder => writer.writeAll("<AudioEncoder>"),
        .audio_node => self.subtype(AudioNode).format(writer),
        .base_audio_context => writer.writeAll("<BaseAudioContext>"),
        .video_decoder => writer.writeAll("<VideoDecoder>"),
        .video_encoder => writer.writeAll("<VideoEncoder>"),
        .media_query_list => writer.writeAll("<MediaQueryList>"),
        .message_port => writer.writeAll("<MessagePort>"),
        .broadcast_channel => writer.writeAll("<BroadcastChannel>"),
        .text_track => writer.writeAll("<TextTrack>"),
        .text_track_cue => writer.writeAll("<TextTrackCue>"),
        .text_track_list => writer.writeAll("<TextTrackList>"),
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
        .payment_request => writer.writeAll("<PaymentRequest>"),
        .payment_response => writer.writeAll("<PaymentResponse>"),
        .permission_status => writer.writeAll("<PermissionStatus>"),
        .navigation_history_entry => writer.writeAll("<NavigationHistoryEntry>"),
    };
}

pub fn toString(self: *EventTarget) []const u8 {
    return switch (self._type) {
        .abort_signal => return "[object AbortSignal]",
        .animation => return "[object Animation]",
        .audio_decoder => return "[object AudioDecoder]",
        .audio_encoder => return "[object AudioEncoder]",
        .audio_node => return self.subtype(AudioNode).toString(),
        .base_audio_context => return "[object BaseAudioContext]",
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
        .payment_request => return "[object PaymentRequest]",
        .payment_response => return "[object PaymentResponse]",
        .performance => return "[object Performance]",
        .permission_status => return "[object PermissionStatus]",
        .screen => return "[object Screen]",
        .screen_orientation => return "[object ScreenOrientation]",
        .service_worker => return "[object ServiceWorker]",
        .service_worker_container => return "[object ServiceWorkerContainer]",
        .service_worker_registration => return "[object ServiceWorkerRegistration]",
        .shared_worker => return "[object SharedWorker]",
        .text_track => return "[object TextTrack]",
        .text_track_cue => return "[object TextTrackCue]",
        .text_track_list => return "[object TextTrackList]",
        .video_decoder => return "[object VideoDecoder]",
        .video_encoder => return "[object VideoEncoder]",
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
    // (fine to go up to 8, since it'll always be padded to that)
    try testing.expectEqual(1, @sizeOf(EventTarget));
    try testing.htmlRunner("events.html", .{});
    try testing.htmlRunner("event/listener_removal.html", .{});
    try testing.htmlRunner("event/message_multiple_listeners.html", .{});
}
