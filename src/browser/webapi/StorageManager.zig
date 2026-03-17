// src/browser/webapi/StorageManager.zig
// Minimal stub for navigator.storage
// https://storage.spec.whatwg.org/#storagemanager

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const StorageManager = @This();
_pad: bool = false,

pub const init: StorageManager = .{};

const StorageEstimate = struct {
    quota: u64,
    usage: u64,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(StorageEstimate);
        pub const Meta = struct {
            pub const name = "StorageEstimate";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
        pub const quota = bridge.accessor(getQuota, null, .{});
        pub const usage = bridge.accessor(getUsage, null, .{});
    };

    fn getQuota(self: *const StorageEstimate) u64 {
        return self.quota;
    }
    fn getUsage(self: *const StorageEstimate) u64 {
        return self.usage;
    }
};

// Returns a resolved Promise<StorageEstimate> with plausible stub values.
// quota = 1GB, usage = 0 (headless browser has no real storage)
pub fn estimate(_: *const StorageManager, page: *Page) !js.Promise {
    const est = try page._factory.create(StorageEstimate{
        .quota = 1024 * 1024 * 1024, // 1 GiB
        .usage = 0,
    });
    return js.Promise.resolve(est, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StorageManager);
    pub const Meta = struct {
        pub const name = "StorageManager";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };
    pub const estimate = bridge.function(StorageManager.estimate, .{});
};
