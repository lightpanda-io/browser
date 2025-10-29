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
const builtin = @import("builtin");

const js = @import("js/js.zig");
const log = @import("../log.zig");

const URL = @import("URL.zig");
const Page = @import("Page.zig");
const Browser = @import("Browser.zig");
const Http = @import("../http/Http.zig");

const Element = @import("webapi/Element.zig");

const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const IS_DEBUG = builtin.mode == .Debug;

const ScriptManager = @This();

page: *Page,

// used to prevent recursive evaluation
is_evaluating: bool,

// Only once this is true can deferred scripts be run
static_scripts_done: bool,

// List of async scripts. We don't care about the execution order of these, but
// on shutdown/abort, we need to cleanup any pending ones.
asyncs: OrderList,

// List of deferred scripts. These must be executed in order, but only once
// dom_loaded == true,
deferreds: OrderList,

shutdown: bool = false,

client: *Http.Client,
buffer_pool: BufferPool,
script_pool: std.heap.MemoryPool(PendingScript),
sync_module_pool: std.heap.MemoryPool(SyncModule),
async_module_pool: std.heap.MemoryPool(AsyncModule),

allocator: Allocator,

// We can download multiple sync modules in parallel, but we want to process
// then in order. We can't use an OrderList, like the other script types,
// because the order we load them might not be the order we want to process
// them in (I'm not sure this is true, but as far as I can tell, v8 doesn't
// make any guarantees about the list of sub-module dependencies it gives us
// So this is more like a cache. When a SyncModule is complete, it's put here
// and can be requested as needed.
sync_modules: std.StringHashMapUnmanaged(*SyncModule),

// Mapping between module specifier and resolution.
// see https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script/type/importmap
// importmap contains resolved urls.
importmap: std.StringHashMapUnmanaged([:0]const u8),

const OrderList = std.DoublyLinkedList;

pub fn init(page: *Page) ScriptManager {
    const browser = page._session.browser;
    // page isn't fully initialized, we can setup our reference, but that's it.
    const allocator = browser.allocator;
    return .{
        .page = page,
        .asyncs = .{},
        .deferreds = .{},
        .importmap = .empty,
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
    // we don't deinit self.importmap b/c we use the page's arena for its
    // allocations.
}

pub fn reset(self: *ScriptManager) void {
    var it = self.sync_modules.valueIterator();
    while (it.next()) |value_ptr| {
        value_ptr.*.buffer.deinit(self.allocator);
        self.sync_module_pool.destroy(value_ptr.*);
    }
    self.sync_modules.clearRetainingCapacity();
    // Our allocator is the page arena, it's been reset. We cannot use
    // clearAndRetainCapacity, since that space is no longer ours
    self.importmap = .empty;

    self.clearList(&self.asyncs);
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

pub fn add(self: *ScriptManager, script_element: *Element.Html.Script, comptime ctx: []const u8) !void {
    if (script_element._executed) {
        // If a script tag gets dynamically created and added to the dom:
        //    document.getElementsByTagName('head')[0].appendChild(script)
        // that script tag will immediately get executed by our scriptAddedCallback.
        // However, if the location where the script tag is inserted happens to be
        // below where processHTMLDoc currently is, then we'll re-run that same script
        // again in processHTMLDoc. This flag is used to let us know if a specific
        // <script> has already been processed.
        return;
    }
    script_element._executed = true;

    const element = script_element.asElement();
    if (element.getAttributeSafe("nomodule") != null) {
        // these scripts should only be loaded if we don't support modules
        // but since we do support modules, we can just skip them.
        return;
    }

    const kind: Script.Kind = blk: {
        const script_type = element.getAttributeSafe("type") orelse break :blk .javascript;
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
        if (std.ascii.eqlIgnoreCase(script_type, "importmap")) {
            break :blk .importmap;
        }

        // "type" could be anything, but only the above are ones we need to process.
        // Common other ones are application/json, application/ld+json, text/template

        return;
    };

    const page = self.page;
    var source: Script.Source = undefined;
    var remote_url: ?[:0]const u8 = null;
    if (element.getAttributeSafe("src")) |src| {
        if (try parseDataURI(page.arena, src)) |data_uri| {
            source = .{ .@"inline" = data_uri };
        } else {
            remote_url = try URL.resolve(page.arena, page.url, src, .{});
            source = .{ .remote = .{} };
        }
    } else {
        const inline_source = try element.asNode().getTextContentAlloc(page.arena);
        source = .{ .@"inline" = inline_source };
    }

    var script = Script{
        .kind = kind,
        .source = source,
        .script_element = script_element,
        .url = remote_url orelse page.url,
        .is_defer = if (remote_url == null) false else element.getAttributeSafe("defer") != null,
        .is_async = if (remote_url == null) false else element.getAttributeSafe("async") != null,
    };

    if (source == .@"inline") {
        // inline script gets executed immediately
        return script.eval(page);
    }

    const pending_script = blk: {
        // Done in a block this way so that, if something fails in this block
        // it's cleaned up with these errdefers
        // BUT, if we need to load/execute the script immediately, cleanup/lifetimes
        // become the responsibility of the outer block.
        const pending_script = try self.script_pool.create();
        errdefer self.script_pool.destroy(pending_script);

        pending_script.* = .{
            .script = script,
            .complete = false,
            .manager = self,
            .node = .{},
        };
        errdefer pending_script.deinit();

        if (comptime IS_DEBUG) {
            log.debug(.http, "script queue", .{
                .ctx = ctx,
                .url = remote_url.?,
                .stack = page.js.stackTrace() catch "???",
            });
        }

        var headers = try self.client.newHeaders();
        try page.requestCookie(.{}).headersForRequest(page.arena, remote_url.?, &headers);

        try self.client.request(.{
            .url = remote_url.?,
            .ctx = pending_script,
            .method = .GET,
            .headers = headers,
            .resource_type = .script,
            .cookie_jar = &page._session.cookie_jar,
            .start_callback = if (log.enabled(.http, .debug)) startCallback else null,
            .header_callback = headerCallback,
            .data_callback = dataCallback,
            .done_callback = doneCallback,
            .error_callback = errorCallback,
        });

        if (script.is_defer) {
            // non-blocking loading, track the list this belongs to, and return
            pending_script.list = &self.deferreds;
            return;
        }

        if (script.is_async) {
            // non-blocking loading, track the list this belongs to, and return
            pending_script.list = &self.asyncs;
            return;
        }

        break :blk pending_script;
    };

    defer pending_script.deinit();

    // this is <script src="..."></script>, it needs to block the caller
    // until it's evaluated
    var client = self.client;
    while (true) {
        if (pending_script.complete) {
            return pending_script.script.eval(page);
        }
        _ = try client.tick(200);
    }
}

// Resolve a module specifier to an valid URL.
pub fn resolveSpecifier(self: *ScriptManager, arena: Allocator, base: [:0]const u8, specifier: [:0]const u8) ![:0]const u8 {
    // If the specifier is mapped in the importmap, return the pre-resolved value.
    if (self.importmap.get(specifier)) |s| {
        return s;
    }

    return URL.resolve(arena, base, specifier, .{});
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
        .cookie_jar = &self.page._session.cookie_jar,
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
    // the map will have their value changed, but the map itself is immutable
    // during this tick.
    const entry = self.sync_modules.getEntry(url) orelse {
        return error.UnknownModule;
    };
    const sync = entry.value_ptr.*;

    // We can have multiple scripts waiting for the same module in concurrency.
    // We use the waiters to ensures only the last waiter deinit the resources.
    sync.waiters += 1;
    defer sync.waiters -= 1;

    var client = self.client;
    while (true) {
        switch (sync.state) {
            .loading => {},
            .done => {
                if (sync.waiters == 1) {
                    // Our caller has its own higher level cache (caching the
                    // actual compiled module). There's no reason for us to keep
                    // this if we are the last waiter.
                    defer self.sync_module_pool.destroy(sync);
                    defer self.sync_modules.removeByPtr(entry.key_ptr);
                    return .{
                        .shared = false,
                        .buffer = sync.buffer,
                        .buffer_pool = &self.buffer_pool,
                    };
                }

                return .{
                    .shared = true,
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
        .cookie_jar = &self.page._session.cookie_jar,
        .ctx = async,
        .resource_type = .script,
        .start_callback = if (log.enabled(.http, .debug)) AsyncModule.startCallback else null,
        .header_callback = AsyncModule.headerCallback,
        .data_callback = AsyncModule.dataCallback,
        .done_callback = AsyncModule.doneCallback,
        .error_callback = AsyncModule.errorCallback,
    });
}

pub fn pageIsLoaded(self: *ScriptManager) void {
    std.debug.assert(self.static_scripts_done == false);
    self.static_scripts_done = true;
    self.evaluate();
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
        self.deferreds.first == null; // and there are no more <script defer src=> to wait for
}

fn asyncScriptIsDone(self: *ScriptManager) void {
    if (self.isDone()) {
        self.page.documentIsComplete();
    }
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

fn parseImportmap(self: *ScriptManager, script: *const Script) !void {
    const content = script.source.content();

    const Imports = struct {
        imports: std.json.ArrayHashMap([]const u8),
    };

    const imports = try std.json.parseFromSliceLeaky(
        Imports,
        self.page.arena,
        content,
        .{ .allocate = .alloc_always },
    );

    var iter = imports.imports.map.iterator();
    while (iter.next()) |entry| {
        // > Relative URLs are resolved to absolute URL addresses using the
        // > base URL of the document containing the import map.
        // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules#importing_modules_using_import_maps
        const resolved_url = try URL.resolve(
            self.page.arena,
            self.page.url,
            entry.value_ptr.*,
            .{},
        );

        try self.importmap.put(self.page.arena, entry.key_ptr.*, resolved_url);
    }

    return;
}

// A script which is pending execution.
// It could be pending because:
//   (a) we're still downloading its content or
//   (b) it's a deferred script which has to be executed in order
pub const PendingScript = struct {
    script: Script,
    complete: bool,
    node: OrderList.Node,
    manager: *ScriptManager,
    list: ?*std.DoublyLinkedList = null,

    fn deinit(self: *PendingScript) void {
        const script = &self.script;
        const manager = self.manager;

        if (script.source == .remote) {
            manager.buffer_pool.release(script.source.remote);
        }

        if (self.list) |list| {
            list.remove(&self.node);
        }
        manager.script_pool.destroy(self);
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
        self.script.eval(manager.page);
        self.deinit();
        // asyncScriptIsDone must be run after the pending script is deinit.
        manager.asyncScriptIsDone();
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
};

const Script = struct {
    kind: Kind,
    url: []const u8,
    is_async: bool,
    is_defer: bool,
    source: Source,
    script_element: *Element.Html.Script,

    const Kind = enum {
        module,
        javascript,
        importmap,
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
        page.document._current_script = self.script_element;
        defer page.document._current_script = null;

        // inline scripts aren't cached. remote ones are.
        const cacheable = self.source == .remote;

        const url = self.url;

        log.info(.browser, "executing script", .{
            .src = url,
            .kind = self.kind,
            .cacheable = cacheable,
        });

        // Handle importmap special case here: the content is a JSON containing
        // imports.
        if (self.kind == .importmap) {
            page._script_manager.parseImportmap(self) catch |err| {
                log.err(.browser, "parse importmap script", .{
                    .err = err,
                    .src = url,
                    .kind = self.kind,
                    .cacheable = cacheable,
                });
                self.executeCallback(self.script_element._on_error, page);
                return;
            };
            self.executeCallback(self.script_element._on_load, page);
            return;
        }

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
                .importmap => unreachable, // handled before the try/catch.
            }
            break :blk true;
        };

        if (success) {
            self.executeCallback(self.script_element._on_load, page);
            return;
        }

        // @ZIGDOM
        // if (page.delayed_navigation) {
        //     // If we're navigating to another page, an error is expected
        //     // since we probably terminated the script forcefully.
        //     return;
        // }

        const msg = try_catch.err(page.arena) catch |err| @errorName(err) orelse "unknown";
        log.warn(.user_script, "eval script", .{
            .url = url,
            .err = msg,
            .cacheable = cacheable,
        });

        self.executeCallback(self.script_element._on_error, page);
    }

    fn executeCallback(self: *const Script, cb_: ?js.Function, page: *Page) void {
        const cb = cb_ orelse return;

        // @ZIGDOM execute the callback
        _ = cb;
        _ = self;
        _ = page;
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
    // number of waiters for the module.
    waiters: u8 = 0,

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
            .shared = false,
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
    shared: bool,

    pub fn deinit(self: *GetResult) void {
        // if the result is shared, don't deinit.
        if (self.shared) {
            return;
        }
        self.buffer_pool.release(self.buffer);
    }

    pub fn src(self: *const GetResult) []const u8 {
        return self.buffer.items;
    }
};

// Parses data:[<media-type>][;base64],<data>
fn parseDataURI(allocator: Allocator, src: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, src, "data:")) {
        return null;
    }

    const uri = src[5..];
    const data_starts = std.mem.indexOfScalar(u8, uri, ',') orelse return null;

    var data = uri[data_starts + 1 ..];

    // Extract the encoding.
    const metadata = uri[0..data_starts];
    if (std.mem.endsWith(u8, metadata, ";base64")) {
        const decoder = std.base64.standard.Decoder;
        const decoded_size = try decoder.calcSizeForSlice(data);

        const buffer = try allocator.alloc(u8, decoded_size);
        errdefer allocator.free(buffer);

        try decoder.decode(buffer, data);
        data = buffer;
    }

    return data;
}

const testing = @import("../testing.zig");
test "DataURI: parse valid" {
    try assertValidDataURI("data:text/javascript; charset=utf-8;base64,Zm9v", "foo");
    try assertValidDataURI("data:text/javascript; charset=utf-8;,foo", "foo");
    try assertValidDataURI("data:,foo", "foo");
}

test "DataURI: parse invalid" {
    try assertInvalidDataURI("atad:,foo");
    try assertInvalidDataURI("data:foo");
    try assertInvalidDataURI("data:");
}

fn assertValidDataURI(uri: []const u8, expected: []const u8) !void {
    defer testing.reset();
    const data_uri = try parseDataURI(testing.arena_allocator, uri) orelse return error.TestFailed;
    try testing.expectEqual(expected, data_uri);
}

fn assertInvalidDataURI(uri: []const u8) !void {
    try testing.expectEqual(null, parseDataURI(undefined, uri));
}
