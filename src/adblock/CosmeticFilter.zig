// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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
const domain = @import("domain.zig");

const CosmeticFilter = @This();

/// '#@#' exception: re-shows elements a hide rule matched.
exception: bool = false,
/// '#?#': the author demands procedural (extended) matching.
extended: bool = false,
/// Raw CSS selector text (trimmed, unvalidated).
selector: []const u8,
/// Empty for generic filters (plain `##...`).
domains: domain.List = .empty,

pub const ParseError = error{
    InvalidSelector,
    InvalidDomainList,
    GenericException,
    NoSupportedDomains,
    UnsupportedScriptlet,
    UnsupportedHtmlFilter,
    UnsupportedAction,
} || std.mem.Allocator.Error;

/// `prefix` is the text before the separator (the domain list, may be
/// empty), `body` the text after it. Flags come from the separator itself
/// (located by the caller's line classification).
pub fn parse(
    arena: std.mem.Allocator,
    prefix: []const u8,
    body_raw: []const u8,
    exception: bool,
    extended: bool,
) ParseError!CosmeticFilter {
    const body = std.mem.trim(u8, body_raw, &std.ascii.whitespace);
    if (body.len == 0) return error.InvalidSelector;

    if (std.mem.startsWith(u8, body, "+js(")) return error.UnsupportedScriptlet;
    if (body[0] == '^') return error.UnsupportedHtmlFilter;
    if (hasActionOperator(body)) return error.UnsupportedAction;

    var filter: CosmeticFilter = .{
        .exception = exception,
        .extended = extended,
        .selector = body,
    };

    const trimmed_prefix = std.mem.trim(u8, prefix, &std.ascii.whitespace);
    if (trimmed_prefix.len > 0) {
        filter.domains = try domain.parse(arena, trimmed_prefix, ',');
    }

    // Generic exceptions ('#@#' with no domain restriction) are invalid:
    // they would disable a hide rule everywhere, which real lists never
    // intend (same rule as adblock-rust).
    if (exception and filter.domains.isEmpty()) return error.GenericException;

    return filter;
}

/// uBO action operators terminate the selector chain and change what the
/// filter does (inject styles, remove nodes/attributes). Unsupported here.
fn hasActionOperator(selector: []const u8) bool {
    if (selector[selector.len - 1] != ')') return false;
    const actions = [_][]const u8{
        ":style(", ":remove(", ":remove-attr(", ":remove-class(", ":watch-attr(",
    };
    for (actions) |action| {
        if (std.mem.indexOf(u8, selector, action) != null) return true;
    }
    return false;
}

const testing = std.testing;

test "adblock.CosmeticFilter: generic and domain-specific hides" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var f = try parse(arena, "", ".ad-banner", false, false);
    try testing.expectEqualStrings(".ad-banner", f.selector);
    try testing.expect(f.domains.isEmpty());
    try testing.expect(!f.exception);

    f = try parse(arena, "example.com,~mail.example.com", "#sidebar-ads", false, false);
    try testing.expectEqual(1, f.domains.included.len);
    try testing.expectEqual(1, f.domains.excluded.len);

    f = try parse(arena, "google.*", "div[data-ad]", false, false);
    try testing.expect(f.domains.included[0].entity);
}

test "adblock.CosmeticFilter: exceptions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const f = try parse(arena, "example.com", ".ad", true, false);
    try testing.expect(f.exception);

    // Exceptions must be domain-scoped.
    try testing.expectError(error.GenericException, parse(arena, "", ".ad", true, false));
}

test "adblock.CosmeticFilter: unsupported bodies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.UnsupportedScriptlet, parse(arena, "example.com", "+js(no-fetch-if, ads)", false, false));
    try testing.expectError(error.UnsupportedHtmlFilter, parse(arena, "example.com", "^script:has-text(adblock)", false, false));
    try testing.expectError(error.UnsupportedAction, parse(arena, "example.com", ".ad:style(position: absolute!important)", false, false));
    try testing.expectError(error.UnsupportedAction, parse(arena, "example.com", ".ad:remove()", false, false));
    try testing.expectError(error.InvalidSelector, parse(arena, "example.com", "  ", false, false));
}
