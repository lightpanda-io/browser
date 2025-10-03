const js = @import("js.zig");
const v8 = js.v8;

const Platform = @This();
inner: v8.Platform,

pub fn init() !Platform {
    if (v8.initV8ICU() == false) {
        return error.FailedToInitializeICU;
    }
    const platform = v8.Platform.initDefault(0, true);
    v8.initV8Platform(platform);
    v8.initV8();
    return .{ .inner = platform };
}

pub fn deinit(self: Platform) void {
    _ = v8.deinitV8();
    v8.deinitV8Platform();
    self.inner.deinit();
}
