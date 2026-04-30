// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const HttpClient = @import("HttpClient.zig");
const http = @import("../network/http.zig");

const js = @import("js/js.zig");
const URL = @import("URL.zig");
const Session = @import("Session.zig");
const Frame = @import("Frame.zig");
const WorkerGlobalScope = @import("webapi/WorkerGlobalScope.zig");

const Element = @import("webapi/Element.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

const ScriptManagerBase = @This();

// Either a *Frame (for page ScriptManagers) or *WorkerGlobalScope (for workers).
// Used from HTTP callbacks that only have a *Script in hand; the Script reaches
// the owner through its manager pointer.
pub const Owner = union(enum) {
    frame: *Frame,
    worker: *WorkerGlobalScope,

    pub fn url(self: Owner) [:0]const u8 {
        return switch (self) {
            .frame => |f| f.url,
            .worker => |w| w.url,
        };
    }

    pub fn frameId(self: Owner) u32 {
        return switch (self) {
            .frame => |f| f._frame_id,
            .worker => |w| w._worker._frame_id,
        };
    }

    pub fn loaderId(self: Owner) u32 {
        return switch (self) {
            .frame => |f| f._loader_id,
            .worker => |w| w._worker._loader_id,
        };
    }

    pub fn session(self: Owner) *Session {
        return switch (self) {
            .frame => |f| f._session,
            .worker => |w| w._session,
        };
    }

    pub fn jsContext(self: Owner) *js.Context {
        return switch (self) {
            .frame => |f| f.js,
            .worker => |w| w.js,
        };
    }

    pub fn addHeaders(self: Owner, headers: *HttpClient.Headers) !void {
        switch (self) {
            .frame => |f| try f.headersForRequest(headers),
            .worker => {},
        }
    }
};

owner: Owner,

// used to prevent recursive evaluation
is_evaluating: bool,

// Only once this is true can deferred scripts be run
static_scripts_done: bool,

// List of async scripts. We don't care about the execution order of these, but
// on shutdown/abort, we need to cleanup any pending ones. Used for both
// frame-side .async scripts and .import / .import_async modules.
async_scripts: std.DoublyLinkedList,

// List of deferred scripts. These must be executed in order, but only once
// dom_loaded == true. Workers never populate this list.
defer_scripts: std.DoublyLinkedList,

// When an async script is ready, it's queued here.
ready_scripts: std.DoublyLinkedList,

shutdown: bool = false,

client: *HttpClient,
allocator: Allocator,

// See ScriptManager.zig for the type's documentation.
imported_modules: std.StringHashMapUnmanaged(ImportedModule),

// Mapping between module specifier and resolution.
// see https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/script/type/importmap
// For workers this stays empty (only Frame authors importmaps via
// ScriptManager.parseImportmap).
importmap: std.StringHashMapUnmanaged([:0]const u8),

// Called at the end of evaluate() after all Base-owned work has run. Frame
// wrapper uses this to drain defer_scripts and fire documentIsLoaded /
// scriptsCompletedLoading. Null for workers.
tail_hook: ?*const fn (*ScriptManagerBase) void,

pub fn init(allocator: Allocator, http_client: *HttpClient, owner: Owner) ScriptManagerBase {
    return .{
        .owner = owner,
        .async_scripts = .{},
        .defer_scripts = .{},
        .ready_scripts = .{},
        .importmap = .empty,
        .is_evaluating = false,
        .allocator = allocator,
        .imported_modules = .empty,
        .client = http_client,
        .static_scripts_done = false,
        .tail_hook = null,
    };
}

pub fn deinit(self: *ScriptManagerBase) void {
    // necessary to free any arenas scripts may be referencing
    self.reset();

    self.imported_modules.deinit(self.allocator);
    // we don't deinit self.importmap b/c we use the owner's arena for its
    // allocations.
}

pub fn reset(self: *ScriptManagerBase) void {
    var it = self.imported_modules.valueIterator();
    while (it.next()) |value_ptr| {
        switch (value_ptr.state) {
            .done => |script| script.deinit(),
            else => {},
        }
    }
    self.imported_modules.clearRetainingCapacity();

    // The importmap's keys/values were allocated from the owner's arena, which
    // has been reset. Can't use clearAndRetainCapacity — that space is no
    // longer ours.
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

pub fn getHeaders(self: *ScriptManagerBase) !http.Headers {
    var headers = try self.client.newHeaders();
    try self.owner.addHeaders(&headers);
    return headers;
}

fn acquireArena(self: *ScriptManagerBase, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.owner.session().getArena(size_or_bucket, debug);
}

fn releaseArena(self: *ScriptManagerBase, arena: Allocator) void {
    self.owner.session().releaseArena(arena);
}

pub fn scriptList(self: *ScriptManagerBase, script: *const Script) *std.DoublyLinkedList {
    return switch (script.mode) {
        .normal => unreachable, // not added to a list, executed immediately
        .@"defer" => &self.defer_scripts,
        .async, .import_async, .import => &self.async_scripts,
    };
}

// Resolve a module specifier to a valid URL.
pub fn resolveSpecifier(self: *ScriptManagerBase, arena: Allocator, base: [:0]const u8, specifier: [:0]const u8) ![:0]const u8 {
    // If the specifier is mapped in the importmap, return the pre-resolved
    // value. For workers this map is empty.
    if (self.importmap.get(specifier)) |s| {
        return s;
    }

    return URL.resolve(arena, base, specifier, .{ .always_dupe = true });
}

pub fn preloadImport(self: *ScriptManagerBase, url: [:0]const u8, referrer: []const u8) !void {
    const gop = try self.imported_modules.getOrPut(self.allocator, url);
    if (gop.found_existing) {
        gop.value_ptr.waiters += 1;
        return;
    }
    errdefer _ = self.imported_modules.remove(url);

    const arena = try self.acquireArena(.large, "SM.preloadImport");
    errdefer self.releaseArena(arena);

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
        self.owner.jsContext().localScope(&ls);
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

    const session = self.owner.session();
    self.client.request(.{
        .ctx = script,
        .params = .{
            .url = url,
            .method = .GET,
            .frame_id = self.owner.frameId(),
            .loader_id = self.owner.loaderId(),
            .headers = try self.getHeaders(),
            .cookie_jar = &session.cookie_jar,
            .cookie_origin = self.owner.url(),
            .resource_type = .script,
            .notification = session.notification,
        },
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

pub fn waitForImport(self: *ScriptManagerBase, url: [:0]const u8) !ModuleSource {
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

pub fn getAsyncImport(self: *ScriptManagerBase, url: [:0]const u8, cb: ImportAsync.Callback, cb_data: *anyopaque, referrer: []const u8) !void {
    const arena = try self.acquireArena(.large, "SM.getAsyncImport");
    errdefer self.releaseArena(arena);

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
        self.owner.jsContext().localScope(&ls);
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

    const session = self.owner.session();
    self.async_scripts.append(&script.node);
    self.client.request(.{
        .ctx = script,
        .params = .{
            .url = url,
            .method = .GET,
            .frame_id = self.owner.frameId(),
            .loader_id = self.owner.loaderId(),
            .headers = try self.getHeaders(),
            .resource_type = .script,
            .cookie_jar = &session.cookie_jar,
            .cookie_origin = self.owner.url(),
            .notification = session.notification,
        },
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

// Called from the Page / Frame to signal it's done parsing the HTML, so
// deferred scripts can start evaluating. Workers never call this.
pub fn staticScriptsDone(self: *ScriptManagerBase) void {
    lp.assert(self.static_scripts_done == false, "ScriptManagerBase.staticScriptsDone", .{});
    self.static_scripts_done = true;
    self.evaluate();
}

pub fn evaluate(self: *ScriptManagerBase) void {
    if (self.is_evaluating) {
        // It's possible for a script.eval to cause evaluate to be called again.
        return;
    }

    self.is_evaluating = true;
    defer self.is_evaluating = false;

    while (self.ready_scripts.popFirst()) |n| {
        var script: *Script = @fieldParentPtr("node", n);
        switch (script.mode) {
            .async => {
                defer script.deinit();
                // Workers never create .async mode scripts.
                script.eval(self.owner.frame);
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
        if (script.complete == false) return;
        defer {
            _ = self.defer_scripts.popFirst();
            script.deinit();
        }
        // Only Frames populate defer_scripts.
        script.eval(self.owner.frame);
    }

    // Frame wrapper uses this to fire documentIsLoaded and
    // scriptsCompletedLoading. Null for workers.
    if (self.tail_hook) |hook| hook(self);
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
    manager: *ScriptManagerBase,

    // for debugging a rare production issue
    header_callback_called: bool = false,

    // for debugging a rare production issue
    debug_transfer_id: u32 = 0,
    debug_transfer_tries: u8 = 0,
    debug_transfer_aborted: bool = false,
    debug_transfer_bytes_received: usize = 0,
    debug_transfer_notified_fail: bool = false,
    debug_transfer_auth_challenge: bool = false,
    debug_transfer_easy_id: usize = 0,

    pub const Kind = enum {
        module,
        javascript,
        importmap,
    };

    pub const Source = union(enum) {
        @"inline": []const u8,
        remote: std.ArrayList(u8),

        pub fn content(self: Source) []const u8 {
            return switch (self) {
                .remote => |buf| buf.items,
                .@"inline" => |c| c,
            };
        }
    };

    pub const ExecutionMode = union(enum) {
        normal,
        @"defer",
        async,
        import,
        import_async: ImportAsync,
    };

    pub fn deinit(self: *Script) void {
        self.manager.releaseArena(self.arena);
    }

    pub fn startCallback(response: HttpClient.Response) !void {
        log.debug(.http, "script fetch start", .{ .req = response });
    }

    pub fn headerCallback(response: HttpClient.Response) !bool {
        const self: *Script = @ptrCast(@alignCast(response.ctx));

        self.status = response.status().?;
        if (response.status() != 200) {
            log.info(.http, "script header", .{
                .req = response,
                .status = response.status(),
                .content_type = response.contentType(),
            });
            return false;
        }

        if (comptime IS_DEBUG) {
            log.debug(.http, "script header", .{
                .req = response,
                .status = response.status(),
                .content_type = response.contentType(),
            });
        }

        switch (response.inner) {
            .transfer => |transfer| {
                // temp debug, trying to figure out why the next assert sometimes
                // fails. Is the buffer just corrupt or is headerCallback really
                // being called twice?
                lp.assert(self.header_callback_called == false, "ScriptManagerBase.Header recall", .{
                    .m = @tagName(std.meta.activeTag(self.mode)),
                    .a1 = self.debug_transfer_id,
                    .a2 = self.debug_transfer_tries,
                    .a3 = self.debug_transfer_aborted,
                    .a4 = self.debug_transfer_bytes_received,
                    .a5 = self.debug_transfer_notified_fail,
                    .a8 = self.debug_transfer_auth_challenge,
                    .a9 = self.debug_transfer_easy_id,
                    .b1 = transfer.id,
                    .b2 = transfer._tries,
                    .b3 = transfer.aborted,
                    .b4 = transfer.bytes_received,
                    .b5 = transfer._notified_fail,
                    .b8 = transfer._auth_challenge != null,
                    .b9 = if (transfer._conn) |c| @intFromPtr(c._easy) else 0,
                });
                self.header_callback_called = true;
                self.debug_transfer_id = transfer.id;
                self.debug_transfer_tries = transfer._tries;
                self.debug_transfer_aborted = transfer.aborted;
                self.debug_transfer_bytes_received = transfer.bytes_received;
                self.debug_transfer_notified_fail = transfer._notified_fail;
                self.debug_transfer_auth_challenge = transfer._auth_challenge != null;
                self.debug_transfer_easy_id = if (transfer._conn) |c| @intFromPtr(c._easy) else 0;
            },
            else => {},
        }

        lp.assert(self.source.remote.capacity == 0, "ScriptManagerBase.Header buffer", .{ .capacity = self.source.remote.capacity });
        var buffer: std.ArrayList(u8) = .empty;
        if (response.contentLength()) |cl| {
            try buffer.ensureTotalCapacity(self.arena, cl);
        }
        self.source = .{ .remote = buffer };
        return true;
    }

    pub fn dataCallback(response: HttpClient.Response, data: []const u8) !void {
        const self: *Script = @ptrCast(@alignCast(response.ctx));
        self._dataCallback(response, data) catch |err| {
            log.err(.http, "SM.dataCallback", .{ .err = err, .transfer = response, .len = data.len });
            return err;
        };
    }

    fn _dataCallback(self: *Script, _: HttpClient.Response, data: []const u8) !void {
        try self.source.remote.appendSlice(self.arena, data);
    }

    pub fn doneCallback(ctx: *anyopaque) !void {
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

    pub fn errorCallback(ctx: *anyopaque, err: anyerror) void {
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

    pub fn eval(self: *Script, frame: *Frame) void {
        // never evaluated, source is passed back to v8, via callbacks.
        if (comptime IS_DEBUG) {
            std.debug.assert(self.mode != .import_async);

            // never evaluated, source is passed back to v8 when asked for it.
            std.debug.assert(self.mode != .import);
        }

        if (frame.isGoingAway()) {
            // don't evaluate scripts for a dying frame.
            return;
        }

        const script_element = self.script_element.?;

        const previous_script = frame.document._current_script;
        frame.document._current_script = script_element;
        defer frame.document._current_script = previous_script;

        // Clear the document.write insertion point for this script
        const previous_write_insertion_point = frame.document._write_insertion_point;
        frame.document._write_insertion_point = null;
        defer frame.document._write_insertion_point = previous_write_insertion_point;

        // inline scripts aren't cached. remote ones are.
        const cacheable = self.source == .remote;

        const url = self.url;

        log.info(.browser, "executing script", .{
            .src = url,
            .kind = self.kind,
            .cacheable = cacheable,
        });

        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();

        const local = &ls.local;

        // Handle importmap special case here: the content is a JSON containing
        // imports.
        if (self.kind == .importmap) {
            frame._script_manager.parseImportmap(self) catch |err| {
                log.err(.browser, "parse importmap script", .{
                    .err = err,
                    .src = url,
                    .kind = self.kind,
                    .cacheable = cacheable,
                });
                self.executeCallback(comptime .wrap("error"), frame);
                return;
            };
            self.executeCallback(comptime .wrap("load"), frame);
            return;
        }

        defer frame._event_manager.clearIgnoreList();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(local);
        defer try_catch.deinit();

        const success = blk: {
            const content = self.source.content();
            switch (self.kind) {
                .javascript => _ = local.eval(content, url) catch break :blk false,
                .module => {
                    // We don't care about waiting for the evaluation here.
                    frame.js.module(false, local, content, url, cacheable) catch break :blk false;
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
            _ = frame.js.scheduler.run() catch |err| {
                log.err(.frame, "scheduler", .{ .err = err });
            };
        }

        if (success) {
            self.executeCallback(comptime .wrap("load"), frame);
            return;
        }

        const caught = try_catch.caughtOrError(frame.call_arena, error.Unknown);
        log.warn(.js, "eval script", .{
            .url = url,
            .caught = caught,
            .cacheable = cacheable,
        });

        self.executeCallback(comptime .wrap("error"), frame);
    }

    fn executeCallback(self: *const Script, typ: String, frame: *Frame) void {
        const Event = @import("webapi/Event.zig");
        const event = Event.initTrusted(typ, .{}, frame._page) catch |err| {
            log.warn(.js, "script internal callback", .{
                .url = self.url,
                .type = typ,
                .err = err,
            });
            return;
        };
        frame._event_manager.dispatchOpts(self.script_element.?.asNode().asEventTarget(), event, .{ .apply_ignore = true }) catch |err| {
            log.warn(.js, "script callback", .{
                .url = self.url,
                .type = typ,
                .err = err,
            });
        };
    }
};

pub const ImportAsync = struct {
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

pub const ImportedModule = struct {
    waiters: u16 = 1,
    state: State = .loading,
    buffer: std.ArrayList(u8) = .{},

    pub const State = union(enum) {
        err,
        loading,
        done: *Script,
    };
};
