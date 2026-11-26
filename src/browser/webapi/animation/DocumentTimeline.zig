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

const js = @import("../../js/js.zig");
const Document = @import("../Document.zig");

// https://drafts.csswg.org/web-animations-1/#the-documenttimeline-interface
//
// document.timeline. Only currentTime is implemented: animations are faked
// (see Animation.zig), but sites read document.timeline.currentTime to line
// up their own animations, and throw when document.timeline is undefined.
const DocumentTimeline = @This();

_document: *Document,

// The default document timeline's origin is the document's time origin, so its
// current time is the value performance.now() returns. A document without a
// browsing context (DOMParser, createHTMLDocument) has an inactive timeline:
// its current time is null.
pub fn getCurrentTime(self: *const DocumentTimeline) ?f64 {
    const frame = self._document._frame orelse return null;
    return frame.window._performance.now();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DocumentTimeline);

    pub const Meta = struct {
        pub const name = "DocumentTimeline";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const currentTime = bridge.accessor(DocumentTimeline.getCurrentTime, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: DocumentTimeline" {
    try testing.htmlRunner("animation/document_timeline.html", .{});
}
