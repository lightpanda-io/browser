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

/// Verify that a command achieved its intent after execution and return
/// both the verdict and a human-readable failure reason (if applicable).
/// Only called when the command did not hard-fail (ExecResult.failed == false).
pub fn verify(self: *Self, arena: std.mem.Allocator, cmd: Command.Command) VerifyResult {
    return switch (cmd) {
        .type_cmd => |args| self.verifyFill(arena, args.selector, args.value),
        .check => |args| self.verifyCheck(arena, args.selector, args.checked),
        .select => |args| self.verifySelect(arena, args.selector, args.value),
        else => .{ .result = .passed },
    };
}

fn verifyFill(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) VerifyResult {
    // Secret env-var references can't be compared literally — just
    // verify the field isn't empty after substitution.
    if (std.mem.indexOf(u8, expected_value, "$LP_") != null) {
        const actual = self.queryElementProperty(arena, selector, "value") orelse return .{ .result = .inconclusive };
        if (actual.len == 0 or std.mem.eql(u8, actual, "null"))
            return .{
                .result = .failed,
                .reason = "element value is empty after fill (expected non-empty for secret)",
            };
        return .{ .result = .passed };
    }
    return self.verifyElementValue(arena, selector, "value", expected_value, "value");
}

fn verifyCheck(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected: bool) VerifyResult {
    const expected_str: []const u8 = if (expected) "true" else "false";
    return self.verifyElementValue(arena, selector, "String(el.checked)", expected_str, "checked state");
}

fn verifySelect(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) VerifyResult {
    return self.verifyElementValue(arena, selector, "value", expected_value, "selected value");
}

fn verifyElementValue(self: *Self, arena: std.mem.Allocator, selector: []const u8, js_property: []const u8, expected: []const u8, label: []const u8) VerifyResult {
    const actual = self.queryElementProperty(arena, selector, js_property) orelse return .{ .result = .inconclusive };
    if (!std.mem.eql(u8, actual, expected))
        return .{
            .result = .failed,
            .reason = std.fmt.allocPrint(arena, "element {s} is \"{s}\" (expected \"{s}\")", .{ label, actual, expected }) catch null,
        };
    return .{ .result = .passed };
}

fn queryElementProperty(self: *Self, arena: std.mem.Allocator, selector: []const u8, js_property: []const u8) ?[]const u8 {
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? {s} : null; }})()",
        .{ Command.stringifyJson(arena, selector), js_property },
    ) catch return null;
    const result = self.tool_executor.callEval(arena, script);
    if (result.is_error) return null;
    return result.text;
}
