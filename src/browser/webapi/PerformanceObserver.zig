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

const js = @import("../js/js.zig");

const Entry = @import("Performance.zig").Entry;

// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceObserver
const PerformanceObserver = @This();

pub fn init(callback: js.Function) PerformanceObserver {
    _ = callback;
    return .{};
}

const ObserverOptions = struct {
    buffered: ?bool = null,
    durationThreshold: ?f64 = null,
    entryTypes: ?[]const []const u8 = null,
    type: ?[]const u8 = null,
};

pub fn observe(self: *const PerformanceObserver, opts_: ?ObserverOptions) void {
    _ = self;
    _ = opts_;
    return;
}

pub fn disconnect(self: *PerformanceObserver) void {
    _ = self;
}

pub fn takeRecords(_: *const PerformanceObserver) []const Entry {
    return &.{};
}

pub fn getSupportedEntryTypes(_: *const PerformanceObserver) [][]const u8 {
    return &.{};
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PerformanceObserver);

    pub const Meta = struct {
        pub const name = "PerformanceObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(PerformanceObserver.init, .{});

    pub const observe = bridge.function(PerformanceObserver.observe, .{});
    pub const disconnect = bridge.function(PerformanceObserver.disconnect, .{});
    pub const takeRecords = bridge.function(PerformanceObserver.takeRecords, .{});
    pub const supportedEntryTypes = bridge.accessor(PerformanceObserver.getSupportedEntryTypes, null, .{.static = true});
};
