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

const HttpClient = @import("HttpClient.zig");

const js = @import("js/js.zig");
const URL = @import("URL.zig");
const Frame = @import("Frame.zig");
const ScriptManagerBase = @import("ScriptManagerBase.zig");

const Element = @import("webapi/Element.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

const ScriptManager = @This();

// Re-exports so Frame / Context callers don't need to import Base directly.
pub const Script = ScriptManagerBase.Script;
pub const ModuleSource = ScriptManagerBase.ModuleSource;

base: ScriptManagerBase,
frame: *Frame,

// have we notified the frame that all scripts are loaded (used to fire the
// "load" event).
frame_notified_of_completion: bool,

// scripts loaded based on a <link rel=preload as=script href=...> found during parsing
preloaded_scripts: std.StringHashMapUnmanaged(PreloadedScript),

pub fn init(allocator: Allocator, http_client: *HttpClient, frame: *Frame) ScriptManager {
    var base = ScriptManagerBase.init(allocator, http_client, .{ .frame = frame });
    base.tail_hook = tailHook;
    return .{
        .base = base,
        .frame = frame,
        .preloaded_scripts = .empty,
        .frame_notified_of_completion = false,
    };
}

pub fn deinit(self: *ScriptManager) void {
    self.freePreloads();
    self.base.deinit();
    self.preloaded_scripts.deinit(self.base.allocator);
}

pub fn reset(self: *ScriptManager) void {
    self.freePreloads();
    self.preloaded_scripts.clearRetainingCapacity();
    self.base.reset();
    self.frame_notified_of_completion = false;
}

// Frees every preloaded Script
fn freePreloads(self: *ScriptManager) void {
    var it = self.preloaded_scripts.valueIterator();
    while (it.next()) |preload_script| {
        preload_script.deinit();
    }
}

// Frame wrapper uses this to fire documentIsLoaded and scriptsCompletedLoading
// once Base has finished processing its ready / defer queues.
pub fn tailHook(base: *ScriptManagerBase) void {
    const self: *ScriptManager = @fieldParentPtr("base", base);
    const frame = self.frame;

    // When all scripts (normal and deferred) are done loading, the document
    // state changes (this ultimately triggers the DOMContentLoaded event).
    // Page makes this safe to call multiple times.
    frame.documentIsLoaded();

    if (base.async_scripts.first == null and self.frame_notified_of_completion == false) {
        self.frame_notified_of_completion = true;
        frame.scriptsCompletedLoading();
    }
}

fn getHeaders(self: *ScriptManager) !HttpClient.Headers {
    return self.base.getHeaders();
}

// Returns true when a fetch was started: the link's load/error event fires
// when the fetch settles. false (duplicate hint) = no event will fire.
pub fn preloadScript(self: *ScriptManager, element: *Element.Html, url: []const u8) !bool {
    if (self.preloaded_scripts.contains(url)) {
        return false;
    }

    const frame = self.frame;
    const arena = try frame.getArena(.large, "SM.preloadScript");
    errdefer frame.releaseArena(arena);

    const owned_url = try arena.dupeZ(u8, url);

    const script = try arena.create(Script);
    script.* = .{
        .arena = arena,
        .url = owned_url,
        .node = .{},
        .manager = &self.base,
        .complete = false,
        .source = .{ .remote = .{} },
        .extra = .preload,
        .hint_element = element,
    };

    try self.preloaded_scripts.putNoClobber(self.base.allocator, owned_url, .{ .state = .{ .loading = script } });
    errdefer _ = self.preloaded_scripts.remove(owned_url);

    if (comptime IS_DEBUG) {
        log.debug(.http, "script queue", .{ .url = owned_url, .ctx = "preload" });
    }

    try frame.makeRequest(.{
        .ctx = script,
        .url = owned_url,
        .method = .GET,
        .frame_id = frame._frame_id,
        .loader_id = frame._loader_id,
        .headers = try self.base.getHeaders(),
        .cookie_jar = &frame._session.cookie_jar,
        .cookie_origin = frame.url,
        .resource_type = .script,
        .notification = frame._session.notification,
        .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
        .header_callback = Script.headerCallback,
        .data_callback = Script.dataCallback,
        .done_callback = PreloadedScript.doneCallback,
        .error_callback = PreloadedScript.errorCallback,
        .shutdown_callback = PreloadedScript.shutdownCallback,
    });
    return true;
}

fn waitForPreload(self: *ScriptManager, url: [:0]const u8) ?*Script {
    if (self.preloaded_scripts.getPtr(url) == null) {
        return null;
    }

    const was_evaluating = self.base.is_evaluating;
    self.base.is_evaluating = true;
    defer self.base.endEvaluationWindow(was_evaluating);

    var client = self.base.client;
    while (true) {
        const entry = self.preloaded_scripts.getPtr(url) orelse return null;
        switch (entry.state) {
            .loading => {
                _ = client.tick(200, .sync_wait) catch return null;
                continue;
            },
            .done => |script| {
                // Preload scripts are single-use. We return it and it becomes
                // the caller's responsibility to free.
                _ = self.preloaded_scripts.remove(url);
                return script;
            },
        }
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

    const element = script_element.asElement();
    if (element.getAttributeSafe(comptime .wrap("nomodule")) != null) {
        // these scripts should only be loaded if we don't support modules
        // but since we do support modules, we can just skip them.
        return;
    }

    const kind: Script.Extra.FrameExtra.Kind = blk: {
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
    const frame = self.frame;

    // A consumed preload (waitForPreload below) is owned by us: its buffer is
    // borrowed by `script`, so it must outlive eval.
    var consumed_preload: ?*Script = null;
    defer if (consumed_preload) |p| {
        p.deinit();
    };

    const arena = try frame.getArena(.large, "SM.addFromElement");
    errdefer if (!handover) {
        frame.releaseArena(arena);
    };

    var source: Script.Source = undefined;
    var remote_url: ?[:0]const u8 = null;
    const base_url = frame.base();
    if (element.getAttributeSafe(comptime .wrap("src"))) |src| {
        // data: and blob: srcs flow through the normal request path; HttpClient
        // synthesizes the response. Execution mode (blocking vs async/defer) is
        // attribute-driven, the same as any other src.
        remote_url = try URL.resolve(arena, base_url, src, .{ .encoding = frame.charset });
        source = .{ .remote = .{} };
    } else {
        var buf = std.Io.Writer.Allocating.init(arena);
        try element.asNode().getChildTextContent(&buf.writer);
        try buf.writer.writeByte(0);
        const data = buf.written();
        const inline_source: [:0]const u8 = data[0 .. data.len - 1 :0];
        if (inline_source.len == 0) {
            // we haven't set script_element._executed = true yet, which is good.
            // If content is appended to the script, we will execute it then.
            frame.releaseArena(arena);
            return;
        }
        source = .{ .@"inline" = inline_source };
    }

    // Only set _executed (already-started) when we actually have content to execute
    script_element._executed = true;
    const is_inline = source == .@"inline";

    const mode: Script.Extra.FrameExtra.Mode = blk: {
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
    };

    const script = try arena.create(Script);
    script.* = .{
        .node = .{},
        .arena = arena,
        .manager = &self.base,
        .source = source,
        .complete = is_inline,
        .status = if (is_inline) 200 else 0,
        .url = remote_url orelse base_url,
        .extra = .{ .frame = .{
            .kind = kind,
            .mode = mode,
            .script_element = script_element,
            .frame = frame,
        } },
    };

    const is_blocking = mode == .normal;

    // Once parsing is done, the deferred-script batch has already drained and
    // won't run again, so a non-blocking script inserted afterwards would go
    // unprocessed. Run it immediately instead. Remote scripts still need to
    // be queued so they execute when their fetch completes.
    const run_immediately = is_blocking or (self.base.static_scripts_done and remote_url == null);
    if (run_immediately == false) {
        self.base.scriptList(script).append(&script.node);
    }

    if (remote_url) |url| {
        if (comptime IS_DEBUG) {
            var ls: js.Local.Scope = undefined;
            frame.js.localScope(&ls);
            defer ls.deinit();

            log.debug(.http, "script queue", .{
                .ctx = ctx,
                .url = remote_url.?,
                .element = element,
                .stack = ls.local.stackTrace() catch "???",
            });
        }

        const was_evaluating = self.base.is_evaluating;
        self.base.is_evaluating = true;
        defer self.base.endEvaluationWindow(was_evaluating);

        if (is_blocking) {
            if (self.waitForPreload(url)) |pre| {
                // There was a preloaded script, we borrow it's source and status
                consumed_preload = pre;
                script.source = pre.source;
                script.status = pre.status;
                script.complete = true;
            } else {
                const response = try self.base.client.syncRequest(arena, .{
                    .url = url,
                    .method = .GET,
                    .frame_id = frame._frame_id,
                    .loader_id = frame._loader_id,
                    .headers = try self.getHeaders(),
                    .cookie_jar = &frame._session.cookie_jar,
                    .cookie_origin = frame.url,
                    .resource_type = .script,
                    .notification = frame._session.notification,
                });

                script.source = .{ .remote = response.body };
                script.status = response.status;
                script.complete = true;
            }
        } else {
            errdefer {
                self.base.scriptList(script).remove(&script.node);
                // Let the outer errdefer handle releasing the arena if client.request fails
            }

            try frame.makeRequest(.{
                .ctx = script,
                .url = url,
                .method = .GET,
                .frame_id = frame._frame_id,
                .loader_id = frame._loader_id,
                .headers = try self.getHeaders(),
                .cookie_jar = &frame._session.cookie_jar,
                .cookie_origin = frame.url,
                .resource_type = .script,
                .notification = frame._session.notification,
                .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
                .header_callback = Script.headerCallback,
                .data_callback = Script.dataCallback,
                .done_callback = Script.doneCallback,
                .error_callback = Script.errorCallback,
            });
        }

        handover = true;
    }

    if (run_immediately == false) {
        return;
    }

    // This will flush any deferred scripts.
    defer self.base.client.deferring_layer.flushFrame(self.base.owner.frameId());

    if (script.status < 200 or script.status > 299) {
        log.info(.http, "script load error", .{ .status = script.status });
        script.executeCallback(comptime .wrap("error"));
        script.deinit();
        return;
    }

    // could have already been evaluating if this is dynamically added
    const was_evaluating = self.base.is_evaluating;
    self.base.is_evaluating = true;
    defer {
        script.deinit();
        self.base.endEvaluationWindow(was_evaluating);
    }

    script.eval();
}

pub fn staticScriptsDone(self: *ScriptManager) void {
    self.base.staticScriptsDone();
}

const PreloadedScript = struct {
    state: State,

    const State = union(enum) {
        loading: *Script,
        done: *Script,
    };

    pub fn deinit(self: PreloadedScript) void {
        switch (self.state) {
            inline else => |script| script.deinit(),
        }
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const script: *Script = @ptrCast(@alignCast(ctx));
        script.complete = true;
        if (comptime IS_DEBUG) {
            log.debug(.http, "script fetch complete", .{ .req = script.url });
        }

        const self: *ScriptManager = @fieldParentPtr("base", script.manager);
        self.preloaded_scripts.getPtr(script.url).?.state = .{ .done = script };
        script.queueHintEvent(.load);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const script: *Script = @ptrCast(@alignCast(ctx));
        if (script.status == 404) {
            log.info(.http, "script 404", .{ .req = script.url, .extra = "preload" });
        } else {
            log.warn(.http, "script fetch error", .{ .err = err, .req = script.url, .extra = "preload", .status = script.status });
        }

        const self: *ScriptManager = @fieldParentPtr("base", script.manager);
        _ = self.preloaded_scripts.remove(script.url);
        script.queueHintEvent(.@"error");
        script.deinit();
    }

    // Owner-driven teardown killed this preload fetch via Transfer.kill, which
    // fires shutdown_callback — not error_callback. Drop the entry (so a
    // synchronous waitForPreload's getPtr returns null and it falls back to a
    // normal fetch) and free the Script. No JS / hint events here, unlike
    // errorCallback, since the owner is being torn down.
    fn shutdownCallback(ctx: *anyopaque) void {
        const script: *Script = @ptrCast(@alignCast(ctx));
        const self: *ScriptManager = @fieldParentPtr("base", script.manager);
        _ = self.preloaded_scripts.remove(script.url);
        script.deinit();
    }
};

const testing = @import("../testing.zig");

test "ScriptManager: PreloadedScript.shutdownCallback drops a .loading preload" {
    defer testing.reset();
    const frame = try testing.pageTest("mcp_nav.html", .{});
    defer frame._session.removePage();

    const sm = &frame._script_manager;
    const url: [:0]const u8 = "http://127.0.0.1:9582/killed-preload.js";

    // Build a `.loading` preload entry directly (mirroring preloadScript) so the
    // test doesn't depend on the network. shutdownCallback frees the Script.
    const arena = try frame.getArena(.large, "test.shutdown");
    const script = try arena.create(Script);
    script.* = .{
        .arena = arena,
        .url = url,
        .node = .{},
        .manager = &sm.base,
        .complete = false,
        .source = .{ .remote = .{} },
        .extra = .preload,
        .hint_element = null,
    };
    try sm.preloaded_scripts.put(sm.base.allocator, url, .{ .state = .{ .loading = script } });

    // Transfer.kill fires this on owner teardown. The entry must be dropped so a
    // synchronous waitForPreload's getPtr returns null and it falls back.
    PreloadedScript.shutdownCallback(script);

    try testing.expect(sm.preloaded_scripts.getPtr(url) == null);
}
