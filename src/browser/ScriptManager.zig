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
const lp = @import("lightpanda");
const builtin = @import("builtin");

const log = @import("../log.zig");
const HttpClient = @import("HttpClient.zig");
const net_http = @import("../network/http.zig");
const String = @import("../string.zig").String;

const js = @import("js/js.zig");
const URL = @import("URL.zig");
const Page = @import("Page.zig");

const Element = @import("webapi/Element.zig");

const Allocator = std.mem.Allocator;

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

client: *HttpClient,
allocator: Allocator,

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

// have we notified the page that all scripts are loaded (used to fire the "load"
// event).
page_notified_of_completion: bool,

pub fn init(allocator: Allocator, http_client: *HttpClient, page: *Page) ScriptManager {
    return .{
        .page = page,
        .async_scripts = .{},
        .defer_scripts = .{},
        .ready_scripts = .{},
        .importmap = .empty,
        .is_evaluating = false,
        .allocator = allocator,
        .imported_modules = .empty,
        .client = http_client,
        .static_scripts_done = false,
        .page_notified_of_completion = false,
    };
}

pub fn deinit(self: *ScriptManager) void {
    // necessary to free any arenas scripts may be referencing
    self.reset();

    self.imported_modules.deinit(self.allocator);
    // we don't deinit self.importmap b/c we use the page's arena for its
    // allocations.
}

pub fn reset(self: *ScriptManager) void {
    var it = self.imported_modules.valueIterator();
    while (it.next()) |value_ptr| {
        switch (value_ptr.state) {
            .done => |script| script.deinit(),
            else => {},
        }
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
        script.deinit();
    }
}

fn getHeaders(self: *ScriptManager) !net_http.Headers {
    var headers = try self.client.newHeaders();
    try self.page.headersForRequest(&headers);
    return headers;
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

    const element = script_element.asElement();
    if (element.getAttributeSafe(comptime .wrap("nomodule")) != null) {
        // these scripts should only be loaded if we don't support modules
        // but since we do support modules, we can just skip them.
        return;
    }

    const kind: Script.Kind = blk: {
        const script_type = element.getAttributeSafe(comptime .wrap("type")) orelse break :blk .javascript;
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

    var handover = false;
    const page = self.page;

    const arena = try page.getArena(.{ .debug = "addFromElement" });
    errdefer if (!handover) {
        page.releaseArena(arena);
    };

    var source: Script.Source = undefined;
    var remote_url: ?[:0]const u8 = null;
    const base_url = page.base();
    if (element.getAttributeSafe(comptime .wrap("src"))) |src| {
        if (try parseDataURI(arena, src)) |data_uri| {
            source = .{ .@"inline" = data_uri };
        } else {
            remote_url = try URL.resolve(arena, base_url, src, .{});
            source = .{ .remote = .{} };
        }
    } else {
        var buf = std.Io.Writer.Allocating.init(arena);
        try element.asNode().getChildTextContent(&buf.writer);
        try buf.writer.writeByte(0);
        const data = buf.written();
        const inline_source: [:0]const u8 = data[0 .. data.len - 1 :0];
        if (inline_source.len == 0) {
            // we haven't set script_element._executed = true yet, which is good.
            // If content is appended to the script, we will execute it then.
            page.releaseArena(arena);
            return;
        }
        source = .{ .@"inline" = inline_source };
    }

    // Only set _executed (already-started) when we actually have content to execute
    script_element._executed = true;
    const is_inline = source == .@"inline";

    const script = try arena.create(Script);
    script.* = .{
        .kind = kind,
        .node = .{},
        .arena = arena,
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

            if (element.getAttributeSafe(comptime .wrap("async")) != null) {
                break :blk .async;
            }

            // Check for defer or module (before checking dynamic script default)
            if (kind == .module or element.getAttributeSafe(comptime .wrap("defer")) != null) {
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
            // Let the outer errdefer handle releasing the arena if client.request fails
        }

        try self.client.request(.{
            .url = url,
            .ctx = script,
            .method = .GET,
            .frame_id = page._frame_id,
            .headers = try self.getHeaders(),
            .blocking = is_blocking,
            .cookie_jar = &page._session.cookie_jar,
            .cookie_origin = page.url,
            .resource_type = .script,
            .notification = page._session.notification,
            .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
            .header_callback = Script.headerCallback,
            .data_callback = Script.dataCallback,
            .done_callback = Script.doneCallback,
            .error_callback = Script.errorCallback,
        });
        handover = true;

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
            script.deinit();
            return;
        }

        // could have already been evaluating if this is dynamically added
        const was_evaluating = self.is_evaluating;
        self.is_evaluating = true;
        defer {
            self.is_evaluating = was_evaluating;
            script.deinit();
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

    const page = self.page;
    const arena = try page.getArena(.{ .debug = "preloadImport" });
    errdefer page.releaseArena(arena);

    const script = try arena.create(Script);
    script.* = .{
        .kind = .module,
        .arena = arena,
        .url = url,
        .node = .{},
        .manager = self,
        .complete = false,
        .script_element = null,
        .source = .{ .remote = .{} },
        .mode = .import,
    };

    gop.value_ptr.* = ImportedModule{};

    if (comptime IS_DEBUG) {
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        log.debug(.http, "script queue", .{
            .url = url,
            .ctx = "module",
            .referrer = referrer,
            .stack = ls.local.stackTrace() catch "???",
        });
    }

    // This seems wrong since we're not dealing with an async import (unlike
    // getAsyncModule below), but all we're trying to do here is pre-load the
    // script for execution at some point in the future (when waitForImport is
    // called).
    self.async_scripts.append(&script.node);

    self.client.request(.{
        .url = url,
        .ctx = script,
        .method = .GET,
        .frame_id = page._frame_id,
        .headers = try self.getHeaders(),
        .cookie_jar = &page._session.cookie_jar,
        .cookie_origin = page.url,
        .resource_type = .script,
        .notification = page._session.notification,
        .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
        .header_callback = Script.headerCallback,
        .data_callback = Script.dataCallback,
        .done_callback = Script.doneCallback,
        .error_callback = Script.errorCallback,
    }) catch |err| {
        self.async_scripts.remove(&script.node);
        return err;
    };
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
            .done => |script| {
                var shared = false;
                const buffer = entry.value_ptr.buffer;
                const waiters = entry.value_ptr.waiters;

                if (waiters == 1) {
                    self.imported_modules.removeByPtr(entry.key_ptr);
                } else {
                    shared = true;
                    entry.value_ptr.waiters = waiters - 1;
                }
                return .{
                    .buffer = buffer,
                    .shared = shared,
                    .script = script,
                };
            },
            .err => return error.Failed,
        }
    }
}

pub fn getAsyncImport(self: *ScriptManager, url: [:0]const u8, cb: ImportAsync.Callback, cb_data: *anyopaque, referrer: []const u8) !void {
    const page = self.page;
    const arena = try page.getArena(.{ .debug = "getAsyncImport" });
    errdefer page.releaseArena(arena);

    const script = try arena.create(Script);
    script.* = .{
        .kind = .module,
        .arena = arena,
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

    if (comptime IS_DEBUG) {
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
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

    self.async_scripts.append(&script.node);
    self.client.request(.{
        .url = url,
        .method = .GET,
        .frame_id = page._frame_id,
        .headers = try self.getHeaders(),
        .ctx = script,
        .resource_type = .script,
        .cookie_jar = &page._session.cookie_jar,
        .cookie_origin = page.url,
        .notification = page._session.notification,
        .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
        .header_callback = Script.headerCallback,
        .data_callback = Script.dataCallback,
        .done_callback = Script.doneCallback,
        .error_callback = Script.errorCallback,
    }) catch |err| {
        self.async_scripts.remove(&script.node);
        return err;
    };
}

// Called from the Page to let us know it's done parsing the HTML. Necessary that
// we know this so that we know that we can start evaluating deferred scripts.
pub fn staticScriptsDone(self: *ScriptManager) void {
    lp.assert(self.static_scripts_done == false, "ScriptManager.staticScriptsDone", .{});
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
                defer script.deinit();
                script.eval(page);
            },
            .import_async => |ia| {
                if (script.status < 200 or script.status > 299) {
                    script.deinit();
                    ia.callback(ia.data, error.FailedToLoad);
                } else {
                    ia.callback(ia.data, .{
                        .shared = false,
                        .script = script,
                        .buffer = script.source.remote,
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
            script.deinit();
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

    if (self.async_scripts.first == null and self.page_notified_of_completion == false) {
        self.page_notified_of_completion = true;
        page.scriptsCompletedLoading();
    }
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
    kind: Kind,
    complete: bool,
    status: u16 = 0,
    source: Source,
    url: []const u8,
    arena: Allocator,
    mode: ExecutionMode,
    node: std.DoublyLinkedList.Node,
    script_element: ?*Element.Html.Script,
    manager: *ScriptManager,

    // for debugging a rare production issue
    header_callback_called: bool = false,

    // for debugging a rare production issue
    debug_transfer_id: u32 = 0,
    debug_transfer_tries: u8 = 0,
    debug_transfer_aborted: bool = false,
    debug_transfer_bytes_received: usize = 0,
    debug_transfer_notified_fail: bool = false,
    debug_transfer_intercept_state: u8 = 0,
    debug_transfer_auth_challenge: bool = false,
    debug_transfer_easy_id: usize = 0,

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
        remote: std.ArrayList(u8),

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

    fn deinit(self: *Script) void {
        self.manager.page.releaseArena(self.arena);
    }

    fn startCallback(transfer: *HttpClient.Transfer) !void {
        log.debug(.http, "script fetch start", .{ .req = transfer });
    }

    fn headerCallback(transfer: *HttpClient.Transfer) !bool {
        const self: *Script = @ptrCast(@alignCast(transfer.ctx));
        const header = &transfer.response_header.?;
        self.status = header.status;
        if (header.status != 200) {
            log.info(.http, "script header", .{
                .req = transfer,
                .status = header.status,
                .content_type = header.contentType(),
            });
            return false;
        }

        if (comptime IS_DEBUG) {
            log.debug(.http, "script header", .{
                .req = transfer,
                .status = header.status,
                .content_type = header.contentType(),
            });
        }

        {
            // temp debug, trying to figure out why the next assert sometimes
            // fails. Is the buffer just corrupt or is headerCallback really
            // being called twice?
            lp.assert(self.header_callback_called == false, "ScriptManager.Header recall", .{
                .m = @tagName(std.meta.activeTag(self.mode)),
                .a1 = self.debug_transfer_id,
                .a2 = self.debug_transfer_tries,
                .a3 = self.debug_transfer_aborted,
                .a4 = self.debug_transfer_bytes_received,
                .a5 = self.debug_transfer_notified_fail,
                .a7 = self.debug_transfer_intercept_state,
                .a8 = self.debug_transfer_auth_challenge,
                .a9 = self.debug_transfer_easy_id,
                .b1 = transfer.id,
                .b2 = transfer._tries,
                .b3 = transfer.aborted,
                .b4 = transfer.bytes_received,
                .b5 = transfer._notified_fail,
                .b7 = @intFromEnum(transfer._intercept_state),
                .b8 = transfer._auth_challenge != null,
                .b9 = if (transfer._conn) |c| @intFromPtr(c._easy) else 0,
            });
            self.header_callback_called = true;
            self.debug_transfer_id = transfer.id;
            self.debug_transfer_tries = transfer._tries;
            self.debug_transfer_aborted = transfer.aborted;
            self.debug_transfer_bytes_received = transfer.bytes_received;
            self.debug_transfer_notified_fail = transfer._notified_fail;
            self.debug_transfer_intercept_state = @intFromEnum(transfer._intercept_state);
            self.debug_transfer_auth_challenge = transfer._auth_challenge != null;
            self.debug_transfer_easy_id = if (transfer._conn) |c| @intFromPtr(c._easy) else 0;
        }

        lp.assert(self.source.remote.capacity == 0, "ScriptManager.Header buffer", .{ .capacity = self.source.remote.capacity });
        var buffer: std.ArrayList(u8) = .empty;
        if (transfer.getContentLength()) |cl| {
            try buffer.ensureTotalCapacity(self.arena, cl);
        }
        self.source = .{ .remote = buffer };
        return true;
    }

    fn dataCallback(transfer: *HttpClient.Transfer, data: []const u8) !void {
        const self: *Script = @ptrCast(@alignCast(transfer.ctx));
        self._dataCallback(transfer, data) catch |err| {
            log.err(.http, "SM.dataCallback", .{ .err = err, .transfer = transfer, .len = data.len });
            return err;
        };
    }
    fn _dataCallback(self: *Script, _: *HttpClient.Transfer, data: []const u8) !void {
        try self.source.remote.appendSlice(self.arena, data);
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
            entry.state = .{ .done = self };
            entry.buffer = self.source.remote;
        }
        manager.evaluate();
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *Script = @ptrCast(@alignCast(ctx));
        log.warn(.http, "script fetch error", .{
            .err = err,
            .req = self.url,
            .mode = std.meta.activeTag(self.mode),
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
            self.deinit();
            return;
        }

        switch (self.mode) {
            .import_async => |ia| ia.callback(ia.data, error.FailedToLoad),
            .import => {
                const entry = manager.imported_modules.getPtr(self.url).?;
                entry.state = .err;
            },
            else => {},
        }
        self.deinit();
        manager.evaluate();
    }

    fn eval(self: *Script, page: *Page) void {
        // never evaluated, source is passed back to v8, via callbacks.
        if (comptime IS_DEBUG) {
            std.debug.assert(self.mode != .import_async);

            // never evaluated, source is passed back to v8 when asked for it.
            std.debug.assert(self.mode != .import);
        }

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
                self.executeCallback(comptime .wrap("error"), page);
                return;
            };
            self.executeCallback(comptime .wrap("load"), page);
            return;
        }

        defer page._event_manager.clearIgnoreList();

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
            log.debug(.browser, "executed script", .{ .src = url, .success = success });
        }

        defer {
            local.runMacrotasks(); // also runs microtasks
            _ = page.js.scheduler.run() catch |err| {
                log.err(.page, "scheduler", .{ .err = err });
            };
        }

        if (success) {
            self.executeCallback(comptime .wrap("load"), page);
            return;
        }

        const caught = try_catch.caughtOrError(page.call_arena, error.Unknown);
        log.warn(.js, "eval script", .{
            .url = url,
            .caught = caught,
            .cacheable = cacheable,
        });

        self.executeCallback(comptime .wrap("error"), page);
    }

    fn executeCallback(self: *const Script, typ: String, page: *Page) void {
        const Event = @import("webapi/Event.zig");
        const event = Event.initTrusted(typ, .{}, page) catch |err| {
            log.warn(.js, "script internal callback", .{
                .url = self.url,
                .type = typ,
                .err = err,
            });
            return;
        };
        page._event_manager.dispatchOpts(self.script_element.?.asNode().asEventTarget(), event, .{ .apply_ignore = true }) catch |err| {
            log.warn(.js, "script callback", .{
                .url = self.url,
                .type = typ,
                .err = err,
            });
        };
    }
};

const ImportAsync = struct {
    data: *anyopaque,
    callback: ImportAsync.Callback,

    pub const Callback = *const fn (ptr: *anyopaque, result: anyerror!ModuleSource) void;
};

pub const ModuleSource = struct {
    shared: bool,
    script: *Script,
    buffer: std.ArrayList(u8),

    pub fn deinit(self: *ModuleSource) void {
        if (self.shared == false) {
            self.script.deinit();
        }
    }

    pub fn src(self: *const ModuleSource) []const u8 {
        return self.buffer.items;
    }
};

const ImportedModule = struct {
    waiters: u16 = 1,
    state: State = .loading,
    buffer: std.ArrayList(u8) = .{},

    const State = union(enum) {
        err,
        loading,
        done: *Script,
    };
};

// Parses data:[<media-type>][;base64],<data>
fn parseDataURI(allocator: Allocator, src: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, src, "data:")) {
        return null;
    }

    const uri = src[5..];
    const data_starts = std.mem.indexOfScalar(u8, uri, ',') orelse return null;
    const data = uri[data_starts + 1 ..];

    const unescaped = try URL.unescape(allocator, data);

    const metadata = uri[0..data_starts];
    if (std.mem.endsWith(u8, metadata, ";base64") == false) {
        return unescaped;
    }

    // Forgiving base64 decode per WHATWG spec:
    // https://infra.spec.whatwg.org/#forgiving-base64-decode
    // Step 1: Remove all ASCII whitespace
    var stripped = try std.ArrayList(u8).initCapacity(allocator, unescaped.len);
    for (unescaped) |c| {
        if (!std.ascii.isWhitespace(c)) {
            stripped.appendAssumeCapacity(c);
        }
    }
    const trimmed = std.mem.trimRight(u8, stripped.items, "=");

    // Length % 4 == 1 is invalid
    if (trimmed.len % 4 == 1) {
        return error.InvalidCharacterError;
    }

    const decoded_size = std.base64.standard_no_pad.Decoder.calcSizeForSlice(trimmed) catch return error.InvalidCharacterError;
    const buffer = try allocator.alloc(u8, decoded_size);
    std.base64.standard_no_pad.Decoder.decode(buffer, trimmed) catch return error.InvalidCharacterError;
    return buffer;
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
