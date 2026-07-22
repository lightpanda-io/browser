// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");
const js = @import("../js/js.zig");

const Page = @import("../Page.zig");
const URL = @import("URL.zig");
const U = @import("../URL.zig");
const Frame = @import("../Frame.zig");

const Location = @This();

_url: *URL,
_rc: lp.RC = .{},

pub fn init(raw_url: []const u8, frame: *Frame) !*Location {
    const url = try URL.init(raw_url, null, &frame.js.execution);
    url.acquireRef();
    errdefer url.releaseRef(frame._page);

    return frame._factory.create(Location{
        ._url = url,
    });
}

pub fn deinit(self: *const Location, page: *Page) void {
    self._url.releaseRef(page);
}

pub fn acquireRef(self: *Location) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *Location, page: *Page) void {
    self._rc.release(self, page);
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

pub fn getOrigin(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.getOrigin(exec);
}

pub fn getSearch(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.getSearch(exec);
}

pub fn getHash(self: *const Location) []const u8 {
    return self._url.getHash();
}

pub fn setPathname(_: *const Location, pathname: []const u8, frame: *Frame) !void {
    const new_url = try U.setPathname(frame.url, pathname, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = frame });
}

pub fn setSearch(_: *const Location, search: []const u8, frame: *Frame) !void {
    const new_url = try U.setSearch(frame.url, search, frame.call_arena);
    return frame.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = frame });
}

pub fn setHash(_: *const Location, hash: []const u8, frame: *Frame) !void {
    const old_url = frame.url;
    const base_end = std.mem.indexOfScalar(u8, old_url, '#') orelse old_url.len;
    // Includes the leading '#'; empty when the URL has no fragment.
    const old_fragment = old_url[base_end..];

    const normalized_hash: []const u8 = blk: {
        if (hash.len == 0) {
            break :blk "";
        } else if (hash[0] == '#') {
            break :blk hash;
        }
        // Scratch only: scheduleNavigation dupes the URL into its own arena
        // synchronously, so the local arena suffices.
        break :blk try std.fmt.allocPrint(frame.local_arena, "#{s}", .{hash});
    };

    // Per the Location hash setter, when the fragment doesn't change no
    // navigation happens at all — in particular `location.hash = ""` on a
    // fragment-less URL must not turn into a same-URL reload.
    if (std.mem.eql(u8, old_fragment, normalized_hash)) {
        return;
    }

    const target_url = if (normalized_hash.len == 0) old_url[0..base_end] else normalized_hash;

    return frame.scheduleNavigation(target_url, .{
        .reason = .script,
        .kind = .{ .replace = null },
    }, .{ .script = frame });
}

pub fn assign(_: *const Location, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = frame });
}

pub fn replace(_: *const Location, url: [:0]const u8, frame: *Frame) !void {
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .replace = null } }, .{ .script = frame });
}

pub fn reload(_: *const Location, frame: *Frame) !void {
    return frame.scheduleNavigation(frame.url, .{ .reason = .script, .kind = .reload }, .{ .script = frame });
}

pub fn toString(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.toString(exec);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Location);

    pub const Meta = struct {
        pub const name = "Location";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const toString = bridge.function(Location.toString, .{});
    pub const href = bridge.accessor(Location.toString, setHref, .{});
    fn setHref(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
        return self.assign(url, frame);
    }

    pub const search = bridge.accessor(Location.getSearch, Location.setSearch, .{});
    pub const hash = bridge.accessor(Location.getHash, Location.setHash, .{});
    pub const pathname = bridge.accessor(Location.getPathname, Location.setPathname, .{});
    pub const hostname = bridge.accessor(Location.getHostname, null, .{});
    pub const host = bridge.accessor(Location.getHost, null, .{});
    pub const port = bridge.accessor(Location.getPort, null, .{});
    pub const origin = bridge.accessor(Location.getOrigin, null, .{});
    pub const protocol = bridge.accessor(Location.getProtocol, null, .{});
    pub const assign = bridge.function(Location.assign, .{});
    pub const replace = bridge.function(Location.replace, .{});
    pub const reload = bridge.function(Location.reload, .{});
};
