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
_frame: *Frame,
_rc: lp.RC = .{},

pub fn init(raw_url: []const u8, frame: *Frame) !*Location {
    const url = try URL.init(raw_url, null, &frame.js.execution);
    url.acquireRef();
    errdefer url.releaseRef(frame.page);

    return frame._factory.create(Location{
        ._url = url,
        ._frame = frame,
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

fn getPathname(self: *const Location) []const u8 {
    return self._url.getPathname();
}

fn getProtocol(self: *const Location) []const u8 {
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

fn getSearch(self: *const Location, exec: *const js.Execution) ![]const u8 {
    return self._url.getSearch(exec);
}

pub fn getHash(self: *const Location) []const u8 {
    return self._url.getHash();
}

pub fn setPathname(self: *const Location, pathname: []const u8, frame: *Frame) !void {
    const target = self._frame;
    const new_url = try U.setPathname(target.url, pathname, frame.call_arena);
    return target.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

fn setSearch(self: *const Location, search: []const u8, frame: *Frame) !void {
    const target = self._frame;
    const new_url = try U.setSearch(target.url, search, frame.call_arena);
    return target.scheduleNavigation(new_url, .{
        .reason = .script,
        .kind = .{ .push = null },
    }, .{ .script = target });
}

fn setHash(self: *const Location, hash: []const u8, frame: *Frame) !void {
    const target = self._frame;
    const old_url = target.url;
    const base_end = std.mem.findScalar(u8, old_url, '#') orelse old_url.len;
    // Includes the leading '#'; empty when the URL has no fragment.
    const old_fragment = old_url[base_end..];

    // Clearing the hash on an URL w/ no fragment does nothing.
    if (old_fragment.len == 0 and (hash.len == 0 or std.mem.eql(u8, hash, "#"))) {
        return;
    }

    const normalized_hash: []const u8 = blk: {
        if (hash.len == 0) {
            break :blk "#";
        } else if (hash[0] == '#') {
            break :blk hash;
        }
        // Scratch only: scheduleNavigation dupes the URL into its own arena
        // synchronously, so the local arena suffices.
        break :blk try frame.local_arena.print("#{s}", .{hash});
    };

    // No navigation when the fragment doesn't change.
    if (std.mem.eql(u8, old_fragment, normalized_hash)) {
        return;
    }

    const target_url = try frame.local_arena.print("{s}{s}", .{ old_url[0..base_end], normalized_hash });

    return target.scheduleNavigation(target_url, .{
        .reason = .script,
        .kind = .{ .replace = null },
    }, .{ .script = target });
}

// The href setter, assign() and replace() parse the URL relative to the entry
// settings object: the calling script's document. It isn't this location's
// document when a script navigates another same-origin window, as in
// iframe.contentWindow.location.href = "page.html". V8 only exposes the
// incumbent context, which is the entry one for a call made by a script.
fn parseFromCaller(self: *const Location, url: [:0]const u8, frame: *Frame) ![]const u8 {
    const caller = frame.js.getIncumbent();
    if (caller == self._frame) {
        return url;
    }
    return U.resolve(frame.call_arena, caller.navigationBase(), url, .{ .encoding = caller.charset });
}

pub fn assign(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
    const target_url = try self.parseFromCaller(url, frame);
    return self._frame.scheduleNavigation(target_url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._frame });
}

pub fn replace(self: *const Location, url: [:0]const u8, frame: *Frame) !void {
    const target_url = try self.parseFromCaller(url, frame);
    return self._frame.scheduleNavigation(target_url, .{ .reason = .script, .kind = .{ .replace = null } }, .{ .script = self._frame });
}

pub fn reload(self: *const Location) !void {
    const target = self._frame;
    return target.scheduleNavigation(target.url, .{ .reason = .script, .kind = .reload }, .{ .script = target });
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
