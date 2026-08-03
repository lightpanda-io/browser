// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const Frame = @import("Frame.zig");
const interactive = @import("interactive.zig");
const Node = @import("webapi/Node.zig");
const Slot = @import("webapi/element/html/Slot.zig");
const IFrame = @import("webapi/element/html/IFrame.zig");
const Anchor = @import("webapi/element/html/Anchor.zig");
const Button = @import("webapi/element/html/Button.zig");
const Input = @import("webapi/element/html/Input.zig");

pub const DumpError = error{ WriteFailed, OutOfMemory, TargetLimit };

pub const Opts = struct {
    with_base: bool = false,
    with_frames: bool = false,
    strip: Opts.Strip = .{},
    shadow: Opts.Shadow = .rendered,
    // A render-only target table. The serializer writes opaque numeric markers
    // without changing the source document.
    live_targets: ?*LiveTargets = null,
    strip_refresh: bool = false,

    pub const Strip = packed struct(u4) {
        js: bool = false,
        ui: bool = false,
        css: bool = false,
        invisible: bool = false,
    };

    pub const Shadow = enum {
        // Skip shadow DOM entirely (innerHTML/outerHTML)
        skip,

        // Dump everything (like "view source")
        complete,

        // Resolve slot elements (like what actually gets rendered)
        rendered,
    };
};

pub const LiveTargets = struct {
    pub const max_elements = 65_535;

    elements: *std.ArrayListUnmanaged(*Node.Element),
    allocator: std.mem.Allocator,
    listener_targets: interactive.ListenerTargetMap = .{},

    fn add(self: *LiveTargets, element: *Node.Element) !usize {
        if (self.elements.items.len >= max_elements) return error.TargetLimit;
        try self.elements.append(self.allocator, element);
        return self.elements.items.len - 1;
    }
};

pub fn root(doc: *Node.Document, opts: Opts, writer: *std.Io.Writer, frame: *Frame) DumpError!void {
    if (doc.is(Node.Document.HTMLDocument) != null) {
        blk: {
            // Ideally we just render the doctype which is part of the document
            if (doc.asNode().firstChild()) |first| {
                if (first._type == .document_type) {
                    break :blk;
                }
            }
            // But if the doc has no child, or the first child isn't a doctype
            // well force it.
            try writer.writeAll("<!DOCTYPE html>");
        }
    }

    return deep(doc.asNode(), opts, writer, frame);
}

pub fn deep(node: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) DumpError!void {
    return _deep(node, opts, false, writer, frame);
}

fn _deep(node: *Node, opts: Opts, comptime force_slot: bool, writer: *std.Io.Writer, frame: *Frame) DumpError!void {
    switch (node._type) {
        .cdata => |cd| {
            if (node.is(Node.CData.Comment)) |_| {
                try writer.writeAll("<!--");
                try writer.writeAll(cd.getData().str());
                try writer.writeAll("-->");
            } else if (node.is(Node.CData.ProcessingInstruction)) |pi| {
                try writer.writeAll("<?");
                try writer.writeAll(pi._target);
                try writer.writeAll(" ");
                try writer.writeAll(cd.getData().str());
                try writer.writeAll("?>");
            } else {
                if (shouldEscapeText(node._parent)) {
                    try writeEscapedText(cd.getData().str(), writer);
                } else {
                    try writer.writeAll(cd.getData().str());
                }
            }
        },
        .element => |el| {
            if (shouldStripElement(el, opts, frame)) {
                return;
            }

            // When opts.shadow == .rendered, we normally skip any element with
            // a slot attribute. Only the "active" element will get rendered into
            // the <slot name="X">. However, the `deep` function is itself used
            // to render that "active" content, so when we're trying to render
            // it, we don't want to skip it.
            if ((comptime force_slot == false) and opts.shadow == .rendered) {
                if (el.getAttributeSafe(comptime .wrap("slot"))) |_| {
                    // Skip - will be rendered by the Slot if it's the active container
                    return;
                }
            }

            try formatElement(el, opts, writer, frame);

            if (opts.with_base and isDocumentHead(el, frame)) {
                try writeBase(frame, writer);
            } else if (opts.with_base and isDocumentElementWithoutHead(el, frame)) {
                try writer.writeAll("<head>");
                try writeBase(frame, writer);
                try writer.writeAll("</head>");
            }

            if (opts.shadow == .rendered) {
                if (el.is(Slot)) |slot| {
                    try dumpSlotContent(slot, opts, writer, frame);
                    return writer.writeAll("</slot>");
                }
            }
            if (opts.shadow != .skip) {
                if (frame._element_shadow_roots.get(el)) |shadow| {
                    try children(shadow.asNode(), opts, writer, frame);
                    // In rendered mode, light DOM is only shown through slots, not directly
                    if (opts.shadow == .rendered) {
                        // Skip rendering light DOM children
                        if (!isVoidElement(el)) {
                            try writer.writeAll("</");
                            try writer.writeAll(el.getTagNameDump());
                            try writer.writeByte('>');
                        }
                        return;
                    }
                }
            }

            if (opts.with_frames and el.is(IFrame) != null) {
                const iframe = el.as(IFrame);
                if (iframe.getContentDocument()) |doc| {
                    // A frame's document should always ahave a frame, but
                    // I'm not willing to crash a release build on that assertion.
                    if (comptime lp.IS_DEBUG) {
                        std.debug.assert(doc._frame != null);
                    }
                    if (doc._frame) |f| {
                        try writer.writeByte('\n');
                        root(doc, opts, writer, f) catch return error.WriteFailed;
                        try writer.writeByte('\n');
                    }
                }
            } else {
                try children(node, opts, writer, frame);
            }

            if (!isVoidElement(el)) {
                try writer.writeAll("</");
                try writer.writeAll(el.getTagNameDump());
                try writer.writeByte('>');
            }
        },
        .document => try children(node, opts, writer, frame),
        .document_type => |dt| {
            try writer.writeAll("<!DOCTYPE ");
            try writer.writeAll(dt.getName());

            const public_id = dt.getPublicId();
            const system_id = dt.getSystemId();
            if (public_id.len != 0 and system_id.len != 0) {
                try writer.writeAll(" PUBLIC \"");
                try writeEscapedText(public_id, writer);
                try writer.writeAll("\" \"");
                try writeEscapedText(system_id, writer);
                try writer.writeByte('"');
            } else if (public_id.len != 0) {
                try writer.writeAll(" PUBLIC \"");
                try writeEscapedText(public_id, writer);
                try writer.writeByte('"');
            } else if (system_id.len != 0) {
                try writer.writeAll(" SYSTEM \"");
                try writeEscapedText(system_id, writer);
                try writer.writeByte('"');
            }
            try writer.writeAll(">\n");
        },
        .document_fragment => try children(node, opts, writer, frame),
        .attribute => {
            // Not called normally, but can be called via XMLSerializer.serializeToString
            // in which case it should return an empty string
            try writer.writeAll("");
        },
    }
}

pub fn children(parent: *Node, opts: Opts, writer: *std.Io.Writer, frame: *Frame) DumpError!void {
    var it = parent.childrenIterator();
    while (it.next()) |child| {
        try deep(child, opts, writer, frame);
    }
}

pub fn isLiveTarget(
    el: *Node.Element,
    frame: *Frame,
    listener_targets: interactive.ListenerTargetMap,
) error{OutOfMemory}!bool {
    const legacy_target = switch (el.getTag()) {
        .anchor => if (el.is(Anchor)) |anchor|
            isLiveAnchor(el, anchor)
        else
            false,
        .button => if (el.is(Button)) |button|
            !el.isDisabled() and button.getForm(frame) == null
        else
            false,
        .input => liveCheckable(el) != null and !el.isDisabled(),
        else => false,
    };
    if (legacy_target) return true;
    return isLiveScriptTarget(el, frame, listener_targets);
}

fn isLiveScriptTarget(
    el: *Node.Element,
    frame: *Frame,
    listener_targets: interactive.ListenerTargetMap,
) error{OutOfMemory}!bool {
    const has_click = interactive.hasListenerType(el.asEventTarget(), listener_targets, "click") or
        try hasInlineClickHandler(el, frame);
    return has_click and
        !el.isDisabled() and
        !hasUnsafeDefaultAction(el, frame) and
        interactive.isVisibleForInteraction(el, frame) and
        !el.hasPointerEventsNone(null, frame);
}

fn hasInlineClickHandler(el: *Node.Element, frame: *Frame) error{OutOfMemory}!bool {
    const html_el = el.is(Node.Element.Html) orelse return false;
    const handler = html_el.getAttributeFunction(.onclick, frame) catch |err| switch (err) {
        error.CompilationError => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return handler != null;
}

fn hasUnsafeDefaultAction(el: *Node.Element, frame: *Frame) bool {
    const activation_node = Frame.user_input.findClickActivationTarget(el.asNode(), true) orelse return false;
    const activation_el = activation_node.is(Node.Element) orelse return false;
    return hasUnsafeActivationTarget(activation_el, frame);
}

fn hasUnsafeActivationTarget(el: *Node.Element, frame: *Frame) bool {
    return switch (el.getTag()) {
        .anchor => if (el.is(Anchor)) |anchor|
            !isLiveAnchor(el, anchor)
        else
            false,
        .button => if (el.is(Button)) |button|
            std.mem.eql(u8, button.getType(), "submit") and button.getForm(frame) != null
        else
            false,
        .input => if (el.is(Input)) |input|
            switch (input._input_type) {
                .submit, .image => input.getForm(frame) != null,
                .file => true,
                else => false,
            }
        else
            false,
        .label => if (el.is(Node.Element.Html.Label)) |label|
            if (label.getControl(frame)) |control|
                hasUnsafeActivationTarget(control, frame)
            else
                false
        else
            false,
        else => false,
    };
}

fn liveCheckable(el: *Node.Element) ?*Input {
    const input = el.is(Input) orelse return null;
    return switch (input._input_type) {
        .checkbox, .radio => input,
        else => null,
    };
}

fn isLiveAnchor(el: *Node.Element, anchor: *Anchor) bool {
    const href = el.getAttributeSafe(comptime .wrap("href")) orelse return false;
    if (href.len == 0 or el.hasAttributeSafe(comptime .wrap("download"))) return false;

    const target = anchor.getTarget();
    return target.len == 0 or
        std.ascii.eqlIgnoreCase(target, "_self") or
        std.ascii.eqlIgnoreCase(target, "_parent") or
        std.ascii.eqlIgnoreCase(target, "_top");
}

fn formatElement(el: *Node.Element, opts: Opts, writer: *std.Io.Writer, frame: *Frame) DumpError!void {
    try writer.writeByte('<');
    try writer.writeAll(el.getTagNameDump());

    const live_checkable = if (opts.live_targets != null) liveCheckable(el) else null;
    for (el.attributeEntries()) |*attr| {
        if (opts.live_targets != null and std.ascii.eqlIgnoreCase(attr.name(), "data-lp-live-target")) {
            continue;
        }
        if (live_checkable != null and std.ascii.eqlIgnoreCase(attr.name(), "checked")) {
            continue;
        }
        try writer.writeByte(' ');
        try attr.format(writer);
    }
    if (live_checkable) |input| {
        if (input.getChecked()) try writer.writeAll(" checked");
    }

    if (opts.live_targets) |targets| {
        if (try isLiveTarget(el, frame, targets.listener_targets)) {
            const id = try targets.add(el);
            try writer.print(" data-lp-live-target=\"{d}\"", .{id});
        }
    }
    try writer.writeByte('>');
}

fn isDocumentHead(el: *Node.Element, frame: *Frame) bool {
    const doc = frame.window._document;
    const html_doc = doc.is(Node.Document.HTMLDocument) orelse return false;
    return html_doc.getHead() == el;
}

fn isDocumentElementWithoutHead(el: *Node.Element, frame: *Frame) bool {
    const doc = frame.window._document;
    const html_doc = doc.is(Node.Document.HTMLDocument) orelse return false;
    return el.getTag() == .html and
        html_doc.asDocument().getDocumentElement() == el and
        html_doc.getHead() == null;
}

fn writeBase(frame: *Frame, writer: *std.Io.Writer) !void {
    try writer.writeAll("<base href=\"");
    try writeEscapedAttributeValue(frame.base(), writer);
    try writer.writeAll("\">");
}

fn writeEscapedAttributeValue(value: []const u8, writer: *std.Io.Writer) !void {
    for (value) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(byte),
        }
    }
}

pub fn toJSON(node: *Node, writer: *std.json.Stringify) !void {
    try writer.beginObject();

    try writer.objectField("type");
    switch (node.type) {
        .cdata => {
            try writer.write("cdata");
        },
        .document => {
            try writer.write("document");
        },
        .document_type => {
            try writer.write("document_type");
        },
        .element => |*el| {
            try writer.write("element");
            try writer.objectField("tag");
            try writer.write(el.tagName());

            try writer.objectField("attributes");
            try writer.beginObject();
            var it = el.attributeIterator();
            while (it.next()) |attr| {
                try writer.objectField(attr.name);
                try writer.write(attr.value);
            }
            try writer.endObject();
        },
    }

    try writer.objectField("children");
    try writer.beginArray();
    var it = node.childrenIterator();
    while (it.next()) |child| {
        try toJSON(child, writer);
    }
    try writer.endArray();
    try writer.endObject();
}

fn dumpSlotContent(slot: *Slot, opts: Opts, writer: *std.Io.Writer, frame: *Frame) DumpError!void {
    const assigned = slot.assignedNodes(null, frame) catch return;

    if (assigned.len > 0) {
        for (assigned) |assigned_node| {
            try _deep(assigned_node, opts, true, writer, frame);
        }
    } else {
        try children(slot.asNode(), opts, writer, frame);
    }
}

fn isVoidElement(el: *const Node.Element) bool {
    return switch (el._type) {
        .html => |html| switch (html._type) {
            .base, .br, .hr, .img, .input, .link, .meta => true,
            else => false,
        },
        .svg => false,
    };
}

fn shouldStripElement(el: *Node.Element, opts: Opts, frame: *Frame) bool {
    // Fast path: with no strip flags set (every innerHTML/outerHTML call)
    if (@as(u4, @bitCast(opts.strip)) == 0 and !opts.strip_refresh) {
        return false;
    }

    const tag_name = el.getTagNameDump();

    if (opts.strip_refresh and std.mem.eql(u8, tag_name, "meta")) {
        if (el.getAttributeSafe(comptime .wrap("http-equiv"))) |http_equiv| {
            if (std.ascii.eqlIgnoreCase(http_equiv, "refresh")) return true;
        }
    }

    if (opts.strip.js) {
        if (std.mem.eql(u8, tag_name, "script")) return true;
        if (std.mem.eql(u8, tag_name, "noscript")) return true;

        if (std.mem.eql(u8, tag_name, "link")) {
            if (el.getAttributeSafe(comptime .wrap("as"))) |as| {
                if (std.mem.eql(u8, as, "script")) return true;
            }
            if (el.getAttributeSafe(comptime .wrap("rel"))) |rel| {
                if (std.mem.eql(u8, rel, "modulepreload") or std.mem.eql(u8, rel, "preload")) {
                    if (el.getAttributeSafe(comptime .wrap("as"))) |as| {
                        if (std.mem.eql(u8, as, "script")) return true;
                    }
                }
            }
        }
    }

    if (opts.strip.css or opts.strip.ui) {
        if (std.mem.eql(u8, tag_name, "style")) return true;

        if (std.mem.eql(u8, tag_name, "link")) {
            if (el.getAttributeSafe(comptime .wrap("rel"))) |rel| {
                if (std.mem.eql(u8, rel, "stylesheet")) return true;
            }
        }
    }

    if (opts.strip.ui) {
        if (std.mem.eql(u8, tag_name, "img")) return true;
        if (std.mem.eql(u8, tag_name, "picture")) return true;
        if (std.mem.eql(u8, tag_name, "video")) return true;
        if (std.mem.eql(u8, tag_name, "audio")) return true;
        if (std.mem.eql(u8, tag_name, "svg")) return true;
        if (std.mem.eql(u8, tag_name, "canvas")) return true;
        if (std.mem.eql(u8, tag_name, "iframe")) return true;
    }

    if (opts.strip.invisible and frame._style_manager.hasAuthorDisplayNone(el)) {
        return true;
    }

    return false;
}

fn shouldEscapeText(node_: ?*Node) bool {
    // Raw text elements serialize their text content literally rather than
    // HTML-escaping it
    const node = node_ orelse return true;
    const element = node.is(Node.Element) orelse return true;
    const html_element = node.is(Node.Element.Html) orelse return true;

    switch (html_element._type) {
        .style, .script, .iframe => return false,
        else => {
            const tag = element.getTagNameLower();
            inline for (.{ "xmp", "noembed", "noframes", "plaintext", "noscript" }) |raw_text_tag| {
                if (std.mem.eql(u8, tag, raw_text_tag)) {
                    return false;
                }
            }
        },
    }
    return true;
}
fn writeEscapedText(text: []const u8, writer: *std.Io.Writer) !void {
    // Fast path: if no special characters, write directly
    const first_special = std.mem.indexOfAnyPos(u8, text, 0, &.{ '&', '<', '>', 194 }) orelse {
        return writer.writeAll(text);
    };

    try writer.writeAll(text[0..first_special]);
    var remaining = try writeEscapedByte(text, first_special, writer);

    while (std.mem.indexOfAnyPos(u8, remaining, 0, &.{ '&', '<', '>', 194 })) |offset| {
        try writer.writeAll(remaining[0..offset]);
        remaining = try writeEscapedByte(remaining, offset, writer);
    }

    if (remaining.len > 0) {
        try writer.writeAll(remaining);
    }
}

fn writeEscapedByte(input: []const u8, index: usize, writer: *std.Io.Writer) ![]const u8 {
    switch (input[index]) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        194 => {
            // non breaking space
            if (input.len > index + 1 and input[index + 1] == 160) {
                try writer.writeAll("&nbsp;");
                return input[index + 2 ..];
            }
            try writer.writeByte(194);
        },
        else => unreachable,
    }
    return input[index + 1 ..];
}

const testing = @import("../testing.zig");

// A fresh page per assertion keeps each dump expectation independent.
fn expectDump(opts: Opts, expected: []const u8) !void {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();

    const frame = page.frame().?;

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(frame.window._document, opts, &aw.writer, frame);
    try testing.expectString(expected, aw.written());
}

test "dump: default dumps the whole document" {
    try expectDump(.{},
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: with_base injects a <base> element" {
    try expectDump(.{ .with_base = true },
        \\<!DOCTYPE html>
        \\<html><head><base href="http://127.0.0.1:9582/src/browser/tests/dump.html"><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: with_base synthesizes a head after the doctype" {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const doc = frame.window._document;
    const html_doc = doc.is(Node.Document.HTMLDocument).?;
    const head = html_doc.getHead().?;
    _ = try head.asNode().parentNode().?.removeChild(head.asNode(), frame);
    const dom_version = frame._page.dom_version;

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(doc, .{ .with_base = true }, &aw.writer, frame);
    try testing.expectString(
        \\<!DOCTYPE html>
        \\<html><head><base href="http://127.0.0.1:9582/src/browser/tests/dump.html"></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    , aw.written());
    try testing.expectEqual(dom_version, frame._page.dom_version);
}

test "dump: live targets replace author markers without mutating the DOM" {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const doc = frame.window._document;
    const body = doc.is(Node.Document.HTMLDocument).?.getBody().?;

    const anchor = try doc.createElement("a", null, frame);
    try anchor.setAttributeSafe(comptime .wrap("href"), .wrap("/next"), frame);
    try anchor.setAttribute(.wrap("DATA-LP-LIVE-TARGET"), .wrap("forged"), frame);
    _ = try body.asNode().appendChild(anchor.asNode(), frame);

    const blank = try doc.createElement("a", null, frame);
    try blank.setAttributeSafe(comptime .wrap("href"), .wrap("/blank"), frame);
    try blank.setAttributeSafe(comptime .wrap("target"), .wrap("_blank"), frame);
    _ = try body.asNode().appendChild(blank.asNode(), frame);

    const download = try doc.createElement("a", null, frame);
    try download.setAttributeSafe(comptime .wrap("href"), .wrap("/file"), frame);
    try download.setAttributeSafe(comptime .wrap("download"), .wrap(""), frame);
    _ = try body.asNode().appendChild(download.asNode(), frame);

    const named = try doc.createElement("a", null, frame);
    try named.setAttributeSafe(comptime .wrap("href"), .wrap("/child"), frame);
    try named.setAttributeSafe(comptime .wrap("target"), .wrap("child"), frame);
    _ = try body.asNode().appendChild(named.asNode(), frame);

    const empty = try doc.createElement("a", null, frame);
    try empty.setAttributeSafe(comptime .wrap("href"), .wrap(""), frame);
    _ = try body.asNode().appendChild(empty.asNode(), frame);

    const button = try doc.createElement("button", null, frame);
    try button.setAttribute(.wrap("data-lp-live-target"), .wrap("forged"), frame);
    _ = try body.asNode().appendChild(button.asNode(), frame);

    const disabled = try doc.createElement("button", null, frame);
    try disabled.setAttributeSafe(comptime .wrap("disabled"), .wrap(""), frame);
    _ = try body.asNode().appendChild(disabled.asNode(), frame);

    const form = try doc.createElement("form", null, frame);
    const associated = try doc.createElement("button", null, frame);
    _ = try form.asNode().appendChild(associated.asNode(), frame);
    _ = try body.asNode().appendChild(form.asNode(), frame);

    const file = try doc.createElement("input", null, frame);
    try file.setAttributeSafe(comptime .wrap("type"), .wrap("file"), frame);
    _ = try body.asNode().appendChild(file.asNode(), frame);

    const invalid_inline = try doc.createElement("div", null, frame);
    try invalid_inline.setAttributeSafe(comptime .wrap("onclick"), .wrap(")"), frame);
    _ = try body.asNode().appendChild(invalid_inline.asNode(), frame);

    var elements: std.ArrayListUnmanaged(*Node.Element) = .empty;
    defer elements.deinit(testing.allocator);
    var targets: LiveTargets = .{ .elements = &elements, .allocator = testing.allocator };
    const dom_version = frame._page.dom_version;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try root(doc, .{ .live_targets = &targets }, &aw.writer, frame);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "<a href=\"/next\" data-lp-live-target=\"0\">") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "<button data-lp-live-target=\"1\">") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "<div onclick=\")\"></div>") != null);
    try testing.expectEqual(@as(usize, 2), elements.items.len);
    try testing.expectEqual(anchor, elements.items[0]);
    try testing.expectEqual(button, elements.items[1]);
    try testing.expect(!try isLiveTarget(blank, frame, .{}));
    try testing.expect(!try isLiveTarget(download, frame, .{}));
    try testing.expect(!try isLiveTarget(named, frame, .{}));
    try testing.expect(!try isLiveTarget(empty, frame, .{}));
    try testing.expect(!try isLiveTarget(disabled, frame, .{}));
    try testing.expect(!try isLiveTarget(associated, frame, .{}));
    try testing.expect(!try isLiveTarget(file, frame, .{}));
    try testing.expectEqual(dom_version, frame._page.dom_version);
}

test "dump: live checkables serialize current checked state" {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const doc = frame.window._document;
    const body = doc.is(Node.Document.HTMLDocument).?.getBody().?;

    const checkbox = try doc.createElement("input", null, frame);
    try checkbox.setAttributeSafe(comptime .wrap("id"), .wrap("checkbox"), frame);
    try checkbox.setAttributeSafe(comptime .wrap("type"), .wrap("checkbox"), frame);
    try checkbox.setAttributeSafe(comptime .wrap("checked"), .wrap(""), frame);
    _ = try body.asNode().appendChild(checkbox.asNode(), frame);
    try checkbox.is(Input).?.setChecked(false, frame);

    const radio = try doc.createElement("input", null, frame);
    try radio.setAttributeSafe(comptime .wrap("id"), .wrap("radio"), frame);
    try radio.setAttributeSafe(comptime .wrap("type"), .wrap("radio"), frame);
    _ = try body.asNode().appendChild(radio.asNode(), frame);
    try radio.is(Input).?.setChecked(true, frame);

    const disabled = try doc.createElement("input", null, frame);
    try disabled.setAttributeSafe(comptime .wrap("type"), .wrap("checkbox"), frame);
    try disabled.setAttributeSafe(comptime .wrap("disabled"), .wrap(""), frame);
    _ = try body.asNode().appendChild(disabled.asNode(), frame);

    const text = try doc.createElement("input", null, frame);
    _ = try body.asNode().appendChild(text.asNode(), frame);

    const file = try doc.createElement("input", null, frame);
    try file.setAttributeSafe(comptime .wrap("type"), .wrap("file"), frame);
    _ = try body.asNode().appendChild(file.asNode(), frame);

    const submit = try doc.createElement("input", null, frame);
    try submit.setAttributeSafe(comptime .wrap("type"), .wrap("submit"), frame);
    _ = try body.asNode().appendChild(submit.asNode(), frame);

    const select = try doc.createElement("select", null, frame);
    _ = try body.asNode().appendChild(select.asNode(), frame);

    var elements: std.ArrayListUnmanaged(*Node.Element) = .empty;
    defer elements.deinit(testing.allocator);
    var targets: LiveTargets = .{ .elements = &elements, .allocator = testing.allocator };

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try root(doc, .{ .live_targets = &targets }, &aw.writer, frame);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "<input id=\"checkbox\" type=\"checkbox\" data-lp-live-target=\"0\">") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "<input id=\"radio\" type=\"radio\" checked data-lp-live-target=\"1\">") != null);
    try testing.expectEqualSlices(*Node.Element, &.{ checkbox, radio }, elements.items);
    try testing.expect(!try isLiveTarget(disabled, frame, .{}));
    try testing.expect(!try isLiveTarget(text, frame, .{}));
    try testing.expect(!try isLiveTarget(file, frame, .{}));
    try testing.expect(!try isLiveTarget(submit, frame, .{}));
    try testing.expect(!try isLiveTarget(select, frame, .{}));
    try testing.expect(checkbox.hasAttributeSafe(comptime .wrap("checked")));
    try testing.expect(!radio.hasAttributeSafe(comptime .wrap("checked")));
}

test "dump: live snapshots strip meta refresh without mutating the DOM" {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const doc = frame.window._document;
    const head = doc.is(Node.Document.HTMLDocument).?.getHead().?;
    const refresh = try doc.createElement("meta", null, frame);
    try refresh.setAttributeSafe(comptime .wrap("http-equiv"), .wrap("refresh"), frame);
    try refresh.setAttributeSafe(comptime .wrap("content"), .wrap("0;url=https://example.test/"), frame);
    _ = try head.asNode().appendChild(refresh.asNode(), frame);
    const dom_version = frame._page.dom_version;

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try root(doc, .{ .strip_refresh = true }, &aw.writer, frame);

    try testing.expect(std.mem.indexOf(u8, aw.written(), "http-equiv=\"refresh\"") == null);
    try testing.expectEqual(dom_version, frame._page.dom_version);
}

test "dump: with_base preserves non-element children without a document element" {
    var page = try testing.pageTest("dump.html", .{});
    defer page.close();

    const frame = page.frame().?;
    const doc = frame.window._document;
    const html = doc.getDocumentElement().?;
    _ = try doc.asNode().removeChild(html.asNode(), frame);
    const comment = try doc.createComment("still-here", frame);
    _ = try doc.asNode().appendChild(comment, frame);
    const dom_version = frame._page.dom_version;

    var aw: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    try root(doc, .{ .with_base = true }, &aw.writer, frame);
    try testing.expectString(
        \\<!DOCTYPE html>
        \\<!--still-here-->
    , aw.written());
    try testing.expect(std.mem.indexOf(u8, aw.written(), "<base") == null);
    try testing.expectEqual(dom_version, frame._page.dom_version);
}

test "dump: strip.js removes script and noscript" {
    try expectDump(.{ .strip = .{ .js = true } },
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><p>visible &amp; well</p></body></html>
    );
}

test "dump: strip.css removes style and stylesheet links" {
    try expectDump(.{ .strip = .{ .css = true } },
        \\<!DOCTYPE html>
        \\<html><head><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: strip.ui removes css plus visual elements" {
    try expectDump(.{ .strip = .{ .ui = true } },
        \\<!DOCTYPE html>
        \\<html><head><script>var a=1;</script></head><body><h1>Title</h1><p class="hidden">secret</p><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}

test "dump: strip.invisible removes author display:none elements" {
    try expectDump(.{ .strip = .{ .invisible = true } },
        \\<!DOCTYPE html>
        \\<html><head><style>.hidden{display:none}</style><link rel="stylesheet" href="data:text/css,"><script>var a=1;</script></head><body><h1>Title</h1><img><svg></svg><noscript>nojs</noscript><p>visible &amp; well</p></body></html>
    );
}
