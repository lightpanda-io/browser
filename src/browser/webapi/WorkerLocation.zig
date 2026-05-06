// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");

const U = @import("../URL.zig");

const WorkerLocation = @This();

// Workers can't navigate, so the URL is fixed for the lifetime of the worker.
_url: [:0]const u8,

pub fn getProtocol(self: *const WorkerLocation) []const u8 {
    return U.getProtocol(self._url);
}

pub fn getHostname(self: *const WorkerLocation) []const u8 {
    return U.getHostname(self._url);
}

pub fn getHost(self: *const WorkerLocation) []const u8 {
    return U.getHost(self._url);
}

pub fn getPort(self: *const WorkerLocation) []const u8 {
    return U.getPort(self._url);
}

pub fn getPathname(self: *const WorkerLocation) []const u8 {
    return U.getPathname(self._url);
}

pub fn getSearch(self: *const WorkerLocation) []const u8 {
    return U.getSearch(self._url);
}

pub fn getHash(self: *const WorkerLocation) []const u8 {
    return U.getHash(self._url);
}

pub fn getOrigin(self: *const WorkerLocation, exec: *const js.Execution) ![]const u8 {
    return (try U.getOrigin(exec.call_arena, self._url)) orelse "null";
}

pub fn toString(self: *const WorkerLocation) [:0]const u8 {
    return self._url;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WorkerLocation);

    pub const Meta = struct {
        pub const name = "WorkerLocation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const toString = bridge.function(WorkerLocation.toString, .{});
    pub const href = bridge.accessor(WorkerLocation.toString, null, .{});
    pub const origin = bridge.accessor(WorkerLocation.getOrigin, null, .{});
    pub const protocol = bridge.accessor(WorkerLocation.getProtocol, null, .{});
    pub const host = bridge.accessor(WorkerLocation.getHost, null, .{});
    pub const hostname = bridge.accessor(WorkerLocation.getHostname, null, .{});
    pub const port = bridge.accessor(WorkerLocation.getPort, null, .{});
    pub const pathname = bridge.accessor(WorkerLocation.getPathname, null, .{});
    pub const search = bridge.accessor(WorkerLocation.getSearch, null, .{});
    pub const hash = bridge.accessor(WorkerLocation.getHash, null, .{});
};
