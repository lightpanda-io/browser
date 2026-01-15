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
async_scripts: std.DoublyLinkedList,

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
imported_modules: std.StringHashMapUnmanaged(ImportedModule),

// Mapping between module specifier and resolution.
// see https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script/type/importmap
// importmap contains resolved urls.
importmap: std.StringHashMapUnmanaged([:0]const u8),

pub fn init(page: *Page) ScriptManager {
    // page isn't fully initialized, we can setup our reference, but that's it.
    const browser = page._session.browser;
    const allocator = browser.allocator;
    return .{
        .page = page,
        .async_scripts = .{},
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
    var it = self.imported_modules.valueIterator();
    while (it.next()) |value_ptr| {
        self.buffer_pool.release(value_ptr.buffer);
    }
    self.imported_modules.clearRetainingCapacity();

    // Our allocator is the page arena, it's been reset. We cannot use
    // clearAndRetainCapacity, since that space is no longer ours
    self.importmap = .empty;

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

pub fn addFromElement(self: *ScriptManager, comptime from_parser: bool, script_element: *Element.Html.Script, comptime ctx: []const u8) !void {
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
    const base_url = page.base();
    if (element.getAttributeSafe("src")) |src| {
        if (try parseDataURI(page.arena, src)) |data_uri| {
            source = .{ .@"inline" = data_uri };
        } else {
            remote_url = try URL.resolve(page.arena, base_url, src, .{});
            source = .{ .remote = .{} };
        }
    } else {
        const inline_source = try element.asNode().getTextContentAlloc(page.arena);
        source = .{ .@"inline" = inline_source };
    }

    const script = try self.script_pool.create();
    errdefer self.script_pool.destroy(script);

    const is_inline = source == .@"inline";

    script.* = .{
        .kind = kind,
        .node = .{},
        .manager = self,
        .source = source,
        .script_element = script_element,
        .complete = is_inline,
        .status = if (is_inline) 200 else 0,
        .url = remote_url orelse base_url,
        .mode = blk: {
            if (source == .@"inline") {
                break :blk if (kind == .module) .@"defer" else .normal;
            }

            if (element.getAttributeSafe("async") != null) {
                break :blk .async;
            }

            // Check for defer or module (before checking dynamic script default)
            if (kind == .module or element.getAttributeSafe("defer") != null) {
                break :blk .@"defer";
            }

            // For dynamically-inserted scripts (not from parser), default to async
            // unless async was explicitly set to false (which removes the attribute)
            // and defer was set to true (checked above)
            if (comptime !from_parser) {
                // Script has src and no explicit async/defer attributes
                // Per HTML spec, dynamically created scripts default to async
                break :blk .async;
            }

            break :blk .normal;
        },
    };

    const is_blocking = script.mode == .normal;
    if (is_blocking == false) {
        self.scriptList(script).append(&script.node);
    }

    if (remote_url) |url| {
        errdefer {
            if (is_blocking == false) {
                self.scriptList(script).remove(&script.node);
            }
            script.deinit(true);
        }

        var headers = try self.client.newHeaders();
        try page.requestCookie(.{}).headersForRequest(page.arena, url, &headers);

        try self.client.request(.{
            .url = url,
            .ctx = script,
            .method = .GET,
            .headers = headers,
            .blocking = is_blocking,
            .cookie_jar = &page._session.cookie_jar,
            .resource_type = .script,
            .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
            .header_callback = Script.headerCallback,
            .data_callback = Script.dataCallback,
            .done_callback = Script.doneCallback,
            .error_callback = Script.errorCallback,
        });

        if (comptime IS_DEBUG) {
            var ls: js.Local.Scope = undefined;
            page.js.localScope(&ls);
            defer ls.deinit();

            log.debug(.http, "script queue", .{
                .ctx = ctx,
                .url = remote_url.?,
                .element = element,
                .stack = ls.local.stackTrace() catch "???",
            });
        }
    }

    if (is_blocking == false) {
        return;
    }

    // this is <script src="..."></script>, it needs to block the caller
    // until it's evaluated
    var client = self.client;
    while (true) {
        if (!script.complete) {
            _ = try client.tick(200);
            continue;
        }
        if (script.status == 0) {
            // an error (that we already logged)
            script.deinit(true);
            return;
        }

        // could have already been evaluating if this is dynamically added
        const was_evaluating = self.is_evaluating;
        self.is_evaluating = true;
        defer {
            self.is_evaluating = was_evaluating;
            script.deinit(true);
        }
        return script.eval(page);
    }
}

fn scriptList(self: *ScriptManager, script: *const Script) *std.DoublyLinkedList {
    return switch (script.mode) {
        .normal => unreachable, // not added to a list, executed immediately
        .@"defer" => &self.defer_scripts,
        .async, .import_async, .import => &self.async_scripts,
    };
}

// Resolve a module specifier to an valid URL.
pub fn resolveSpecifier(self: *ScriptManager, arena: Allocator, base: [:0]const u8, specifier: [:0]const u8) ![:0]const u8 {
    // If the specifier is mapped in the importmap, return the pre-resolved value.
    if (self.importmap.get(specifier)) |s| {
        return s;
    }

    return URL.resolve(arena, base, specifier, .{ .always_dupe = true });
}

pub fn preloadImport(self: *ScriptManager, url: [:0]const u8, referrer: []const u8) !void {
    const gop = try self.imported_modules.getOrPut(self.allocator, url);
    if (gop.found_existing) {
        gop.value_ptr.waiters += 1;
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
        .complete = false,
        .script_element = null,
        .source = .{ .remote = .{} },
        .mode = .import,
    };

    gop.value_ptr.* = ImportedModule{
        .manager = self,
    };

    var headers = try self.client.newHeaders();
    try self.page.requestCookie(.{}).headersForRequest(self.page.arena, url, &headers);

    if (comptime IS_DEBUG) {
        var ls: js.Local.Scope = undefined;
        self.page.js.localScope(&ls);
        defer ls.deinit();

        log.debug(.http, "script queue", .{
            .url = url,
            .ctx = "module",
            .referrer = referrer,
            .stack = ls.local.stackTrace() catch "???",
        });
    }

    try self.client.request(.{
        .url = url,
        .ctx = script,
        .method = .GET,
        .headers = headers,
        .cookie_jar = &self.page._session.cookie_jar,
        .resource_type = .script,
        .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
        .header_callback = Script.headerCallback,
        .data_callback = Script.dataCallback,
        .done_callback = Script.doneCallback,
        .error_callback = Script.errorCallback,
    });

    // This seems wrong since we're not dealing with an async import (unlike
    // getAsyncModule below), but all we're trying to do here is pre-load the
    // script for execution at some point in the future (when waitForImport is
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
    while (true) {
        switch (entry.value_ptr.state) {
            .loading => {
                _ = try client.tick(200);
                continue;
            },
            .done => {
                var shared = false;
                const buffer = entry.value_ptr.buffer;
                const waiters = entry.value_ptr.waiters;

                if (waiters == 0) {
                    self.imported_modules.removeByPtr(entry.key_ptr);
                } else {
                    shared = true;
                    entry.value_ptr.waiters = waiters - 1;
                }
                return .{
                    .buffer = buffer,
                    .shared = shared,
                    .buffer_pool = &self.buffer_pool,
                };
            },
            .err => return error.Failed,
        }
    }
}

pub fn getAsyncImport(self: *ScriptManager, url: [:0]const u8, cb: ImportAsync.Callback, cb_data: *anyopaque, referrer: []const u8) !void {
    const script = try self.script_pool.create();
    errdefer self.script_pool.destroy(script);

    script.* = .{
        .kind = .module,
        .url = url,
        .node = .{},
        .manager = self,
        .complete = false,
        .script_element = null,
        .source = .{ .remote = .{} },
        .mode = .{ .import_async = .{
            .callback = cb,
            .data = cb_data,
        } },
    };

    var headers = try self.client.newHeaders();
    try self.page.requestCookie(.{}).headersForRequest(self.page.arena, url, &headers);

    if (comptime IS_DEBUG) {
        var ls: js.Local.Scope = undefined;
        self.page.js.localScope(&ls);
        defer ls.deinit();

        log.debug(.http, "script queue", .{
            .url = url,
            .ctx = "dynamic module",
            .referrer = referrer,
            .stack = ls.local.stackTrace() catch "???",
        });
    }

    // It's possible, but unlikely, for client.request to immediately finish
    // a request, thus calling our callback. We generally don't want a call
    // from v8 (which is why we're here), to result in a new script evaluation.
    // So we block even the slightest change that `client.request` immediately
    // executes a callback.
    const was_evaluating = self.is_evaluating;
    self.is_evaluating = true;
    defer self.is_evaluating = was_evaluating;

    try self.client.request(.{
        .url = url,
        .method = .GET,
        .headers = headers,
        .ctx = script,
        .resource_type = .script,
        .cookie_jar = &self.page._session.cookie_jar,
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
                if (script.status < 200 or script.status > 299) {
                    ia.callback(ia.data, error.FailedToLoad);
                } else {
                    ia.callback(ia.data, .{
                        .shared = false,
                        .buffer = script.source.remote,
                        .buffer_pool = &self.buffer_pool,
                    });
                }
            },
            else => unreachable, // no other script is put in this list
        }
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
        const resolved_url = try URL.resolve(
            self.page.arena,
            self.page.base(),
            entry.value_ptr.*,
            .{},
        );

        try self.importmap.put(self.page.arena, entry.key_ptr.*, resolved_url);
    }
}

pub const Script = struct {
    complete: bool,
    kind: Kind,
    status: u16 = 0,
    source: Source,
    url: []const u8,
    mode: ExecutionMode,
    node: std.DoublyLinkedList.Node,
    script_element: ?*Element.Html.Script,
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
        self.status = header.status;
        if (header.status != 200) {
            log.info(.http, "script header", .{
                .req = transfer,
                .status = header.status,
                .content_type = header.contentType(),
            });
            return;
        }

        if (comptime IS_DEBUG) {
            log.debug(.http, "script header", .{
                .req = transfer,
                .status = header.status,
                .content_type = header.contentType(),
            });
        }

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
        if (comptime IS_DEBUG) {
            log.debug(.http, "script fetch complete", .{ .req = self.url });
        }

        const manager = self.manager;
        if (self.mode == .async or self.mode == .import_async) {
            manager.async_scripts.remove(&self.node);
            manager.ready_scripts.append(&self.node);
        } else if (self.mode == .import) {
            manager.async_scripts.remove(&self.node);
            const entry = manager.imported_modules.getPtr(self.url).?;
            entry.state = .done;
            entry.buffer = self.source.remote;
            self.deinit(false);
        }
        manager.evaluate();
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        log.warn(.http, "script fetch error", .{
            .err = err,
            .req = self.url,
            .mode = self.mode,
            .kind = self.kind,
            .status = self.status,
        });

        if (self.mode == .normal) {
            // This is blocked in a loop at the end of addFromElement, setting
            // it to complete with a status of 0 will signal the error.
            self.status = 0;
            self.complete = true;
            return;
        }

        const manager = self.manager;
        manager.scriptList(self).remove(&self.node);
        if (manager.shutdown) {
            self.deinit(true);
            return;
        }

        if (self.mode == .import) {
            const entry = self.manager.imported_modules.getPtr(self.url).?;
            entry.state = .err;
        }
        self.deinit(true);
        manager.evaluate();
    }

    fn eval(self: *Script, page: *Page) void {
        // never evaluated, source is passed back to v8, via callbacks.
        std.debug.assert(self.mode != .import_async);

        // never evaluated, source is passed back to v8 when asked for it.
        std.debug.assert(self.mode != .import);

        if (page.isGoingAway()) {
            // don't evaluate scripts for a dying page.
            return;
        }

        const script_element = self.script_element.?;

        const previous_script = page.document._current_script;
        page.document._current_script = script_element;
        defer page.document._current_script = previous_script;

        // Clear the document.write insertion point for this script
        const previous_write_insertion_point = page.document._write_insertion_point;
        page.document._write_insertion_point = null;
        defer page.document._write_insertion_point = previous_write_insertion_point;

        // inline scripts aren't cached. remote ones are.
        const cacheable = self.source == .remote;

        const url = self.url;

        log.info(.browser, "executing script", .{
            .src = url,
            .kind = self.kind,
            .cacheable = cacheable,
        });

        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        const local = &ls.local;

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
                self.executeCallback("error", local.toLocal(script_element._on_error), page);
                return;
            };
            self.executeCallback("load", local.toLocal(script_element._on_load), page);
            return;
        }

        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        const success = blk: {
            const content = self.source.content();
            switch (self.kind) {
                .javascript => _ = local.eval(content, url) catch break :blk false,
                .module => {
                    // We don't care about waiting for the evaluation here.
                    page.js.module(false, local, content, url, cacheable) catch break :blk false;
                },
                .importmap => unreachable, // handled before the try/catch.
            }
            break :blk true;
        };

        if (comptime IS_DEBUG) {
            log.debug(.browser, "executed script", .{ .src = url, .success = success, .on_load = script_element._on_load != null });
        }

        defer {
            // We should run microtasks even if script execution fails.
            page.js.runMicrotasks();
            _ = page.scheduler.run() catch |err| {
                log.err(.page, "scheduler", .{ .err = err });
            };
        }

        if (success) {
            self.executeCallback("load", local.toLocal(script_element._on_load), page);
            return;
        }

        const caught = try_catch.caughtOrError(page.call_arena, error.Unknown);
        log.warn(.js, "eval script", .{
            .url = url,
            .caught = caught,
            .cacheable = cacheable,
        });

        self.executeCallback("error", local.toLocal(script_element._on_error), page);
    }

    fn executeCallback(self: *const Script, comptime typ: []const u8, cb_: ?js.Function, page: *Page) void {
        const cb = cb_ orelse return;

        const Event = @import("webapi/Event.zig");
        const event = Event.initTrusted(typ, .{}, page) catch |err| {
            log.warn(.js, "script internal callback", .{
                .url = self.url,
                .type = typ,
                .err = err,
            });
            return;
        };

        var caught: js.TryCatch.Caught = undefined;
        cb.tryCall(void, .{event}, &caught) catch {
            log.warn(.js, "script callback", .{
                .url = self.url,
                .type = typ,
                .caught = caught,
            });
        };
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
    shared: bool,
    buffer_pool: *BufferPool,
    buffer: std.ArrayList(u8),

    pub fn deinit(self: *ModuleSource) void {
        if (self.shared == false) {
            self.buffer_pool.release(self.buffer);
        }
    }

    pub fn src(self: *const ModuleSource) []const u8 {
        return self.buffer.items;
    }
};

const ImportedModule = struct {
    manager: *ScriptManager,
    state: State = .loading,
    buffer: std.ArrayList(u8) = .{},
    waiters: u16 = 1,

    const State = enum {
        err,
        done,
        loading,
    };
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
