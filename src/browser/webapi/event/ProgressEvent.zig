const Page = @import("../../Page.zig");
const Event = @import("../Event.zig");

const ProgressEvent = @This();
_proto: *Event,
_total: usize = 0,
_loaded: usize = 0,
_length_computable: bool = false,

pub fn init(typ: []const u8, total: usize, loaded: usize, page: *Page) !*ProgressEvent {
    return page._factory.event(typ, ProgressEvent{
        ._proto = undefined,
        ._total = total,
        ._loaded = loaded,
    });
}

pub fn asEvent(self: *ProgressEvent) *Event {
    return self._proto;
}

pub fn getTotal(self: *const ProgressEvent) usize {
    return self._total;
}

pub fn getLoaded(self: *const ProgressEvent) usize {
    return self._loaded;
}

pub fn getLengthComputable(self: *const ProgressEvent) bool {
    return self._length_computable;
}

pub const JsApi = struct {
    const js = @import("../../js/js.zig");
    pub const bridge = js.Bridge(ProgressEvent);

    pub const Meta = struct {
        pub const name = "ProgressEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(ProgressEvent.init, .{});
    pub const total = bridge.accessor(ProgressEvent.getTotal, null, .{});
    pub const loaded = bridge.accessor(ProgressEvent.getLoaded, null, .{});
    pub const lengthComputable = bridge.accessor(ProgressEvent.getLengthComputable, null, .{});
};
