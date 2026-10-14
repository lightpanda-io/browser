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

/// The event handlers (onclick, ...) of HTML elements.
pub const Handler = enum {
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
    ontouchcancel,
    ontouchend,
    ontouchmove,
    ontouchstart,
    ontransitioncancel,
    ontransitionend,
    ontransitionrun,
    ontransitionstart,
    onvolumechange,
    onwaiting,
    onwheel,
};

const handlers = std.StaticStringMap(void).initComptime(blk: {
    const names = @typeInfo(Handler).@"enum".field_names;
    var entries: [names.len]struct { []const u8 } = undefined;
    for (names, 0..) |name, i| {
        entries[i] = .{name};
    }
    break :blk entries;
});

/// Whether `name` (e.g. "onclick") is an event handler content attribute.
pub fn isEventHandler(name: []const u8) bool {
    return handlers.has(name);
}

const testing = @import("../../testing.zig");
test "GlobalEventHandlers: isEventHandler" {
    try testing.expectEqual(true, isEventHandler("onabort"));
    try testing.expectEqual(true, isEventHandler("onselect"));
    try testing.expectEqual(false, isEventHandler("abort"));
    try testing.expectEqual(false, isEventHandler("on"));
    try testing.expectEqual(false, isEventHandler(""));
    try testing.expectEqual(false, isEventHandler("onunknown"));
}
