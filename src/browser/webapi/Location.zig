const js = @import("../js/js.zig");

const URL = @import("URL.zig");
const Page = @import("../Page.zig");

const Location = @This();

_url: *URL,

pub fn init(raw_url: [:0]const u8, page: *Page) !*Location {
    const url = try URL.init(raw_url, null, page);
    return page._factory.create(Location{
        ._url = url,
    });
}

pub fn getPathname(self: *const Location) []const u8 {
    return self._url.getPathname();
}

pub fn getProtocol(self: *const Location) []const u8 {
    return self._url.getProtocol();
}

pub fn getHostname(self: *const Location) []const u8 {
    return self._url.getHostname();
}

pub fn getHost(self: *const Location) []const u8 {
    return self._url.getHost();
}

pub fn getPort(self: *const Location) []const u8 {
    return self._url.getPort();
}

pub fn getOrigin(self: *const Location, page: *const Page) ![]const u8 {
    return self._url.getOrigin(page);
}

pub fn getSearch(self: *const Location) []const u8 {
    return self._url.getSearch();
}

pub fn getHash(self: *const Location) []const u8 {
    return self._url.getHash();
}

pub fn toString(self: *const Location, page: *const Page) ![:0]const u8 {
    return self._url.toString(page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Location);

    pub const Meta = struct {
        pub const name = "Location";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const toString = bridge.function(Location.toString, .{});
    pub const href = bridge.accessor(Location.toString, null, .{});
    pub const search = bridge.accessor(Location.getSearch, null, .{});
    pub const hash = bridge.accessor(Location.getHash, null, .{});
    pub const pathname = bridge.accessor(Location.getPathname, null, .{});
    pub const hostname = bridge.accessor(Location.getHostname, null, .{});
    pub const host = bridge.accessor(Location.getHost, null, .{});
    pub const port = bridge.accessor(Location.getPort, null, .{});
    pub const origin = bridge.accessor(Location.getOrigin, null, .{});
    pub const protocol = bridge.accessor(Location.getProtocol, null, .{});
};
