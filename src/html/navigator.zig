// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const builtin = @import("builtin");
const parser = @import("netsurf");
const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const CallbackArg = jsruntime.CallbackArg;
const Loop = jsruntime.Loop;

const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const EventTarget = @import("../dom/event_target.zig").EventTarget;

const storage = @import("../storage/storage.zig");

// https://html.spec.whatwg.org/multipage/system-state.html#navigator
pub const Navigator = struct {
    pub const mem_guarantied = true;

    agent: []const u8 = "Lightpanda/1.0",
    version: []const u8 = "1.0",
    vendor: []const u8 = "",
    platform: []const u8 = std.fmt.comptimePrint("{any} {any}", .{ builtin.os.tag, builtin.cpu.arch }),

    language: []const u8 = "en-US",

    pub fn get_userAgent(self: *Navigator) []const u8 {
        return self.agent;
    }
    pub fn get_appCodeName(_: *Navigator) []const u8 {
        return "Mozilla";
    }
    pub fn get_appName(_: *Navigator) []const u8 {
        return "Netscape";
    }
    pub fn get_appVersion(self: *Navigator) []const u8 {
        return self.version;
    }
    pub fn get_platform(self: *Navigator) []const u8 {
        return self.platform;
    }
    pub fn get_product(_: *Navigator) []const u8 {
        return "Gecko";
    }
    pub fn get_productSub(_: *Navigator) []const u8 {
        return "20030107";
    }
    pub fn get_vendor(self: *Navigator) []const u8 {
        return self.vendor;
    }
    pub fn get_vendorSub(_: *Navigator) []const u8 {
        return "";
    }
    pub fn get_language(self: *Navigator) []const u8 {
        return self.language;
    }
    // TODO wait for arrays.
    //pub fn get_languages(self: *Navigator) [][]const u8 {
    //    return .{self.language};
    //}
    pub fn get_online(_: *Navigator) bool {
        return true;
    }
    pub fn _registerProtocolHandler(_: *Navigator, scheme: []const u8, url: []const u8) void {
        _ = scheme;
        _ = url;
    }
    pub fn _unregisterProtocolHandler(_: *Navigator, scheme: []const u8, url: []const u8) void {
        _ = scheme;
        _ = url;
    }

    pub fn get_cookieEnabled(_: *Navigator) bool {
        return true;
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var navigator = [_]Case{
        .{ .src = "navigator.userAgent", .ex = "Lightpanda/1.0" },
        .{ .src = "navigator.appVersion", .ex = "1.0" },
        .{ .src = "navigator.language", .ex = "en-US" },
    };
    try checkCases(js_env, &navigator);
}
