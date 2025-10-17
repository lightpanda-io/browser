const js = @import("../../js/js.zig");

const CData = @import("../CData.zig");

const Comment = @This();

_proto: *CData,

pub const JsApi = struct {
    pub const bridge = js.Bridge(Comment);

    pub const Meta = struct {
        pub const name = "Comment";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
