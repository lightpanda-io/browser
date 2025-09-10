const std = @import("std");
const log = @import("../../log.zig");

const netsurf = @import("../netsurf.zig");
const Event = @import("event.zig").Event;
const JsObject = @import("../env.zig").JsObject;

const c = @cImport({
    @cInclude("dom/dom.h");
    @cInclude("core/pi.h");
    @cInclude("dom/bindings/hubbub/parser.h");
    @cInclude("events/event_target.h");
    @cInclude("events/event.h");
    @cInclude("events/mouse_event.h");
    @cInclude("events/keyboard_event.h");
    @cInclude("utils/validate.h");
    @cInclude("html/html_element.h");
    @cInclude("html/html_document.h");
});

// TODO: We currently don't have a UIEvent interface so we skip it in the prototype chain.
// https://developer.mozilla.org/en-US/docs/Web/API/UIEvent
const UIEvent = Event;

// https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent
pub const KeyboardEvent = struct {
    pub const Self = netsurf.KeyboardEvent;
    pub const prototype = *UIEvent;

    pub const KeyLocationCode = enum(u16) {
        standard = 0x00,
        left = 0x01,
        right = 0x02,
        numpad = 0x03,
        mobile = 0x04, // Non-standard, deprecated.
        joystick = 0x05, // Non-standard, deprecated.
    };

    pub const ConstructorOptions = struct {
        key: []const u8 = "",
        code: []const u8 = "",
        location: KeyLocationCode = .standard,
        char_code: u32 = 0,
        key_code: u32 = 0,
        which: u32 = 0,
        repeat: bool = false,
        ctrl_key: bool = false,
        shift_key: bool = false,
        alt_key: bool = false,
        meta_key: bool = false,
        is_composing: bool = false,
    };

    pub fn constructor(event_type: []const u8, maybe_options: ?ConstructorOptions) !*netsurf.KeyboardEvent {
        const options = maybe_options orelse ConstructorOptions{};

        const event = try netsurf.keyboardEventCreate();
        try netsurf.keyboardEventInit(
            event,
            event_type,
            .{
                .bubbles = false,
                .cancelable = false,
                .key = options.key,
                .code = options.code,
                .alt = options.alt_key,
                .ctrl = options.ctrl_key,
                .meta = options.meta_key,
                .shift = options.shift_key,
            },
        );

        return event;
    }
};

const testing = @import("../../testing.zig");
test "Browser: Events.Keyboard" {
    try testing.htmlRunner("events/keyboard.html");
}
