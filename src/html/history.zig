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
const jsruntime = @import("jsruntime");

const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-history-interface
pub const History = struct {
    pub const mem_guarantied = true;

    const ScrollRestaurationMode = enum {
        auto,
        manual,
    };

    scrollRestauration: ScrollRestaurationMode = .audio,

    pub fn get_length(_: *History) u64 {
        return 0;
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var history = [_]Case{
        .{ .src = "true", .ex = "true" },
    };
    try checkCases(js_env, &history);
}
