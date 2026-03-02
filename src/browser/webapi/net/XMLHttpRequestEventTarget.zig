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

const Page = @import("../../Page.zig");
const EventTarget = @import("../EventTarget.zig");
const ProgressEvent = @import("../event/ProgressEvent.zig");

const XMLHttpRequestEventTarget = @This();

_type: Type,
_proto: *EventTarget,
_on_abort: ?js.Function.Temp = null,
_on_error: ?js.Function.Temp = null,
_on_load: ?js.Function.Temp = null,
_on_load_end: ?js.Function.Temp = null,
_on_load_start: ?js.Function.Temp = null,
_on_progress: ?js.Function.Temp = null,
_on_timeout: ?js.Function.Temp = null,

pub const Type = union(enum) {
    request: *@import("XMLHttpRequest.zig"),
    // TODO: xml_http_request_upload
};

pub fn asEventTarget(self: *XMLHttpRequestEventTarget) *EventTarget {
    return self._proto;
}

pub fn dispatch(self: *XMLHttpRequestEventTarget, comptime event_type: DispatchType, progress_: ?Progress, local: *const js.Local, page: *Page) !void {
    const field, const typ = comptime blk: {
        break :blk switch (event_type) {
            .abort => .{ "_on_abort", "abort" },
            .err => .{ "_on_error", "error" },
            .load => .{ "_on_load", "load" },
            .load_end => .{ "_on_load_end", "loadend" },
            .load_start => .{ "_on_load_start", "loadstart" },
            .progress => .{ "_on_progress", "progress" },
            .timeout => .{ "_on_timeout", "timeout" },
        };
    };

    const progress = progress_ orelse Progress{};
    const event = (try ProgressEvent.initTrusted(
        comptime .wrap(typ),
        .{ .total = progress.total, .loaded = progress.loaded },
        page,
    )).asEvent();

    return page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event,
        local.toLocal(@field(self, field)),
        .{ .context = "XHR " ++ typ },
    );
}

pub fn getOnAbort(self: *const XMLHttpRequestEventTarget) ?js.Function.Temp {
    return self._on_abort;
}

pub fn setOnAbort(self: *XMLHttpRequestEventTarget, cb: ?js.Function.Temp) !void {
    self._on_abort = cb;
}

pub fn getOnError(self: *const XMLHttpRequestEventTarget) ?js.Function.Temp {
    return self._on_error;
}

pub fn setOnError(self: *XMLHttpRequestEventTarget, cb: ?js.Function.Temp) !void {
    self._on_error = cb;
}

pub fn getOnLoad(self: *const XMLHttpRequestEventTarget) ?js.Function.Temp {
    return self._on_load;
}

pub fn setOnLoad(self: *XMLHttpRequestEventTarget, cb: ?js.Function.Temp) !void {
    self._on_load = cb;
}

pub fn getOnLoadEnd(self: *const XMLHttpRequestEventTarget) ?js.Function.Temp {
    return self._on_load_end;
}

pub fn setOnLoadEnd(self: *XMLHttpRequestEventTarget, cb: ?js.Function.Temp) !void {
    self._on_load_end = cb;
}

pub fn getOnLoadStart(self: *const XMLHttpRequestEventTarget) ?js.Function.Temp {
    return self._on_load_start;
}

pub fn setOnLoadStart(self: *XMLHttpRequestEventTarget, cb: ?js.Function.Temp) !void {
    self._on_load_start = cb;
}

pub fn getOnProgress(self: *const XMLHttpRequestEventTarget) ?js.Function.Temp {
    return self._on_progress;
}

pub fn setOnProgress(self: *XMLHttpRequestEventTarget, cb: ?js.Function.Temp) !void {
    self._on_progress = cb;
}

pub fn getOnTimeout(self: *const XMLHttpRequestEventTarget) ?js.Function.Temp {
    return self._on_timeout;
}

pub fn setOnTimeout(self: *XMLHttpRequestEventTarget, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_timeout = try cb.tempWithThis(self);
    } else {
        self._on_timeout = null;
    }
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
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(XMLHttpRequestEventTarget);

    pub const Meta = struct {
        pub const name = "XMLHttpRequestEventTarget";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const onloadstart = bridge.accessor(XMLHttpRequestEventTarget.getOnLoadStart, XMLHttpRequestEventTarget.setOnLoadStart, .{});
    pub const onprogress = bridge.accessor(XMLHttpRequestEventTarget.getOnProgress, XMLHttpRequestEventTarget.setOnProgress, .{});
    pub const onabort = bridge.accessor(XMLHttpRequestEventTarget.getOnAbort, XMLHttpRequestEventTarget.setOnAbort, .{});
    pub const onerror = bridge.accessor(XMLHttpRequestEventTarget.getOnError, XMLHttpRequestEventTarget.setOnError, .{});
    pub const onload = bridge.accessor(XMLHttpRequestEventTarget.getOnLoad, XMLHttpRequestEventTarget.setOnLoad, .{});
    pub const ontimeout = bridge.accessor(XMLHttpRequestEventTarget.getOnTimeout, XMLHttpRequestEventTarget.setOnTimeout, .{});
    pub const onloadend = bridge.accessor(XMLHttpRequestEventTarget.getOnLoadEnd, XMLHttpRequestEventTarget.setOnLoadEnd, .{});
};
