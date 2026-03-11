const js = @import("../js/js.zig");

const FileList = @This();

/// Padding to avoid zero-size struct, which causes identity_map pointer collisions.
_pad: bool = false,

pub fn getLength(_: *const FileList) u32 {
    return 0;
}

pub fn item(_: *const FileList, _: u32) ?*@import("File.zig") {
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(FileList);

    pub const Meta = struct {
        pub const name = "FileList";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const length = bridge.accessor(FileList.getLength, null, .{});
    pub const item = bridge.function(FileList.item, .{});
};
