// src/browser/webapi/Permissions.zig
//
// Minimal Permissions API stub.
// https://www.w3.org/TR/permissions/
//
// Turnstile probes: navigator.permissions.query({ name: 'notifications' })
// It expects a Promise resolving to { state: 'granted' | 'denied' | 'prompt' }

const std = @import("std");
const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Permissions = @This();

// Padding to avoid zero-size struct pointer collisions
_pad: bool = false,

pub const init: Permissions = .{};

const QueryDescriptor = struct {
    name: []const u8,
};

const PermissionStatus = struct {
    state: []const u8,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PermissionStatus);
        pub const Meta = struct {
            pub const name = "PermissionStatus";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };
        pub const state = bridge.accessor(getState, null, .{});
    };

    fn getState(self: *const PermissionStatus) []const u8 {
        return self.state;
    }
};

// query() returns a Promise<PermissionStatus>.
// We always report 'prompt' (the default safe value — neither granted nor denied).
pub fn query(_: *const Permissions, _: QueryDescriptor, page: *Page) !js.Promise {
    const status = try page._factory.create(PermissionStatus{ .state = "prompt" });
    return js.Promise.resolve(status, page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Permissions);

    pub const Meta = struct {
        pub const name = "Permissions";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const query = bridge.function(Permissions.query, .{ .dom_exception = true });
};
