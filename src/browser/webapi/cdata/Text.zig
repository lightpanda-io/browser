const js = @import("../../js/js.zig");

const CData = @import("../CData.zig");

const Text = @This();

_proto: *CData,

pub fn getWholeText(self: *Text) []const u8 {
    return self._proto._data;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Text);

    pub const Meta = struct {
        pub const name = "Text";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const wholeText = bridge.accessor(Text.getWholeText, null, .{});
};
