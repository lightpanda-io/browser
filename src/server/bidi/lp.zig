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

// Lightpanda-specific BiDi commands, called as "lp.<command>".

const std = @import("std");

const Notification = @import("../../Notification.zig");

const BiDi = @import("BiDi.zig");
const browsing_context = @import("browsing_context.zig");

pub fn processMessage(cmd: *BiDi.Command, action: []const u8) !void {
    const command = std.meta.stringToEnum(enum {
        handleUserPrompt,
    }, action) orelse return error.UnknownCommand;

    switch (command) {
        .handleUserPrompt => return handleUserPrompt(cmd),
    }
}

pub fn registerNotifications(bidi: *BiDi) !void {
    try bidi.notification.register(.javascript_dialog_opening, bidi, onJavascriptDialogOpening);
}

// The BiDi version of CDP's LP.handleJavaScriptDialog.
//
// alert(), confirm() and prompt() never block: they return as soon as they're
// called. So a standard WebDriver BiDi handleUserPrompt always comes too late and
// answers "no such alert".
//
// lp.handleUserPrompt lets a client choose the answer *before* it runs the JS
// that opens the dialog. It takes the same params as
// browsingContext.handleUserPrompt. The answer is saved on the browsing
// context, and the next dialog uses it and clears it.
//
// Without a saved answer, the dialog is dismissed: confirm returns false,
// prompt returns null.
fn handleUserPrompt(cmd: *BiDi.Command) !void {
    const p = try cmd.params(struct {
        context: []const u8,
        accept: bool = true,
        userText: ?[]const u8 = null,
    });
    const ctx = (try browsing_context.requireContext(cmd, p.context)) orelse return;

    // The dialog may open during a later command, so the text must outlive
    // this command's arena.
    const user_text: ?[]const u8 = if (p.userText) |t|
        try cmd.bidi.session_arena.allocator().dupe(u8, t)
    else
        null;

    ctx.pending_prompt_response = .{
        .accept = p.accept,
        .prompt_text = user_text,
    };
    return cmd.sendDone();
}

// Gives the saved answer, if any, to the dialog that is opening. Dialogs from
// iframes use the top-level context's answer too: it's the only context we
// report.
fn onJavascriptDialogOpening(ptr: *anyopaque, event: *const Notification.JavascriptDialogOpening) !void {
    const bidi: *BiDi = @ptrCast(@alignCast(ptr));
    const ctx = &(bidi.browsing_context orelse return);
    if (ctx.pending_prompt_response) |pending| {
        event.response.* = pending;
        ctx.pending_prompt_response = null;
    }
}

const testing = @import("testing.zig");
test "bidi.lp: handleUserPrompt" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const context_id = try ctx.createContext(.{});

    try ctx.processMessage(.{ .id = 1, .method = "lp.handleUserPrompt", .params = .{ .context = "nope" } });
    try ctx.expectSentError("no such frame", null, .{ .id = 1 });
    try ctx.processMessage(.{ .id = 2, .method = "lp.nope", .params = .{ .context = context_id } });
    try ctx.expectSentError("unknown command", null, .{ .id = 2 });

    const Case = struct {
        // null: no saved answer
        accept: ?bool,
        user_text: ?[]const u8 = null,
        expression: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .accept = null, .expression = "String(confirm('x'))", .expected = "false" },
        .{ .accept = null, .expression = "String(prompt('x', 'def'))", .expected = "null" },
        .{ .accept = true, .expression = "String(confirm('x'))", .expected = "true" },
        // the previous dialog used the answer
        .{ .accept = null, .expression = "String(confirm('x'))", .expected = "false" },
        .{ .accept = false, .expression = "String(confirm('x'))", .expected = "false" },
        .{ .accept = true, .user_text = "hello", .expression = "String(prompt('q', 'def'))", .expected = "hello" },
        .{ .accept = true, .expression = "String(prompt('q', 'def'))", .expected = "def" },
        .{ .accept = true, .expression = "String(prompt('q'))", .expected = "" },
        .{ .accept = false, .user_text = "hello", .expression = "String(prompt('q', 'def'))", .expected = "null" },
        // alert uses the answer too, so it doesn't carry over to the next dialog
        .{ .accept = true, .expression = "alert('a'), String(confirm('x'))", .expected = "false" },
    };

    var id: u64 = 3;
    for (cases) |case| {
        if (case.accept) |accept| {
            try ctx.processMessage(.{
                .id = id,
                .method = "lp.handleUserPrompt",
                .params = .{ .context = context_id, .accept = accept, .userText = case.user_text },
            });
            try ctx.expectSentResult(null, .{ .id = id });
            id += 1;
        }
        try ctx.processMessage(.{
            .id = id,
            .method = "script.evaluate",
            .params = .{ .expression = case.expression, .awaitPromise = false, .target = .{ .context = context_id } },
        });
        try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "string", .value = case.expected } }, .{ .id = id });
        id += 1;
    }
}
