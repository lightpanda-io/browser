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

// The V8 inspector implements the Debugger domain: forward the methods and
// let it answer (and emit Debugger.scriptParsed & co) on the sending session.
// Pausing isn't supported: runMessageLoopOnPause doesn't block, so a pause
// can't be inspected or stepped through. The commands that set up or drive a
// pause are rejected. A `debugger;` statement still reports Debugger.paused
// then Debugger.resumed, and execution goes on.
pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
        getPossibleBreakpoints,
        getScriptSource,
        getStackTrace,
        getWasmBytecode,
        disassembleWasmModule,
        nextWasmDisassemblyChunk,
        removeBreakpoint,
        searchInContent,
        setAsyncCallStackDepth,
        setBlackboxExecutionContexts,
        setBlackboxPatterns,
        setBlackboxedRanges,
        setBreakpointsActive,
        setScriptSource,
        setSkipAllPauses,
        setPauseOnExceptions,
        // pause
        pause,
        pauseOnAsyncCall,
        @"resume",
        stepInto,
        stepOver,
        stepOut,
        continueToLocation,
        restartFrame,
        evaluateOnCallFrame,
        setReturnValue,
        setVariableValue,
        setBreakpoint,
        setBreakpointByUrl,
        setBreakpointOnFunctionCall,
        setInstrumentationBreakpoint,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .setPauseOnExceptions => return setPauseOnExceptions(cmd),
        .pause,
        .pauseOnAsyncCall,
        .stepInto,
        .stepOver,
        .stepOut,
        .continueToLocation,
        .restartFrame,
        .evaluateOnCallFrame,
        .setReturnValue,
        .setVariableValue,
        .setBreakpoint,
        .setBreakpointByUrl,
        .setBreakpointOnFunctionCall,
        .setInstrumentationBreakpoint,
        => return pauseNotSupported(cmd),
        else => return sendInspector(cmd),
    }
}

// "none" is V8's default: nothing to pause on.
fn setPauseOnExceptions(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct { state: []const u8 })) orelse return error.InvalidParams;
    if (std.mem.eql(u8, params.state, "none")) {
        return sendInspector(cmd);
    }
    return pauseNotSupported(cmd);
}

fn pauseNotSupported(cmd: *CDP.Command) !void {
    return cmd.sendError(-32000, "Debugger pausing is not supported", .{});
}

fn sendInspector(cmd: *CDP.Command) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;

    // the result to return is handled directly by the inspector.
    try bc.callInspector(cmd);
}

const testing = @import("../testing.zig");

test "cdp.debugger: enable returns a debuggerId" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-DBG", .url = "hi.html", .target_id = "FID-00000DBG01".* });
    try ctx.processMessage(.{ .id = 1, .method = "Debugger.enable" });

    var i: usize = 0;
    const result = blk: while (try ctx.getSentMessage(i)) |msg| : (i += 1) {
        const id = msg.object.get("id") orelse continue;
        if (id == .integer and id.integer == 1) break :blk msg.object.get("result").?;
    } else return error.NoResult;
    const debugger_id = result.object.get("debuggerId") orelse return error.NoDebuggerId;
    try testing.expectEqual(true, debugger_id == .string and debugger_id.string.len > 0);

    try ctx.processMessage(.{ .id = 2, .method = "Debugger.disable" });
    try ctx.expectSentResult(null, .{ .id = 2 });
}

test "cdp.debugger: scriptParsed is sent to the session that enabled it" {
    var ctx = try testing.context();
    defer ctx.deinit();

    const bc = try ctx.loadBrowserContext(.{ .id = "BID-DBG2", .url = "hi.html", .target_id = "FID-00000DBG02".*, .session_id = "SID-PRIMARY" });
    _ = try bc.attachSession("SID-AUX", null);

    try ctx.processMessage(.{ .id = 10, .method = "Debugger.enable", .sessionId = "SID-AUX" });
    try ctx.processMessage(.{ .id = 11, .method = "Runtime.evaluate", .sessionId = "SID-AUX", .params = .{ .expression = "1 + 1\n//# sourceURL=dbg-test.js" } });
    try ctx.expectSentEvent("Debugger.scriptParsed", .{ .url = "dbg-test.js" }, .{ .session_id = "SID-AUX" });

    try ctx.processMessage(.{ .id = 12, .method = "Debugger.setSkipAllPauses", .sessionId = "SID-AUX", .params = .{ .skip = true } });
    try ctx.expectSentResult(null, .{ .id = 12, .session_id = "SID-AUX" });
}

test "cdp.debugger: a debugger statement does not block execution" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-DBG3", .url = "hi.html", .target_id = "FID-00000DBG03".*, .session_id = "SID-PRIMARY" });
    try ctx.processMessage(.{ .id = 20, .method = "Debugger.enable" });
    try ctx.processMessage(.{ .id = 21, .method = "Runtime.evaluate", .params = .{ .expression = "debugger; 40 + 2", .returnByValue = true } });
    try ctx.expectSentEvent("Debugger.paused", .{ .reason = "other" }, .{ .session_id = "SID-PRIMARY" });
    try ctx.expectSentEvent("Debugger.resumed", null, .{ .session_id = "SID-PRIMARY" });
    try ctx.expectSentResult(.{ .result = .{ .type = "number", .value = 42 } }, .{ .id = 21, .session_id = "SID-PRIMARY" });
}

test "cdp.debugger: pause commands are rejected" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-DBG4", .url = "hi.html", .target_id = "FID-00000DBG04".* });
    try ctx.processMessage(.{ .id = 30, .method = "Debugger.enable" });

    var id: usize = 31;
    for ([_][]const u8{
        "Debugger.pause",
        "Debugger.pauseOnAsyncCall",
        "Debugger.stepInto",
        "Debugger.stepOver",
        "Debugger.stepOut",
        "Debugger.continueToLocation",
        "Debugger.restartFrame",
        "Debugger.evaluateOnCallFrame",
        "Debugger.setReturnValue",
        "Debugger.setVariableValue",
        "Debugger.setBreakpoint",
        "Debugger.setBreakpointByUrl",
        "Debugger.setBreakpointOnFunctionCall",
        "Debugger.setInstrumentationBreakpoint",
    }) |method| {
        try ctx.processMessage(.{ .id = id, .method = method });
        try ctx.expectSentError(-32000, "Debugger pausing is not supported", .{ .id = id });
        id += 1;
    }
}

test "cdp.debugger: setPauseOnExceptions only accepts none" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-DBG5", .url = "hi.html", .target_id = "FID-00000DBG05".* });
    try ctx.processMessage(.{ .id = 50, .method = "Debugger.enable" });

    try ctx.processMessage(.{ .id = 51, .method = "Debugger.setPauseOnExceptions", .params = .{ .state = "none" } });
    try ctx.expectSentResult(null, .{ .id = 51 });

    try ctx.processMessage(.{ .id = 52, .method = "Debugger.setPauseOnExceptions", .params = .{ .state = "all" } });
    try ctx.expectSentError(-32000, "Debugger pausing is not supported", .{ .id = 52 });
}
