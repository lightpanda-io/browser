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

const CDP = @import("../CDP.zig");
const js = @import("../../../browser/js/js.zig");
const Notification = @import("../../../Notification.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        runIfWaitingForDebugger,
        evaluate,
        addBinding,
        callFunctionOn,
        releaseObject,
        getProperties,
        releaseObjectGroup,
        awaitPromise,
        compileScript,
        runScript,
        queryObjects,
        globalLexicalScopeNames,
        removeBinding,
        terminateExecution,
        getExceptionDetails,
        discardConsoleEntries,
        getHeapUsage,
        getIsolateId,
        setCustomObjectFormatterEnabled,
        setMaxCallStackSizeToCapture,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .runIfWaitingForDebugger => return cmd.sendResult(null, .{}),
        .enable => return enable(cmd),
        .disable => return disable(cmd),
        // Bookkeeping that can neither observe nor change the page's global.
        .releaseObjectGroup, .discardConsoleEntries, .getHeapUsage, .getIsolateId, .setCustomObjectFormatterEnabled, .setMaxCallStackSizeToCapture => return sendInspector(cmd),
        else => {
            const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
            bc.main_world_touched = true;
            return sendInspector(cmd);
        },
    }
}

fn enable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    try bc.runtimeEnable();
    return sendInspector(cmd);
}

fn disable(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.runtimeDisable();
    return sendInspector(cmd);
}

fn sendInspector(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // the result to return is handled directly by the inspector.
    bc.callInspector(cmd.input.json);
}

// Object arguments stay remote handles; serializing them would execute page JS.
const RemoteObject = struct {
    type: []const u8,
    subtype: ?[]const u8,
    className: ?[]const u8,
    description: ?[]const u8,
    objectId: ?[]const u8,
    value: ?std.json.Value = null,
    unserializableValue: ?[]const u8 = null,

    fn setPrimitive(self: *RemoteObject, arena: Allocator, value: js.Value) !void {
        if (value.isString()) |str| {
            self.value = .{ .string = try str.toSliceWithAlloc(arena) };
        } else if (value.isBoolean()) {
            self.value = .{ .bool = value.isTrue() };
        } else if (value.isNull()) {
            self.value = .null;
        } else if (value.isNumber()) {
            const n = try value.toF64();
            if (std.math.isNan(n)) {
                self.unserializableValue = "NaN";
            } else if (std.math.isInf(n)) {
                self.unserializableValue = if (n > 0) "Infinity" else "-Infinity";
            } else if (n == 0 and std.math.signbit(n)) {
                self.unserializableValue = "-0";
            } else if (value.isInt32()) {
                self.value = .{ .integer = @intFromFloat(n) };
            } else {
                self.value = .{ .float = n };
            }
        } else if (value.isBigInt()) {
            self.unserializableValue = try std.fmt.allocPrint(arena, "{s}n", .{try value.toStringSliceWithAlloc(arena)});
        }
    }
};

const ConsoleMessage = struct {
    type: []const u8,
    executionContextId: i32,
    timestamp: u64,
    args: []RemoteObject,
};

pub fn consoleMessage(arena: Allocator, bc: *CDP.BrowserContext, event: *const Notification.ConsoleMessage) !void {
    const session_id = bc.session_id orelse return;
    const frame = bc.mainFrame() orelse return error.FrameNotLoaded;

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const context_id = bc.inspector_session.inspector.getContextId(&ls.local);

    var args: std.ArrayList(RemoteObject) = .empty;
    for (event.values) |value| {
        const remote_object = try bc.inspector_session.getRemoteObject(
            &ls.local,
            "",
            value,
        );
        defer remote_object.deinit();

        const arg = try args.addOne(arena);
        arg.* = .{
            .type = try remote_object.getType(arena),
            .subtype = try remote_object.getSubtype(arena),
            .className = try remote_object.getClassName(arena),
            .description = try remote_object.getDescription(arena),
            .objectId = try remote_object.getObjectId(arena),
        };
        try arg.setPrimitive(arena, value);
    }

    return bc.cdp.sendEvent("Runtime.consoleAPICalled", ConsoleMessage{
        .type = @tagName(event.type),
        .timestamp = event.timestamp,
        .executionContextId = context_id,
        .args = args.items,
    }, .{ .session_id = session_id });
}

const testing = @import("../testing.zig");

test "cdp.runtime: inspector-handled methods pass through" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-RT", .url = "hi.html", .target_id = "FID-0000000RTP".* });
    try ctx.processMessage(.{ .id = 50, .method = "Runtime.enable" });

    try ctx.processMessage(.{ .id = 51, .method = "Runtime.releaseObjectGroup", .params = .{ .objectGroup = "handles" } });
    try ctx.expectSentResult(null, .{ .id = 51 });

    try ctx.processMessage(.{ .id = 52, .method = "Runtime.discardConsoleEntries" });
    try ctx.expectSentResult(null, .{ .id = 52 });
}

test "cdp.runtime: consoleAPICalled type matches the console method" {
    testing.silenceLog(&.{.js});

    // Wire types per the CDP protocol: console.log -> "log",
    // console.warn -> "warning" (not "warn"), console.info -> "info",
    // console.error -> "error", console.debug -> "debug".
    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-CONS", .url = "hi.html", .target_id = "FID-0000000CON".* });
    try ctx.processMessage(.{ .id = 60, .method = "Runtime.enable" });

    const frame = bc.mainFrame() orelse unreachable;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec("console.log('l'); console.warn('w'); console.info('i'); console.error('e'); console.debug('d');", null);

    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "log" }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "warning" }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "info" }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "error" }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "debug" }, .{});
}

test "cdp.runtime: consoleAPICalled only carries values for primitives" {
    testing.silenceLog(&.{.js});

    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-CONS", .url = "hi.html", .target_id = "FID-0000000CON".* });
    try ctx.processMessage(.{ .id = 60, .method = "Runtime.enable" });

    const frame = bc.mainFrame() orelse unreachable;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec(
        \\globalThis.probed = 0;
        \\const div = document.createElement('div');
        \\Object.defineProperty(div, 'id', { get() { globalThis.probed++; return 'x'; }, enumerable: true });
        \\const obj = { toJSON() { globalThis.probed++; return 'x'; } };
        \\const cycle = {}; cycle.self = cycle;
        \\console.log(div, obj, 'str', 12, 1.5, true, null, undefined, NaN, -0, 10n,
        \\    Infinity, -Infinity, false, 0, 2 ** 40, -9007199254740993n, Symbol('test'),
        \\    function named() {}, cycle, new Number(42));
    , null);

    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "log", .args = .{
        .{ .type = "object", .className = "HTMLDivElement" },
        .{ .type = "object", .className = "Object" },
        .{ .type = "string", .value = "str" },
        .{ .type = "number", .value = 12 },
        .{ .type = "number", .value = 1.5 },
        .{ .type = "boolean", .value = true },
        .{ .type = "object", .subtype = "null", .value = null },
        .{ .type = "undefined" },
        .{ .type = "number", .unserializableValue = "NaN" },
        .{ .type = "number", .unserializableValue = "-0" },
        .{ .type = "bigint", .unserializableValue = "10n" },
        .{ .type = "number", .unserializableValue = "Infinity" },
        .{ .type = "number", .unserializableValue = "-Infinity" },
        .{ .type = "boolean", .value = false },
        .{ .type = "number", .value = 0 },
        .{ .type = "number", .value = @as(f64, 1099511627776) },
        .{ .type = "bigint", .unserializableValue = "-9007199254740993n" },
        .{ .type = "symbol" },
        .{ .type = "function" },
        .{ .type = "object" },
        .{ .type = "object", .className = "Number" },
    } }, .{});

    const event = ctx.received.items[ctx.received.items.len - 1];
    const args = event.object.get("params").?.object.get("args").?.array.items;
    try testing.expectEqual(21, args.len);
    try testing.expect(args[6].object.get("value").? == .null);
    for ([_]usize{ 0, 1, 7, 8, 9, 10, 11, 12, 16, 17, 18, 19, 20 }) |i| {
        try testing.expectEqual(null, args[i].object.get("value"));
    }
    for ([_]usize{ 0, 1, 18, 19, 20 }) |i| {
        try testing.expect(args[i].object.contains("objectId"));
    }
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 13, 14, 15, 17, 18, 19, 20 }) |i| {
        try testing.expectEqual(null, args[i].object.get("unserializableValue"));
    }

    const probed = try ls.local.exec("globalThis.probed", null);
    try testing.expectEqual(0, try probed.toF64());
}

test "cdp.runtime: console calls made while a notification is being built" {
    testing.silenceLog(&.{.js});

    var ctx = try testing.context();
    defer ctx.deinit();

    var bc = try ctx.loadBrowserContext(.{ .id = "BID-CONS", .url = "hi.html", .target_id = "FID-0000000CON".* });
    try ctx.processMessage(.{ .id = 60, .method = "Runtime.enable" });
    try ctx.processMessage(.{ .id = 61, .method = "Console.enable" });

    const frame = bc.mainFrame() orelse unreachable;
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    // Legacy Console formatting can re-enter the notification handlers.
    _ = try ls.local.exec(
        \\const inner = 'x'.repeat(120);
        \\const probe = { toString() { console.log(inner); console.log(inner); return 'outer'; } };
        \\console.log('head-marker', probe, 'tail-marker-'.repeat(20));
    , null);

    const inner = "x" ** 120;
    const tail = "tail-marker-" ** 20;
    try ctx.expectSentEvent("Console.messageAdded", .{ .level = "log", .text = inner }, .{});
    try ctx.expectSentEvent("Console.messageAdded", .{ .level = "log", .text = "head-marker outer " ++ tail }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "log", .args = .{.{ .type = "string", .value = inner }} }, .{});
    try ctx.expectSentEvent("Runtime.consoleAPICalled", .{ .type = "log", .args = .{ .{ .type = "string", .value = "head-marker" }, .{ .type = "object", .className = "Object" }, .{ .type = "string", .value = tail } } }, .{});
    try testing.expectEqual(0, ctx.cdp().notification_depth);
    try testing.expectEqual(0, ctx.cdp().link.send_depth);
    try ctx.processMessage(.{ .id = 62, .method = "Runtime.evaluate", .params = .{ .expression = "6 * 7" } });
    try ctx.expectSentResult(.{ .result = .{ .type = "number", .value = 42 } }, .{ .id = 62 });
}
