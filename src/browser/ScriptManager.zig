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
async_scripts: std.DoublyLinkedList,

// Normal scripts (non-deferred & non-async). These must be executed in order
normal_scripts: std.DoublyLinkedList,

// List of deferred scripts. These must be executed in order, but only once
// dom_loaded == true,
defer_scripts: std.DoublyLinkedList,

// When an async script is ready, it's queued here. We played with executing
// them as they complete, but it can cause timing issues with v8 module loading.
ready_scripts: std.DoublyLinkedList,

shutdown: bool = false,

client: *Http.Client,
allocator: Allocator,
buffer_pool: BufferPool,

script_pool: std.heap.MemoryPool(Script),

// We can download multiple sync modules in parallel, but we want to process
// them in order. We can't use an std.DoublyLinkedList, like the other script types,
// because the order we load them might not be the order we want to process
// them in (I'm not sure this is true, but as far as I can tell, v8 doesn't
// make any guarantees about the list of sub-module dependencies it gives us
// So this is more like a cache. When an imported module is completed, its
// source is placed here (keyed by the full url) for some point in the future
// when v8 asks for it.
// The type is confusing (too confusing? move to a union). Starts of as `null`
// then transitions to either an error (from errorCalback) or the completed
// buffer from doneCallback
imported_modules: std.StringHashMapUnmanaged(?error{Failed}!std.ArrayList(u8)),

// Mapping between module specifier and resolution.
// see https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script/type/importmap
// importmap contains resolved urls.
importmap: std.StringHashMapUnmanaged([:0]const u8),

pub fn init(browser: *Browser, page: *Page) ScriptManager {
    // page isn't fully initialized, we can setup our reference, but that's it.
    const allocator = browser.allocator;
    return .{
        .page = page,
        .async_scripts = .{},
        .normal_scripts = .{},
        .defer_scripts = .{},
        .ready_scripts = .{},
        .importmap = .empty,
        .is_evaluating = false,
        .allocator = allocator,
        .imported_modules = .empty,
        .client = browser.http_client,
        .static_scripts_done = false,
        .buffer_pool = BufferPool.init(allocator, 5),
        .script_pool = std.heap.MemoryPool(Script).init(allocator),
    };
}

pub fn deinit(self: *ScriptManager) void {
    // necessary to free any buffers scripts may be referencing
    self.reset();

    self.buffer_pool.deinit();
    self.script_pool.deinit();
    self.imported_modules.deinit(self.allocator);
    // we don't deinit self.importmap b/c we use the page's arena for its
    // allocations.
}

pub fn reset(self: *ScriptManager) void {
    {
        var it = self.imported_modules.valueIterator();
        while (it.next()) |value_ptr| {
            // might have not been loaded yet (null)
            const result = value_ptr.* orelse continue;
            // might have loaded an error, in which case there's nothing to free
            var buf = result catch continue;
            buf.deinit(self.allocator);
        }
        self.imported_modules.clearRetainingCapacity();
    }

    // Our allocator is the page arena, it's been reset. We cannot use
    // clearAndRetainCapacity, since that space is no longer ours
    self.importmap = .empty;

    clearList(&self.normal_scripts);
    clearList(&self.defer_scripts);
    clearList(&self.async_scripts);
    clearList(&self.ready_scripts);
    self.static_scripts_done = false;
}

fn clearList(list: *std.DoublyLinkedList) void {
    while (list.popFirst()) |n| {
        const script: *Script = @fieldParentPtr("node", n);
        script.deinit(true);
    }
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

    const script = try self.script_pool.create();
    errdefer self.script_pool.destroy(script);

    script.* = .{
        .kind = kind,
        .node = .{},
        .manager = self,
        .source = source,
        .element = element,
        .complete = source == .@"inline",
        .url = remote_url orelse page.url.raw,
        .mode = blk: {
            if (source == .@"inline") {
                // inline modules are deferred, all other inline scripts have a
                // normal execution flow
                break :blk if (kind == .module) .@"defer" else .normal;
            }
            if (try parser.elementGetAttribute(element, "async") != null) {
                break :blk .async;
            }
            if (try parser.elementGetAttribute(element, "defer") != null) {
                break :blk .@"defer";
            }
            break :blk .normal;
        },
    };

    const list = self.scriptList(script);
    list.append(&script.node);
    errdefer list.remove(&script.node);

    if (remote_url) |url| {
        var headers = try self.client.newHeaders();
        try page.requestCookie(.{}).headersForRequest(page.arena, url, &headers);

        try self.client.request(.{
            .url = url,
            .ctx = script,
            .method = .GET,
            .headers = headers,
            .cookie_jar = page.cookie_jar,
            .resource_type = .script,
            .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
            .header_callback = Script.headerCallback,
            .data_callback = Script.dataCallback,
            .done_callback = Script.doneCallback,
            .error_callback = Script.errorCallback,
        });

        log.debug(.http, "script queue", .{
            .ctx = ctx,
            .url = remote_url.?,
            .stack = page.js.stackTrace() catch "???",
        });
    }
}

fn scriptList(self: *ScriptManager, script: *const Script) *std.DoublyLinkedList {
    return switch (script.mode) {
        .normal => if (script.kind == .module) &self.defer_scripts else &self.normal_scripts,
        .@"defer" => &self.defer_scripts,
        .async, .import_async, .import => &self.async_scripts,
    };
}

// Resolve a module specifier to an valid URL.
pub fn resolveSpecifier(self: *ScriptManager, arena: Allocator, specifier: []const u8, base: []const u8) ![:0]const u8 {
    // If the specifier is mapped in the importmap, return the pre-resolved value.
    if (self.importmap.get(specifier)) |s| {
        return s;
    }

    return URL.stitch(
        arena,
        specifier,
        base,
        .{ .alloc = .if_needed, .null_terminated = true },
    );
}

pub fn preloadImport(self: *ScriptManager, url: [:0]const u8, referrer: []const u8) !void {
    const gop = try self.imported_modules.getOrPut(self.allocator, url);
    if (gop.found_existing) {
        return;
    }
    errdefer _ = self.imported_modules.remove(url);

    const script = try self.script_pool.create();
    errdefer self.script_pool.destroy(script);

    script.* = .{
        .kind = .module,
        .url = url,
        .node = .{},
        .manager = self,
        .element = null,
        .complete = false,
        .source = .{ .remote = .{} },
        .mode = .import,
    };

    gop.value_ptr.* = null;

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
        .ctx = script,
        .method = .GET,
        .headers = headers,
        .cookie_jar = self.page.cookie_jar,
        .resource_type = .script,
        .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
        .header_callback = Script.headerCallback,
        .data_callback = Script.dataCallback,
        .done_callback = Script.doneCallback,
        .error_callback = Script.errorCallback,
    });

    // This seems wrong since we're not dealing with an async import (unlike
    // getAsyncModule below), but all we're trying to do here is pre-load the
    // script for execution at some point in the future (when waitForModule is
    // called).
    self.async_scripts.append(&script.node);
}

pub fn waitForImport(self: *ScriptManager, url: [:0]const u8) !ModuleSource {
    const entry = self.imported_modules.getEntry(url) orelse {
        // It shouldn't be possible for v8 to ask for a module that we didn't
        // `preloadImport` above.
        return error.UnknownModule;
    };

    const was_evaluating = self.is_evaluating;
    self.is_evaluating = true;
    defer self.is_evaluating = was_evaluating;

    var client = self.client;
    while (entry.value_ptr.* == null) {
        // rely on http's timeout settings to avoid an endless/long loop.
        _ = try client.tick(200);
    }

    defer self.imported_modules.removeByPtr(entry.key_ptr);

    // it's possible we stored an error in the map, if so, we'll return it now
    const buf = try (entry.value_ptr.*.?);

    return .{
        .buffer = buf,
        .buffer_pool = &self.buffer_pool,
    };
}

pub fn getAsyncImport(self: *ScriptManager, url: [:0]const u8, cb: ImportAsync.Callback, cb_data: *anyopaque, referrer: []const u8) !void {
    const script = try self.script_pool.create();
    errdefer self.script_pool.destroy(script);

    script.* = .{
        .kind = .module,
        .url = url,
        .node = .{},
        .manager = self,
        .element = null,
        .complete = false,
        .source = .{ .remote = .{} },
        .mode = .{ .import_async = .{
            .callback = cb,
            .data = cb_data,
        } },
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
        .ctx = script,
        .resource_type = .script,
        .cookie_jar = self.page.cookie_jar,
        .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
        .header_callback = Script.headerCallback,
        .data_callback = Script.dataCallback,
        .done_callback = Script.doneCallback,
        .error_callback = Script.errorCallback,
    });

    self.async_scripts.append(&script.node);
}

// Called from the Page to let us know it's done parsing the HTML. Necessary that
// we know this so that we know that we can start evaluating deferred scripts.
pub fn staticScriptsDone(self: *ScriptManager) void {
    std.debug.assert(self.static_scripts_done == false);
    self.static_scripts_done = true;
    self.evaluate();
}

fn evaluate(self: *ScriptManager) void {
    if (self.is_evaluating) {
        // It's possible for a script.eval to cause evaluate to be called again.
        return;
    }

    const page = self.page;
    self.is_evaluating = true;
    defer self.is_evaluating = false;

    while (self.ready_scripts.popFirst()) |n| {
        var script: *Script = @fieldParentPtr("node", n);
        switch (script.mode) {
            .async => {
                defer script.deinit(true);
                script.eval(page);
            },
            .import_async => |ia| {
                defer script.deinit(false);
                ia.callback(ia.data, .{
                    .buffer = script.source.remote,
                    .buffer_pool = &self.buffer_pool,
                });
            },
            else => unreachable, // no other script is put in this list
        }
    }

    while (self.normal_scripts.first) |n| {
        // These need to be processed in-order
        var script: *Script = @fieldParentPtr("node", n);
        if (script.complete == false) {
            return;
        }
        defer {
            _ = self.normal_scripts.popFirst();
            script.deinit(true);
        }
        script.eval(page);
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

    while (self.defer_scripts.first) |n| {
        var script: *Script = @fieldParentPtr("node", n);
        if (script.complete == false) {
            return;
        }
        defer {
            _ = self.defer_scripts.popFirst();
            script.deinit(true);
        }
        script.eval(page);
    }

    // At this point all normal scripts and deferred scripts are done, PLUS
    // the page has signaled that it's done parsing HTML (static_scripts_done == true).
    //

    // When all scripts (normal and deferred) are done loading, the document
    // state changes (this ultimately triggers the DOMContentLoaded event).
    // Page makes this safe to call multiple times.
    page.documentIsLoaded();

    if (self.async_scripts.first == null) {
        // Looks like all async scripts are done too!
        // Page makes this safe to call multiple times.
        page.documentIsComplete();
    }
}

pub fn isDone(self: *const ScriptManager) bool {
    return self.static_scripts_done and // page is done processing initial html
        self.normal_scripts.first == null and // no normal scripts
        self.defer_scripts.first == null and // no deferred scripts
        self.async_scripts.first == null; // no async scripts
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
        const resolved_url = try URL.stitch(
            self.page.arena,
            entry.value_ptr.*,
            self.page.url.raw,
            .{ .alloc = .if_needed, .null_terminated = true },
        );

        try self.importmap.put(self.page.arena, entry.key_ptr.*, resolved_url);
    }
}

const Script = struct {
    complete: bool,
    kind: Kind,
    source: Source,
    url: []const u8,
    mode: ExecutionMode,
    node: std.DoublyLinkedList.Node,
    element: ?*parser.Element,
    manager: *ScriptManager,

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

    const ExecutionMode = union(enum) {
        normal,
        @"defer",
        async,
        import,
        import_async: ImportAsync,
    };

    fn deinit(self: *Script, comptime release_buffer: bool) void {
        if ((comptime release_buffer) and self.source == .remote) {
            self.manager.buffer_pool.release(self.source.remote);
        }
        self.manager.script_pool.destroy(self);
    }

    fn startCallback(transfer: *Http.Transfer) !void {
        log.debug(.http, "script fetch start", .{ .req = transfer });
    }

    fn headerCallback(transfer: *Http.Transfer) !void {
        const self: *Script = @ptrCast(@alignCast(transfer.ctx));
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
        std.debug.assert(self.source.remote.capacity == 0);
        var buffer = self.manager.buffer_pool.get();
        if (transfer.getContentLength()) |cl| {
            try buffer.ensureTotalCapacity(self.manager.allocator, cl);
        }
        self.source = .{ .remote = buffer };
    }

    fn dataCallback(transfer: *Http.Transfer, data: []const u8) !void {
        const self: *Script = @ptrCast(@alignCast(transfer.ctx));
        self._dataCallback(transfer, data) catch |err| {
            log.err(.http, "SM.dataCallback", .{ .err = err, .transfer = transfer, .len = data.len });
            return err;
        };
    }
    fn _dataCallback(self: *Script, _: *Http.Transfer, data: []const u8) !void {
        try self.source.remote.appendSlice(self.manager.allocator, data);
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        self.complete = true;
        log.debug(.http, "script fetch complete", .{ .req = self.url });

        const manager = self.manager;
        if (self.mode == .async or self.mode == .import_async) {
            manager.async_scripts.remove(&self.node);
            manager.ready_scripts.append(&self.node);
        } else if (self.mode == .import) {
            manager.async_scripts.remove(&self.node);
            const entry = manager.imported_modules.getPtr(self.url).?;
            entry.* = self.source.remote;
            self.deinit(false);
        }
        manager.evaluate();
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        log.warn(.http, "script fetch error", .{ .req = self.url, .err = err });

        const manager = self.manager;
        manager.scriptList(self).remove(&self.node);
        if (manager.shutdown) {
            self.deinit(true);
            return;
        }

        if (self.mode == .import) {
            const entry = self.manager.imported_modules.getPtr(self.url).?;
            entry.* = error.Failed;
        }
        self.deinit(true);
        manager.evaluate();
    }

    fn eval(self: *Script, page: *Page) void {
        // never evaluated, source is passed back to v8, via callbacks.
        std.debug.assert(self.mode != .import_async);

        // never evaluated, source is passed back to v8 when asked for it.
        std.debug.assert(self.mode != .import);

        // select.element can only be null for an import_async or an import
        page.setCurrentScript(@ptrCast(self.element.?)) catch |err| {
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

        // Handle importmap special case here: the content is a JSON containing
        // imports.
        if (self.kind == .importmap) {
            page.script_manager.parseImportmap(self) catch |err| {
                log.err(.browser, "parse importmap script", .{
                    .err = err,
                    .src = url,
                    .kind = self.kind,
                    .cacheable = cacheable,
                });
                self.executeCallback("onerror", page);
                return;
            };
            self.executeCallback("onload", page);
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
        const element = self.element.?;
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

const ImportAsync = struct {
    data: *anyopaque,
    callback: ImportAsync.Callback,

    pub const Callback = *const fn (ptr: *anyopaque, result: anyerror!ModuleSource) void;
};

pub const ModuleSource = struct {
    buffer_pool: *BufferPool,
    buffer: std.ArrayListUnmanaged(u8),

    pub fn deinit(self: *ModuleSource) void {
        self.buffer_pool.release(self.buffer);
    }

    pub fn src(self: *const ModuleSource) []const u8 {
        return self.buffer.items;
    }
};
