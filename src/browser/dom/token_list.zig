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

const js = @import("../js/js.zig");
const log = @import("../../log.zig");
const parser = @import("../netsurf.zig");
const iterator = @import("../iterator/iterator.zig");

const DOMException = @import("exceptions.zig").DOMException;

pub const Interfaces = .{
    DOMTokenList,
    DOMTokenListIterable,
    TokenListEntriesIterator,
    TokenListEntriesIterator.Iterable,
};

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
        return (try parser.tokenListGetValue(self)) orelse "";
    }

    pub fn set_value(self: *parser.TokenList, value: []const u8) !void {
        return parser.tokenListSetValue(self, value);
    }

    pub fn _toString(self: *parser.TokenList) ![]const u8 {
        return (try get_value(self)) orelse "";
    }

    pub fn _keys(self: *parser.TokenList) !iterator.U32Iterator {
        return .{ .length = try get_length(self) };
    }

    pub fn _values(self: *parser.TokenList) DOMTokenListIterable {
        return DOMTokenListIterable.init(.{ .token_list = self });
    }

    pub fn _entries(self: *parser.TokenList) TokenListEntriesIterator {
        return TokenListEntriesIterator.init(.{ .token_list = self });
    }

    pub fn _symbol_iterator(self: *parser.TokenList) DOMTokenListIterable {
        return _values(self);
    }

    // TODO handle thisArg
    pub fn _forEach(self: *parser.TokenList, cbk: js.Function, this_arg: js.Object) !void {
        var entries = _entries(self);
        while (try entries._next()) |entry| {
            var result: js.Function.Result = undefined;
            cbk.tryCallWithThis(void, this_arg, .{ entry.@"1", entry.@"0", self }, &result) catch {
                log.debug(.user_script, "callback error", .{
                    .err = result.exception,
                    .stack = result.stack,
                    .soure = "tokenList foreach",
                });
            };
        }
    }
};

const DOMTokenListIterable = iterator.Iterable(Iterator, "DOMTokenListIterable");
const TokenListEntriesIterator = iterator.NumericEntries(Iterator, "TokenListEntriesIterator");

pub const Iterator = struct {
    index: u32 = 0,
    token_list: *parser.TokenList,

    // used when wrapped in an iterator.NumericEntries
    pub const Error = parser.DOMError;

    pub fn _next(self: *Iterator) !?[]const u8 {
        const index = self.index;
        self.index = index + 1;
        return DOMTokenList._item(self.token_list, index);
    }
};

const testing = @import("../../testing.zig");
test "Browser: DOM.TokenList" {
    try testing.htmlRunner("dom/token_list.html");
}
