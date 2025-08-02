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

const log = @import("../log.zig");
const parser = @import("netsurf.zig");

const Env = @import("env.zig").Env;
const Page = @import("page.zig").Page;
const Browser = @import("browser.zig").Browser;
const HttpClient = @import("../http/Client.zig");
const URL = @import("../url.zig").URL;

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const ScriptManager = @This();

page: *Page,

// Only once this is true can deferred scripts be run
static_scripts_done: bool,

// when async_count == 0 and static_script_done == true, the document is completed
// loading (i.e. page.documentIsComplete should be called).
async_count: usize,

// Normal scripts (non-deffered & non-async). These must be executed ni order
scripts: OrderList,

// List of deferred scripts. These must be executed in order, but only once
// dom_loaded == true,
deferred: OrderList,

client: *HttpClient,
allocator: Allocator,
buffer_pool: BufferPool,
script_pool: std.heap.MemoryPool(PendingScript),

const OrderList = std.DoublyLinkedList(*PendingScript);

pub fn init(browser: *Browser, page: *Page) ScriptManager {
    // page isn't fully initialized, we can setup our reference, but that's it.
    const allocator = browser.allocator;
    return .{
        .page = page,
        .scripts = .{},
        .deferred = .{},
        .async_count = 0,
        .allocator = allocator,
        .client = browser.http_client,
        .static_scripts_done = false,
        .buffer_pool = BufferPool.init(allocator, 5),
        .script_pool = std.heap.MemoryPool(PendingScript).init(allocator),
    };
}

pub fn deinit(self: *ScriptManager) void {
    self.buffer_pool.deinit();
    self.script_pool.deinit();
}

pub fn reset(self: *ScriptManager) void {
    self.client.abort();
    self.clearList(&self.scripts);
    self.clearList(&self.deferred);
    self.static_scripts_done = false;
}

fn clearList(_: *const ScriptManager, list: *OrderList) void {
    while (list.first) |node| {
        const pending_script = node.data;
        // this removes it from the list
        pending_script.deinit();
    }
    std.debug.assert(list.first == null);
}

pub fn addFromElement(self: *ScriptManager, element: *parser.Element) !void {
    if (try parser.elementGetAttribute(element, "nomodule") != null) {
        // these scripts should only be loaded if we don't support modules
        // but since we do support modules, we can just skip them.
        return;
    }

    // If a script tag gets dynamically created and added to the dom:
    //    document.getElementsByTagName('head')[0].appendChild(script)
    // that script tag will immediately get executed by our scriptAddedCallback.
    // However, if the location where the script tag is inserted happens to be
    // below where processHTMLDoc curently is, then we'll re-run that same script
    // again in processHTMLDoc. This flag is used to let us know if a specific
    // <script> has already been processed.
    if (try parser.scriptGetProcessed(@ptrCast(element))) {
        return;
    }
    try parser.scriptSetProcessed(@ptrCast(element), true);

    const kind: Script.Kind = blk: {
        const script_type = try parser.elementGetAttribute(element, "type") orelse break :blk .javascript;
        if (script_type.len == 0) {
            break :blk .javascript;
        }
        if (std.ascii.eqlIgnoreCase(script_type, "application/javascript")) {
            break :blk .javascript;
        }
        if (std.ascii.eqlIgnoreCase(script_type, "text/javascript")) {
            break :blk .javascript;
        }
        if (std.ascii.eqlIgnoreCase(script_type, "module")) {
            break :blk .module;
        }
        log.warn(.user_script, "unknown script type", .{ .type = script_type });
        return;
    };

    var onload: ?Script.Callback = null;
    var onerror: ?Script.Callback = null;

    const page = self.page;
    if (page.getNodeState(@ptrCast(element))) |se| {
        // if the script has a node state, then it was dynamically added and thus
        // the onload/onerror were saved in the state (if there are any)
        if (se.onload) |function| {
            onload = .{ .function = function };
        }
        if (se.onerror) |function| {
            onerror = .{ .function = function };
        }
    } else {
        // if the script has no node state, then it could still be dynamically
        // added (could have been dynamically added, but no attributes were set
        // which required a node state to be created) or it could be a inline
        // <script>.
        if (try parser.elementGetAttribute(element, "onload")) |string| {
            onload = .{ .string = string };
        }
        if (try parser.elementGetAttribute(element, "onerror")) |string| {
            onerror = .{ .string = string };
        }
    }

    var source: Script.Source = undefined;
    var remote_url: ?[:0]const u8 = null;
    if (try parser.elementGetAttribute(element, "src")) |src| {
        remote_url = try URL.stitch(page.arena, src, page.url.raw, .{ .null_terminated = true });
        source = .{ .remote = .{} };
    } else {
        const inline_source = try parser.nodeTextContent(@ptrCast(element)) orelse return;
        source = .{ .@"inline" = inline_source };
    }

    var script = Script{
        .kind = kind,
        .onload = onload,
        .onerror = onerror,
        .element = element,
        .source = source,
        .url = remote_url orelse page.url.raw,
        .is_defer = try parser.elementGetAttribute(element, "defer") != null,
        .is_async = try parser.elementGetAttribute(element, "async") != null,
    };

    if (source == .@"inline" and self.scripts.first == null) {
        // inline script with no pending scripts, execute it immediately.
        return script.eval(page);
    }

    const pending_script = try self.script_pool.create();
    errdefer self.script_pool.destroy(pending_script);
    pending_script.* = .{
        .script = script,
        .complete = false,
        .manager = self,
        .node = undefined,
    };

    if (source == .@"inline") {
        // if we're here, it means that we have pending scripts (i.e. self.ordered
        // is not empty). Because the script is inline, it's complete/ready, but
        // we need to process them in order
        pending_script.complete = true;
        self.scripts.append(&pending_script.node);
        return;
    }

    try self.client.request(.{
        .url = remote_url.?,
        .ctx = pending_script,
        .method = .GET,
        .start_callback = startCallback,
        .header_done_callback = headerCallback,
        .data_callback = dataCallback,
        .done_callback = doneCallback,
        .error_callback = errorCallback,
    });
}

pub fn staticScriptsDone(self: *ScriptManager) void {
    std.debug.assert(self.static_scripts_done == false);
    self.static_scripts_done = true;
}

// try to evaluate completed scripts (in order). This is called whenever a script
// is completed.
fn evaluate(self: *ScriptManager) void {
    const page = self.page;

    while (self.scripts.first) |n| {
        var pending_script = n.data;
        if (pending_script.complete == false) {
            return;
        }
        defer pending_script.deinit();
        pending_script.script.eval(page);
    }

    if (self.static_scripts_done == false) {
        // We can only execute deferred scripts if
        // 1 - all the normal scripts are done
        // 2 - and we've loaded all the normal scripts
        // The last one isn't obvious, but it's possible for self.scripts to/
        // be empty not because we're done executing all the normal scripts
        // but because we're done executing some (or maybe none), but we're still
        // parsing the HTML.
        return;
    }

    while (self.deferred.first) |n| {
        var pending_script = n.data;
        if (pending_script.complete == false) {
            return;
        }
        defer pending_script.deinit();
        pending_script.script.eval(page);
    }

    // When all scripts (normal and deferred) are done loading, the document
    // state changes (this ultimately triggers the DOMContentLoaded event)
    page.documentIsLoaded();

    if (self.async_count == 0) {
        // if we're here, then its like `asyncDone`
        // 1 - there are no async scripts pending
        // 2 - we checkecked static_scripts_done == true above
        // 3 - we drained self.scripts above
        // 4 - we drained self.deferred above
        page.documentIsComplete();
    }
}

pub fn isDone(self: *const ScriptManager) bool {
    return self.async_count == 0 and // there are no more async scripts
        self.static_scripts_done and // and we've finished parsing the HTML to queue all <scripts>
        self.scripts.first == null and // and there are no more <script src=> to wait for
        self.deferred.first == null; // and there are no more <script defer src=> to wait for
}

fn asyncDone(self: *ScriptManager) void {
    self.async_count -= 1;
    if (self.isDone()) {
        // then the document is considered complete
        self.page.documentIsComplete();
    }
}

fn getList(self: *ScriptManager, script: *const Script) ?*OrderList {
    if (script.is_defer) {
        return &self.deferred;
    }

    if (script.is_async) {
        // async don't need to execute in order.
        return null;
    }

    return &self.scripts;
}

fn startCallback(transfer: *HttpClient.Transfer) !void {
    const script: *PendingScript = @alignCast(@ptrCast(transfer.ctx));
    script.startCallback(transfer) catch |err| {
        log.err(.http, "SM.startCallback", .{ .err = err, .transfer = transfer });
        return err;
    };
}

fn headerCallback(transfer: *HttpClient.Transfer) !void {
    const script: *PendingScript = @alignCast(@ptrCast(transfer.ctx));
    script.headerCallback(transfer) catch |err| {
        log.err(.http, "SM.headerCallback", .{ .err = err, .transfer = transfer });
        return err;
    };
}

fn dataCallback(transfer: *HttpClient.Transfer, data: []const u8) !void {
    const script: *PendingScript = @alignCast(@ptrCast(transfer.ctx));
    script.dataCallback(data) catch |err| {
        log.err(.http, "SM.dataCallback", .{ .err = err, .transfer = transfer, .len = data.len });
        return err;
    };
}

fn doneCallback(ctx: *anyopaque) !void {
    const script: *PendingScript = @alignCast(@ptrCast(ctx));
    script.doneCallback();
}

fn errorCallback(ctx: *anyopaque, err: anyerror) void {
    const script: *PendingScript = @alignCast(@ptrCast(ctx));
    script.errorCallback(err);
}

// A script which is pending execution.
// It could be pending because:
//   (a) we're still downloading its content or
//   (b) this is a non-async script that has to be executed in order
const PendingScript = struct {
    script: Script,
    complete: bool,
    node: OrderList.Node,
    manager: *ScriptManager,

    fn deinit(self: *PendingScript) void {
        var manager = self.manager;
        if (self.script.source == .remote) {
            manager.buffer_pool.release(self.script.source.remote);
        }
        if (manager.getList(&self.script)) |list| {
            list.remove(&self.node);
        }
    }

    fn startCallback(self: *PendingScript, transfer: *HttpClient.Transfer) !void {
        if (self.manager.getList(&self.script)) |list| {
            self.node.data = self;
            list.append(&self.node);
        }

        // if the script is async, it isn't tracked in a list, because we can
        // execute it as soon as it's done loading.
        log.debug(.http, "script fetch start", .{ .req = transfer });
    }

    fn headerCallback(self: *PendingScript, transfer: *HttpClient.Transfer) !void {
        const header = &transfer.response_header.?;
        if (header.status != 200) {
            return error.InvalidStatusCode;
        }

        // @newhttp TODO: pre size based on content-length
        // @newhttp TODO: max-length enfocement
        self.script.source = .{ .remote = self.manager.buffer_pool.get() };

        log.debug(.http, "script header", .{
            .req = transfer,
            .status = header.status,
            .content_type = header.contentType(),
        });
    }

    fn dataCallback(self: *PendingScript, data: []const u8) !void {
        // @newhttp TODO: max-length enforcement
        try self.script.source.remote.appendSlice(self.manager.allocator, data);
    }

    fn doneCallback(self: *PendingScript) void {
        log.debug(.http, "script fetch complete", .{ .req = self.script.url });

        const manager = self.manager;
        if (self.script.is_async) {
            // async script can be evaluated immediately
            defer self.deinit();
            self.script.eval(self.manager.page);
            manager.asyncDone();
        } else {
            self.complete = true;
            self.manager.evaluate();
        }
    }

    fn errorCallback(self: *PendingScript, err: anyerror) void {
        log.warn(.http, "script fetch error", .{ .req = self.script.url, .err = err });
        self.deinit();
    }
};

const Script = struct {
    kind: Kind,
    url: []const u8,
    is_async: bool,
    is_defer: bool,
    source: Source,
    onload: ?Callback,
    onerror: ?Callback,
    element: *parser.Element,

    const Kind = enum {
        module,
        javascript,
    };

    const Callback = union(enum) {
        string: []const u8,
        function: Env.Function,
    };

    const Source = union(enum) {
        @"inline": []const u8,
        remote: std.ArrayListUnmanaged(u8),

        fn content(self: Source) []const u8 {
            return switch (self) {
                .remote => |buf| buf.items,
                .@"inline" => |c| c,
            };
        }
    };

    fn eval(self: *Script, page: *Page) void {

        // inline scripts aren't cached. remote ones are.
        const cacheable = self.source == .remote;

        const url = self.url;

        log.debug(.browser, "executing script", .{
            .src = url,
            .kind = self.kind,
            .cacheable = cacheable,
        });

        const js_context = page.main_context;
        var try_catch: Env.TryCatch = undefined;
        try_catch.init(js_context);
        defer try_catch.deinit();

        const success = blk: {
            const content = self.source.content();
            switch (self.kind) {
                .javascript => _ = js_context.eval(content, url) catch break :blk false,
                .module => {
                    // We don't care about waiting for the evaluation here.
                    _ = js_context.module(content, url, cacheable) catch break :blk false;
                },
            }
            break :blk true;
        };

        if (success) {
            self.executeCallback("onload", page);
            return;
        }

        if (page.delayed_navigation) {
            // If we're navigating to another page, an error is expected
            // since we probably terminated the script forcefully.
            return;
        }

        const msg = try_catch.err(page.arena) catch |err| @errorName(err) orelse "unknown";
        log.warn(.user_script, "eval script", .{
            .url = url,
            .err = msg,
            .cacheable = cacheable,
        });

        self.executeCallback("onerror", page);
    }

    fn executeCallback(self: *const Script, comptime typ: []const u8, page: *Page) void {
        const callback = @field(self, typ) orelse return;

        switch (callback) {
            .string => |str| {
                var try_catch: Env.TryCatch = undefined;
                try_catch.init(page.main_context);
                defer try_catch.deinit();

                _ = page.main_context.exec(str, typ) catch |err| {
                    const msg = try_catch.err(page.arena) catch @errorName(err) orelse "unknown";
                    log.warn(.user_script, "script callback", .{
                        .url = self.url,
                        .err = msg,
                        .type = typ,
                        .@"inline" = true,
                    });
                };
            },
            .function => |f| {
                const Event = @import("events/event.zig").Event;
                const loadevt = parser.eventCreate() catch |err| {
                    log.err(.browser, "SM event creation", .{ .err = err });
                    return;
                };
                defer parser.eventDestroy(loadevt);

                var result: Env.Function.Result = undefined;
                const iface = Event.toInterface(loadevt) catch |err| {
                    log.err(.browser, "SM event interface", .{ .err = err });
                    return;
                };
                f.tryCall(void, .{iface}, &result) catch {
                    log.warn(.user_script, "script callback", .{
                        .url = self.url,
                        .type = typ,
                        .err = result.exception,
                        .stack = result.stack,
                        .@"inline" = false,
                    });
                };
            },
        }
    }
};

const BufferPool = struct {
    free: List = .{},
    available: usize,
    allocator: Allocator,
    max_concurrent_transfers: u8,
    node_pool: std.heap.MemoryPool(List.Node),

    const List = std.DoublyLinkedList(std.ArrayListUnmanaged(u8));

    fn init(allocator: Allocator, max_concurrent_transfers: u8) BufferPool {
        return .{
            .free = .{},
            .available = 0,
            .allocator = allocator,
            .max_concurrent_transfers = max_concurrent_transfers,
            .node_pool = std.heap.MemoryPool(List.Node).init(allocator),
        };
    }

    fn deinit(self: *BufferPool) void {
        const allocator = self.allocator;

        var node = self.free.first;
        while (node) |n| {
            node = n.next;
            n.data.deinit(allocator);
        }
        self.node_pool.deinit();
    }

    fn get(self: *BufferPool) ArrayListUnmanaged(u8) {
        const node = self.free.popFirst() orelse {
            // return a new buffer
            return .{};
        };

        defer self.node_pool.destroy(node);
        return node.data;
    }

    fn release(self: *BufferPool, buffer: ArrayListUnmanaged(u8)) void {
        // @newhttp TODO: discard buffers that are larger than some configured max?

        // create mutable copy
        var b = buffer;

        if (self.available == self.max_concurrent_transfers) {
            b.deinit(self.allocator);
        }

        const node = self.node_pool.create() catch |err| {
            b.deinit(self.allocator);
            log.err(.http, "SM BufferPool release", .{ .err = err });
            return;
        };

        b.clearRetainingCapacity();
        node.data = b;
        self.available += 1;
        self.free.append(node);
    }
};
