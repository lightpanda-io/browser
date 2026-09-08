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

const RemoteObject = struct {
    type: []const u8,
    subtype: ?[]const u8,
    className: ?[]const u8,
    description: ?[]const u8,
    objectId: ?[]const u8,
    value: js.Value,
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

        try args.append(arena, .{
            .type = try remote_object.getType(arena),
            .subtype = try remote_object.getSubtype(arena),
            .className = try remote_object.getClassName(arena),
            .description = try remote_object.getDescription(arena),
            .objectId = try remote_object.getObjectId(arena),
            .value = value,
        });
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
