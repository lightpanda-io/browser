const std = @import("std");
const Command = @import("Command.zig");
const ToolExecutor = @import("ToolExecutor.zig");

const Self = @This();

tool_executor: *ToolExecutor,

pub const Result = enum {
    passed,
    failed,
    inconclusive,
};

pub const PreState = struct {
    url: []const u8,
    dom_element_count: ?u32,
};

pub fn capturePreState(self: *Self, arena: std.mem.Allocator) PreState {
    return .{
        .url = self.tool_executor.getCurrentUrl(),
        .dom_element_count = self.getDomElementCount(arena),
    };
}

/// Returns the reason verification failed, or null if it passed/was inconclusive.
pub fn failureReason(self: *Self, arena: std.mem.Allocator, cmd: Command.Command, pre: PreState, intent: ?[]const u8) ?[]const u8 {
    return switch (cmd) {
        .type_cmd => |args| self.fillFailureReason(arena, args.selector, args.value),
        .check => |args| self.checkFailureReason(arena, args.selector, args.checked),
        .click => self.clickFailureReason(arena, pre, intent),
        else => null,
    };
}

/// Verify that a command achieved its intent after execution.
/// Only called when the command did not hard-fail (ExecResult.failed == false).
pub fn verify(self: *Self, arena: std.mem.Allocator, cmd: Command.Command, pre: PreState, intent: ?[]const u8) Result {
    return switch (cmd) {
        .type_cmd => |args| self.verifyFill(arena, args.selector, args.value),
        .check => |args| self.verifyCheck(arena, args.selector, args.checked),
        .click => self.verifyClick(arena, pre, intent),
        else => .passed,
    };
}

fn verifyFill(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) Result {
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? el.value : null; }})()",
        .{jsonQuote(arena, selector)},
    ) catch return .inconclusive;

    const actual = self.tool_executor.callEval(arena, script) orelse return .inconclusive;

    // Secret values ($LP_*): just verify non-empty.
    if (std.mem.indexOf(u8, expected_value, "$LP_") != null) {
        return if (actual.len == 0 or std.mem.eql(u8, actual, "null")) .failed else .passed;
    }

    // Plain values: exact comparison.
    return if (std.mem.eql(u8, actual, expected_value)) .passed else .failed;
}

fn verifyCheck(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected: bool) Result {
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? String(el.checked) : null; }})()",
        .{jsonQuote(arena, selector)},
    ) catch return .inconclusive;

    const actual = self.tool_executor.callEval(arena, script) orelse return .inconclusive;
    const expected_str: []const u8 = if (expected) "true" else "false";
    return if (std.mem.eql(u8, actual, expected_str)) .passed else .failed;
}

fn verifyClick(self: *Self, arena: std.mem.Allocator, pre: PreState, intent: ?[]const u8) Result {
    // URL changed → click had an effect
    const current_url = self.tool_executor.getCurrentUrl();
    if (!std.mem.eql(u8, pre.url, current_url)) return .passed;

    // DOM element count changed → click had a visible effect (modal, accordion, etc.)
    if (pre.dom_element_count) |before_count| {
        const after_count = self.getDomElementCount(arena);
        if (after_count) |ac| {
            if (ac != before_count) return .passed;
        }
    }

    // URL unchanged, DOM unchanged — check if intent suggests navigation was expected
    if (intent) |i| {
        if (containsNavigationIntent(i)) return .failed;
    }

    // No intent, nothing changed — can't tell if this is wrong
    return .inconclusive;
}

fn getDomElementCount(self: *Self, arena: std.mem.Allocator) ?u32 {
    const result = self.tool_executor.callEval(arena, "document.querySelectorAll('*').length") orelse return null;
    return std.fmt.parseInt(u32, result, 10) catch null;
}

fn containsNavigationIntent(intent: []const u8) bool {
    const keywords = [_][]const u8{ "login", "submit", "sign in", "log in", "next", "go to", "navigate", "redirect" };
    var lower_buf: [512]u8 = undefined;
    const len = @min(intent.len, lower_buf.len);
    for (intent[0..len], 0..) |c, j| {
        lower_buf[j] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..len];
    for (keywords) |kw| {
        if (std.mem.indexOf(u8, lower, kw) != null) return true;
    }
    return false;
}

fn fillFailureReason(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) ?[]const u8 {
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? el.value : null; }})()",
        .{jsonQuote(arena, selector)},
    ) catch return null;

    const actual = self.tool_executor.callEval(arena, script) orelse return null;

    if (std.mem.indexOf(u8, expected_value, "$LP_") != null) {
        if (actual.len == 0 or std.mem.eql(u8, actual, "null"))
            return std.fmt.allocPrint(arena, "element value is empty after fill (expected non-empty for secret)", .{}) catch null;
        return null;
    }

    if (!std.mem.eql(u8, actual, expected_value))
        return std.fmt.allocPrint(arena, "element value is \"{s}\" after fill (expected \"{s}\")", .{ actual, expected_value }) catch null;
    return null;
}

fn checkFailureReason(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected: bool) ?[]const u8 {
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? String(el.checked) : null; }})()",
        .{jsonQuote(arena, selector)},
    ) catch return null;

    const actual = self.tool_executor.callEval(arena, script) orelse return null;
    const expected_str: []const u8 = if (expected) "true" else "false";
    if (!std.mem.eql(u8, actual, expected_str))
        return std.fmt.allocPrint(arena, "element checked state is {s} (expected {s})", .{ actual, expected_str }) catch null;
    return null;
}

fn clickFailureReason(self: *Self, arena: std.mem.Allocator, pre: PreState, intent: ?[]const u8) ?[]const u8 {
    const current_url = self.tool_executor.getCurrentUrl();
    if (!std.mem.eql(u8, pre.url, current_url)) return null; // URL changed, passed

    if (pre.dom_element_count) |before_count| {
        if (self.getDomElementCount(arena)) |ac| {
            if (ac != before_count) return null; // DOM changed, passed
        }
    }

    if (intent) |i| {
        if (containsNavigationIntent(i))
            return std.fmt.allocPrint(arena, "click had no effect: URL unchanged (still {s}), DOM unchanged, but intent suggests navigation was expected", .{current_url}) catch null;
    }
    return null;
}

fn jsonQuote(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(s, .{}, &aw.writer) catch return "\"\"";
    return aw.written();
}
