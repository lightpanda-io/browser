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

const parser = @import("../netsurf.zig");

const DOMException = @import("exceptions.zig").DOMException;

// https://dom.spec.whatwg.org/#domtokenlist
pub const DOMTokenList = struct {
    pub const Self = parser.TokenList;
    pub const Exception = DOMException;

    pub fn get_length(self: *parser.TokenList) !u32 {
        return parser.tokenListGetLength(self);
    }

    pub fn _item(self: *parser.TokenList, index: u32) !?[]const u8 {
        return parser.tokenListItem(self, index);
    }

    pub fn _contains(self: *parser.TokenList, token: []const u8) !bool {
        return parser.tokenListContains(self, token);
    }

    pub fn _add(self: *parser.TokenList, tokens: []const []const u8) !void {
        for (tokens) |token| {
            try parser.tokenListAdd(self, token);
        }
    }

    pub fn _remove(self: *parser.TokenList, tokens: []const []const u8) !void {
        for (tokens) |token| {
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

const testing = @import("../../testing.zig");
test "Browser.DOM.TokenList" {
    var runner = try testing.jsRunner(testing.allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "let gs = document.getElementById('para-empty')", "undefined" },
        .{ "let cl = gs.classList", "undefined" },
        .{ "gs.className", "ok empty" },
        .{ "cl.value", "ok empty" },
        .{ "cl.length", "2" },
        .{ "gs.className = 'foo bar baz'", "foo bar baz" },
        .{ "gs.className", "foo bar baz" },
        .{ "cl.length", "3" },
        .{ "gs.className = 'ok empty'", "ok empty" },
        .{ "cl.length", "2" },
    }, .{});

    try runner.testCases(&.{
        .{ "let cl2 = gs.classList", "undefined" },
        .{ "cl2.length", "2" },
        .{ "cl2.item(0)", "ok" },
        .{ "cl2.item(1)", "empty" },
        .{ "cl2.contains('ok')", "true" },
        .{ "cl2.contains('nok')", "false" },
        .{ "cl2.add('foo', 'bar', 'baz')", "undefined" },
        .{ "cl2.length", "5" },
        .{ "cl2.remove('foo', 'bar', 'baz')", "undefined" },
        .{ "cl2.length", "2" },
    }, .{});

    try runner.testCases(&.{
        .{ "let cl3 = gs.classList", "undefined" },
        .{ "cl3.toggle('ok')", "false" },
        .{ "cl3.toggle('ok')", "true" },
        .{ "cl3.length", "2" },
    }, .{});

    try runner.testCases(&.{
        .{ "let cl4 = gs.classList", "undefined" },
        .{ "cl4.replace('ok', 'nok')", "true" },
        .{ "cl4.value", "empty nok" },
        .{ "cl4.replace('nok', 'ok')", "true" },
        .{ "cl4.value", "empty ok" },
    }, .{});
}
