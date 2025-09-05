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

// used to prevent executing scripts while we're doing a blocking load
is_blocking: bool = false,

// Only once this is true can deferred scripts be run
static_scripts_done: bool,

// List of async scripts. We don't care about the execution order of these, but
// on shutdown/abort, we need to cleanup any pending ones.
asyncs: OrderList,

// When an async script is ready to be evaluated, it's moved from asyncs to
// this list. You might think we can evaluate an async script as soon as it's
// done, but we can only evaluate scripts when `is_blocking == false`. So this
// becomes a list of scripts to execute on the next evaluate().
asyncs_ready: OrderList,

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

const OrderList = std.DoublyLinkedList;

pub fn init(browser: *Browser, page: *Page) ScriptManager {
    // page isn't fully initialized, we can setup our reference, but that's it.
    const allocator = browser.allocator;
    return .{
        .page = page,
        .asyncs = .{},
        .scripts = .{},
        .deferreds = .{},
        .asyncs_ready = .{},
        .is_evaluating = false,
        .allocator = allocator,
        .client = browser.http_client,
        .static_scripts_done = false,
        .buffer_pool = BufferPool.init(allocator, 5),
        .script_pool = std.heap.MemoryPool(PendingScript).init(allocator),
    };
}

pub fn deinit(self: *ScriptManager) void {
    self.reset();
    self.buffer_pool.deinit();
    self.script_pool.deinit();
}

pub fn reset(self: *ScriptManager) void {
    self.clearList(&self.asyncs);
    self.clearList(&self.scripts);
    self.clearList(&self.deferreds);
    self.clearList(&self.asyncs_ready);
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
        }
        remote_url = try URL.stitch(page.arena, src, page.url.raw, .{ .null_terminated = true });
        source = .{ .remote = .{} };
    } else {
        const inline_source = try parser.nodeTextContent(@ptrCast(element)) orelse return;
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
        log.debug(.http, "script queue", .{ .url = remote_url.? });
    }

    pending_script.getList().append(&pending_script.node);

    errdefer pending_script.deinit();

    var headers = try Http.Headers.init();
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

// @TODO: Improving this would have the simplest biggest performance improvement
// for most sites.
//
// For JS imports (both static and dynamic), we currently block to get the
// result (the content of the file).
//
// For static imports, this is necessary, since v8 is expecting the compiled module
// as part of the function return. (we should try to pre-load the JavaScript
// source via module.GetModuleRequests(), but that's for a later time).
//
// For dynamic dynamic imports, this is not strictly necessary since the v8
// call returns a Promise; we could make this a normal get call, associated with
// the promise, and when done, resolve the promise.
//
// In both cases, for now at least, we just issue a "blocking" request. We block
// by ticking the http client until the script is complete.
//
// This uses the client.blockingRequest call which has a dedicated handle for
// these blocking requests. Because they are blocking, we're guaranteed to have
// only 1 at a time, thus the 1 reserved handle.
//
// You almost don't need the http client's blocking handle. In most cases, you
// should always have 1 free handle whenever you get here, because we always
// release the handle before executing the doneCallback. So, if a module does:
//    import * as x from 'blah'
// And we need to load 'blah', there should always be 1 free handle - the handle
// of the http GET we just completed before executing the module.
// The exception to this, and the reason we need a special blocking handle, is
// for inline modules within the HTML page itself:
//    <script type=module>import ....</script>
// Unlike external modules which can only ever be executed after releasing an
// http handle, these are executed without there necessarily being a free handle.
// Thus, Http/Client.zig maintains a dedicated handle for these calls.
pub fn blockingGet(self: *ScriptManager, url: [:0]const u8) !BlockingResult {
    std.debug.assert(self.is_blocking == false);

    self.is_blocking = true;
    defer {
        self.is_blocking = false;

        // we blocked evaluation while loading this script, there could be
        // scripts ready to process.
        self.evaluate();
    }

    var blocking = Blocking{
        .allocator = self.allocator,
        .buffer_pool = &self.buffer_pool,
    };

    var headers = try Http.Headers.init();
    try self.page.requestCookie(.{}).headersForRequest(self.page.arena, url, &headers);

    var client = self.client;
    try client.blockingRequest(.{
        .url = url,
        .method = .GET,
        .headers = headers,
        .cookie_jar = self.page.cookie_jar,
        .ctx = &blocking,
        .resource_type = .script,
        .start_callback = if (log.enabled(.http, .debug)) Blocking.startCallback else null,
        .header_callback = Blocking.headerCallback,
        .data_callback = Blocking.dataCallback,
        .done_callback = Blocking.doneCallback,
        .error_callback = Blocking.errorCallback,
    });

    // rely on http's timeout settings to avoid an endless/long loop.
    while (true) {
        _ = try client.tick(200);
        switch (blocking.state) {
            .running => {},
            .done => |result| return result,
            .err => |err| return err,
        }
    }
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

    if (self.is_blocking) {
        // Cannot evaluate scripts while a blocking-load is in progress. Not
        // only could that result in incorrect evaluation order, it could
        // trigger another blocking request, while we're doing a blocking request.
        return;
    }

    const page = self.page;
    self.is_evaluating = true;
    defer self.is_evaluating = false;

    // every script in asyncs_ready is ready to be evaluated.
    while (self.asyncs_ready.first) |n| {
        var pending_script: *PendingScript = @fieldParentPtr("node", n);
        defer pending_script.deinit();
        pending_script.script.eval(page);
    }

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
        if (self.script.is_async) {
            manager.asyncs.remove(&self.node);
            manager.asyncs_ready.append(&self.node);
        }
        manager.evaluate();
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
            return if (self.complete) &self.manager.asyncs_ready else &self.manager.asyncs;
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
        const callback = self.getCallback(typ, page) orelse return;

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

const Blocking = struct {
    allocator: Allocator,
    buffer_pool: *BufferPool,
    state: State = .{ .running = {} },
    buffer: std.ArrayListUnmanaged(u8) = .{},

    const State = union(enum) {
        running: void,
        err: anyerror,
        done: BlockingResult,
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

        if (header.status != 200) {
            return error.InvalidStatusCode;
        }

        var self: *Blocking = @ptrCast(@alignCast(transfer.ctx));
        self.buffer = self.buffer_pool.get();
    }

    fn dataCallback(transfer: *Http.Transfer, data: []const u8) !void {
        // too verbose
        // log.debug(.http, "script data chunk", .{
        //     .req = transfer,
        //     .blocking = true,
        // });

        var self: *Blocking = @ptrCast(@alignCast(transfer.ctx));
        self.buffer.appendSlice(self.allocator, data) catch |err| {
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
        var self: *Blocking = @ptrCast(@alignCast(ctx));
        self.state = .{ .done = .{
            .buffer = self.buffer,
            .buffer_pool = self.buffer_pool,
        } };
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        var self: *Blocking = @ptrCast(@alignCast(ctx));
        self.state = .{ .err = err };
        self.buffer_pool.release(self.buffer);
    }
};

pub const BlockingResult = struct {
    buffer: std.ArrayListUnmanaged(u8),
    buffer_pool: *BufferPool,

    pub fn deinit(self: *BlockingResult) void {
        self.buffer_pool.release(self.buffer);
    }

    pub fn src(self: *const BlockingResult) []const u8 {
        return self.buffer.items;
    }
};
