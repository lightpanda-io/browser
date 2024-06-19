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

const parser = @import("netsurf");

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const generate = @import("../generate.zig");

const NodeList = @import("nodelist.zig").NodeList;

pub const Interfaces = generate.Tuple(.{
    MutationObserver,
});

// WEB IDL https://dom.spec.whatwg.org/#interface-mutationobserver
pub const MutationObserver = struct {
    cbk: Callback,

    pub const mem_guarantied = true;

    pub const MutationObserverInit = struct {
        childList: bool = false,
        attributes: bool = false,
        characterData: bool = false,
        subtree: bool = false,
        attributeOldValue: bool = false,
        characterDataOldValue: bool = false,
        // TODO
        // attributeFilter: [][]const u8,
    };

    pub fn constructor(cbk: Callback) !MutationObserver {
        return MutationObserver{
            .cbk = cbk,
        };
    }

    pub fn _observe(
        _: *MutationObserver,
        _: *parser.Node,
        _: ?MutationObserverInit,
    ) !void {}

    // TODO
    pub fn _disconnect(_: *MutationObserver) !void {}
};

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var constructor = [_]Case{
        .{ .src = "new MutationObserver(() => {}).observe(document, { childList: true });", .ex = "undefined" },
    };
    try checkCases(js_env, &constructor);
}
