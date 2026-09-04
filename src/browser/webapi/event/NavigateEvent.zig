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
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const NavigationHistoryEntry = @import("../navigation/NavigationHistoryEntry.zig");
const NavigationType = @import("../navigation/root.zig").NavigationType;
const NavigationDestination = @import("../navigation/NavigationDestination.zig");

const String = lp.String;

const NavigateEvent = @This();

pub const Proto = Event;

_proto: *Event,
_navigation_type: NavigationType,
_can_intercept: bool,
_user_initiated: bool,
_hash_change: bool,
_download_request: ?[]const u8,
_info: ?js.Value.Global,
_has_ua_visual_transition: bool,
_destination: *NavigationDestination,

_intercepted: bool = false,

_handler: ?js.Function.Global = null,
_focus_reset: ?[]const u8 = null,
_scroll: ?[]const u8 = null,

const NavigateEventOptions = struct {
    canIntercept: bool = false,
    destination: *NavigationDestination,
    downloadRequest: ?[]const u8 = null,
    hasUAVisualTransition: bool = false,
    hashChange: bool = false,
    info: ?js.Value = null,
    navigationType: ?[]const u8 = null,
    userInitiated: bool = false,
    // TODO: formData
    // TODO: signal
    // TODO: sourceElement
};

const Options = Event.inheritOptions(NavigateEvent, NavigateEventOptions);

pub fn init(typ: []const u8, opts: Options, frame: *Frame) !*NavigateEvent {
    const arena = try frame.getArena(.tiny, "NavigateEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, opts, false, frame);
}

pub fn initTrusted(typ: String, opts: Options, frame: *Frame) !*NavigateEvent {
    const arena = try frame.getArena(.tiny, "NavigateEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, opts, true, frame);
}

fn initWithTrusted(
    arena: *lp.Arena,
    typ: String,
    opts: Options,
    trusted: bool,
    frame: *Frame,
) !*NavigateEvent {
    // Per NavigateEventInit, navigationType defaults to "push" when omitted.
    const navigation_type = if (opts.navigationType) |nav_type_str|
        std.meta.stringToEnum(NavigationType, nav_type_str) orelse .push
    else
        .push;

    const info: ?js.Value.Global = if (opts.info) |v| try v.persist() else null;

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
            // TODO: signal
            // TODO: formData
            // TODO: sourceElement
            ._download_request = opts.downloadRequest,
            ._info = info,
            ._has_ua_visual_transition = opts.hasUAVisualTransition,
        },
    );
    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *NavigateEvent) *Event {
    return self._proto;
}

pub fn getNavigationType(self: *const NavigateEvent) []const u8 {
    return @tagName(self._navigation_type);
}

pub fn getCanIntercept(self: *const NavigateEvent) bool {
    return self._can_intercept;
}

pub fn getDestination(self: *const NavigateEvent) *NavigationDestination {
    return self._destination;
}

pub fn getUserInitiated(self: *const NavigateEvent) bool {
    return self._user_initiated;
}

pub fn getHashChange(self: *const NavigateEvent) bool {
    return self._hash_change;
}

pub fn getDownloadRequest(self: *const NavigateEvent) ?[]const u8 {
    return self._download_request;
}

pub fn getInfo(self: *const NavigateEvent, exec: *const js.Execution) ?js.Value {
    if (self._info) |info| {
        return exec.js.local.?.toLocal(info);
    }

    return null;
}

pub fn getHasUAVisualTransition(self: *const NavigateEvent) bool {
    return self._has_ua_visual_transition;
}

const InterceptOptions = struct {
    focusReset: ?[]const u8 = null,
    handler: ?js.Function = null,
    scroll: ?[]const u8 = null,
};

// https://html.spec.whatwg.org/#dom-navigateevent-intercept
pub fn intercept(self: *NavigateEvent, opts: ?InterceptOptions) !void {
    lp.log.warn(.browser, "navigate intercept 1", .{});

    if (!self._can_intercept) {
        return error.InvalidStateError;
    }
    if (!self._proto.getCancelable()) {
        return error.InvalidStateError;
    }

    lp.log.warn(.browser, "navigate intercept 2", .{});
    self._intercepted = true;

    if (opts) |o| {
        if (o.handler) |handler| self._handler = try handler.persist();
        self._focus_reset = o.focusReset;
        self._scroll = o.scroll;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigateEvent);

    pub const Meta = struct {
        pub const name = "NavigateEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(NavigateEvent.init, .{});
    pub const navigationType = bridge.accessor(NavigateEvent.getNavigationType, null, .{});
    pub const canIntercept = bridge.accessor(NavigateEvent.getCanIntercept, null, .{});
    pub const destination = bridge.accessor(NavigateEvent.getDestination, null, .{});
    pub const userInitiated = bridge.accessor(NavigateEvent.getUserInitiated, null, .{});
    pub const hashChange = bridge.accessor(NavigateEvent.getHashChange, null, .{});
    pub const downloadRequest = bridge.accessor(NavigateEvent.getDownloadRequest, null, .{});
    pub const info = bridge.accessor(NavigateEvent.getInfo, null, .{});
    pub const hasUAVisualTransition = bridge.accessor(NavigateEvent.getHasUAVisualTransition, null, .{});
    pub const intercept = bridge.function(NavigateEvent.intercept, .{});
};
