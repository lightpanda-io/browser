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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");

const UIEvent = @import("UIEvent.zig");
const PointerEvent = @import("PointerEvent.zig");

const String = lp.String;
const Allocator = std.mem.Allocator;

const MouseEvent = @This();

pub const MouseButton = enum(u8) {
    main = 0,
    auxiliary = 1,
    secondary = 2,
    fourth = 3,
    fifth = 4,
};

pub const Type = union(enum) {
    generic,
    pointer_event: *PointerEvent,
    wheel_event: *@import("WheelEvent.zig"),
};

_type: Type,
_proto: *UIEvent,

_alt_key: bool,
_button: MouseButton,
_buttons: u16,
_client_x: f64,
_client_y: f64,
_ctrl_key: bool,
_meta_key: bool,
// https://developer.mozilla.org/en-US/docs/Web/API/MouseEvent/relatedTarget
_related_target: ?*EventTarget = null,
_screen_x: f64,
_screen_y: f64,
_shift_key: bool,

pub const MouseEventOptions = struct {
    screenX: f64 = 0.0,
    screenY: f64 = 0.0,
    clientX: f64 = 0.0,
    clientY: f64 = 0.0,
    ctrlKey: bool = false,
    shiftKey: bool = false,
    altKey: bool = false,
    metaKey: bool = false,
    button: i32 = 0,
    buttons: u16 = 0,
    relatedTarget: ?*EventTarget = null,
};

pub const Options = Event.inheritOptions(
    MouseEvent,
    MouseEventOptions,
);

pub fn init(typ: []const u8, _opts: ?Options, frame: *Frame) !*MouseEvent {
    const arena = try frame.getArena(.tiny, "MouseEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, _opts, false, frame);
}

pub fn initTrusted(typ: String, _opts: ?Options, frame: *Frame) !*MouseEvent {
    const arena = try frame.getArena(.tiny, "MouseEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, _opts, true, frame);
}

fn initWithTrusted(arena: Allocator, typ: String, _opts: ?Options, trusted: bool, frame: *Frame) !*MouseEvent {
    const opts = _opts orelse Options{};

    const event = try frame._factory.uiEvent(
        arena,
        typ,
        MouseEvent{
            ._type = .generic,
            ._proto = undefined,
            ._screen_x = opts.screenX,
            ._screen_y = opts.screenY,
            ._client_x = opts.clientX,
            ._client_y = opts.clientY,
            ._ctrl_key = opts.ctrlKey,
            ._shift_key = opts.shiftKey,
            ._alt_key = opts.altKey,
            ._meta_key = opts.metaKey,
            ._button = std.meta.intToEnum(MouseButton, opts.button) catch return error.TypeError,
            ._buttons = opts.buttons,
            ._related_target = opts.relatedTarget,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

pub fn asEvent(self: *MouseEvent) *Event {
    return self._proto.asEvent();
}

pub fn as(self: *MouseEvent, comptime T: type) *T {
    return self.is(T).?;
}

pub fn is(self: *MouseEvent, comptime T: type) ?*T {
    switch (self._type) {
        .generic => return if (T == MouseEvent) self else null,
        .pointer_event => |e| return if (T == PointerEvent) e else null,
        .wheel_event => |e| return if (T == @import("WheelEvent.zig")) e else null,
    }
    return null;
}

pub fn getAltKey(self: *const MouseEvent) bool {
    return self._alt_key;
}

pub fn getButton(self: *const MouseEvent) u8 {
    return @intFromEnum(self._button);
}

pub fn getButtons(self: *const MouseEvent) u16 {
    return self._buttons;
}

pub fn getClientX(self: *const MouseEvent) f64 {
    return self._client_x;
}

pub fn getClientY(self: *const MouseEvent) f64 {
    return self._client_y;
}

pub fn getCtrlKey(self: *const MouseEvent) bool {
    return self._ctrl_key;
}

pub fn getMetaKey(self: *const MouseEvent) bool {
    return self._meta_key;
}

pub fn getPageX(self: *const MouseEvent) f64 {
    // this should be clientX + window.scrollX
    return self._client_x;
}

pub fn getPageY(self: *const MouseEvent) f64 {
    // this should be clientY + window.scrollY
    return self._client_y;
}

pub fn getRelatedTarget(self: *const MouseEvent) ?*EventTarget {
    return self._related_target;
}

pub fn getScreenX(self: *const MouseEvent) f64 {
    return self._screen_x;
}

pub fn getScreenY(self: *const MouseEvent) f64 {
    return self._screen_y;
}

pub fn getShiftKey(self: *const MouseEvent) bool {
    return self._shift_key;
}

// Deprecated: tracks the same value as offsetX/clientX in the absence of layout.
pub fn getLayerX(self: *const MouseEvent) f64 {
    return self._client_x;
}

pub fn getLayerY(self: *const MouseEvent) f64 {
    return self._client_y;
}

pub fn getModifierState(self: *const MouseEvent, key: []const u8) bool {
    if (std.mem.eql(u8, key, "Alt") or std.mem.eql(u8, key, "AltGraph")) return self._alt_key;
    if (std.mem.eql(u8, key, "Control")) return self._ctrl_key;
    if (std.mem.eql(u8, key, "Shift")) return self._shift_key;
    if (std.mem.eql(u8, key, "Meta")) return self._meta_key;
    if (std.mem.eql(u8, key, "Accel")) return self._ctrl_key or self._meta_key;
    return false;
}

pub fn initMouseEvent(
    self: *MouseEvent,
    typ: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
    view: ?*@import("../Window.zig"),
    detail: ?i32,
    screen_x: ?i32,
    screen_y: ?i32,
    client_x: ?i32,
    client_y: ?i32,
    ctrl_key: ?bool,
    alt_key: ?bool,
    shift_key: ?bool,
    meta_key: ?bool,
    button: ?i16,
    related_target: ?*EventTarget,
) !void {
    const ui = self._proto;
    const event = ui._proto;
    if (event._event_phase != .none) {
        return;
    }

    event._type_string = try String.init(event._arena, typ, .{});
    event._bubbles = bubbles orelse false;
    event._cancelable = cancelable orelse false;
    ui._view = view;
    ui._detail = if (detail) |d| @intCast(@max(d, 0)) else 0;
    self._screen_x = @floatFromInt(screen_x orelse 0);
    self._screen_y = @floatFromInt(screen_y orelse 0);
    self._client_x = @floatFromInt(client_x orelse 0);
    self._client_y = @floatFromInt(client_y orelse 0);
    self._ctrl_key = ctrl_key orelse false;
    self._alt_key = alt_key orelse false;
    self._shift_key = shift_key orelse false;
    self._meta_key = meta_key orelse false;
    self._button = std.meta.intToEnum(MouseButton, button orelse 0) catch return error.TypeError;
    self._related_target = related_target;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MouseEvent);

    pub const Meta = struct {
        pub const name = "MouseEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(MouseEvent.init, .{});
    pub const altKey = bridge.accessor(getAltKey, null, .{});
    pub const button = bridge.accessor(getButton, null, .{});
    pub const buttons = bridge.accessor(getButtons, null, .{});
    pub const clientX = bridge.accessor(getClientX, null, .{});
    pub const clientY = bridge.accessor(getClientY, null, .{});
    pub const ctrlKey = bridge.accessor(getCtrlKey, null, .{});
    pub const metaKey = bridge.accessor(getMetaKey, null, .{});
    pub const offsetX = bridge.property(0.0, .{ .template = false });
    pub const offsetY = bridge.property(0.0, .{ .template = false });
    pub const pageX = bridge.accessor(getPageX, null, .{});
    pub const pageY = bridge.accessor(getPageY, null, .{});
    pub const relatedTarget = bridge.accessor(getRelatedTarget, null, .{});
    pub const screenX = bridge.accessor(getScreenX, null, .{});
    pub const screenY = bridge.accessor(getScreenY, null, .{});
    pub const shiftKey = bridge.accessor(getShiftKey, null, .{});
    pub const layerX = bridge.accessor(getLayerX, null, .{});
    pub const layerY = bridge.accessor(getLayerY, null, .{});
    pub const x = bridge.accessor(getClientX, null, .{});
    pub const y = bridge.accessor(getClientY, null, .{});
    pub const getModifierState = bridge.function(MouseEvent.getModifierState, .{});
    pub const initMouseEvent = bridge.function(MouseEvent.initMouseEvent, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: MouseEvent" {
    try testing.htmlRunner("event/mouse.html", .{});
}
