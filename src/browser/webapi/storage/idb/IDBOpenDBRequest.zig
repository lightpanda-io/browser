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

const js = @import("../../../js/js.zig");

const EventTarget = @import("../../EventTarget.zig");
const IDBRequest = @import("IDBRequest.zig");

// The request returned by IDBFactory.open / deleteDatabase.
const IDBOpenDBRequest = @This();

pub const Proto = IDBRequest;

_proto: *IDBRequest,

pub fn asEventTarget(self: *IDBOpenDBRequest) *EventTarget {
    return self._proto.asEventTarget();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IDBOpenDBRequest);

    pub const Meta = struct {
        pub const name = "IDBOpenDBRequest";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onblocked = EventTarget.handlerAccessor(IDBOpenDBRequest, "blocked");
    pub const onupgradeneeded = EventTarget.handlerAccessor(IDBOpenDBRequest, "upgradeneeded");
};
