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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const Element = @import("../Element.zig");
const AbortSignal = @import("../AbortSignal.zig");
const DOMException = @import("../DOMException.zig");
const FormData = @import("../net/FormData.zig");
const NavigationType = @import("../navigation/root.zig").NavigationType;
const NavigationDestination = @import("../navigation/NavigationDestination.zig");

const String = lp.String;

// https://developer.mozilla.org/en-US/docs/Web/API/NavigateEvent
const NavigateEvent = @This();

pub const Proto = Event;

_proto: *Event,
_navigation_type: NavigationType,
_destination: *NavigationDestination,
_can_intercept: bool, // TODO. Not supported, currently always false
_user_initiated: bool,
_hash_change: bool,
_signal: *AbortSignal,
_form_data: ?*FormData,
_download_request: ?[]const u8,
_info: ?js.Value.Global,
_has_ua_visual_transition: bool,
_source_element: ?*Element,

const NavigateEventOptions = struct {
    canIntercept: bool = false,
    destination: *NavigationDestination,
    downloadRequest: ?[]const u8 = null,
    formData: ?*FormData = null,
    hasUAVisualTransition: bool = false,
    hashChange: bool = false,
    info: ?js.Value.Global = null,
    navigationType: []const u8 = "push",
    signal: *AbortSignal,
    sourceElement: ?*Element = null,
    userInitiated: bool = false,
};

pub const Options = Event.inheritOptions(NavigateEvent, NavigateEventOptions);

pub fn init(typ: []const u8, opts: Options, frame: *Frame) !*NavigateEvent {
    const arena = try frame.getArena(.tiny, "NavigateEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, opts, false, frame);
}

pub fn initTrusted(opts: Options, frame: *Frame) !*NavigateEvent {
    const arena = try frame.getArena(.tiny, "NavigateEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, comptime .wrap("navigate"), opts, true, frame);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts: Options, trusted: bool, frame: *Frame) !*NavigateEvent {
    const navigation_type = std.meta.stringToEnum(NavigationType, opts.navigationType) orelse return error.TypeError;
    const download_request = if (opts.downloadRequest) |dr| try arena.dupe(u8, dr) else null;

    const event = try frame._factory.event(
        arena,
        typ,
        NavigateEvent{
            ._proto = undefined,
            ._navigation_type = navigation_type,
            ._destination = opts.destination,
            ._can_intercept = opts.canIntercept,
            ._user_initiated = opts.userInitiated,
            ._hash_change = opts.hashChange,
            ._signal = opts.signal,
            ._form_data = opts.formData,
            ._download_request = download_request,
            ._info = opts.info,
            ._has_ua_visual_transition = opts.hasUAVisualTransition,
            ._source_element = opts.sourceElement,
        },
    );
    if (opts.formData) |fd| {
        fd.acquireRef();
    }

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn deinit(self: *NavigateEvent, page: *Page) void {
    if (self._info) |info| {
        info.release();
    }
    if (self._form_data) |fd| {
        fd.releaseRef(page);
    }
}

pub fn asEvent(self: *NavigateEvent) *Event {
    return self._proto;
}

fn getNavigationType(self: *const NavigateEvent) []const u8 {
    return @tagName(self._navigation_type);
}

fn getDestination(self: *const NavigateEvent) *NavigationDestination {
    return self._destination;
}

fn getCanIntercept(self: *const NavigateEvent) bool {
    return self._can_intercept;
}

fn getUserInitiated(self: *const NavigateEvent) bool {
    return self._user_initiated;
}

fn getHashChange(self: *const NavigateEvent) bool {
    return self._hash_change;
}

fn getSignal(self: *const NavigateEvent) *AbortSignal {
    return self._signal;
}

fn getFormData(self: *const NavigateEvent) ?*FormData {
    return self._form_data;
}

fn getDownloadRequest(self: *const NavigateEvent) ?[]const u8 {
    return self._download_request;
}

const InfoReturn = union(enum) { value: js.Value.Global, undefined: void };

fn getInfo(self: *const NavigateEvent) InfoReturn {
    const info = self._info orelse return .undefined;
    return .{ .value = info };
}

fn getHasUAVisualTransition(self: *const NavigateEvent) bool {
    return self._has_ua_visual_transition;
}

fn getSourceElement(self: *const NavigateEvent) ?*Element {
    return self._source_element;
}

const Thrown = union(enum) { exception: js.Exception, undefined: void };

// The messages match Chrome's.
fn sharedChecks(self: *const NavigateEvent, comptime method: []const u8, frame: *Frame) ?js.Exception {
    const local = frame.js.local.?;
    const event = self._proto;
    if (event._is_trusted == false) {
        return local.newException(DOMException.init(method ++ "() may only be called on a trusted event.", "SecurityError"));
    }
    if (event._prevent_default) {
        return local.newException(DOMException.init(method ++ "() may not be called if the event has been canceled.", "InvalidStateError"));
    }
    // A trusted navigate event is being dispatched while it's the ongoing
    // navigation's (direct dispatch doesn't set the event phase).
    if (frame._ongoing_navigate) |ongoing| {
        if (ongoing.event == self) {
            return null;
        }
    }
    return local.newException(DOMException.init(method ++ "() may only be called while the navigate event is being dispatched.", "InvalidStateError"));
}

// Not supported: canIntercept is always false, so this always throws.
fn intercept(self: *const NavigateEvent, _: ?js.Value, frame: *Frame) !Thrown {
    const local = frame.js.local.?;
    if (self.sharedChecks("intercept", frame)) |exception| {
        return .{ .exception = exception };
    }

    if (self._can_intercept == false) {
        const message = try frame.page_arena.print(
            "A navigation with URL '{s}' cannot be intercepted by in a window with origin '{s}' and URL '{s}'.",
            .{ self._destination._url, frame.origin orelse "null", frame.url },
        );
        return .{ .exception = local.newException(DOMException.init(message, "SecurityError")) };
    }
    return .undefined;
}

fn scroll(self: *const NavigateEvent, frame: *Frame) Thrown {
    if (self.sharedChecks("scroll", frame)) |exception| {
        return .{ .exception = exception };
    }
    // Only an intercepted navigation can be scrolled, and we never intercept.
    return .{ .exception = frame.js.local.?.newException(DOMException.init("intercept() must be called before scroll()", "InvalidStateError")) };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigateEvent);

    pub const Meta = struct {
        pub const name = "NavigateEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(NavigateEvent.init, .{});
    pub const navigationType = bridge.accessor(NavigateEvent.getNavigationType, null, .{});
    pub const destination = bridge.accessor(NavigateEvent.getDestination, null, .{});
    pub const canIntercept = bridge.accessor(NavigateEvent.getCanIntercept, null, .{});
    pub const userInitiated = bridge.accessor(NavigateEvent.getUserInitiated, null, .{});
    pub const hashChange = bridge.accessor(NavigateEvent.getHashChange, null, .{});
    pub const signal = bridge.accessor(NavigateEvent.getSignal, null, .{});
    pub const formData = bridge.accessor(NavigateEvent.getFormData, null, .{});
    pub const downloadRequest = bridge.accessor(NavigateEvent.getDownloadRequest, null, .{});
    pub const info = bridge.accessor(NavigateEvent.getInfo, null, .{});
    pub const hasUAVisualTransition = bridge.accessor(NavigateEvent.getHasUAVisualTransition, null, .{});
    pub const sourceElement = bridge.accessor(NavigateEvent.getSourceElement, null, .{});
    pub const intercept = bridge.function(NavigateEvent.intercept, .{});
    pub const scroll = bridge.function(NavigateEvent.scroll, .{});
};
