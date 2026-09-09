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

//! A compiled `/regex/` filter body. Filter lists write them in JavaScript
//! `RegExp` syntax and uBO runs them with `new RegExp(src, 'i')` against the
//! raw request URL (no flag under `$match-case`); PCRE2 reads that syntax
//! as-is, escapes like `\/` included.
//!
//! A compiled pattern and its `Context` are never modified after `compile`,
//! so one `Regex` can be shared by every HTTP client thread; the per-call
//! match data is what PCRE2 requires to be private.

const std = @import("std");
const lp = @import("lightpanda");
const pcre2 = @import("pcre2");

const Allocator = std.mem.Allocator;

const log = lp.log;

const Regex = @This();

code: *pcre2.pcre2_code_8,
context: *const Context,

pub const Error = error{ InvalidRegex, OutOfMemory };

/// What every `Regex` compiled through it shares: the allocator PCRE2 draws
/// from, and the compile and match settings. Outlives the regexes.
pub const Context = struct {
    allocator: Allocator,
    general: *pcre2.pcre2_general_context_8,
    compile_context: *pcre2.pcre2_compile_context_8,
    match_context: *pcre2.pcre2_match_context_8,

    // A pattern from a list that backtracks this much on one URL is broken,
    // not slow; giving up costs a false negative on that request, nothing
    // more.
    const MATCH_LIMIT = 100_000;
    const DEPTH_LIMIT = 10_000;

    pub fn init(allocator: Allocator) Allocator.Error!*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.allocator = allocator;

        // PCRE2 hands `self` back to the callbacks, so the context has to be
        // at its final address before anything is allocated through it.
        const general = pcre2.pcre2_general_context_create_8(cMalloc, cFree, self) orelse return error.OutOfMemory;
        errdefer pcre2.pcre2_general_context_free_8(general);

        const compile_context = pcre2.pcre2_compile_context_create_8(general) orelse return error.OutOfMemory;
        errdefer pcre2.pcre2_compile_context_free_8(compile_context);
        // JavaScript without the `u` flag reads an unknown escape as the
        // literal character, and that is the mode uBO compiles filters in.
        _ = pcre2.pcre2_set_compile_extra_options_8(compile_context, pcre2.PCRE2_EXTRA_BAD_ESCAPE_IS_LITERAL);

        const match_context = pcre2.pcre2_match_context_create_8(general) orelse return error.OutOfMemory;
        _ = pcre2.pcre2_set_match_limit_8(match_context, MATCH_LIMIT);
        _ = pcre2.pcre2_set_depth_limit_8(match_context, DEPTH_LIMIT);

        self.general = general;
        self.compile_context = compile_context;
        self.match_context = match_context;
        return self;
    }

    pub fn deinit(self: *Context) void {
        pcre2.pcre2_match_context_free_8(self.match_context);
        pcre2.pcre2_compile_context_free_8(self.compile_context);
        pcre2.pcre2_general_context_free_8(self.general);
        self.allocator.destroy(self);
    }

    // PCRE2 frees without a size, so every block carries its own in a
    // header that keeps the payload at malloc's alignment.
    const HEADER = 16;
    const alignment: std.mem.Alignment = .fromByteUnits(HEADER);

    fn cMalloc(size: usize, data: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *const Context = @ptrCast(@alignCast(data.?));
        const total = std.math.add(usize, size, HEADER) catch return null;
        const block = self.allocator.alignedAlloc(u8, alignment, total) catch return null;
        std.mem.writeInt(usize, block[0..@sizeOf(usize)], total, .little);
        return block.ptr + HEADER;
    }

    fn cFree(ptr: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const payload = ptr orelse return;
        const self: *const Context = @ptrCast(@alignCast(data.?));
        const base: [*]align(HEADER) u8 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(payload)) - HEADER));
        const total = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
        self.allocator.free(base[0..total]);
    }
};

pub fn compile(context: *const Context, pattern: []const u8, case_insensitive: bool) Error!Regex {
    const options: u32 = if (case_insensitive) pcre2.PCRE2_CASELESS else 0;
    var err_code: c_int = 0;
    var err_offset: usize = 0;
    const code = pcre2.pcre2_compile_8(
        pattern.ptr,
        pattern.len,
        options,
        &err_code,
        &err_offset,
        context.compile_context,
    ) orelse {
        // Compile errors are positive codes; 21 is the one for a failed
        // allocation, and that is ours, not the pattern's.
        if (err_code == 21) return error.OutOfMemory;
        var buf: [256]u8 = undefined;
        const len = pcre2.pcre2_get_error_message_8(err_code, &buf, buf.len);
        const message: []const u8 = if (len < 0) "unknown error" else buf[0..@intCast(len)];
        log.debug(.app, "adblock regex rejected", .{
            .pattern = pattern,
            .err = message,
            .offset = err_offset,
        });
        return error.InvalidRegex;
    };
    return .{ .code = code, .context = context };
}

pub fn deinit(self: Regex) void {
    pcre2.pcre2_code_free_8(self.code);
}

/// Whether the pattern matches anywhere in `text`, as `RegExp.test` would
/// answer. A match that hits the backtracking limits counts as no match.
pub fn matches(self: Regex, text: []const u8) bool {
    // One pair is the whole-match span, all a test needs; capture groups in
    // the pattern are simply not recorded.
    const match_data = pcre2.pcre2_match_data_create_8(1, self.context.general) orelse return false;
    defer pcre2.pcre2_match_data_free_8(match_data);

    const rc = pcre2.pcre2_match_8(self.code, text.ptr, text.len, 0, 0, match_data, self.context.match_context);
    return rc >= 0;
}

const testing = @import("../../testing.zig");

test "adblock.Regex: JavaScript escapes and unanchored search" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    const regex = try Regex.compile(context, "^https?:\\/\\/[0-9a-z]{5,}\\.com\\/.*", true);
    defer regex.deinit();

    try testing.expect(regex.matches("https://abcde.com/x"));
    try testing.expect(regex.matches("HTTPS://ABCDE.COM/X"));
    try testing.expect(!regex.matches("https://abcd.com/x"));
    try testing.expect(!regex.matches("https://abcde.org/x"));

    const invoke = try Regex.compile(context, "\\/[0-9a-f]{32}\\/invoke\\.js", true);
    defer invoke.deinit();
    try testing.expect(invoke.matches("https://host.com/0123456789abcdef0123456789abcdef/invoke.js"));
    try testing.expect(!invoke.matches("https://host.com/0123456789abcdef0123456789abcde/invoke.js"));

    const dash = try Regex.compile(context, "[a-z\\-]+\\?s=", true);
    defer dash.deinit();
    try testing.expect(dash.matches("https://x.com/a-b?s=1"));
    try testing.expect(!dash.matches("https://x.com/?s=1"));
}

test "adblock.Regex: case sensitivity follows the flag" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    const caseless = try Regex.compile(context, "\\/Ads\\/", true);
    defer caseless.deinit();
    try testing.expect(caseless.matches("https://x.com/ads/1.js"));
    try testing.expect(caseless.matches("https://x.com/ADS/1.js"));

    const exact = try Regex.compile(context, "\\/[a-z0-9]{12}\\/[a-zA-Z0-9]{20,}$", false);
    defer exact.deinit();
    try testing.expect(exact.matches("https://x.com/abcdef123456/aBcDeFgHiJkLmNoPqRsTuV"));
    try testing.expect(!exact.matches("https://x.com/ABCDEF123456/aBcDeFgHiJkLmNoPqRsTuV"));
}

test "adblock.Regex: invalid patterns are errors, runaway ones no match" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    try testing.expectError(error.InvalidRegex, Regex.compile(context, "(", true));
    try testing.expectError(error.InvalidRegex, Regex.compile(context, "a{2,1}", true));

    // An unknown alphanumeric escape is the literal, as in JavaScript.
    const literal = try Regex.compile(context, "\\q", true);
    defer literal.deinit();
    try testing.expect(literal.matches("https://x.com/q"));

    // Exponential backtracking stops at the match limit instead of stalling
    // the request.
    const runaway = try Regex.compile(context, "^(a+)+$", true);
    defer runaway.deinit();
    const subject = "a" ** 64 ++ "b";
    try testing.expect(!runaway.matches(subject));
    try testing.expect(runaway.matches("a" ** 64));
}
