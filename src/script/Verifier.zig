// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const Command = @import("Command.zig");
const CDPNode = @import("../cdp/Node.zig");

const Self = @This();

session: *lp.Session,
node_registry: *CDPNode.Registry,

/// Verdict for a verify pass.
///   passed       — the command's intent was confirmed against the DOM.
///   failed       — the DOM doesn't reflect the intent; payload is the
///                  human-readable explanation, or null if formatting the
///                  message itself OOM'd.
///   inconclusive — no verification rule applies (or one was inconclusive,
///                  e.g. the queried property couldn't be read).
pub const VerifyResult = union(enum) {
    passed,
    failed: ?[]const u8,
    inconclusive,
};

/// Verify that a command achieved its intent after execution. Only called
/// when the command did not hard-fail (ExecResult.failed == false).
/// Commands without a dedicated verifier return `.inconclusive` so callers
/// can distinguish "no verification available" from "explicitly verified".
pub fn verify(self: *Self, arena: std.mem.Allocator, cmd: Command.Command) VerifyResult {
    return switch (cmd) {
        .type_cmd => |args| self.verifyFill(arena, args.selector, args.value),
        .check => |args| self.verifyCheck(arena, args.selector, args.checked),
        .select => |args| self.verifySelect(arena, args.selector, args.value),
        else => .inconclusive,
    };
}

fn verifyFill(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) VerifyResult {
    // Secret env-var references can't be compared literally — just
    // verify the field isn't empty after substitution.
    if (std.mem.indexOf(u8, expected_value, "$LP_") != null) {
        const actual = self.queryElementProperty(arena, selector, "value") orelse return .inconclusive;
        if (actual.len == 0 or std.mem.eql(u8, actual, "null"))
            return .{ .failed = "element value is empty after fill (expected non-empty for secret)" };
        return .passed;
    }
    return self.verifyElementValue(arena, selector, .{ .js_property = "value", .expected = expected_value, .label = "value" });
}

fn verifyCheck(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected: bool) VerifyResult {
    const expected_str: []const u8 = if (expected) "true" else "false";
    return self.verifyElementValue(arena, selector, .{ .js_property = "String(el.checked)", .expected = expected_str, .label = "checked state" });
}

fn verifySelect(self: *Self, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) VerifyResult {
    return self.verifyElementValue(arena, selector, .{ .js_property = "value", .expected = expected_value, .label = "selected value" });
}

const Check = struct {
    js_property: []const u8,
    expected: []const u8,
    label: []const u8,
};

fn verifyElementValue(self: *Self, arena: std.mem.Allocator, selector: []const u8, check: Check) VerifyResult {
    const actual = self.queryElementProperty(arena, selector, check.js_property) orelse return .inconclusive;
    if (!std.mem.eql(u8, actual, check.expected))
        return .{ .failed = std.fmt.allocPrint(arena, "element {s} is \"{s}\" (expected \"{s}\")", .{ check.label, actual, check.expected }) catch null };
    return .passed;
}

fn queryElementProperty(self: *Self, arena: std.mem.Allocator, selector: []const u8, js_property: []const u8) ?[]const u8 {
    const selector_json = std.json.Stringify.valueAlloc(arena, selector, .{}) catch return null;
    const script = std.fmt.allocPrint(
        arena,
        "(function(){{ var el = document.querySelector({s}); return el ? {s} : null; }})()",
        .{ selector_json, js_property },
    ) catch return null;
    const result = browser_tools.evalScript(arena, self.session, self.node_registry, script) catch return null;
    return switch (result) {
        .ok => |t| t,
        .js_error => null,
    };
}
