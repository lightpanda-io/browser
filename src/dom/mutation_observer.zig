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

const parser = @import("netsurf");

const jsruntime = @import("jsruntime");
const Callback = jsruntime.Callback;
const CallbackResult = jsruntime.CallbackResult;
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

const generate = @import("../generate.zig");

const NodeList = @import("nodelist.zig").NodeList;

pub const Interfaces = generate.Tuple(.{
    MutationObserver,
    MutationRecord,
    MutationRecords,
});

const Walker = @import("../dom/walker.zig").WalkerChildren;

const log = std.log.scoped(.events);

// WEB IDL https://dom.spec.whatwg.org/#interface-mutationobserver
pub const MutationObserver = struct {
    cbk: Callback,
    observers: Observers,

    pub const mem_guarantied = true;

    const Observer = struct {
        node: *parser.Node,
        options: MutationObserverInit,
    };

    const deinitFunc = struct {
        fn deinit(ctx: ?*anyopaque, alloc: std.mem.Allocator) void {
            const o: *Observer = @ptrCast(@alignCast(ctx));
            alloc.destroy(o);
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

    pub fn constructor(cbk: Callback) !MutationObserver {
        return MutationObserver{
            .cbk = cbk,
            .observers = .{},
        };
    }

    // TODO
    fn resolveOptions(opt: ?MutationObserverInit) MutationObserverInit {
        return opt orelse .{};
    }

    pub fn _observe(self: *MutationObserver, alloc: std.mem.Allocator, node: *parser.Node, options: ?MutationObserverInit) !void {
        const o = try alloc.create(Observer);
        o.* = .{
            .node = node,
            .options = resolveOptions(options),
        };
        errdefer alloc.destroy(o);

        // register the new observer.
        try self.observers.append(alloc, o);

        // register node's events.
        if (o.options.childList or o.options.subtree) {
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                alloc,
                "DOMNodeInserted",
                EventHandler,
                .{ .cbk = self.cbk, .data = o, .deinitFunc = deinitFunc },
                false,
            );
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                alloc,
                "DOMNodeRemoved",
                EventHandler,
                .{ .cbk = self.cbk, .data = o, .deinitFunc = deinitFunc },
                false,
            );
        }
        if (o.options.attr()) {
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                alloc,
                "DOMAttrModified",
                EventHandler,
                .{ .cbk = self.cbk, .data = o, .deinitFunc = deinitFunc },
                false,
            );
        }
        if (o.options.cdata()) {
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                alloc,
                "DOMCharacterDataModified",
                EventHandler,
                .{ .cbk = self.cbk, .data = o, .deinitFunc = deinitFunc },
                false,
            );
        }
        if (o.options.subtree) {
            try parser.eventTargetAddEventListener(
                parser.toEventTarget(parser.Node, node),
                alloc,
                "DOMSubtreeModified",
                EventHandler,
                .{ .cbk = self.cbk, .data = o, .deinitFunc = deinitFunc },
                false,
            );
        }
    }

    // TODO
    pub fn _disconnect(_: *MutationObserver) !void {
        // TODO unregister listeners.
    }

    pub fn deinit(self: *MutationObserver, alloc: std.mem.Allocator) void {
        // TODO unregister listeners.
        for (self.observers.items) |o| alloc.destroy(o);
        self.observers.deinit(alloc);
    }

    // TODO
    pub fn _takeRecords(_: MutationObserver) ?[]const u8 {
        return &[_]u8{};
    }
};

// Handle multiple record?
pub const MutationRecords = struct {
    first: ?MutationRecord = null,

    pub const mem_guarantied = true;

    pub fn get_length(self: *MutationRecords) u32 {
        if (self.first == null) return 0;

        return 1;
    }

    pub fn postAttach(self: *MutationRecords, js_obj: jsruntime.JSObject) !void {
        if (self.first) |mr| {
            try js_obj.set("0", mr);
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

    pub const mem_guarantied = true;

    pub fn get_type(self: MutationRecord) []const u8 {
        return self.type;
    }

    pub fn get_addedNodes(self: MutationRecord) NodeList {
        return self.addedNodes;
    }

    pub fn get_removedNodes(self: MutationRecord) NodeList {
        return self.addedNodes;
    }

    pub fn get_target(self: MutationRecord) *parser.Node {
        return self.target;
    }

    pub fn get_attributeName(self: MutationRecord) ?[]const u8 {
        return self.attributeName;
    }

    pub fn get_attributeNamespace(self: MutationRecord) ?[]const u8 {
        return self.attributeNamespace;
    }

    pub fn get_previousSibling(self: MutationRecord) ?*parser.Node {
        return self.previousSibling;
    }

    pub fn get_nextSibling(self: MutationRecord) ?*parser.Node {
        return self.nextSibling;
    }

    pub fn get_oldValue(self: MutationRecord) ?[]const u8 {
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

    fn handle(evt: ?*parser.Event, data: parser.EventHandlerData) void {
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
        const o: *MutationObserver.Observer = @ptrCast(@alignCast(data.data));

        if (!apply(o, node)) return;

        const muevt = parser.eventToMutationEvent(evt.?);

        // TODO get the allocator by another way?
        const alloc = data.cbk.nat_ctx.alloc;

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

        var res = CallbackResult.init(alloc);
        defer res.deinit();

        // TODO pass MutationRecords and MutationObserver
        data.cbk.trycall(.{mrs}, &res) catch |e| log.err("mutation event handler error: {any}", .{e});

        // in case of function error, we log the result and the trace.
        if (!res.success) {
            log.info("mutation observer event handler error: {s}", .{res.result orelse "unknown"});
            log.debug("{s}", .{res.stack orelse "no stack trace"});
        }
    }
}.handle;

pub fn testExecFn(
    _: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    var constructor = [_]Case{
        .{ .src = "new MutationObserver(() => {}).observe(document, { childList: true });", .ex = "undefined" },
    };
    try checkCases(js_env, &constructor);

    var attr = [_]Case{
        .{ .src = 
        \\var nb = 0;
        \\var mrs;
        \\new MutationObserver((mu) => {
        \\    mrs = mu;
        \\    nb++;
        \\}).observe(document.firstElementChild, { attributes: true, attributeOldValue: true });
        \\document.firstElementChild.setAttribute("foo", "bar");
        \\// ignored b/c it's about another target.
        \\document.firstElementChild.firstChild.setAttribute("foo", "bar");
        \\nb;
        , .ex = "1" },
        .{ .src = "mrs[0].type", .ex = "attributes" },
        .{ .src = "mrs[0].target == document.firstElementChild", .ex = "true" },
        .{ .src = "mrs[0].target.getAttribute('foo')", .ex = "bar" },
        .{ .src = "mrs[0].attributeName", .ex = "foo" },
        .{ .src = "mrs[0].oldValue", .ex = "null" },
    };
    try checkCases(js_env, &attr);

    var cdata = [_]Case{
        .{ .src = 
        \\var node = document.getElementById("para").firstChild;
        \\var nb2 = 0;
        \\var mrs2;
        \\new MutationObserver((mu) => {
        \\    mrs2 = mu;
        \\    nb2++;
        \\}).observe(node, { characterData: true, characterDataOldValue: true });
        \\node.data = "foo";
        \\nb2;
        , .ex = "1" },
        .{ .src = "mrs2[0].type", .ex = "characterData" },
        .{ .src = "mrs2[0].target == node", .ex = "true" },
        .{ .src = "mrs2[0].target.data", .ex = "foo" },
        .{ .src = "mrs2[0].oldValue", .ex = " And" },
    };
    try checkCases(js_env, &cdata);
}
