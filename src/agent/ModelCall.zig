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

//! Runs `Client.runTools` on a helper thread so the agent thread keeps pumping
//! the session while the model thinks; otherwise page transfers stall and the
//! watchdog kills the page's JS. Tool calls and streamed text still run on the
//! agent thread, and the two threads take turns.

const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");

const Client = zenai.provider.Client;
const Message = zenai.provider.Message;

const ModelCall = @This();

const ToolCall = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    arguments: ?std.json.Value,
    result: Client.ToolHandler.Result = undefined,
};

allocator: std.mem.Allocator,
handler: Client.ToolHandler,
stream: ?Client.TextDeltaHook,
posted: std.Io.Event = .unset,
answered: std.Io.Event = .unset,
outcome: Client.Error!Client.RunToolsResult = undefined,

// What the helper hands over. Streamed text is buffered rather than waited on,
// so the helper keeps reading the model while the agent thread is in a page tick.
mutex: std.Io.Mutex = .init,
text: std.ArrayList(u8) = .empty,
tool_call: ?*ToolCall = null,
finished: bool = false,

/// `client.runTools`, with `session` pumped until the model is done. Falls
/// back to a call on this thread if the helper thread can't start.
pub fn run(
    session: *lp.Session,
    client: Client,
    model: []const u8,
    messages: *std.ArrayList(Message),
    list_alloc: std.mem.Allocator,
    data_alloc: std.mem.Allocator,
    handler: Client.ToolHandler,
    config: Client.RunToolsConfig,
) Client.Error!Client.RunToolsResult {
    var self: ModelCall = .{ .allocator = list_alloc, .handler = handler, .stream = config.stream };
    defer self.text.deinit(list_alloc);

    var forwarded = config;
    if (config.stream != null) forwarded.stream = .{ .context = @ptrCast(&self), .onText = forwardText };
    const forward_tool: Client.ToolHandler = .{ .context = @ptrCast(&self), .callFn = forwardTool };

    const args = .{ client, model, messages, list_alloc, data_alloc, forward_tool, forwarded };
    const thread = std.Thread.spawn(.{}, helperMain, .{ &self, args }) catch
        return client.runTools(model, messages, list_alloc, data_alloc, handler, config);
    self.serve(session);
    thread.join();
    return self.outcome;
}

fn helperMain(self: *ModelCall, args: anytype) void {
    self.outcome = @call(.auto, Client.runTools, args);
    self.mutex.lockUncancelable(lp.io);
    self.finished = true;
    self.mutex.unlock(lp.io);
    self.posted.set(lp.io);
}

/// Agent thread: run what the helper hands over, pump the session in between.
fn serve(self: *ModelCall, session: *lp.Session) void {
    while (true) {
        session.pumpUntil(&self.posted);
        self.posted.reset();

        self.mutex.lockUncancelable(lp.io);
        var text = self.text;
        self.text = .empty;
        const tool_call = self.tool_call;
        self.tool_call = null;
        const finished = self.finished;
        self.mutex.unlock(lp.io);

        if (text.items.len > 0) self.stream.?.call(text.items);
        text.deinit(self.allocator);
        if (tool_call) |call| {
            call.result = self.handler.callFn(self.handler.context, call.allocator, call.name, call.arguments);
            self.answered.set(lp.io);
        }
        if (finished) return;
    }
}

fn forwardTool(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, arguments: ?std.json.Value) Client.ToolHandler.Result {
    const self: *ModelCall = @ptrCast(@alignCast(ctx));
    var call: ToolCall = .{ .allocator = allocator, .name = name, .arguments = arguments };
    self.answered.reset();
    self.mutex.lockUncancelable(lp.io);
    self.tool_call = &call;
    self.mutex.unlock(lp.io);
    self.posted.set(lp.io);
    self.answered.waitUncancelable(lp.io);
    return call.result;
}

fn forwardText(ctx: *anyopaque, delta: []const u8) void {
    const self: *ModelCall = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    // Streaming is display only: on OOM the chunk is dropped, not the turn.
    self.text.appendSlice(self.allocator, delta) catch return;
    self.posted.set(lp.io);
}
