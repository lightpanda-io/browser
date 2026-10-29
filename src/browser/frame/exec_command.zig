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

// document.execCommand and the queryCommand* methods.
// https://w3c.github.io/editing/docs/execCommand/
//
// A command is supported only once it does what Chrome does, events included:
// a caller that gets true skips its fallback. Every other command is
// unsupported, which the spec answers with false (or "" for the value), not an
// exception.

const std = @import("std");
const lp = @import("lightpanda");

const Frame = @import("../Frame.zig");
const Node = @import("../webapi/Node.zig");
const Element = @import("../webapi/Element.zig");
const Document = @import("../webapi/Document.zig");
const user_input = @import("user_input.zig");

const log = lp.log;

const Command = enum {
    insertText,
    delete,
    forwardDelete,

    // Command names are ASCII case-insensitive.
    fn parse(name: []const u8) ?Command {
        const info = @typeInfo(Command).@"enum";
        inline for (info.field_names, info.field_values) |field_name, field_value| {
            if (std.ascii.eqlIgnoreCase(field_name, name)) {
                return @fromBackingInt(@intCast(field_value));
            }
        }
        return null;
    }
};

pub fn exec(doc: *Document, name: []const u8, value: []const u8) !bool {
    const command = Command.parse(name) orelse {
        log.info(.not_implemented, "document.execCommand", .{ .command = name });
        return false;
    };
    const frame = doc._frame orelse return false;
    if (doc._exec_command_running) {
        return false;
    }
    doc._exec_command_running = true;
    defer doc._exec_command_running = false;

    return switch (command) {
        .insertText => insertText(frame, value),
        .delete => delete(frame, false),
        .forwardDelete => delete(frame, true),
    };
}

pub fn isSupported(doc: *const Document, name: []const u8) bool {
    return doc._frame != null and Command.parse(name) != null;
}

pub fn isEnabled(doc: *Document, name: []const u8) bool {
    if (doc._frame == null) {
        return false;
    }
    const command = Command.parse(name) orelse return false;
    return switch (command) {
        .insertText, .delete, .forwardDelete => editTarget(doc) != null,
    };
}

const EditTarget = union(enum) {
    input: *Element.Html.Input,
    textarea: *Element.Html.TextArea,
    host: *Element,
};

fn editTarget(doc: *Document) ?EditTarget {
    const active = doc._active_element;
    if (active) |el| {
        if (el.is(Element.Html.Input)) |input| {
            if (input.acceptsTextEntry() == false or user_input.acceptsEdit(el) == false) {
                return null;
            }
            return .{ .input = input };
        }
        if (el.is(Element.Html.TextArea)) |textarea| {
            if (user_input.acceptsEdit(el) == false) {
                return null;
            }
            return .{ .textarea = textarea };
        }
    }

    if (doc._selection._range) |range| {
        const node = range.asAbstractRange().getStartContainer();
        if (node.is(Element) orelse node.parentElement()) |el| {
            if (el.isEditable()) {
                if (user_input.outermostEditingHost(el)) |host| {
                    return .{ .host = host };
                }
            }
        }
    }

    const el = active orelse return null;
    if (el.isEditable() == false) {
        return null;
    }
    const host = user_input.outermostEditingHost(el) orelse return null;
    return .{ .host = host };
}

// Unlike typed text, no beforeinput or textInput: just the edit and input.
fn insertText(frame: *Frame, text: []const u8) !bool {
    const target = editTarget(frame.document) orelse return false;
    if (text.len == 0 and isCollapsed(frame.document, target)) {
        // nothing to replace and nothing to insert
        return true;
    }

    switch (target) {
        .input => |input| {
            // a single-line control turns line breaks into spaces
            const scratch = try frame.getArena(text.len, "execCommand.insertText");
            defer scratch.release();
            const line = try scratch.allocator().dupe(u8, text);
            std.mem.replaceScalar(u8, line, '\n', ' ');
            try input.rememberValueBeforeEdit(frame);
            try input.innerInsert(line, line, "insertText", frame);
        },
        .textarea => |textarea| {
            try textarea.rememberValueBeforeEdit(frame);
            var it = std.mem.splitScalar(u8, text, '\n');
            if (it.next()) |line| {
                if (line.len > 0) {
                    try textarea.innerInsert(line, line, "insertText", frame);
                }
            }
            while (it.next()) |line| {
                try textarea.innerInsert("\n", null, "insertText", frame);
                if (line.len > 0) {
                    try textarea.innerInsert(line, line, "insertText", frame);
                }
            }
        },
        .host => |host| {
            if (std.mem.indexOfScalar(u8, text, '\n') != null) {
                // Chrome splits the block at a line break, which needs an editing
                // pipeline. Safer to refuse (return false) and hope the caller
                // has a fallback when we return false.
                log.info(.not_implemented, "execCommand.insertText", .{ .line_break = true });
                return false;
            }
            if (selectionInSelect(frame.document)) {
                return false;
            }
            try user_input.insertAtSelection(frame, host, text);
        },
    }
    return true;
}

// Like typed Backspace or Delete, with no beforeinput: just the edit and input.
// At either end of the content there's nothing to delete; that still succeeds,
// with no event.
fn delete(frame: *Frame, forward: bool) !bool {
    const target = editTarget(frame.document) orelse return false;
    const input_type = if (forward) "deleteContentForward" else "deleteContentBackward";
    switch (target) {
        inline .input, .textarea => |ctl| {
            try ctl.rememberValueBeforeEdit(frame);
            try ctl.innerDelete(forward, input_type, frame);
        },
        .host => |host| {
            if (selectionInSelect(frame.document)) {
                return false;
            }
            if (try user_input.deleteAtSelection(frame, host, forward) == false) {
                // Chrome merges blocks, deletes a <br>, an image, ...
                log.info(.not_implemented, "execCommand.delete", .{ .forward = forward });
                return false;
            }
        },
    }
    return true;
}

fn selectionInSelect(doc: *Document) bool {
    const range = doc._selection._range orelse return false;
    const abstract = range.asAbstractRange();
    return inSelect(abstract.getStartContainer()) or inSelect(abstract.getEndContainer());
}

// Edits never land inside a <select>, no mater the selection.
fn inSelect(node: *Node) bool {
    var current: ?*Node = node;
    while (current) |n| : (current = n.parentNode()) {
        const el = n.is(Element) orelse continue;
        if (el.is(Element.Html.Select) != null or el.is(Element.Html.Option) != null or el.is(Element.Html.OptGroup) != null) {
            return true;
        }
    }
    return false;
}

fn isCollapsed(doc: *Document, target: EditTarget) bool {
    return switch (target) {
        inline .input, .textarea => |ctl| ctl._selection_start == ctl._selection_end,
        .host => {
            const range = doc._selection._range orelse return true;
            return range.asAbstractRange().getCollapsed();
        },
    };
}
