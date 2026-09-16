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

//! A pattern in JavaScript `RegExp` syntax, run by PCRE2, which reads that
//! syntax as-is, escapes like `\/` included.
//!
//! A compiled pattern and its `Context` are never modified after `compile`,
//! so one `Regex` can be shared by every thread; the per-call match data is
//! what PCRE2 requires to be private.

const std = @import("std");
const pcre2 = @import("pcre2");

const Allocator = std.mem.Allocator;

const Regex = @This();

code: *pcre2.pcre2_code_8,
context: *const Context,

pub const Error = error{ InvalidRegex, OutOfMemory };

pub const Options = struct {
    case_insensitive: bool = false,
    /// UTF-8 aware matching: `.` consumes a code point and caseless folding
    /// works beyond ASCII. An invalid sequence in the subject fails to match
    /// rather than erroring. `\b` and `\w` stay ASCII, as in JavaScript.
    unicode: bool = false,
    /// JavaScript's `s`.
    dot_all: bool = false,
    /// JavaScript's `m`.
    multiline: bool = false,
};

pub const Diagnostic = struct {
    offset: usize = 0,
    len: usize = 0,
    buf: [256]u8 = undefined,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Shared by every `Regex` compiled through it; outlives them.
///
/// PCRE2 would happily use libc's malloc; it is handed the owner's allocator
/// so that a compiled pattern nobody freed fails a test the way any other
/// leak does.
pub const Context = struct {
    allocator: Allocator,
    general: *pcre2.pcre2_general_context_8,
    compile_context: *pcre2.pcre2_compile_context_8,
    match_context: *pcre2.pcre2_match_context_8,

    // Patterns come from lists and prompts, never from code: one that
    // backtracks this much on a subject is broken, not slow, and giving up
    // costs a false negative on that subject, nothing more.
    const MATCH_LIMIT = 100_000;
    const DEPTH_LIMIT = 10_000;

    pub fn init(allocator: Allocator) Allocator.Error!*Context {
        const self = try allocator.create(Context);
        errdefer allocator.destroy(self);
        self.allocator = allocator;

        // PCRE2 hands the allocator back to the callbacks by address, so the
        // context has to be at its final one before anything is allocated
        // through it.
        const general = pcre2.pcre2_general_context_create_8(cMalloc, cFree, &self.allocator) orelse return error.OutOfMemory;
        errdefer pcre2.pcre2_general_context_free_8(general);

        const compile_context = pcre2.pcre2_compile_context_create_8(general) orelse return error.OutOfMemory;
        errdefer pcre2.pcre2_compile_context_free_8(compile_context);
        // JavaScript reads an unknown escape as the literal character.
        _ = pcre2.pcre2_set_compile_extra_options_8(compile_context, pcre2.PCRE2_EXTRA_BAD_ESCAPE_IS_LITERAL);

        const match_context = pcre2.pcre2_match_context_create_8(general) orelse return error.OutOfMemory;
        _ = pcre2.pcre2_set_match_limit_8(match_context, MATCH_LIMIT);
        _ = pcre2.pcre2_set_depth_limit_8(match_context, DEPTH_LIMIT);

        self.general = general;
        self.compile_context = compile_context;
        self.match_context = match_context;
        return self;
    }

    /// A failed compile fills `diag`, when given, with PCRE2's message and the
    /// offset of the offending character.
    pub fn compile(self: *const Context, pattern: []const u8, options: Options, diag: ?*Diagnostic) Error!Regex {
        var flags: u32 = 0;
        if (options.case_insensitive) flags |= pcre2.PCRE2_CASELESS;
        if (options.unicode) flags |= pcre2.PCRE2_UTF | pcre2.PCRE2_MATCH_INVALID_UTF;
        if (options.dot_all) flags |= pcre2.PCRE2_DOTALL;
        if (options.multiline) flags |= pcre2.PCRE2_MULTILINE;

        var err_code: c_int = 0;
        var err_offset: usize = 0;
        const code = pcre2.pcre2_compile_8(
            pattern.ptr,
            pattern.len,
            flags,
            &err_code,
            &err_offset,
            self.compile_context,
        ) orelse {
            // A failed allocation is ours, not the pattern's.
            if (err_code == pcre2.PCRE2_ERROR_HEAP_FAILED) return error.OutOfMemory;
            if (diag) |d| {
                const len = pcre2.pcre2_get_error_message_8(err_code, &d.buf, d.buf.len);
                d.len = if (len < 0) 0 else @intCast(len);
                d.offset = err_offset;
            }
            return error.InvalidRegex;
        };
        return .{ .code = code, .context = self };
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
        const allocator: *const Allocator = @ptrCast(@alignCast(data.?));
        const total = std.math.add(usize, size, HEADER) catch return null;
        const block = allocator.alignedAlloc(u8, alignment, total) catch return null;
        std.mem.writeInt(usize, block[0..@sizeOf(usize)], total, .little);
        return block.ptr + HEADER;
    }

    fn cFree(ptr: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const payload = ptr orelse return;
        const allocator: *const Allocator = @ptrCast(@alignCast(data.?));
        const base: [*]align(HEADER) u8 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(payload)) - HEADER));
        const total = std.mem.readInt(usize, base[0..@sizeOf(usize)], .little);
        allocator.free(base[0..total]);
    }
};

pub fn deinit(self: Regex) void {
    pcre2.pcre2_code_free_8(self.code);
}

// What one match allocates: its match data and the 20KB of backtracking
// frames PCRE2 starts with, which only a deeply nested pattern outgrows.
const MATCH_SCRATCH = 24 * 1024;

/// Whether the pattern matches anywhere in `text`, as `RegExp.test` would
/// answer. A match that hits the backtracking limits counts as no match.
pub fn matches(self: Regex, text: []const u8) bool {
    var scratch = std.heap.stackFallback(MATCH_SCRATCH, self.context.allocator);
    var allocator = scratch.get();
    const general = pcre2.pcre2_general_context_create_8(Context.cMalloc, Context.cFree, &allocator) orelse return false;
    defer pcre2.pcre2_general_context_free_8(general);

    // One pair is the whole-match span, all a test needs; capture groups in
    // the pattern are simply not recorded.
    const match_data = pcre2.pcre2_match_data_create_8(1, general) orelse return false;
    defer pcre2.pcre2_match_data_free_8(match_data);

    const rc = pcre2.pcre2_match_8(self.code, text.ptr, text.len, 0, 0, match_data, self.context.match_context);
    return rc >= 0;
}

const testing = @import("testing.zig");

test "Regex: JavaScript escapes and unanchored search" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    const regex = try context.compile("^https?:\\/\\/[0-9a-z]{5,}\\.com\\/.*", .{ .case_insensitive = true }, null);
    defer regex.deinit();

    try testing.expect(regex.matches("https://abcde.com/x"));
    try testing.expect(regex.matches("HTTPS://ABCDE.COM/X"));
    try testing.expect(!regex.matches("https://abcd.com/x"));
    try testing.expect(!regex.matches("https://abcde.org/x"));

    const invoke = try context.compile("\\/[0-9a-f]{32}\\/invoke\\.js", .{ .case_insensitive = true }, null);
    defer invoke.deinit();
    try testing.expect(invoke.matches("https://host.com/0123456789abcdef0123456789abcdef/invoke.js"));
    try testing.expect(!invoke.matches("https://host.com/0123456789abcdef0123456789abcde/invoke.js"));

    const dash = try context.compile("[a-z\\-]+\\?s=", .{ .case_insensitive = true }, null);
    defer dash.deinit();
    try testing.expect(dash.matches("https://x.com/a-b?s=1"));
    try testing.expect(!dash.matches("https://x.com/?s=1"));
}

test "Regex: case is kept by default" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    const exact = try context.compile("\\/[a-z0-9]{12}\\/[a-zA-Z0-9]{20,}$", .{}, null);
    defer exact.deinit();
    try testing.expect(exact.matches("https://x.com/abcdef123456/aBcDeFgHiJkLmNoPqRsTuV"));
    try testing.expect(!exact.matches("https://x.com/ABCDEF123456/aBcDeFgHiJkLmNoPqRsTuV"));
}

test "Regex: invalid patterns are errors, runaway ones no match" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    try testing.expectError(error.InvalidRegex, context.compile("(", .{}, null));
    try testing.expectError(error.InvalidRegex, context.compile("a{2,1}", .{}, null));

    // An unknown alphanumeric escape is the literal, as in JavaScript.
    const literal = try context.compile("\\q", .{ .case_insensitive = true }, null);
    defer literal.deinit();
    try testing.expect(literal.matches("https://x.com/q"));

    // Exponential backtracking stops at the match limit instead of stalling
    // the caller.
    const runaway = try context.compile("^(a+)+$", .{ .case_insensitive = true }, null);
    defer runaway.deinit();
    const subject = "a" ** 64 ++ "b";
    try testing.expect(!runaway.matches(subject));
    try testing.expect(runaway.matches("a" ** 64));
}

test "Regex: dot_all and multiline follow the JavaScript flags" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    const dot = try context.compile("a.b", .{}, null);
    defer dot.deinit();
    try testing.expect(!dot.matches("a\nb"));
    const dot_all = try context.compile("a.b", .{ .dot_all = true }, null);
    defer dot_all.deinit();
    try testing.expect(dot_all.matches("a\nb"));

    const line = try context.compile("^b$", .{}, null);
    defer line.deinit();
    try testing.expect(!line.matches("a\nb"));
    const multiline = try context.compile("^b$", .{ .multiline = true }, null);
    defer multiline.deinit();
    try testing.expect(multiline.matches("a\nb"));
}

test "Regex: a diagnostic names the fault and where it is" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidRegex, context.compile("ab(", .{}, &diag));
    try testing.expectString("missing closing parenthesis", diag.message());
    try testing.expectEqual(3, diag.offset);
}

test "Regex: unicode folds case beyond ASCII and tolerates invalid bytes" {
    const context: *Context = try .init(testing.allocator);
    defer context.deinit();

    const ascii = try context.compile("^реклама$", .{ .case_insensitive = true }, null);
    defer ascii.deinit();
    try testing.expect(ascii.matches("реклама"));
    try testing.expect(!ascii.matches("Реклама"));

    const unicode = try context.compile("^реклама$", .{ .case_insensitive = true, .unicode = true }, null);
    defer unicode.deinit();
    try testing.expect(unicode.matches("Реклама"));
    try testing.expect(unicode.matches("РЕКЛАМА"));

    // One code point, not one byte.
    const single = try context.compile("^.$", .{ .unicode = true }, null);
    defer single.deinit();
    try testing.expect(single.matches("é"));
    try testing.expect(!single.matches("ab"));

    // Word boundaries stay ASCII, as in JavaScript.
    const word = try context.compile("\\bshare\\b", .{ .unicode = true }, null);
    defer word.deinit();
    try testing.expect(word.matches("éshare"));

    const sidebar = try context.compile("sidebar", .{ .unicode = true }, null);
    defer sidebar.deinit();
    try testing.expect(sidebar.matches("sidebar\xFF"));
    try testing.expect(!sidebar.matches("\xFF"));
}
