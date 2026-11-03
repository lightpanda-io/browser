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
const NodeRegistry = @import("../../../NodeRegistry.zig");
const DOMNode = @import("../../../browser/webapi/Node.zig");
const properties = @import("../../../browser/css/properties.zig");
const CSSStyleDeclaration = @import("../../../browser/webapi/css/CSSStyleDeclaration.zig");

pub fn processMessage(cmd: *CDP.Command) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        getComputedStyleForNode,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .getComputedStyleForNode => return getComputedStyleForNode(cmd),
    }
}

const ComputedProperty = struct {
    name: []const u8,
    value: []const u8,
};

// https://chromedevtools.github.io/devtools-protocol/tot/CSS/#method-getComputedStyleForNode
// The values are the ones window.getComputedStyle() gives.
fn getComputedStyleForNode(cmd: *CDP.Command) !void {
    const params = (try cmd.params(struct {
        nodeId: NodeRegistry.Id,
    })) orelse return error.InvalidParams;

    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    const main_frame = bc.mainFrame() orelse return error.FrameNotLoaded;
    const node = bc.node_registry.lookup_by_id.get(params.nodeId) orelse return error.NodeNotFound;

    // A text node has the style of its parent element, like in Chrome.
    const element = node.dom.is(DOMNode.Element) orelse node.dom.parentElement() orelse return error.NodeIsNotAnElement;
    const frame = element.ownerFrame(main_frame) orelse main_frame;

    const decl = CSSStyleDeclaration{
        ._element = element,
        ._is_computed = true,
    };

    // decl.getPropertyValue uses frame.local_arena, which is only reset
    // between JS calls. So we reset it manually here.
    defer frame.resetLocalArena();

    const computed = try cmd.arena.alloc(ComputedProperty, properties.computed_names.len);
    for (computed, properties.computed_names) |*prop, name| {
        prop.* = .{
            .name = name,
            .value = try cmd.arena.dupe(u8, decl.getPropertyValue(name, frame)),
        };
    }

    return cmd.sendResult(.{
        .computedStyle = computed,
        .extraFields = .{ .isAppearanceBase = false },
    }, .{});
}

const testing = @import("../testing.zig");

test "cdp.css: getComputedStyleForNode" {
    var ctx = try testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-A", .url = "cdp/css_computed.html" });

    try ctx.processMessage(.{ .id = 1, .method = "DOM.getDocument" });
    try ctx.processMessage(.{ .id = 2, .method = "DOM.querySelector", .params = .{ .nodeId = 1, .selector = "#styled" } });
    try ctx.processMessage(.{ .id = 3, .method = "DOM.querySelector", .params = .{ .nodeId = 1, .selector = "#hidden" } });

    const styled = try testing.sentResult(&ctx, 2);
    const hidden = try testing.sentResult(&ctx, 3);

    try ctx.processMessage(.{ .id = 4, .method = "CSS.getComputedStyleForNode", .params = .{ .nodeId = styled.get("nodeId").?.integer } });
    const styled_style = (try testing.sentResult(&ctx, 4)).get("computedStyle").?.array.items;

    try std.testing.expectEqual(properties.computed_names.len, styled_style.len);

    try expectValue(styled_style, "color", "rgb(255, 0, 0)");
    try expectValue(styled_style, "width", "10px");
    try expectValue(styled_style, "display", "block");
    try expectValue(styled_style, "position", "static");
    // No shorthands, no aliases.
    try std.testing.expectEqual(null, findValue(styled_style, "margin"));
    try std.testing.expectEqual(null, findValue(styled_style, "word-wrap"));

    try ctx.processMessage(.{ .id = 5, .method = "CSS.getComputedStyleForNode", .params = .{ .nodeId = hidden.get("nodeId").?.integer } });
    const hidden_style = (try testing.sentResult(&ctx, 5)).get("computedStyle").?.array.items;
    try expectValue(hidden_style, "display", "none");

    // A text node gets its parent's style.
    try ctx.processMessage(.{ .id = 6, .method = "DOM.requestChildNodes", .params = .{ .nodeId = styled.get("nodeId").?.integer } });
    try ctx.processMessage(.{ .id = 7, .method = "DOM.describeNode", .params = .{ .nodeId = styled.get("nodeId").?.integer, .depth = 1 } });
    const described = try testing.sentResult(&ctx, 7);
    const text_id = described.get("node").?.object.get("children").?.array.items[0].object.get("nodeId").?.integer;
    try ctx.processMessage(.{ .id = 8, .method = "CSS.getComputedStyleForNode", .params = .{ .nodeId = text_id } });
    const text_style = (try testing.sentResult(&ctx, 8)).get("computedStyle").?.array.items;
    try expectValue(text_style, "color", "rgb(255, 0, 0)");

    try ctx.processMessage(.{ .id = 9, .method = "CSS.getComputedStyleForNode", .params = .{ .nodeId = 99999 } });
    try ctx.expectSentError(-31998, "NodeNotFound", .{ .id = 9 });
}

fn findValue(style: []const std.json.Value, name: []const u8) ?[]const u8 {
    for (style) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, name)) {
            return entry.object.get("value").?.string;
        }
    }
    return null;
}

fn expectValue(style: []const std.json.Value, name: []const u8, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, findValue(style, name) orelse return error.PropertyNotFound);
}
