const std = @import("std");
const js = @import("../../js/js.zig");

const Intl = @This();

// Skeleton implementation with no actual functionality yet.
// This allows `if (Intl)` checks to pass, while property checks
// like `if (Intl.Locale)` will return undefined.
// We can add actual implementations as we encounter real-world use cases.

pub const JsApi = struct {
    pub const bridge = js.Bridge(Intl);

    pub const Meta = struct {
        pub const name = "Intl";
        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
        pub const empty_with_no_proto = true;
    };
};
