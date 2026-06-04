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

const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");

const EventTarget = @import("../EventTarget.zig");
const XMLHttpRequest = @import("XMLHttpRequest.zig");
const XMLHttpRequestEventTarget = @import("XMLHttpRequestEventTarget.zig");

// https://xhr.spec.whatwg.org/#xmlhttprequestupload
//
// Returned by XMLHttpRequest.upload. It only inherits from
// XMLHttpRequestEventTarget; it has no members of its own. We don't yet emit
// upload progress events, but the object still needs to exist so scripts (e.g.
// htmx) can call addEventListener on it without throwing.
const XMLHttpRequestUpload = @This();

_proto: *XMLHttpRequestEventTarget,
_xhr: *XMLHttpRequest,

// pub fn deinit(self: *XMLHttpRequestUpload, _: *Page) void {
//     self._proto.releaseListeners();
// }

pub fn releaseRef(self: *XMLHttpRequestUpload, page: *Page) void {
    self._xhr.releaseRef(page);
}

pub fn acquireRef(self: *XMLHttpRequestUpload) void {
    self._xhr.acquireRef();
}

pub fn asEventTarget(self: *XMLHttpRequestUpload) *EventTarget {
    return self._proto.asEventTarget();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLHttpRequestUpload);

    pub const Meta = struct {
        pub const name = "XMLHttpRequestUpload";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};
