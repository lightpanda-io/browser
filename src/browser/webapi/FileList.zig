const js = @import("../js/js.zig");

const File = @import("File.zig");

const FileList = @This();

_files: []*File = &.{},

pub fn getLength(self: *const FileList) u32 {
    return @intCast(self._files.len);
}

pub fn item(self: *const FileList, index: u32) ?*File {
    if (index >= self._files.len) return null;
    return self._files[index];
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
