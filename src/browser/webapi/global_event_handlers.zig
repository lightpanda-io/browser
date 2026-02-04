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

const js = @import("../js/js.zig");

const EventTarget = @import("EventTarget.zig");

/// Better to discriminate it since not directly a pointer int.
///
/// See `calculateKey` to obtain one.
const Key = u64;

/// Use `calculateKey` to create a key.
pub const Lookup = std.AutoHashMapUnmanaged(Key, js.Function.Global);

/// Enum of known event listeners; increasing the size of it (u7)
/// can cause `Key` to behave incorrectly.
pub const Handler = enum(u7) {
    onabort,
    onanimationcancel,
    onanimationend,
    onanimationiteration,
    onanimationstart,
    onauxclick,
    onbeforeinput,
    onbeforematch,
    onbeforetoggle,
    onblur,
    oncancel,
    oncanplay,
    oncanplaythrough,
    onchange,
    onclick,
    onclose,
    oncommand,
    oncontentvisibilityautostatechange,
    oncontextlost,
    oncontextmenu,
    oncontextrestored,
    oncopy,
    oncuechange,
    oncut,
    ondblclick,
    ondrag,
    ondragend,
    ondragenter,
    ondragexit,
    ondragleave,
    ondragover,
    ondragstart,
    ondrop,
    ondurationchange,
    onemptied,
    onended,
    onerror,
    onfocus,
    onformdata,
    onfullscreenchange,
    onfullscreenerror,
    ongotpointercapture,
    oninput,
    oninvalid,
    onkeydown,
    onkeypress,
    onkeyup,
    onload,
    onloadeddata,
    onloadedmetadata,
    onloadstart,
    onlostpointercapture,
    onmousedown,
    onmousemove,
    onmouseout,
    onmouseover,
    onmouseup,
    onpaste,
    onpause,
    onplay,
    onplaying,
    onpointercancel,
    onpointerdown,
    onpointerenter,
    onpointerleave,
    onpointermove,
    onpointerout,
    onpointerover,
    onpointerrawupdate,
    onpointerup,
    onprogress,
    onratechange,
    onreset,
    onresize,
    onscroll,
    onscrollend,
    onsecuritypolicyviolation,
    onseeked,
    onseeking,
    onselect,
    onselectionchange,
    onselectstart,
    onslotchange,
    onstalled,
    onsubmit,
    onsuspend,
    ontimeupdate,
    ontoggle,
    ontransitioncancel,
    ontransitionend,
    ontransitionrun,
    ontransitionstart,
    onvolumechange,
    onwaiting,
    onwheel,
};

/// Calculates a lookup key to use with lookup for event target.
/// NEVER use generated key to retrieve a pointer back. Portability is not guaranteed.
pub fn calculateKey(event_target: *EventTarget, handler_type: Handler) Key {
    // Check if we have 3 bits available from alignment of 8.
    lp.assert(@alignOf(EventTarget) == 8, "calculateKey: incorrect alignment", .{
        .event_target_alignment = @alignOf(EventTarget),
    });

    const ptr = @intFromPtr(event_target) >> 3;
    lp.assert(ptr < (1 << 57), "calculateKey: pointer overflow", .{ .ptr = ptr });
    return ptr | (@as(Key, @intFromEnum(handler_type)) << 57);
}
