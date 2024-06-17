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
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;
const Variadic = jsruntime.Variadic;

const DOMException = @import("exceptions.zig").DOMException;

// https://dom.spec.whatwg.org/#domtokenlist
pub const DOMTokenList = struct {
    pub const Self = parser.TokenList;
    pub const Exception = DOMException;
    pub const mem_guarantied = true;

    pub fn get_length(self: *parser.TokenList) !u32 {
        return parser.tokenListGetLength(self);
    }

    pub fn _item(self: *parser.TokenList, index: u32) !?[]const u8 {
        return parser.tokenListItem(self, index);
    }

    pub fn _contains(self: *parser.TokenList, token: []const u8) !bool {
        return parser.tokenListContains(self, token);
    }

    pub fn _add(self: *parser.TokenList, tokens: ?Variadic([]const u8)) !void {
        if (tokens == null) return;
        for (tokens.?.slice) |token| {
            try parser.tokenListAdd(self, token);
        }
    }

    pub fn _remove(self: *parser.TokenList, tokens: ?Variadic([]const u8)) !void {
        if (tokens == null) return;
        for (tokens.?.slice) |token| {
            try parser.tokenListRemove(self, token);
        }
    }

    /// If token is the empty string, then throw a "SyntaxError" DOMException.
    /// If token contains any ASCII whitespace, then throw an
    /// "InvalidCharacterError" DOMException.
    fn validateToken(token: []const u8) !void {
        if (token.len == 0) {
            return parser.DOMError.Syntax;
        }
        for (token) |c| {
            if (std.ascii.isWhitespace(c)) return parser.DOMError.InvalidCharacter;
        }
    }

    pub fn _toggle(self: *parser.TokenList, token: []const u8, force: ?bool) !bool {
        try validateToken(token);
        const exists = try parser.tokenListContains(self, token);
        if (exists) {
            if (force == null or force.? == false) {
                try parser.tokenListRemove(self, token);
                return false;
            }
            return true;
        }

        if (force == null or force.? == true) {
            try parser.tokenListAdd(self, token);
            return true;
        }
        return false;
    }

    pub fn _replace(self: *parser.TokenList, token: []const u8, new: []const u8) !bool {
        try validateToken(token);
        try validateToken(new);
        const exists = try parser.tokenListContains(self, token);
        if (!exists) return false;
        try parser.tokenListRemove(self, token);
        try parser.tokenListAdd(self, new);
        return true;
    }

    // TODO to implement.
    pub fn _supports(_: *parser.TokenList, token: []const u8) !bool {
        try validateToken(token);
        return error.TypeError;
    }

    pub fn get_value(self: *parser.TokenList) !?[]const u8 {
        return try parser.tokenListGetValue(self);
    }
};

// Tests
// -----

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var dynamiclist = [_]Case{
        .{ .src = "let gs = document.getElementById('para-empty')", .ex = "undefined" },
        .{ .src = "let cl = gs.classList", .ex = "undefined" },
        .{ .src = "gs.className", .ex = "ok empty" },
        .{ .src = "cl.value", .ex = "ok empty" },
        .{ .src = "cl.length", .ex = "2" },
        .{ .src = "gs.className = 'foo bar baz'", .ex = "foo bar baz" },
        .{ .src = "gs.className", .ex = "foo bar baz" },
        .{ .src = "cl.length", .ex = "3" },
        .{ .src = "gs.className = 'ok empty'", .ex = "ok empty" },
        .{ .src = "cl.length", .ex = "2" },
    };
    try checkCases(js_env, &dynamiclist);

    var testcases = [_]Case{
        .{ .src = "let cl2 = gs.classList", .ex = "undefined" },
        .{ .src = "cl2.length", .ex = "2" },
        .{ .src = "cl2.item(0)", .ex = "ok" },
        .{ .src = "cl2.item(1)", .ex = "empty" },
        .{ .src = "cl2.contains('ok')", .ex = "true" },
        .{ .src = "cl2.contains('nok')", .ex = "false" },
        .{ .src = "cl2.add('foo', 'bar', 'baz')", .ex = "undefined" },
        .{ .src = "cl2.length", .ex = "5" },
        .{ .src = "cl2.remove('foo', 'bar', 'baz')", .ex = "undefined" },
        .{ .src = "cl2.length", .ex = "2" },
    };
    try checkCases(js_env, &testcases);

    var toogle = [_]Case{
        .{ .src = "let cl3 = gs.classList", .ex = "undefined" },
        .{ .src = "cl3.toggle('ok')", .ex = "false" },
        .{ .src = "cl3.toggle('ok')", .ex = "true" },
        .{ .src = "cl3.length", .ex = "2" },
    };
    try checkCases(js_env, &toogle);

    var replace = [_]Case{
        .{ .src = "let cl4 = gs.classList", .ex = "undefined" },
        .{ .src = "cl4.replace('ok', 'nok')", .ex = "true" },
        .{ .src = "cl4.value", .ex = "empty nok" },
        .{ .src = "cl4.replace('nok', 'ok')", .ex = "true" },
        .{ .src = "cl4.value", .ex = "empty ok" },
    };
    try checkCases(js_env, &replace);
}
