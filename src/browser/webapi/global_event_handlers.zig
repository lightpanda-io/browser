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

const Key = struct {
    target: *EventTarget,
    handler: Handler,

    /// Fuses `target` pointer and `handler` enum; used at hashing.
    /// NEVER use a fusion to retrieve a pointer back. Portability is not guaranteed.
    /// See `Context.hash`.
    fn fuse(self: *const Key) u64 {
        // Check if we have 3 bits available from alignment of 8.
        lp.assert(@alignOf(EventTarget) == 8, "Key.fuse: incorrect alignment", .{
            .event_target_alignment = @alignOf(EventTarget),
        });

        const ptr = @intFromPtr(self.target) >> 3;
        lp.assert(ptr < (1 << 57), "Key.fuse: pointer overflow", .{ .ptr = ptr });
        return ptr | (@as(u64, @intFromEnum(self.handler)) << 57);
    }
};

const Context = struct {
    pub fn hash(_: @This(), key: Key) u64 {
        return std.hash.int(key.fuse());
    }

    pub fn eql(_: @This(), a: Key, b: Key) bool {
        return a.fuse() == b.fuse();
    }
};

pub const Lookup = std.HashMapUnmanaged(
    Key,
    js.Function.Global,
    Context,
    std.hash_map.default_max_load_percentage,
);

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
