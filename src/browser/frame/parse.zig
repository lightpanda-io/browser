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

const Frame = @import("../Frame.zig");
const Parser = @import("../parser/Parser.zig");

const Node = @import("../webapi/Node.zig");
const Element = @import("../webapi/Element.zig");
const Document = @import("../webapi/Document.zig");
const ShadowRoot = @import("../webapi/ShadowRoot.zig");
const slotting = @import("../webapi/element/slotting.zig");

pub fn htmlAsChildren(frame: *Frame, node: *Node, html: []const u8) !void {
    return fragment(frame, node, html, .{});
}

// Range.createContextualFragment variant: unlike innerHTML et al., its scripts
// are run when the fragment is inserted into a document.
pub fn contextualFragment(frame: *Frame, node: *Node, html: []const u8) !void {
    return fragment(frame, node, html, .{ .scripts_runnable = true });
}

pub const FragmentParseOpts = struct {
    scripts_runnable: bool = false,
    allow_declarative_shadow: bool = false,
    context: ?*Element = null, // the parse context when it isn't the supplied `node`
};

pub fn fragment(frame: *Frame, node: *Node, html: []const u8, opts: FragmentParseOpts) !void {
    const previous_parse_mode = frame._parse_mode;
    frame._parse_mode = .fragment;
    defer frame._parse_mode = previous_parse_mode;

    // A context element in a document without a browsing context
    // (createHTMLDocument, new Document, DOMParser output) has no custom
    // element registry.
    const previous_creation = frame._custom_element_creation;
    const document = node.ownerDocument(frame) orelse node.as(Document);
    if (document._frame == null) {
        // a document without a browsing context (DOMParser et al.) has
        // no custom element and should stay undefined.
        frame._custom_element_creation = .undefined;
    }
    defer frame._custom_element_creation = previous_creation;

    // The html5ever wrapper-unwrap below rebinds children without going
    // through the insertion path, so recompute slot assignments for any
    // shadow tree this fragment landed in (idempotent; signals only on diff).
    defer if (frame._element_shadow_roots.count() != 0) {
        const root = node.getRootNode(.{});
        if (root.is(ShadowRoot) != null) {
            slotting.assignSlottablesForTree(root, frame);
        }
        if (node.is(Element)) |el| {
            if (el.hostedShadowRoot(frame)) |shadow_root| {
                slotting.assignSlottablesForTree(shadow_root.asNode(), frame);
            }
        }
    };

    const previous_scripts_runnable = frame._fragment_scripts_runnable;
    frame._fragment_scripts_runnable = opts.scripts_runnable;
    defer frame._fragment_scripts_runnable = previous_scripts_runnable;

    var parser = Parser.init(frame.call_arena, node, frame, .{
        .allow_declarative_shadow = opts.allow_declarative_shadow,
        .context = opts.context,
    });
    parser.parseFragment(html);
    if (parser.terminated) {
        return error.ExecutionTerminated;
    }

    // html5ever wraps fragment output in an <html> element; unwrap so its
    // children land directly on `node`. See https://github.com/servo/html5ever/issues/583.
    // Because of custom element callbacks, the structure might not be what
    // we expect, and nodes might be altogether removed. We deal with this in a
    // few different places, but always the same way: leave it as-is.
    const first = node.firstChild() orelse return;
    if (first.is(Element.Html.Html) == null) {
        return;
    }
    node._first_child = first._first_child;
    first._first_child = null;
    first._parent = null;
    first._prev = null;
    first._next = null;

    // No mutation records for the unwrapped children either; see the comment
    // about fragment parses in _insertNodeRelative.
    var it = node.childrenIterator();
    while (it.next()) |child| {
        child._parent = node;
    }
}

// Build a detached XMLDocument from `xml` (DOMParser.parseFromString and
// XMLHttpRequest.responseXML). Returns null when the input isn't well-formed
// XML.
pub fn xmlDocument(frame: *Frame, xml: []const u8) !?*Document.XMLDocument {
    const arena = try frame.getArena(.medium, "parse.xmlDocument");
    defer arena.release();

    const previous_parse_mode = frame._parse_mode;
    frame._parse_mode = .fragment;
    defer frame._parse_mode = previous_parse_mode;

    // No browsing context, so no custom element registry.
    const previous_creation = frame._custom_element_creation;
    frame._custom_element_creation = .undefined;
    defer frame._custom_element_creation = previous_creation;

    const doc = try frame._factory.document(Document.XMLDocument{ ._proto = undefined });
    const doc_node = doc.asNode();
    var parser = Parser.init(arena.allocator(), doc_node, frame, .{});
    parser.parseXML(xml);
    if (parser.terminated) {
        return error.ExecutionTerminated;
    }

    if (parser.err != null or parser.xml_error or doc_node.firstChild() == null) {
        return null;
    }

    // If first node is a `ProcessingInstruction` (e.g. the <?xml?>
    // declaration), skip it.
    const first_child = doc_node.firstChild().?;
    if (first_child.getNodeType() == 7) {
        _ = try doc_node.removeChild(first_child, frame);
    }

    return doc;
}
