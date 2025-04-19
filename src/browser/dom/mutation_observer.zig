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

const parser = @import("../netsurf.zig");
const SessionState = @import("../env.zig").SessionState;

const Env = @import("../env.zig").Env;
const JsThis = @import("../env.zig").JsThis;
const NodeList = @import("nodelist.zig").NodeList;

pub const Interfaces = .{
    MutationObserver,
    MutationRecord,
    MutationRecords,
};

const Walker = @import("../dom/walker.zig").WalkerChildren;

const log = std.log.scoped(.events);

// WEB IDL https://dom.spec.whatwg.org/#interface-mutationobserver
pub const MutationObserver = struct {
    cbk: Env.Callback,
    observers: Observers,

    const Observer = struct {
        node: *parser.Node,
        options: MutationObserverInit,
    };

    const deinitFunc = struct {
        fn deinit(ctx: ?*anyopaque, allocator: std.mem.Allocator) void {
            const o: *Observer = @ptrCast(@alignCast(ctx));
            allocator.destroy(o);
        }
    }.deinit;

    const Observers = std.ArrayListUnmanaged(*Observer);

    pub const MutationObserverInit = struct {
        childList: bool = false,
        attributes: bool = false,
        characterData: bool = false,
        subtree: bool = false,
        attributeOldValue: bool = false,
        characterDataOldValue: bool = false,
        // TODO
        // attributeFilter: [][]const u8,

        fn attr(self: MutationObserverInit) bool {
            return self.attributes or self.attributeOldValue;
        }

        fn cdata(self: MutationObserverInit) bool {
            return self.characterData or self.characterDataOldValue;
        }
    };

    pub fn constructor(cbk: Env.Callback) !MutationObserver {
        return MutationObserver{
            .cbk = cbk,
            .observers = .{},
        };
    }

    // TODO
    fn resolveOptions(opt: ?MutationObserverInit) MutationObserverInit {
        return opt orelse .{};
    }

    pub fn _observe(self: *MutationObserver, node: *parser.Node, options: ?MutationObserverInit, state: *SessionState) !void {
        const arena = state.arena;
        const o = try arena.create(Observer);
        o.* = .{
            .node = node,
            .options = resolveOptions(options),
        };
        errdefer arena.destroy(o);

        // register the new observer.
        try self.observers.append(arena, o);

        // register node's events.
        if (o.options.childList or o.options.subtree) {
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                arena,
                "DOMNodeInserted",
                EventHandler,
                .{ .cbk = self.cbk, .ctx = o, .deinitFunc = deinitFunc },
                false,
            );
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                arena,
                "DOMNodeRemoved",
                EventHandler,
                .{ .cbk = self.cbk, .ctx = o, .deinitFunc = deinitFunc },
                false,
            );
        }
        if (o.options.attr()) {
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                arena,
                "DOMAttrModified",
                EventHandler,
                .{ .cbk = self.cbk, .ctx = o, .deinitFunc = deinitFunc },
                false,
            );
        }
        if (o.options.cdata()) {
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                arena,
                "DOMCharacterDataModified",
                EventHandler,
                .{ .cbk = self.cbk, .ctx = o, .deinitFunc = deinitFunc },
                false,
            );
        }
        if (o.options.subtree) {
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                arena,
                "DOMSubtreeModified",
                EventHandler,
                .{ .cbk = self.cbk, .ctx = o, .deinitFunc = deinitFunc },
                false,
            );
        }
    }

    // TODO
    pub fn _disconnect(_: *MutationObserver) !void {
        // TODO unregister listeners.
    }

    pub fn deinit(self: *MutationObserver, state: *SessionState) void {
        const arena = state.arena;
        // TODO unregister listeners.
        for (self.observers.items) |o| {
            arena.destroy(o);
        }
        self.observers.deinit(arena);
    }

    // TODO
    pub fn _takeRecords(_: *const MutationObserver) ?[]const u8 {
        return &[_]u8{};
    }
};

// Handle multiple record?
pub const MutationRecords = struct {
    first: ?MutationRecord = null,

    pub fn get_length(self: *const MutationRecords) u32 {
        if (self.first == null) return 0;

        return 1;
    }
    pub fn indexed_get(self: *const MutationRecords, i: u32, has_value: *bool) ?MutationRecord {
        _ = i;
        return self.first orelse {
            has_value.* = false;
            return null;
        };
    }
    pub fn postAttach(self: *const MutationRecords, js_this: JsThis) !void {
        if (self.first) |mr| {
            try js_this.set("0", mr);
        }
    }
};

pub const MutationRecord = struct {
    type: []const u8,
    target: *parser.Node,
    addedNodes: NodeList = NodeList.init(),
    removedNodes: NodeList = NodeList.init(),
    previousSibling: ?*parser.Node = null,
    nextSibling: ?*parser.Node = null,
    attributeName: ?[]const u8 = null,
    attributeNamespace: ?[]const u8 = null,
    oldValue: ?[]const u8 = null,

    pub fn get_type(self: *const MutationRecord) []const u8 {
        return self.type;
    }

    pub fn get_addedNodes(self: *const MutationRecord) NodeList {
        return self.addedNodes;
    }

    pub fn get_removedNodes(self: *const MutationRecord) NodeList {
        return self.addedNodes;
    }

    pub fn get_target(self: *const MutationRecord) *parser.Node {
        return self.target;
    }

    pub fn get_attributeName(self: *const MutationRecord) ?[]const u8 {
        return self.attributeName;
    }

    pub fn get_attributeNamespace(self: *const MutationRecord) ?[]const u8 {
        return self.attributeNamespace;
    }

    pub fn get_previousSibling(self: *const MutationRecord) ?*parser.Node {
        return self.previousSibling;
    }

    pub fn get_nextSibling(self: *const MutationRecord) ?*parser.Node {
        return self.nextSibling;
    }

    pub fn get_oldValue(self: *const MutationRecord) ?[]const u8 {
        return self.oldValue;
    }
};

// EventHandler dedicated to mutation events.
const EventHandler = struct {
    fn apply(o: *MutationObserver.Observer, target: *parser.Node) bool {
        // mutation on any target is always ok.
        if (o.options.subtree) return true;
        // if target equals node, alway ok.
        if (target == o.node) return true;

        // no subtree, no same target and no childlist, always noky.
        if (!o.options.childList) return false;

        // target must be a child of o.node
        const walker = Walker{};
        var next: ?*parser.Node = null;
        while (true) {
            next = walker.get_next(o.node, next) catch break orelse break;
            if (next.? == target) return true;
        }

        return false;
    }

    fn handle(evt: ?*parser.Event, data: *const parser.JSEventHandlerData) void {
        if (evt == null) return;

        var mrs: MutationRecords = .{};

        const t = parser.eventType(evt.?) catch |e| {
            log.err("mutation observer event type: {any}", .{e});
            return;
        };
        const et = parser.eventTarget(evt.?) catch |e| {
            log.err("mutation observer event target: {any}", .{e});
            return;
        } orelse return;
        const node = parser.eventTargetToNode(et);

        // retrieve the observer from the data.
        const o: *MutationObserver.Observer = @ptrCast(@alignCast(data.ctx));

        if (!apply(o, node)) return;

        const muevt = parser.eventToMutationEvent(evt.?);

        // TODO get the allocator by another way?
        const alloc = data.cbk.executor.scope_arena;

        if (std.mem.eql(u8, t, "DOMAttrModified")) {
            mrs.first = .{
                .type = "attributes",
                .target = o.node,
                .attributeName = parser.mutationEventAttributeName(muevt) catch null,
            };

            // record old value if required.
            if (o.options.attributeOldValue) {
                mrs.first.?.oldValue = parser.mutationEventPrevValue(muevt) catch null;
            }
        } else if (std.mem.eql(u8, t, "DOMCharacterDataModified")) {
            mrs.first = .{
                .type = "characterData",
                .target = o.node,
            };

            // record old value if required.
            if (o.options.characterDataOldValue) {
                mrs.first.?.oldValue = parser.mutationEventPrevValue(muevt) catch null;
            }
        } else if (std.mem.eql(u8, t, "DOMNodeInserted")) {
            mrs.first = .{
                .type = "childList",
                .target = o.node,
                .addedNodes = NodeList.init(),
                .removedNodes = NodeList.init(),
            };

            const rn = parser.mutationEventRelatedNode(muevt) catch null;
            if (rn) |n| {
                mrs.first.?.addedNodes.append(alloc, n) catch |e| {
                    log.err("mutation event handler error: {any}", .{e});
                    return;
                };
            }
        } else if (std.mem.eql(u8, t, "DOMNodeRemoved")) {
            mrs.first = .{
                .type = "childList",
                .target = o.node,
                .addedNodes = NodeList.init(),
                .removedNodes = NodeList.init(),
            };

            const rn = parser.mutationEventRelatedNode(muevt) catch null;
            if (rn) |n| {
                mrs.first.?.removedNodes.append(alloc, n) catch |e| {
                    log.err("mutation event handler error: {any}", .{e});
                    return;
                };
            }
        } else {
            return;
        }

        // TODO pass MutationRecords and MutationObserver
        var result: Env.Callback.Result = undefined;
        data.cbk.tryCall(.{mrs}, &result) catch {
            log.err("mutation observer callback error: {s}", .{result.exception});
            log.debug("stack:\n{s}", .{result.stack orelse "???"});
        };
    }
}.handle;

const testing = @import("../../testing.zig");
test "Browser.DOM.MutationObserver" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "new MutationObserver(() => {}).observe(document, { childList: true });", "undefined" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\ var nb = 0;
            \\ var mrs;
            \\ new MutationObserver((mu) => {
            \\    mrs = mu;
            \\    nb++;
            \\ }).observe(document.firstElementChild, { attributes: true, attributeOldValue: true });
            \\ document.firstElementChild.setAttribute("foo", "bar");
            \\ // ignored b/c it's about another target.
            \\ document.firstElementChild.firstChild.setAttribute("foo", "bar");
            \\ nb;
            ,
            "1",
        },
        .{ "mrs[0].type", "attributes" },
        .{ "mrs[0].target == document.firstElementChild", "true" },
        .{ "mrs[0].target.getAttribute('foo')", "bar" },
        .{ "mrs[0].attributeName", "foo" },
        .{ "mrs[0].oldValue", "null" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\ var node = document.getElementById("para").firstChild;
            \\ var nb2 = 0;
            \\ var mrs2;
            \\ new MutationObserver((mu) => {
            \\     mrs2 = mu;
            \\     nb2++;
            \\ }).observe(node, { characterData: true, characterDataOldValue: true });
            \\ node.data = "foo";
            \\ nb2;
            ,
            "1",
        },
        .{ "mrs2[0].type", "characterData" },
        .{ "mrs2[0].target == node", "true" },
        .{ "mrs2[0].target.data", "foo" },
        .{ "mrs2[0].oldValue", " And" },
    }, .{});
}
