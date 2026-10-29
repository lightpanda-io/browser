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

const EventTarget = @import("../EventTarget.zig");
const ProgressEvent = @import("../event/ProgressEvent.zig");

const Execution = js.Execution;

const XMLHttpRequestEventTarget = @This();

pub const Proto = EventTarget;

_type: Type,
_proto: *EventTarget,

pub const Type = union(enum) {
    request: *@import("XMLHttpRequest.zig"),
    upload: *@import("XMLHttpRequestUpload.zig"),
};

pub fn asEventTarget(self: *XMLHttpRequestEventTarget) *EventTarget {
    return self._proto;
}

pub fn dispatch(self: *XMLHttpRequestEventTarget, comptime event_type: DispatchType, progress_: ?Progress, exec: *const Execution) !void {
    const typ = comptime switch (event_type) {
        .abort => "abort",
        .err => "error",
        .load => "load",
        .load_end => "loadend",
        .load_start => "loadstart",
        .progress => "progress",
        .timeout => "timeout",
    };

    const progress = progress_ orelse Progress{};
    const event = (try ProgressEvent.initTrusted(
        comptime .wrap(typ),
        .{
            .total = progress.total,
            .loaded = progress.loaded,
            .lengthComputable = progress.length_computable,
        },
        exec.page,
    )).asEvent();

    return exec.dispatch(
        self.asEventTarget(),
        event,
        .{ .context = "XHR " ++ typ },
    );
}

const DispatchType = enum {
    abort,
    err,
    load,
    load_end,
    load_start,
    progress,
    timeout,
};

const Progress = struct {
    loaded: usize = 0,
    total: usize = 0,
    length_computable: bool = false,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLHttpRequestEventTarget);

    pub const Meta = struct {
        pub const name = "XMLHttpRequestEventTarget";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onloadstart = EventTarget.handlerAccessor(XMLHttpRequestEventTarget, "loadstart");
    pub const onprogress = EventTarget.handlerAccessor(XMLHttpRequestEventTarget, "progress");
    pub const onabort = EventTarget.handlerAccessor(XMLHttpRequestEventTarget, "abort");
    pub const onerror = EventTarget.handlerAccessor(XMLHttpRequestEventTarget, "error");
    pub const onload = EventTarget.handlerAccessor(XMLHttpRequestEventTarget, "load");
    pub const ontimeout = EventTarget.handlerAccessor(XMLHttpRequestEventTarget, "timeout");
    pub const onloadend = EventTarget.handlerAccessor(XMLHttpRequestEventTarget, "loadend");
};
