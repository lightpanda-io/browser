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

const js = @import("js/js.zig");
const log = @import("../log.zig");
const parser = @import("netsurf.zig");

const Page = @import("page.zig").Page;
const DataURI = @import("DataURI.zig");
const Http = @import("../http/Http.zig");
const Browser = @import("browser.zig").Browser;
const URL = @import("../url.zig").URL;

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const ScriptManager = @This();

page: *Page,

// used to prevent recursive evalutaion
is_evaluating: bool,

// Only once this is true can deferred scripts be run
static_scripts_done: bool,

// List of async scripts. We don't care about the execution order of these, but
// on shutdown/abort, we need to cleanup any pending ones.
asyncs: OrderList,

// Normal scripts (non-deferred & non-async). These must be executed in order
scripts: OrderList,

// List of deferred scripts. These must be executed in order, but only once
// dom_loaded == true,
deferreds: OrderList,

shutdown: bool = false,

client: *Http.Client,
allocator: Allocator,
buffer_pool: BufferPool,
script_pool: std.heap.MemoryPool(PendingScript),
sync_module_pool: std.heap.MemoryPool(SyncModule),
async_module_pool: std.heap.MemoryPool(AsyncModule),

// We can download multiple sync modules in parallel, but we want to process
// then in order. We can't use an OrderList, like the other script types,
// because the order we load them might not be the order we want to process
// them in (I'm not sure this is true, but as far as I can tell, v8 doesn't
// make any guarantees about the list of sub-module dependencies it gives us
// So this is more like a cache. When a SyncModule is complete, it's put here
// and can be requested as needed.
sync_modules: std.StringHashMapUnmanaged(*SyncModule),

const OrderList = std.DoublyLinkedList;

pub fn init(browser: *Browser, page: *Page) ScriptManager {
    // page isn't fully initialized, we can setup our reference, but that's it.
    const allocator = browser.allocator;
    return .{
        .page = page,
        .asyncs = .{},
        .scripts = .{},
        .deferreds = .{},
        .sync_modules = .empty,
        .is_evaluating = false,
        .allocator = allocator,
        .client = browser.http_client,
        .static_scripts_done = false,
        .buffer_pool = BufferPool.init(allocator, 5),
        .script_pool = std.heap.MemoryPool(PendingScript).init(allocator),
        .sync_module_pool = std.heap.MemoryPool(SyncModule).init(allocator),
        .async_module_pool = std.heap.MemoryPool(AsyncModule).init(allocator),
    };
}

pub fn deinit(self: *ScriptManager) void {
    self.reset();
    var it = self.sync_modules.valueIterator();
    while (it.next()) |value_ptr| {
        value_ptr.*.buffer.deinit(self.allocator);
        self.sync_module_pool.destroy(value_ptr.*);
    }

    self.buffer_pool.deinit();
    self.script_pool.deinit();
    self.sync_module_pool.deinit();
    self.async_module_pool.deinit();

    self.sync_modules.deinit(self.allocator);
}

pub fn reset(self: *ScriptManager) void {
    var it = self.sync_modules.valueIterator();
    while (it.next()) |value_ptr| {
        value_ptr.*.buffer.deinit(self.allocator);
        self.sync_module_pool.destroy(value_ptr.*);
    }
    self.sync_modules.clearRetainingCapacity();

    self.clearList(&self.asyncs);
    self.clearList(&self.scripts);
    self.clearList(&self.deferreds);
    self.static_scripts_done = false;
}

fn clearList(_: *const ScriptManager, list: *OrderList) void {
    while (list.first) |node| {
        const pending_script: *PendingScript = @fieldParentPtr("node", node);
        // this removes it from the list
        pending_script.deinit();
    }
    std.debug.assert(list.first == null);
}

pub fn addFromElement(self: *ScriptManager, element: *parser.Element, comptime ctx: []const u8) !void {
    if (try parser.elementGetAttribute(element, "nomodule") != null) {
        // these scripts should only be loaded if we don't support modules
        // but since we do support modules, we can just skip them.
        return;
    }

    // If a script tag gets dynamically created and added to the dom:
    //    document.getElementsByTagName('head')[0].appendChild(script)
    // that script tag will immediately get executed by our scriptAddedCallback.
    // However, if the location where the script tag is inserted happens to be
    // below where processHTMLDoc currently is, then we'll re-run that same script
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

        // "type" could be anything, but only the above are ones we need to process.
        // Common other ones are application/json, application/ld+json, text/template

        return;
    };

    const page = self.page;
    var source: Script.Source = undefined;
    var remote_url: ?[:0]const u8 = null;
    if (try parser.elementGetAttribute(element, "src")) |src| {
        if (try DataURI.parse(page.arena, src)) |data_uri| {
            source = .{ .@"inline" = data_uri };
        } else {
            remote_url = try URL.stitch(page.arena, src, page.url.raw, .{ .null_terminated = true });
            source = .{ .remote = .{} };
        }
    } else {
        const inline_source = parser.nodeTextContent(@ptrCast(element)) orelse return;
        source = .{ .@"inline" = inline_source };
    }

    var script = Script{
        .kind = kind,
        .element = element,
        .source = source,
        .url = remote_url orelse page.url.raw,
        .is_defer = if (remote_url == null) false else try parser.elementGetAttribute(element, "defer") != null,
        .is_async = if (remote_url == null) false else try parser.elementGetAttribute(element, "async") != null,
    };

    if (source == .@"inline" and self.scripts.first == null) {
        // inline script with no pending scripts, execute it immediately.
        // (if there is a pending script, then we cannot execute this immediately
        // as it needs to best executed in order)
        return script.eval(page);
    }

    const pending_script = try self.script_pool.create();
    errdefer self.script_pool.destroy(pending_script);
    pending_script.* = .{
        .script = script,
        .complete = false,
        .manager = self,
        .node = .{},
    };

    if (source == .@"inline") {
        // if we're here, it means that we have pending scripts (i.e. self.scripts
        // is not empty). Because the script is inline, it's complete/ready, but
        // we need to process them in order
        pending_script.complete = true;
        self.scripts.append(&pending_script.node);
        return;
    } else {
        log.debug(.http, "script queue", .{
            .ctx = ctx,
            .url = remote_url.?,
            .stack = page.js.stackTrace() catch "???",
        });
    }

    pending_script.getList().append(&pending_script.node);

    errdefer pending_script.deinit();

    var headers = try self.client.newHeaders();
    try page.requestCookie(.{}).headersForRequest(page.arena, remote_url.?, &headers);

    try self.client.request(.{
        .url = remote_url.?,
        .ctx = pending_script,
        .method = .GET,
        .headers = headers,
        .cookie_jar = page.cookie_jar,
        .resource_type = .script,
        .start_callback = if (log.enabled(.http, .debug)) startCallback else null,
        .header_callback = headerCallback,
        .data_callback = dataCallback,
        .done_callback = doneCallback,
        .error_callback = errorCallback,
    });
}

pub fn getModule(self: *ScriptManager, url: [:0]const u8, referrer: []const u8) !void {
    const gop = try self.sync_modules.getOrPut(self.allocator, url);
    if (gop.found_existing) {
        // already requested
        return;
    }
    errdefer _ = self.sync_modules.remove(url);

    const sync = try self.sync_module_pool.create();
    errdefer self.sync_module_pool.destroy(sync);

    sync.* = .{ .manager = self };
    gop.value_ptr.* = sync;

    var headers = try self.client.newHeaders();
    try self.page.requestCookie(.{}).headersForRequest(self.page.arena, url, &headers);

    log.debug(.http, "script queue", .{
        .url = url,
        .ctx = "module",
        .referrer = referrer,
        .stack = self.page.js.stackTrace() catch "???",
    });

    try self.client.request(.{
        .url = url,
        .ctx = sync,
        .method = .GET,
        .headers = headers,
        .cookie_jar = self.page.cookie_jar,
        .resource_type = .script,
        .start_callback = if (log.enabled(.http, .debug)) SyncModule.startCallback else null,
        .header_callback = SyncModule.headerCallback,
        .data_callback = SyncModule.dataCallback,
        .done_callback = SyncModule.doneCallback,
        .error_callback = SyncModule.errorCallback,
    });
}

pub fn waitForModule(self: *ScriptManager, url: [:0]const u8) !GetResult {
    // Normally it's dangerous to hold on to map pointers. But here, the map
    // can't change. It's possible that by calling `tick`, other entries within
    // the map will have their value change, but the map itself is immutable
    // during this tick.
    const entry = self.sync_modules.getEntry(url) orelse {
        return error.UnknownModule;
    };
    const sync = entry.value_ptr.*;

    var client = self.client;
    while (true) {
        switch (sync.state) {
            .loading => {},
            .done => {
                // Our caller has its own higher level cache (caching the
                // actual compiled module). There's no reason for us to keep this
                defer self.sync_module_pool.destroy(sync);
                defer self.sync_modules.removeByPtr(entry.key_ptr);
                return .{
                    .buffer = sync.buffer,
                    .buffer_pool = &self.buffer_pool,
                };
            },
            .err => |err| return err,
        }
        // rely on http's timeout settings to avoid an endless/long loop.
        _ = try client.tick(200);
    }
}

pub fn getAsyncModule(self: *ScriptManager, url: [:0]const u8, cb: AsyncModule.Callback, cb_data: *anyopaque, referrer: []const u8) !void {
    const async = try self.async_module_pool.create();
    errdefer self.async_module_pool.destroy(async);

    async.* = .{
        .cb = cb,
        .manager = self,
        .cb_data = cb_data,
    };

    var headers = try self.client.newHeaders();
    try self.page.requestCookie(.{}).headersForRequest(self.page.arena, url, &headers);

    log.debug(.http, "script queue", .{
        .url = url,
        .ctx = "dynamic module",
        .referrer = referrer,
        .stack = self.page.js.stackTrace() catch "???",
    });

    try self.client.request(.{
        .url = url,
        .method = .GET,
        .headers = headers,
        .cookie_jar = self.page.cookie_jar,
        .ctx = async,
        .resource_type = .script,
        .start_callback = if (log.enabled(.http, .debug)) AsyncModule.startCallback else null,
        .header_callback = AsyncModule.headerCallback,
        .data_callback = AsyncModule.dataCallback,
        .done_callback = AsyncModule.doneCallback,
        .error_callback = AsyncModule.errorCallback,
    });
}
pub fn staticScriptsDone(self: *ScriptManager) void {
    std.debug.assert(self.static_scripts_done == false);
    self.static_scripts_done = true;
}

// try to evaluate completed scripts (in order). This is called whenever a script
// is completed.
fn evaluate(self: *ScriptManager) void {
    if (self.is_evaluating) {
        // It's possible for a script.eval to cause evaluate to be called again.
        // This is particularly true with blockingGet, but even without this,
        // it's theoretically possible (but unlikely). We could make this work
        // but there's little reason to support the complexity.
        return;
    }

    const page = self.page;
    self.is_evaluating = true;
    defer self.is_evaluating = false;

    while (self.scripts.first) |n| {
        var pending_script: *PendingScript = @fieldParentPtr("node", n);
        if (pending_script.complete == false) {
            return;
        }
        defer pending_script.deinit();
        pending_script.script.eval(page);
    }

    if (self.static_scripts_done == false) {
        // We can only execute deferred scripts if
        // 1 - all the normal scripts are done
        // 2 - we've finished parsing the HTML and at least queued all the scripts
        // The last one isn't obvious, but it's possible for self.scripts to
        // be empty not because we're done executing all the normal scripts
        // but because we're done executing some (or maybe none), but we're still
        // parsing the HTML.
        return;
    }

    while (self.deferreds.first) |n| {
        var pending_script: *PendingScript = @fieldParentPtr("node", n);
        if (pending_script.complete == false) {
            return;
        }
        defer pending_script.deinit();
        pending_script.script.eval(page);
    }

    // When all scripts (normal and deferred) are done loading, the document
    // state changes (this ultimately triggers the DOMContentLoaded event)
    page.documentIsLoaded();

    if (self.asyncs.first == null) {
        // 1 - there are no async scripts pending
        // 2 - we checkecked static_scripts_done == true above
        // 3 - we drained self.scripts above
        // 4 - we drained self.deferred above
        page.documentIsComplete();
    }
}

pub fn isDone(self: *const ScriptManager) bool {
    return self.asyncs.first == null and // there are no more async scripts
        self.static_scripts_done and // and we've finished parsing the HTML to queue all <scripts>
        self.scripts.first == null and // and there are no more <script src=> to wait for
        self.deferreds.first == null; // and there are no more <script defer src=> to wait for
}

fn startCallback(transfer: *Http.Transfer) !void {
    const script: *PendingScript = @ptrCast(@alignCast(transfer.ctx));
    script.startCallback(transfer) catch |err| {
        log.err(.http, "SM.startCallback", .{ .err = err, .transfer = transfer });
        return err;
    };
}

fn headerCallback(transfer: *Http.Transfer) !void {
    const script: *PendingScript = @ptrCast(@alignCast(transfer.ctx));
    try script.headerCallback(transfer);
}

fn dataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const script: *PendingScript = @ptrCast(@alignCast(transfer.ctx));
    script.dataCallback(transfer, data) catch |err| {
        log.err(.http, "SM.dataCallback", .{ .err = err, .transfer = transfer, .len = data.len });
        return err;
    };
}

fn doneCallback(ctx: *anyopaque) !void {
    const script: *PendingScript = @ptrCast(@alignCast(ctx));
    script.doneCallback();
}

fn errorCallback(ctx: *anyopaque, err: anyerror) void {
    const script: *PendingScript = @ptrCast(@alignCast(ctx));
    script.errorCallback(err);
}

// A script which is pending execution.
// It could be pending because:
//   (a) we're still downloading its content or
//   (b) this is a non-async script that has to be executed in order
pub const PendingScript = struct {
    script: Script,
    complete: bool,
    node: OrderList.Node,
    manager: *ScriptManager,

    fn deinit(self: *PendingScript) void {
        const script = &self.script;
        const manager = self.manager;

        if (script.source == .remote) {
            manager.buffer_pool.release(script.source.remote);
        }
        self.getList().remove(&self.node);
    }

    fn remove(self: *PendingScript) void {
        if (self.node) |*node| {
            self.getList().remove(node);
            self.node = null;
        }
    }

    fn startCallback(self: *PendingScript, transfer: *Http.Transfer) !void {
        _ = self;
        log.debug(.http, "script fetch start", .{ .req = transfer });
    }

    fn headerCallback(self: *PendingScript, transfer: *Http.Transfer) !void {
        const header = &transfer.response_header.?;
        if (header.status != 200) {
            log.info(.http, "script header", .{
                .req = transfer,
                .status = header.status,
                .content_type = header.contentType(),
            });
            return;
        }

        log.debug(.http, "script header", .{
            .req = transfer,
            .status = header.status,
            .content_type = header.contentType(),
        });

        // If this isn't true, then we'll likely leak memory. If you don't
        // set `CURLOPT_SUPPRESS_CONNECT_HEADERS` and CONNECT to a proxy, this
        // will fail. This assertion exists to catch incorrect assumptions about
        // how libcurl works, or about how we've configured it.
        std.debug.assert(self.script.source.remote.capacity == 0);
        var buffer = self.manager.buffer_pool.get();
        if (transfer.getContentLength()) |cl| {
            try buffer.ensureTotalCapacity(self.manager.allocator, cl);
        }
        self.script.source = .{ .remote = buffer };
    }

    fn dataCallback(self: *PendingScript, transfer: *Http.Transfer, data: []const u8) !void {
        _ = transfer;
        // too verbose
        // log.debug(.http, "script data chunk", .{
        //     .req = transfer,
        //     .len = data.len,
        // });

        try self.script.source.remote.appendSlice(self.manager.allocator, data);
    }

    fn doneCallback(self: *PendingScript) void {
        log.debug(.http, "script fetch complete", .{ .req = self.script.url });

        const manager = self.manager;
        self.complete = true;
        if (!self.script.is_async) {
            manager.evaluate();
            return;
        }
        // async script can be evaluated immediately
        defer self.deinit();
        self.script.eval(manager.page);
    }

    fn errorCallback(self: *PendingScript, err: anyerror) void {
        log.warn(.http, "script fetch error", .{ .req = self.script.url, .err = err });

        const manager = self.manager;

        self.deinit();

        if (manager.shutdown) {
            return;
        }

        manager.evaluate();
    }

    fn getList(self: *const PendingScript) *OrderList {
        // When a script has both the async and defer flag set, it should be
        // treated as async. Async is newer, so some websites use both so that
        // if async isn't known, it'll fallback to defer.

        const script = &self.script;
        if (script.is_async) {
            return &self.manager.asyncs;
        }

        if (script.is_defer) {
            return &self.manager.deferreds;
        }

        return &self.manager.scripts;
    }
};

const Script = struct {
    kind: Kind,
    url: []const u8,
    is_async: bool,
    is_defer: bool,
    source: Source,
    element: *parser.Element,

    const Kind = enum {
        module,
        javascript,
    };

    const Callback = union(enum) {
        string: []const u8,
        function: js.Function,
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
        page.setCurrentScript(@ptrCast(self.element)) catch |err| {
            log.err(.browser, "set document script", .{ .err = err });
            return;
        };

        defer page.setCurrentScript(null) catch |err| {
            log.err(.browser, "clear document script", .{ .err = err });
        };

        // inline scripts aren't cached. remote ones are.
        const cacheable = self.source == .remote;

        const url = self.url;

        log.info(.browser, "executing script", .{
            .src = url,
            .kind = self.kind,
            .cacheable = cacheable,
        });

        const js_context = page.js;
        var try_catch: js.TryCatch = undefined;
        try_catch.init(js_context);
        defer try_catch.deinit();

        const success = blk: {
            const content = self.source.content();
            switch (self.kind) {
                .javascript => _ = js_context.eval(content, url) catch break :blk false,
                .module => {
                    // We don't care about waiting for the evaluation here.
                    js_context.module(false, content, url, cacheable) catch break :blk false;
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
        const callback = self.getCallback(typ, page) orelse return;

        switch (callback) {
            .string => |str| {
                var try_catch: js.TryCatch = undefined;
                try_catch.init(page.js);
                defer try_catch.deinit();

                _ = page.js.exec(str, typ) catch |err| {
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

                var result: js.Function.Result = undefined;
                const iface = Event.toInterface(loadevt);
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

    fn getCallback(self: *const Script, comptime typ: []const u8, page: *Page) ?Callback {
        const element = self.element;
        // first we check if there was an el.onload set directly on the
        // element in JavaScript (if so, it'd be stored in the node state)
        if (page.getNodeState(@ptrCast(element))) |se| {
            if (@field(se, typ)) |function| {
                return .{ .function = function };
            }
        }
        // if we have no node state, or if the node state has no onload/onerror
        // then check for the onload/onerror attribute
        if (parser.elementGetAttribute(element, typ) catch null) |string| {
            return .{ .string = string };
        }
        return null;
    }
};

const BufferPool = struct {
    count: usize,
    available: List = .{},
    allocator: Allocator,
    max_concurrent_transfers: u8,
    mem_pool: std.heap.MemoryPool(Container),

    const List = std.DoublyLinkedList;

    const Container = struct {
        node: List.Node,
        buf: std.ArrayListUnmanaged(u8),
    };

    fn init(allocator: Allocator, max_concurrent_transfers: u8) BufferPool {
        return .{
            .available = .{},
            .count = 0,
            .allocator = allocator,
            .max_concurrent_transfers = max_concurrent_transfers,
            .mem_pool = std.heap.MemoryPool(Container).init(allocator),
        };
    }

    fn deinit(self: *BufferPool) void {
        const allocator = self.allocator;

        var node = self.available.first;
        while (node) |n| {
            const container: *Container = @fieldParentPtr("node", n);
            container.buf.deinit(allocator);
            node = n.next;
        }
        self.mem_pool.deinit();
    }

    fn get(self: *BufferPool) std.ArrayListUnmanaged(u8) {
        const node = self.available.popFirst() orelse {
            // return a new buffer
            return .{};
        };

        self.count -= 1;
        const container: *Container = @fieldParentPtr("node", node);
        defer self.mem_pool.destroy(container);
        return container.buf;
    }

    fn release(self: *BufferPool, buffer: ArrayListUnmanaged(u8)) void {
        // create mutable copy
        var b = buffer;

        if (self.count == self.max_concurrent_transfers) {
            b.deinit(self.allocator);
            return;
        }

        const container = self.mem_pool.create() catch |err| {
            b.deinit(self.allocator);
            log.err(.http, "SM BufferPool release", .{ .err = err });
            return;
        };

        b.clearRetainingCapacity();
        container.* = .{ .buf = b, .node = .{} };
        self.count += 1;
        self.available.append(&container.node);
    }
};

const SyncModule = struct {
    manager: *ScriptManager,
    buffer: std.ArrayListUnmanaged(u8) = .{},
    state: State = .loading,

    const State = union(enum) {
        done,
        loading,
        err: anyerror,
    };

    fn startCallback(transfer: *Http.Transfer) !void {
        log.debug(.http, "script fetch start", .{ .req = transfer, .blocking = true });
    }

    fn headerCallback(transfer: *Http.Transfer) !void {
        const header = &transfer.response_header.?;
        log.debug(.http, "script header", .{
            .req = transfer,
            .blocking = true,
            .status = header.status,
            .content_type = header.contentType(),
        });

        var self: *SyncModule = @ptrCast(@alignCast(transfer.ctx));
        if (header.status != 200) {
            self.finished(.{ .err = error.InvalidStatusCode });
            return error.InvalidStatusCode;
        }

        self.buffer = self.manager.buffer_pool.get();
    }

    fn dataCallback(transfer: *Http.Transfer, data: []const u8) !void {
        // too verbose
        // log.debug(.http, "script data chunk", .{
        //     .req = transfer,
        //     .blocking = true,
        // });

        var self: *SyncModule = @ptrCast(@alignCast(transfer.ctx));
        self.buffer.appendSlice(self.manager.allocator, data) catch |err| {
            log.err(.http, "SM.dataCallback", .{
                .err = err,
                .len = data.len,
                .blocking = true,
                .transfer = transfer,
            });
            return err;
        };
    }

    fn doneCallback(ctx: *anyopaque) !void {
        var self: *SyncModule = @ptrCast(@alignCast(ctx));
        self.finished(.done);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        var self: *SyncModule = @ptrCast(@alignCast(ctx));
        self.finished(.{ .err = err });
    }

    fn finished(self: *SyncModule, state: State) void {
        self.state = state;
    }
};

pub const AsyncModule = struct {
    cb: Callback,
    cb_data: *anyopaque,
    manager: *ScriptManager,
    buffer: std.ArrayListUnmanaged(u8) = .{},

    pub const Callback = *const fn (ptr: *anyopaque, result: anyerror!GetResult) void;

    fn startCallback(transfer: *Http.Transfer) !void {
        log.debug(.http, "script fetch start", .{ .req = transfer, .async = true });
    }

    fn headerCallback(transfer: *Http.Transfer) !void {
        const header = &transfer.response_header.?;
        log.debug(.http, "script header", .{
            .req = transfer,
            .async = true,
            .status = header.status,
            .content_type = header.contentType(),
        });

        if (header.status != 200) {
            return error.InvalidStatusCode;
        }

        var self: *AsyncModule = @ptrCast(@alignCast(transfer.ctx));
        self.buffer = self.manager.buffer_pool.get();
    }

    fn dataCallback(transfer: *Http.Transfer, data: []const u8) !void {
        // too verbose
        // log.debug(.http, "script data chunk", .{
        //     .req = transfer,
        //     .blocking = true,
        // });

        var self: *AsyncModule = @ptrCast(@alignCast(transfer.ctx));
        self.buffer.appendSlice(self.manager.allocator, data) catch |err| {
            log.err(.http, "SM.dataCallback", .{
                .err = err,
                .len = data.len,
                .ascyn = true,
                .transfer = transfer,
            });
            return err;
        };
    }

    fn doneCallback(ctx: *anyopaque) !void {
        var self: *AsyncModule = @ptrCast(@alignCast(ctx));
        defer self.manager.async_module_pool.destroy(self);
        self.cb(self.cb_data, .{
            .buffer = self.buffer,
            .buffer_pool = &self.manager.buffer_pool,
        });
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        var self: *AsyncModule = @ptrCast(@alignCast(ctx));

        if (err != error.Abort) {
            self.cb(self.cb_data, err);
        }

        if (self.buffer.items.len > 0) {
            self.manager.buffer_pool.release(self.buffer);
        }

        self.manager.async_module_pool.destroy(self);
    }
};

pub const GetResult = struct {
    buffer: std.ArrayListUnmanaged(u8),
    buffer_pool: *BufferPool,

    pub fn deinit(self: *GetResult) void {
        self.buffer_pool.release(self.buffer);
    }

    pub fn src(self: *const GetResult) []const u8 {
        return self.buffer.items;
    }
};
