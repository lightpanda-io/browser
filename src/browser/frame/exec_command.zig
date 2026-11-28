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
const dump = @import("../dump.zig");
const Node = @import("../webapi/Node.zig");
const Range = @import("../webapi/Range.zig");
const AbstractRange = @import("../webapi/AbstractRange.zig");
const Element = @import("../webapi/Element.zig");
const Document = @import("../webapi/Document.zig");
const EventTarget = @import("../webapi/EventTarget.zig");
const DataTransfer = @import("../webapi/DataTransfer.zig");
const ClipboardEvent = @import("../webapi/event/ClipboardEvent.zig");
const InputEvent = @import("../webapi/event/InputEvent.zig");
const user_input = @import("user_input.zig");

const log = lp.log;

// Per-document options for other commands, set by styleWithCSS, useCSS and
// defaultParagraphSeparator.
pub const Settings = struct {
    // format with inline style rather than element, "style=font-weight: bold"
    // vs <b>..</b>
    css: bool = false,

    // the block insertParagraph makes when there's none to split
    paragraph_separator: enum { div, p } = .div,
};

const Command = enum {
    styleWithCSS,
    useCSS,
    defaultParagraphSeparator,
    insertText,
    delete,
    forwardDelete,
    selectAll,
    insertLineBreak,
    insertParagraph,
    copy,
    cut,
    bold,
    italic,
    underline,
    strikeThrough,
    // No paste: Chrome only lets extensions read the clipboard this way, a
    // page gets false. A real paste is Ctrl+V.

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

    fn format(self: Command) ?Format {
        return switch (self) {
            .bold => .bold,
            .italic => .italic,
            .underline => .underline,
            .strikeThrough => .strike_through,
            else => null,
        };
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

    const settings = &doc._exec_command_settings;
    return switch (command) {
        .styleWithCSS => {
            settings.css = !std.ascii.eqlIgnoreCase(value, "false");
            return true;
        },
        .useCSS => {
            settings.css = std.ascii.eqlIgnoreCase(value, "false");
            return true;
        },
        .defaultParagraphSeparator => {
            if (std.ascii.eqlIgnoreCase(value, "div")) {
                settings.paragraph_separator = .div;
            } else if (std.ascii.eqlIgnoreCase(value, "p")) {
                settings.paragraph_separator = .p;
            }
            // Yes, ignore any other value, but still return true.
            return true;
        },
        .insertText => insertText(frame, value),
        .delete => delete(frame, false),
        .forwardDelete => delete(frame, true),
        .selectAll => {
            try user_input.selectAll(frame);
            return true;
        },
        .insertLineBreak => insertLineBreak(frame),
        .insertParagraph => insertParagraph(frame),
        .copy => copyOrCut(frame, .copy),
        .cut => copyOrCut(frame, .cut),
        .bold, .italic, .underline, .strikeThrough => formatSelection(frame, command.format().?),
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
        .insertLineBreak, .insertParagraph => {
            const target = editTarget(doc) orelse return false;
            return switch (target) {
                .host => |host| user_input.selectionEditableIn(host, doc),
                .input, .textarea => true,
            };
        },
        inline .copy, .cut => |c| {
            const source = copySource(doc) orelse return false;
            if (isPassword(source) or source.collapsed()) {
                return false;
            }
            return c == .copy or source.editable(doc);
        },
        .bold, .italic, .underline, .strikeThrough => formatHost(doc) != null,
        .selectAll, .styleWithCSS, .useCSS, .defaultParagraphSeparator => true,
    };
}

pub fn queryState(doc: *Document, name: []const u8) bool {
    const frame = doc._frame orelse return false;
    const command = Command.parse(name) orelse return false;
    if (command.format()) |format| {
        return formatState(frame, format).all;
    }
    return switch (command) {
        .styleWithCSS => doc._exec_command_settings.css,
        else => false,
    };
}

pub fn queryIndeterm(doc: *Document, name: []const u8) bool {
    const frame = doc._frame orelse return false;
    const command = Command.parse(name) orelse return false;
    const format = command.format() orelse return false;
    const state = formatState(frame, format);
    return state.any and !state.all;
}

pub fn queryValue(doc: *Document, name: []const u8) []const u8 {
    const frame = doc._frame orelse return "";
    const command = Command.parse(name) orelse return "";
    if (command.format()) |format| {
        // Chrome's, where the spec has ""
        return if (formatState(frame, format).all) "true" else "false";
    }
    return switch (command) {
        .defaultParagraphSeparator => @tagName(doc._exec_command_settings.paragraph_separator),
        else => "",
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
            if (try user_input.deleteAtSelection(frame, host, forward, input_type) == false) {
                // Chrome merges blocks, deletes a <br>, an image, ...
                log.info(.not_implemented, "execCommand.delete", .{ .forward = forward });
                return false;
            }
        },
    }
    return true;
}

// Like Shift+Enter, with no beforeinput: just the edit and input.
fn insertLineBreak(frame: *Frame) !bool {
    const target = editTarget(frame.document) orelse return false;
    switch (target) {
        // a single-line control has nowhere to put it, yet it succeeds
        .input => {},
        .textarea => |textarea| {
            try textarea.rememberValueBeforeEdit(frame);
            try textarea.innerInsert("\n", null, "insertLineBreak", frame);
        },
        .host => |host| {
            if (selectionInSelect(frame.document)) {
                return false;
            }
            if (try user_input.insertLineBreakAtSelection(frame, host, "insertLineBreak") == false) {
                // Chrome merges blocks for a selection across them
                log.info(.not_implemented, "execCommand.insertLineBreak", .{});
                return false;
            }
        },
    }
    return true;
}

// Like Enter. No `beforeinput`, just edit the input
fn insertParagraph(frame: *Frame) !bool {
    const target = editTarget(frame.document) orelse return false;
    switch (target) {
        .input => {}, // does nothing except succeeds
        .textarea => |textarea| {
            try textarea.rememberValueBeforeEdit(frame);
            try textarea.innerInsert("\n", null, "insertParagraph", frame);
        },
        .host => |host| {
            if (selectionInSelect(frame.document)) {
                return false;
            }
            if (try user_input.insertParagraphAtSelection(frame, host) == false) {
                log.info(.not_implemented, "execCommand.insertParagraph", .{});
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

// Where copy and cut take the selected text from: the focused text control,
// else the document's selection. Chrome's selection stays put when focus moves
// to something without text, a button say.
const CopySource = union(enum) {
    input: *Element.Html.Input,
    textarea: *Element.Html.TextArea,
    range: *Range,

    fn collapsed(self: CopySource) bool {
        return switch (self) {
            inline .input, .textarea => |ctl| ctl._selection_start == ctl._selection_end,
            .range => |range| range.asAbstractRange().getCollapsed(),
        };
    }

    fn editable(self: CopySource, doc: *Document) bool {
        return switch (self) {
            inline .input, .textarea => |ctl| user_input.acceptsEdit(ctl.asElement()),
            .range => self.editingHost(doc) != null,
        };
    }

    // For a document selection, the host a cut deletes it from.
    fn editingHost(self: CopySource, doc: *Document) ?*Element {
        if (self != .range or selectionInSelect(doc)) {
            return null;
        }
        const node = self.range.asAbstractRange().getStartContainer();
        const el = node.is(Element) orelse node.parentElement() orelse return null;
        if (el.isEditable() == false) {
            return null;
        }
        const host = user_input.outermostEditingHost(el) orelse return null;
        return if (user_input.selectionEditableIn(host, doc)) host else null;
    }

    fn text(self: CopySource, frame: *Frame) ![]const u8 {
        return switch (self) {
            inline .input, .textarea => |ctl| ctl.selectedText(frame),
            .range => |range| range.toSelectionString(frame),
        };
    }

    // The copy or cut event's target: the control, else where the selection
    // starts.
    fn eventTarget(self: CopySource) ?*EventTarget {
        return switch (self) {
            inline .input, .textarea => |ctl| ctl.asElement().asEventTarget(),
            .range => |range| {
                const node = range.asAbstractRange().getStartContainer();
                const el = node.is(Element) orelse node.parentElement() orelse return null;
                return el.asEventTarget();
            },
        };
    }
};

fn copySource(doc: *Document) ?CopySource {
    if (doc._active_element) |el| {
        if (el.is(Element.Html.Input)) |input| {
            if (input.tracksSelection()) {
                return .{ .input = input };
            }
        } else if (el.is(Element.Html.TextArea)) |textarea| {
            return .{ .textarea = textarea };
        }
    }
    const range = doc._selection._range orelse return null;
    return .{ .range = range };
}

// https://w3c.github.io/clipboard-apis/#fire-a-clipboard-event
// The clipboard is the Browser's, never the system's, the one
// navigator.clipboard reads. Unlike Chrome, no user activation is needed: we
// don't track it, as for writeText.
fn copyOrCut(frame: *Frame, comptime kind: enum { copy, cut }) !bool {
    const doc = frame.document;
    if (isPassword(copySource(doc))) {
        // Chrome: no event, nothing copied, yet it succeeds
        return true;
    }

    const target: *EventTarget = blk: {
        if (copySource(doc)) |source| {
            if (source.eventTarget()) |t| {
                break :blk t;
            }
        }
        if (doc.getBody()) |body| {
            break :blk body.asEventTarget();
        }
        break :blk doc.asEventTarget();
    };

    const browser = frame._session.browser;
    const data_transfer = try DataTransfer.init(frame);
    data_transfer.acquireRef();
    defer data_transfer.releaseRef(frame.page);
    data_transfer._effect_allowed = "uninitialized";

    const event = try ClipboardEvent.initTrusted(@tagName(kind), .{
        .bubbles = true,
        .cancelable = true,
        .composed = true,
        .clipboardData = data_transfer,
    }, frame);
    const cancelled = try frame._event_manager.dispatchCancelable(target, event.asEvent());
    if (cancelled and data_transfer._items.items.len > 0) {
        // What the listeners put there: "" when they set no text/plain.
        try browser.setClipboard(try data_transfer.getData("text/plain", frame));
    }
    // A listener keeping clipboardData finds it empty and unchangeable.
    try data_transfer.clearItems(frame);
    data_transfer._mode = .protected;
    if (cancelled) {
        return true;
    }

    // A listener can move focus or the selection: take the text from wherever
    // it is now.
    const source = copySource(doc) orelse return true;
    if (isPassword(source) or source.collapsed()) {
        return true;
    }
    if (kind == .cut and source.editable(doc) == false) {
        // Chrome copies nothing either
        return true;
    }
    try browser.setClipboard(try source.text(frame));
    if (kind == .copy) {
        return true;
    }

    switch (source) {
        inline .input, .textarea => |ctl| {
            try ctl.rememberValueBeforeEdit(frame);
            try ctl.innerDelete(false, "deleteByCut", frame);
        },
        .range => {
            const host = source.editingHost(doc).?;
            if (try user_input.deleteAtSelection(frame, host, false, "deleteByCut") == false) {
                log.info(.not_implemented, "execCommand.cut", .{});
                return false;
            }
        },
    }
    return true;
}

fn isPassword(source: ?CopySource) bool {
    const s = source orelse return false;
    return s == .input and s.input._input_type == .password;
}

// Inline formatting: bold, italic, underline and strikeThrough.
// https://w3c.github.io/editing/docs/execCommand/#inline-formatting-commands
//
// A command toggles: when every selected text is already formatted it's
// removed, otherwise it's applied to all of it ("set the selection's value").
// Chrome's markup: <b>, <i>, <u>, <strike>, or with styleWithCSS a span with
// font-weight, font-style or text-decoration-line. Turning bold or italic off
// where the formatting comes from something we can't unwrap, a heading say,
// takes a font-weight (or font-style) normal span, in both modes.
//
// Whether text is formatted is read from the elements and their style
// attribute, not from stylesheets: the style manager doesn't resolve fonts.

pub const Format = enum {
    bold,
    italic,
    underline,
    strike_through,

    fn inputType(self: Format) []const u8 {
        return switch (self) {
            .bold => "formatBold",
            .italic => "formatItalic",
            .underline => "formatUnderline",
            .strike_through => "formatStrikeThrough",
        };
    }

    // font-weight and font-style are inherited, a nearer element can turn
    // them off. Text decorations add up: an ancestor's can't be undone.
    fn inherited(self: Format) bool {
        return self == .bold or self == .italic;
    }

    fn tag(self: Format) Element.Tag {
        return switch (self) {
            .bold => .b,
            .italic => .i,
            .underline => .u,
            .strike_through => .strike,
        };
    }

    fn style(self: Format, on: bool) []const u8 {
        return switch (self) {
            .bold => if (on) "font-weight: bold;" else "font-weight: normal;",
            .italic => if (on) "font-style: italic;" else "font-style: normal;",
            .underline => "text-decoration-line: underline;",
            .strike_through => "text-decoration-line: line-through;",
        };
    }

    fn decorationToken(self: Format) []const u8 {
        return if (self == .underline) "underline" else "line-through";
    }
};

/// Formatting chosen with a collapsed selection, for the text typed next
/// there. It goes as soon as the caret moves.
pub const TypingStyle = struct {
    node: ?*Node = null,
    offset: u32 = 0,
    values: std.EnumArray(Format, ?bool) = .initFill(null),
};

// The editing host formatting applies to: the selection's, in rich editable
// content. A text control can't hold formatting.
fn formatHost(doc: *Document) ?*Element {
    if (doc._active_element) |el| {
        if (el.is(Element.Html.Input) != null or el.is(Element.Html.TextArea) != null) {
            return null;
        }
    }
    const range = doc._selection._range orelse return null;
    if (selectionInSelect(doc)) {
        return null;
    }
    const node = range.asAbstractRange().getStartContainer();
    const el = node.is(Element) orelse node.parentElement() orelse return null;
    if (el.isEditable() == false) {
        return null;
    }
    const host = user_input.outermostEditingHost(el) orelse return null;
    return if (user_input.selectionEditableIn(host, doc)) host else null;
}

fn formatSelection(frame: *Frame, format: Format) !bool {
    const doc = frame.document;
    const host = formatHost(doc) orelse return false;
    const range = doc._selection._range.?.asAbstractRange();
    if (range.getCollapsed()) {
        // Nothing to format: remember it for the next typed text. No input
        // event, as in Chrome.
        const node = range.getStartContainer();
        const offset = range.getStartOffset();
        const typing = &doc._exec_command_typing_style;
        if (typingStyleAt(doc) == null) {
            typing.* = .{ .node = node, .offset = offset };
        }
        typing.values.set(format, !formatState(frame, format).all);
        return true;
    }

    const on = !formatState(frame, format).all;
    var ctx = FormatContext{
        .frame = frame,
        .host = host.asNode(),
        .format = format,
        .css = doc._exec_command_settings.css,
    };
    if (try ctx.splitSelection(range)) {
        // what clearing leaves unformatted is set again below
        for (try ctx.containedElements()) |el| {
            if (specifiedValue(el, format, frame) != null) {
                try ctx.clearValue(el);
            }
        }
        for (try ctx.topNodes()) |node| {
            try ctx.setNodeValue(node, on);
        }

        // Like Chrome, the selection is the formatted text.
        const selection = &doc._selection;
        const start, const start_offset = boundaryBefore(ctx.first);
        const end, const end_offset = boundaryAfter(ctx.last);
        try selection.collapse(start, start_offset, frame);
        try selection.extend(end, end_offset, frame);
    }

    const event = try InputEvent.initTrusted(comptime .wrap("input"), .{
        .bubbles = true,
        .composed = true,
        .data = null,
        .inputType = format.inputType(),
    }, frame);
    try frame._event_manager.dispatch(host.asEventTarget(), event.asEvent());
    return true;
}

const State = struct {
    // every selected text is formatted (and there's at least one)
    all: bool = false,
    // some is
    any: bool = false,
};

// The state of `format` for the selection, by queryCommandState and
// queryCommandIndeterm. Like Chrome on Linux and Windows, and the spec: true
// when all the text is formatted, indeterminate when only some is. (Chrome on
// macOS looks at the start of the selection, and is never indeterminate.)
fn formatState(frame: *Frame, format: Format) State {
    const doc = frame.document;
    const host = formatHost(doc) orelse return .{};
    const range = doc._selection._range.?.asAbstractRange();
    if (range.getCollapsed()) {
        if (typingStyleAt(doc)) |typing| {
            if (typing.values.get(format)) |value| {
                return .{ .all = value, .any = false };
            }
        }
        const node = caretNode(range.getStartContainer(), range.getStartOffset());
        return .{ .all = effectiveValue(node, format, frame), .any = false };
    }

    const host_node = host.asNode();
    const first, const last = boundaryLeaves(
        host_node,
        range.getStartContainer(),
        range.getStartOffset(),
        range.getEndContainer(),
        range.getEndOffset(),
    ) orelse return .{};
    var state = State{ .all = true };
    var count: usize = 0;
    var node = first;
    while (true) {
        if (isFormattableText(frame, host_node, node)) {
            count += 1;
            if (effectiveValue(node, format, frame)) {
                state.any = true;
            } else {
                state.all = false;
            }
        }
        if (node == last) {
            break;
        }
        node = nextNode(node, host_node) orelse break;
    }
    if (count == 0) {
        state.all = false;
    }
    return state;
}

// The node whose formatting text typed at a caret takes: the text node it
// joins, as insertAtSelection picks it, else the container.
fn caretNode(container: *Node, offset: u32) *Node {
    if (container.is(Node.CData) != null) {
        return container;
    }
    if (offset > 0) {
        if (container.getChildAt(offset - 1)) |before| {
            if (before.is(Node.CData.Text) != null) {
                return before;
            }
        }
    }
    if (container.getChildAt(offset)) |after| {
        if (after.is(Node.CData.Text) != null) {
            return after;
        }
    }
    return container;
}

// The typing style, when the caret is still where it was chosen.
fn typingStyleAt(doc: *Document) ?*TypingStyle {
    const typing = &doc._exec_command_typing_style;
    const node = typing.node orelse return null;
    const range = doc._selection._range orelse return null;
    const abstract = range.asAbstractRange();
    if (!abstract.getCollapsed() or abstract.getStartContainer() != node or abstract.getStartOffset() != typing.offset) {
        return null;
    }
    return typing;
}

/// For text about to be typed: the formatting chosen at the caret with a
/// collapsed selection, if it's still there. Either way it's used up.
pub fn takeTypingStyle(doc: *Document) ?std.EnumArray(Format, ?bool) {
    const typing = typingStyleAt(doc);
    defer doc._exec_command_typing_style = .{};
    return if (typing) |t| t.values else null;
}

/// Formats the text just typed, `text` from `start` to `end`, with the typing
/// style. Returns where the caret goes: at the end of that text, now a node
/// of its own.
pub fn applyTypingStyle(frame: *Frame, host: *Element, text: *Node.CData.Text, start: u32, end: u32, values: std.EnumArray(Format, ?bool)) !struct { *Node, u32 } {
    var typed = text;
    if (end < typed.asCData().getLength()) {
        _ = try typed.splitText(end, frame);
    }
    if (start > 0) {
        typed = try typed.splitText(start, frame);
    }
    const node = typed.asCData().asNode();
    var ctx = FormatContext{
        .frame = frame,
        .host = host.asNode(),
        .format = .bold,
        .css = frame.document._exec_command_settings.css,
    };
    // in order: bold then italic is <b><i>X</i></b>, as in Chrome
    for (std.enums.values(Format)) |format| {
        const value = values.get(format) orelse continue;
        ctx.format = format;
        try ctx.setNodeValue(node, value);
    }
    return .{ node, end - start };
}

const FormatContext = struct {
    frame: *Frame,
    host: *Node,
    format: Format,
    css: bool,
    // the selection's first and last leaves, once text nodes at its ends are split
    first: *Node = undefined,
    last: *Node = undefined,
    // every leaf from first to last
    leaves: std.AutoHashMapUnmanaged(*Node, void) = .empty,

    // Splits text nodes the selection starts or ends in, so the selected
    // text has nodes of its own. False when nothing is selected.
    fn splitSelection(self: *FormatContext, range: *const AbstractRange) !bool {
        const frame = self.frame;
        var start = range.getStartContainer();
        var start_offset = range.getStartOffset();
        var end = range.getEndContainer();
        var end_offset = range.getEndOffset();
        // the end first: the start's offset still holds after
        if (end.is(Node.CData.Text)) |t| {
            if (end_offset > 0 and end_offset < t.asCData().getLength()) {
                _ = try t.splitText(end_offset, frame);
            }
        }
        if (start.is(Node.CData.Text)) |t| {
            if (start_offset > 0 and start_offset < t.asCData().getLength()) {
                const rest = (try t.splitText(start_offset, frame)).asCData().asNode();
                if (end == start) {
                    end = rest;
                    end_offset -= start_offset;
                }
                start = rest;
                start_offset = 0;
            }
        }
        self.first, self.last = boundaryLeaves(self.host, start, start_offset, end, end_offset) orelse return false;
        var node = self.first;
        while (true) {
            if (isLeaf(node)) {
                try self.leaves.put(frame.call_arena, node, {});
            }
            if (node == self.last) {
                break;
            }
            node = nextNode(node, self.host) orelse break;
        }
        return true;
    }

    // Whether all of `node` is selected: a leaf in the selection, or an
    // element with its leaves in it.
    fn contained(self: *const FormatContext, node: *Node) bool {
        if (isLeaf(node)) {
            return self.leaves.contains(node);
        }
        const first = firstLeafIn(node) orelse return false;
        const last = lastLeafIn(node) orelse return false;
        return self.leaves.contains(first) and self.leaves.contains(last);
    }

    // The selected nodes whose parent isn't selected, in tree order.
    fn topNodes(self: *const FormatContext) ![]const *Node {
        var list: std.ArrayList(*Node) = .empty;
        try self.collectTop(self.host, &list);
        return list.items;
    }

    fn collectTop(self: *const FormatContext, parent: *Node, list: *std.ArrayList(*Node)) !void {
        var child = parent.firstChild();
        while (child) |c| : (child = c.nextSibling()) {
            if (self.contained(c)) {
                try list.append(self.frame.call_arena, c);
            } else if (c.is(Element) != null and (c.contains(self.first) or c.contains(self.last))) {
                try self.collectTop(c, list);
            }
        }
    }

    // Every editable element the selection contains, in tree order.
    fn containedElements(self: *const FormatContext) ![]const *Element {
        var list: std.ArrayList(*Element) = .empty;
        for (try self.topNodes()) |node| {
            try self.collectEditable(node, &list);
        }
        return list.items;
    }

    fn collectEditable(self: *const FormatContext, node: *Node, list: *std.ArrayList(*Element)) !void {
        const el = node.is(Element) orelse return;
        if (el.isEditable() == false) {
            return;
        }
        try list.append(self.frame.call_arena, el);
        var child = node.firstChild();
        while (child) |c| : (child = c.nextSibling()) {
            try self.collectEditable(c, list);
        }
    }

    // https://w3c.github.io/editing/docs/execCommand/#set-the-selection's-value
    // ("set the node's value"): formats `node`, or the parts of it that can
    // be, as `on` says.
    fn setNodeValue(self: *FormatContext, node: *Node, on: bool) !void {
        if (node.is(Element)) |el| {
            if (el.isEditable() == false) {
                return;
            }
            if (!isInline(self.frame, el)) {
                // a block can't go in a <b>: its content does
                for (try children(self.frame, node)) |child| {
                    try self.setNodeValue(child, on);
                }
                return;
            }
        } else if (!isFormattableText(self.frame, self.host, node)) {
            return;
        }
        try self.pushDownValues(node, on);
        try self.forceValue(node, on);
    }

    // https://w3c.github.io/editing/docs/execCommand/#push-down-values
    // An inline ancestor formatting `node` the other way is cleared, and the
    // rest of its content wrapped to keep that formatting.
    fn pushDownValues(self: *FormatContext, node: *Node, on: bool) !void {
        const frame = self.frame;
        var ancestors: std.ArrayList(*Element) = .empty;
        var current = node.parentNode();
        while (current) |n| : (current = n.parentNode()) {
            const el = n.is(Element) orelse break;
            if (n == self.host or el.isEditable() == false or !isInline(self.frame, el)) {
                break;
            }
            try ancestors.append(frame.call_arena, el);
        }

        var top: ?usize = null;
        for (ancestors.items, 0..) |el, i| {
            const value = specifiedValue(el, self.format, frame) orelse continue;
            if (value != on) {
                top = i;
            }
        }
        var i = (top orelse return) + 1;
        var propagated: ?bool = null;
        while (i > 0) {
            i -= 1;
            const ancestor = ancestors.items[i];
            const on_path = if (i == 0) node else ancestors.items[i - 1].asNode();
            const content = try children(frame, ancestor.asNode());
            if (specifiedValue(ancestor, self.format, frame)) |value| {
                propagated = value;
                try self.clearValue(ancestor);
            }
            const value = propagated orelse continue;
            for (content) |child| {
                if (child != on_path) {
                    try self.forceValue(child, value);
                }
            }
        }
    }

    // https://w3c.github.io/editing/docs/execCommand/#force-the-value
    fn forceValue(self: *FormatContext, node: *Node, on: bool) !void {
        if (node.is(Element)) |el| {
            if (!isInline(self.frame, el)) {
                for (try children(self.frame, node)) |child| {
                    try self.forceValue(child, on);
                }
                return;
            }
        } else if (node.is(Node.CData.Text)) |text| {
            if (text.asCData().getLength() == 0) {
                return;
            }
        } else {
            return;
        }
        if (effectiveValue(node, self.format, self.frame) == on) {
            return;
        }
        if (!on and !self.format.inherited()) {
            // nothing turns an ancestor's text decoration off
            return;
        }
        try self.wrap(node, on);
    }

    // Wraps `node` in an element that formats it, or moves it into a sibling
    // that's one, as Chrome does: "<b>a</b>b" with b bold is "<b>ab</b>".
    fn wrap(self: *FormatContext, node: *Node, on: bool) !void {
        const frame = self.frame;
        if (node.previousSibling()) |prev| {
            if (self.isWrapper(prev, on)) {
                _ = try prev.appendChild(node, frame);
                if (prev.nextSibling()) |next| {
                    if (self.isWrapper(next, on)) {
                        try moveChildren(frame, next, prev, null);
                        _ = try next.parentNode().?.removeChild(next, frame);
                    }
                }
                return;
            }
        }
        if (node.nextSibling()) |next| {
            if (self.isWrapper(next, on)) {
                _ = try next.insertBefore(node, next.firstChild(), frame);
                return;
            }
        }
        const wrapper = if (on and !self.css)
            try frame.document.createElement(@tagName(self.format.tag()), null, frame)
        else blk: {
            const span = try frame.document.createElement("span", null, frame);
            try span.setAttributeSafe(comptime .wrap("style"), .wrap(self.format.style(on)), frame);
            break :blk span;
        };
        const parent = node.parentNode().?;
        _ = try parent.insertBefore(wrapper.asNode(), node, frame);
        _ = try wrapper.asNode().appendChild(node, frame);
    }

    // Whether `node` is an element wrap would create: <b> without attributes,
    // a span with the one style declaration.
    fn isWrapper(self: *const FormatContext, node: *Node, on: bool) bool {
        const el = node.is(Element) orelse return false;
        if (el._type != .html) {
            return false;
        }
        if (on and !self.css) {
            return el.getTag() == self.format.tag() and !el.hasAttributes();
        }
        if (el.getTag() != .span or el.attributeEntries().len != 1) {
            return false;
        }
        const style = el.inlineStyle(self.frame) orelse return false;
        if (style.asCSSStyleDeclaration().length() != 1) {
            return false;
        }
        return specifiedValue(el, self.format, self.frame) == on;
    }

    // https://w3c.github.io/editing/docs/execCommand/#clear-the-value
    // Removes the formatting `el` itself gives: unwraps a plain <b>, drops
    // the declaration from a style attribute, makes a <b> with other
    // attributes a <span>.
    fn clearValue(self: *FormatContext, el: *Element) !void {
        const frame = self.frame;
        if (isSimpleModifiable(el, frame)) {
            return unwrap(frame, el.asNode());
        }
        try removeStyleValue(el, self.format, frame);
        if (el.getTag() == .span and !el.hasAttributes()) {
            return unwrap(frame, el.asNode());
        }
        if (formatTag(el, self.format)) {
            const span = try frame.document.createElement("span", null, frame);
            for (el.attributeEntries()) |*entry| {
                try span.setAttributeSafe(.wrap(entry.name()), .wrap(entry.value()), frame);
            }
            const node = el.asNode();
            const parent = node.parentNode().?;
            _ = try parent.insertBefore(span.asNode(), node, frame);
            try moveChildren(frame, node, span.asNode(), null);
            _ = try parent.removeChild(node, frame);
        }
    }
};

// https://w3c.github.io/editing/docs/execCommand/#specified-command-value
// The formatting `el` gives, by itself: its style attribute, else its tag.
// Null when it doesn't say.
fn specifiedValue(el: *Element, format: Format, frame: *Frame) ?bool {
    if (el._type != .html) {
        return null;
    }
    if (styleValue(el, format, frame)) |value| {
        return value;
    }
    return if (formatTag(el, format)) true else null;
}

// The tags formatting commands make and remove.
fn formatTag(el: *Element, format: Format) bool {
    return switch (format) {
        .bold => el.getTag() == .b or el.getTag() == .strong,
        .italic => el.getTag() == .i or el.getTag() == .em,
        .underline => el.getTag() == .u,
        .strike_through => el.getTag() == .s or el.getTag() == .strike,
    };
}

// Formatting from the user agent's stylesheet, which no command removes.
fn defaultValue(el: *Element, format: Format) bool {
    if (el._type != .html) {
        return false;
    }
    return switch (format) {
        .bold => switch (el.getTag()) {
            .h1, .h2, .h3, .h4, .h5, .h6, .th => true,
            else => false,
        },
        .italic => switch (el.getTag()) {
            .cite, .dfn, .@"var", .address => true,
            else => false,
        },
        .underline => el.getTag() == .ins,
        .strike_through => el.getTag() == .del,
    };
}

fn styleValue(el: *Element, format: Format, frame: *Frame) ?bool {
    const style = el.inlineStyle(frame) orelse return null;
    const decl = style.asCSSStyleDeclaration();
    switch (format) {
        .bold => {
            const value = std.mem.trim(u8, decl.getPropertyValue("font-weight", frame), " ");
            if (value.len == 0) {
                return null;
            }
            if (std.ascii.eqlIgnoreCase(value, "bold") or std.ascii.eqlIgnoreCase(value, "bolder")) {
                return true;
            }
            const weight = std.fmt.parseFloat(f64, value) catch return false;
            return weight >= 600;
        },
        .italic => {
            const value = std.mem.trim(u8, decl.getPropertyValue("font-style", frame), " ");
            if (value.len == 0) {
                return null;
            }
            return std.ascii.startsWithIgnoreCase(value, "italic") or std.ascii.startsWithIgnoreCase(value, "oblique");
        },
        .underline, .strike_through => {
            for ([_][]const u8{ "text-decoration-line", "text-decoration" }) |property| {
                if (hasToken(decl.getPropertyValue(property, frame), format.decorationToken())) {
                    return true;
                }
            }
            return null;
        },
    }
}

fn hasToken(value: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t\n");
    while (it.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, token)) {
            return true;
        }
    }
    return false;
}

// Drops the declaration of `format` from `el`'s style attribute, and the
// attribute when that leaves it empty.
fn removeStyleValue(el: *Element, format: Format, frame: *Frame) !void {
    const style = el.inlineStyle(frame) orelse return;
    const decl = style.asCSSStyleDeclaration();
    switch (format) {
        .bold => _ = try decl.removeProperty("font-weight", frame),
        .italic => _ = try decl.removeProperty("font-style", frame),
        .underline, .strike_through => for ([_][]const u8{ "text-decoration-line", "text-decoration" }) |property| {
            const value = decl.getPropertyValue(property, frame);
            if (!hasToken(value, format.decorationToken())) {
                continue;
            }
            var rest: std.ArrayList(u8) = .empty;
            var it = std.mem.tokenizeAny(u8, value, " \t\n");
            while (it.next()) |word| {
                if (std.ascii.eqlIgnoreCase(word, format.decorationToken())) {
                    continue;
                }
                if (rest.items.len > 0) {
                    try rest.append(frame.call_arena, ' ');
                }
                try rest.appendSlice(frame.call_arena, word);
            }
            if (rest.items.len == 0) {
                _ = try decl.removeProperty(property, frame);
            } else {
                try decl.setProperty(property, rest.items, null, frame);
            }
        },
    }
    if (decl.length() == 0 and el.hasAttributeSafe(comptime .wrap("style"))) {
        try el.removeAttribute(comptime .wrap("style"), frame);
    }
}

// https://w3c.github.io/editing/docs/execCommand/#effective-command-value
fn effectiveValue(node: *Node, format: Format, frame: *Frame) bool {
    var current: ?*Element = node.is(Element) orelse node.parentElement();
    while (current) |el| : (current = el.asNode().parentElement()) {
        const value = specifiedValue(el, format, frame) orelse (if (defaultValue(el, format)) true else continue);
        if (format.inherited() or value) {
            return value;
        }
    }
    return false;
}

// https://w3c.github.io/editing/docs/execCommand/#simple-modifiable-element
// A formatting element that's only there for its formatting: without
// attributes, or with a style attribute of one declaration that fits it.
fn isSimpleModifiable(el: *Element, frame: *Frame) bool {
    if (el._type != .html) {
        return false;
    }
    const tag = el.getTag();
    switch (tag) {
        .a, .b, .em, .font, .i, .s, .span, .strike, .strong, .sub, .sup, .u => {},
        else => return false,
    }
    if (!el.hasAttributes()) {
        return true;
    }
    if (el.attributeEntries().len != 1 or !el.hasAttributeSafe(comptime .wrap("style"))) {
        return false;
    }
    const style = el.inlineStyle(frame) orelse return true;
    const decl = style.asCSSStyleDeclaration();
    if (decl.length() == 0) {
        return true;
    }
    if (decl.length() != 1) {
        return false;
    }
    const property = decl.item(0, frame);
    const decoration = std.mem.eql(u8, property, "text-decoration") or std.mem.eql(u8, property, "text-decoration-line");
    return switch (tag) {
        .b, .strong => std.mem.eql(u8, property, "font-weight"),
        .i, .em => std.mem.eql(u8, property, "font-style"),
        .a, .font, .span => true,
        .s, .strike, .u => decoration,
        else => false,
    };
}

// Text a formatting command formats, and whose formatting decides its state.
fn isFormattableText(frame: *Frame, host: *Node, node: *Node) bool {
    const text = node.is(Node.CData.Text) orelse return false;
    if (text.asCData().getLength() == 0 or !editableText(node)) {
        return false;
    }
    const data = text.asCData().getData().str();
    if (std.mem.trim(u8, data, " \t\n\r\x0c").len != 0) {
        return true;
    }
    // Whitespace between blocks, which doesn't show: Chrome leaves it be.
    const parent = node.parentElement() orelse return false;
    if (node.parentNode() != host and isInline(frame, parent)) {
        return true;
    }
    for ([_]?*Node{ node.previousSibling(), node.nextSibling() }) |sibling| {
        const s = sibling orelse return false;
        if (s.is(Element)) |el| {
            if (!isInline(frame, el)) {
                return false;
            }
        }
    }
    return true;
}

// An element <b> can hold: an inline one. A block, a table cell, ... has its
// content formatted instead.
fn isInline(frame: *Frame, el: *Element) bool {
    const style_manager = &frame._style_manager;
    return !style_manager.hasDisplayNone(el) and style_manager.isInlineLevel(el);
}

fn editableText(node: *Node) bool {
    const parent = node.parentElement() orelse return false;
    return parent.isEditable();
}

// What a selection covers is a run of leaves in tree order: text nodes and
// void elements (<br>, <img>).
fn isLeaf(node: *Node) bool {
    if (node.is(Node.CData.Text) != null) {
        return true;
    }
    const el = node.is(Element) orelse return false;
    return dump.isVoidElement(el);
}

// The first and last leaf from (start, start_offset) to (end, end_offset),
// within `root`. Null when there's none. A text node the selection only
// touches the edge of isn't in it.
fn boundaryLeaves(root: *Node, start: *Node, start_offset: u32, end: *Node, end_offset: u32) ?struct { *Node, *Node } {
    var first: ?*Node = blk: {
        if (start.is(Node.CData)) |cdata| {
            if (start.is(Node.CData.Text) != null and start_offset < cdata.getLength()) {
                break :blk start;
            }
            break :blk nextSkippingChildren(start, root);
        }
        break :blk start.getChildAt(start_offset) orelse nextSkippingChildren(start, root);
    };
    while (first) |n| {
        if (isLeaf(n)) break;
        first = nextNode(n, root);
    }

    var last: ?*Node = blk: {
        if (end.is(Node.CData) != null) {
            if (end.is(Node.CData.Text) != null and end_offset > 0) {
                break :blk end;
            }
            break :blk previousNode(end, root);
        }
        if (end_offset > 0) {
            if (end.getChildAt(end_offset - 1)) |child| {
                break :blk lastDescendant(child);
            }
        }
        break :blk previousNode(end, root);
    };
    while (last) |n| {
        if (isLeaf(n)) break;
        last = previousNode(n, root);
    }

    const f = first orelse return null;
    const l = last orelse return null;
    if (f != l and f.compareDocumentPosition(l) & 0x04 == 0) {
        // the last is before the first: nothing in between
        return null;
    }
    return .{ f, l };
}

fn nextNode(node: *Node, root: *Node) ?*Node {
    if (node.firstChild()) |child| {
        return child;
    }
    return nextSkippingChildren(node, root);
}

fn nextSkippingChildren(node: *Node, root: *Node) ?*Node {
    var current = node;
    while (current != root) {
        if (current.nextSibling()) |next| {
            return next;
        }
        current = current.parentNode() orelse return null;
    }
    return null;
}

fn previousNode(node: *Node, root: *Node) ?*Node {
    if (node == root) {
        return null;
    }
    if (node.previousSibling()) |prev| {
        return lastDescendant(prev);
    }
    const parent = node.parentNode() orelse return null;
    return if (parent == root) null else parent;
}

fn lastDescendant(node: *Node) *Node {
    var current = node;
    while (current.lastChild()) |child| {
        current = child;
    }
    return current;
}

fn firstLeafIn(root: *Node) ?*Node {
    var current = root.firstChild();
    while (current) |n| : (current = nextNode(n, root)) {
        if (isLeaf(n)) {
            return n;
        }
    }
    return null;
}

fn lastLeafIn(root: *Node) ?*Node {
    var current: ?*Node = if (root.lastChild()) |c| lastDescendant(c) else null;
    while (current) |n| : (current = previousNode(n, root)) {
        if (isLeaf(n)) {
            return n;
        }
    }
    return null;
}

fn boundaryBefore(leaf: *Node) struct { *Node, u32 } {
    if (leaf.is(Node.CData.Text) != null) {
        return .{ leaf, 0 };
    }
    const parent = leaf.parentNode().?;
    return .{ parent, parent.getChildIndex(leaf).? };
}

fn boundaryAfter(leaf: *Node) struct { *Node, u32 } {
    if (leaf.is(Node.CData.Text)) |text| {
        return .{ leaf, @intCast(text.asCData().getLength()) };
    }
    const parent = leaf.parentNode().?;
    return .{ parent, parent.getChildIndex(leaf).? + 1 };
}

// `node`'s children, as they are now: what's done with them can move them.
fn children(frame: *Frame, node: *Node) ![]const *Node {
    var list: std.ArrayList(*Node) = .empty;
    var child = node.firstChild();
    while (child) |c| : (child = c.nextSibling()) {
        try list.append(frame.call_arena, c);
    }
    return list.items;
}

fn moveChildren(frame: *Frame, from: *Node, to: *Node, before: ?*Node) !void {
    while (from.firstChild()) |child| {
        _ = try to.insertBefore(child, before, frame);
    }
}

// Replaces `node` with its children.
fn unwrap(frame: *Frame, node: *Node) !void {
    const parent = node.parentNode() orelse return;
    try moveChildren(frame, node, parent, node);
    _ = try parent.removeChild(node, frame);
}

const testing = @import("../../testing.zig");
test "WebApi: execCommand copy and cut" {
    const browser = testing.test_session.browser;
    defer {
        browser.clearPermissions();
        browser.allocator.free(browser.clipboard);
        browser.clipboard = "";
    }
    // to read back what was copied
    try browser.setPermission("clipboard-read", .granted);
    try testing.htmlRunner("clipboard_exec_command.html", .{});
}
