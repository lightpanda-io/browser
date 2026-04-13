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

pub const VerifyResult = struct {
    result: Result,
    reason: ?[]const u8 = null,
};

pub const PreState = struct {
    url: []const u8,
    dom_element_count: ?u32,
};

pub fn capturePreState(self: *Self, arena: std.mem.Allocator, cmd: Command.Command) PreState {
    return .{
        .url = self.tool_executor.getCurrentUrl(),
        .dom_element_count = if (cmd == .click) self.getDomElementCount(arena) else null,
    };
}

/// Verify that a command achieved its intent after execution and return
/// both the verdict and a human-readable failure reason (if applicable).
/// Only called when the command did not hard-fail (ExecResult.failed == false).
pub fn verify(self: *Self, arena: std.mem.Allocator, cmd: Command.Command, pre: PreState) VerifyResult {
    return switch (cmd) {
        .type_cmd => |args| self.verifyFill(arena, args.selector, args.value),
        .check => |args| self.verifyCheck(arena, args.selector, args.checked),
        .select => |args| self.verifySelect(arena, args.selector, args.value),
        .click => self.verifyClick(arena, pre),
        else => .{ .result = .passed },
    };
}

fn verifyFill(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) VerifyResult {
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? el.value : null; }})()",
        .{jsonQuote(arena, selector)},
    ) catch return .{ .result = .inconclusive };

    const actual = self.tool_executor.callEval(arena, script) orelse return .{ .result = .inconclusive };

    if (std.mem.indexOf(u8, expected_value, "$LP_") != null) {
        if (actual.len == 0 or std.mem.eql(u8, actual, "null"))
            return .{
                .result = .failed,
                .reason = std.fmt.allocPrint(arena, "element value is empty after fill (expected non-empty for secret)", .{}) catch null,
            };
        return .{ .result = .passed };
    }

    if (!std.mem.eql(u8, actual, expected_value))
        return .{
            .result = .failed,
            .reason = std.fmt.allocPrint(arena, "element value is \"{s}\" after fill (expected \"{s}\")", .{ actual, expected_value }) catch null,
        };
    return .{ .result = .passed };
}

fn verifyCheck(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected: bool) VerifyResult {
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? String(el.checked) : null; }})()",
        .{jsonQuote(arena, selector)},
    ) catch return .{ .result = .inconclusive };

    const actual = self.tool_executor.callEval(arena, script) orelse return .{ .result = .inconclusive };
    const expected_str: []const u8 = if (expected) "true" else "false";
    if (!std.mem.eql(u8, actual, expected_str))
        return .{
            .result = .failed,
            .reason = std.fmt.allocPrint(arena, "element checked state is {s} (expected {s})", .{ actual, expected_str }) catch null,
        };
    return .{ .result = .passed };
}

fn verifySelect(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) VerifyResult {
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? el.value : null; }})()",
        .{jsonQuote(arena, selector)},
    ) catch return .{ .result = .inconclusive };

    const actual = self.tool_executor.callEval(arena, script) orelse return .{ .result = .inconclusive };
    if (!std.mem.eql(u8, actual, expected_value))
        return .{
            .result = .failed,
            .reason = std.fmt.allocPrint(arena, "element selected value is \"{s}\" (expected \"{s}\")", .{ actual, expected_value }) catch null,
        };
    return .{ .result = .passed };
}

fn verifyClick(self: *Self, arena: std.mem.Allocator, pre: PreState) VerifyResult {
    const current_url = self.tool_executor.getCurrentUrl();
    if (!std.mem.eql(u8, pre.url, current_url)) return .{ .result = .passed };

    if (pre.dom_element_count) |before_count| {
        if (self.getDomElementCount(arena)) |ac| {
            if (ac != before_count) return .{ .result = .passed };
        }
    }

    return .{ .result = .inconclusive };
}

fn getDomElementCount(self: *Self, arena: std.mem.Allocator) ?u32 {
    const result = self.tool_executor.callEval(arena, "document.querySelectorAll('*').length") orelse return null;
    return std.fmt.parseInt(u32, result, 10) catch null;
}

fn jsonQuote(arena: std.mem.Allocator, s: []const u8) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(s, .{}, &aw.writer) catch return "\"\"";
    return aw.written();
}

test "jsonQuote produces valid JSON string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("\"hello\"", jsonQuote(a, "hello"));
    try std.testing.expectEqualStrings("\"a\\\"b\"", jsonQuote(a, "a\"b"));
    try std.testing.expectEqualStrings("\"\"", jsonQuote(a, ""));
}
