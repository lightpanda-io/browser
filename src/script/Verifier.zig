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
const Command = @import("command.zig").Command;
const CDPNode = @import("../cdp/Node.zig");

const Verifier = @This();

session: *lp.Session,
node_registry: *CDPNode.Registry,

pub const VerifyResult = union(enum) {
    passed,
    failed: []const u8,
    inconclusive,
};

/// Closed set of element properties the verifier can probe — keeps the JS
/// template injection-free (no caller-supplied expression text).
const ElementProperty = enum {
    value,
    checked_string,

    fn jsExpr(self: ElementProperty) []const u8 {
        return switch (self) {
            .value => "el.value",
            .checked_string => "String(el.checked)",
        };
    }
};

/// Fallback when allocPrint OOMs — lets `VerifyResult.failed` stay non-optional.
const failed_reason_oom = "verification failed (out of memory while formatting reason)";

/// Verify that a command achieved its intent after execution. Only called
/// when the command did not hard-fail (ToolResult.is_error == false).
/// Commands without a dedicated verifier return `.inconclusive` so callers
/// can distinguish "no verification available" from "explicitly verified".
///
/// backendNodeId-addressed commands are intentionally `.inconclusive`: the
/// id is a CDP-side handle with no in-page accessor, and recorded paths use
/// CSS selectors per `driver_guidance` (backendNodeId calls can't be
/// recorded as PandaScript anyway).
pub fn verify(self: *Verifier, arena: std.mem.Allocator, cmd: Command) VerifyResult {
    const tc = switch (cmd) {
        .tool_call => |t| t,
        else => return .inconclusive,
    };
    const args = tc.args orelse return .inconclusive;
    if (args != .object) return .inconclusive;
    const selector = (args.object.get("selector") orelse return .inconclusive);
    if (selector != .string) return .inconclusive;

    switch (tc.tool) {
        .fill => {
            const value = args.object.get("value") orelse return .inconclusive;
            if (value != .string) return .inconclusive;
            return self.verifyFill(arena, selector.string, value.string);
        },
        .setChecked => {
            const checked = args.object.get("checked") orelse return .inconclusive;
            if (checked != .bool) return .inconclusive;
            return self.verifyCheck(arena, selector.string, checked.bool);
        },
        .selectOption => {
            const value = args.object.get("value") orelse return .inconclusive;
            if (value != .string) return .inconclusive;
            return self.verifySelect(arena, selector.string, value.string);
        },
        else => return .inconclusive,
    }
}

fn verifyFill(self: *Verifier, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) VerifyResult {
    // Secret env-var references can't be compared literally — just
    // verify the field isn't empty after substitution.
    if (std.mem.indexOf(u8, expected_value, "$LP_") != null) {
        var actual = self.queryElementProperty(arena, selector, .value) orelse return .inconclusive;
        if (actual.len == 0) {
            self.settle();
            actual = self.queryElementProperty(arena, selector, .value) orelse return .inconclusive;
        }
        if (actual.len == 0)
            return .{ .failed = "element value is empty after fill (expected non-empty for secret)" };
        return .passed;
    }
    return self.verifyElementValue(arena, selector, .{ .property = .value, .expected = expected_value, .label = "value" });
}

fn verifyCheck(self: *Verifier, arena: std.mem.Allocator, selector: []const u8, expected: bool) VerifyResult {
    const expected_str: []const u8 = if (expected) "true" else "false";
    return self.verifyElementValue(arena, selector, .{ .property = .checked_string, .expected = expected_str, .label = "checked state" });
}

fn verifySelect(self: *Verifier, arena: std.mem.Allocator, selector: []const u8, expected_value: []const u8) VerifyResult {
    return self.verifyElementValue(arena, selector, .{ .property = .value, .expected = expected_value, .label = "selected value" });
}

const Check = struct {
    property: ElementProperty,
    expected: []const u8,
    label: []const u8,
};

fn verifyElementValue(self: *Verifier, arena: std.mem.Allocator, selector: []const u8, check: Check) VerifyResult {
    var actual = self.queryElementProperty(arena, selector, check.property) orelse return .inconclusive;
    if (std.mem.eql(u8, actual, check.expected)) return .passed;

    // Frameworks (React, Vue) reflect state changes through a microtask /
    // re-render. Reading inside the same tick can miss the update — drain
    // one runner tick and try again before declaring failure.
    self.settle();
    actual = self.queryElementProperty(arena, selector, check.property) orelse return .inconclusive;
    if (std.mem.eql(u8, actual, check.expected)) return .passed;

    const msg = std.fmt.allocPrint(arena, "element {s} is \"{s}\" (expected \"{s}\")", .{ check.label, actual, check.expected }) catch failed_reason_oom;
    return .{ .failed = msg };
}

/// Drain pending microtasks / macrotasks so a same-tick re-render
/// reflects in DOM state before the next query. Best-effort; failures
/// to acquire the runner fall through silently.
fn settle(self: *Verifier) void {
    var runner = self.session.runner(.{}) catch return;
    runner.wait(.{ .ms = 50, .until = .done }) catch {};
}

/// Returns the property value, or `null` when the element is missing or the
/// eval failed. A single-byte tag (`v` = present, `m` = missing) disambiguates
/// from values that happen to stringify to "null", so `value="null"` after
/// `/fill ... value=null` doesn't look like a missing element.
fn queryElementProperty(self: *Verifier, arena: std.mem.Allocator, selector: []const u8, property: ElementProperty) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("(function(){ var el = document.querySelector(") catch return null;
    std.json.Stringify.value(selector, .{}, &aw.writer) catch return null;
    aw.writer.writeAll("); return el ? 'v' + (") catch return null;
    aw.writer.writeAll(property.jsExpr()) catch return null;
    aw.writer.writeAll(") : 'm'; })()") catch return null;
    const result = browser_tools.evalScript(arena, self.session, self.node_registry, aw.written()) catch return null;
    const text = result.okText() orelse return null;
    if (text.len == 0 or text[0] != 'v') return null;
    return text[1..];
}
