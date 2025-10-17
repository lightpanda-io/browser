const js = @import("../../js/js.zig");

const Page = @import("../../Page.zig");
const EventTarget = @import("../EventTarget.zig");
const ProgressEvent = @import("../event/ProgressEvent.zig");

const XMLHttpRequestEventTarget = @This();

_type: Type,
_proto: *EventTarget,
_on_abort: ?js.Function = null,
_on_error: ?js.Function = null,
_on_load: ?js.Function = null,
_on_load_end: ?js.Function = null,
_on_load_start: ?js.Function = null,
_on_progress: ?js.Function = null,
_on_timeout: ?js.Function = null,

pub const Type = union(enum) {
    request: @import("XMLHttpRequest.zig"),
    // TODO: xml_http_request_upload
};

pub fn asEventTarget(self: *XMLHttpRequestEventTarget) *EventTarget {
    return self._proto;
}

pub fn dispatch(self: *XMLHttpRequestEventTarget, comptime event_type: DispatchType, progress_: ?Progress, page: *Page) !void {
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
    const event = try ProgressEvent.init(typ, progress.total, progress.loaded, page);

    return page._event_manager.dispatchWithFunction(
        self.asEventTarget(),
        event.asEvent(),
        @field(self, field),
        .{ .context = "XHR " ++ typ },
    );
}

pub fn getOnAbort(self: *const XMLHttpRequestEventTarget) ?js.Function {
    return self._on_abort;
}

pub fn setOnAbort(self: *XMLHttpRequestEventTarget, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_abort = try cb.withThis(self);
    } else {
        self._on_abort = null;
    }
}

pub fn getOnError(self: *const XMLHttpRequestEventTarget) ?js.Function {
    return self._on_error;
}

pub fn setOnError(self: *XMLHttpRequestEventTarget, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_error = try cb.withThis(self);
    } else {
        self._on_error = null;
    }
}

pub fn getOnLoad(self: *const XMLHttpRequestEventTarget) ?js.Function {
    return self._on_load;
}

pub fn setOnLoad(self: *XMLHttpRequestEventTarget, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_load = try cb.withThis(self);
    } else {
        self._on_load = null;
    }
}

pub fn getOnLoadEnd(self: *const XMLHttpRequestEventTarget) ?js.Function {
    return self._on_load_end;
}

pub fn setOnLoadEnd(self: *XMLHttpRequestEventTarget, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_load_end = try cb.withThis(self);
    } else {
        self._on_load_end = null;
    }
}

pub fn getOnLoadStart(self: *const XMLHttpRequestEventTarget) ?js.Function {
    return self._on_load_start;
}

pub fn setOnLoadStart(self: *XMLHttpRequestEventTarget, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_load_start = try cb.withThis(self);
    } else {
        self._on_load_start = null;
    }
}

pub fn getOnProgress(self: *const XMLHttpRequestEventTarget) ?js.Function {
    return self._on_progress;
}

pub fn setOnProgress(self: *XMLHttpRequestEventTarget, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_progress = try cb.withThis(self);
    } else {
        self._on_progress = null;
    }
}

pub fn getOnTimeout(self: *const XMLHttpRequestEventTarget) ?js.Function {
    return self._on_timeout;
}

pub fn setOnTimeout(self: *XMLHttpRequestEventTarget, cb_: ?js.Function) !void {
    if (cb_) |cb| {
        self._on_timeout = try cb.withThis(self);
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
        pub var class_index: u16 = 0;
    };

    pub const onloadstart = bridge.accessor(XMLHttpRequestEventTarget.getOnLoadStart, XMLHttpRequestEventTarget.setOnLoadStart, .{});
    pub const onprogress = bridge.accessor(XMLHttpRequestEventTarget.getOnProgress, XMLHttpRequestEventTarget.setOnProgress, .{});
    pub const onabort = bridge.accessor(XMLHttpRequestEventTarget.getOnAbort, XMLHttpRequestEventTarget.setOnAbort, .{});
    pub const onerror = bridge.accessor(XMLHttpRequestEventTarget.getOnError, XMLHttpRequestEventTarget.setOnError, .{});
    pub const onload = bridge.accessor(XMLHttpRequestEventTarget.getOnLoad, XMLHttpRequestEventTarget.setOnLoad, .{});
    pub const ontimeout = bridge.accessor(XMLHttpRequestEventTarget.getOnTimeout, XMLHttpRequestEventTarget.setOnTimeout, .{});
    pub const onloadend = bridge.accessor(XMLHttpRequestEventTarget.getOnLoadEnd, XMLHttpRequestEventTarget.setOnLoadEnd, .{});
};
