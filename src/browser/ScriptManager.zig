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

pub fn init(allocator: Allocator, http_client: *HttpClient, frame: *Frame) ScriptManager {
    var base = ScriptManagerBase.init(allocator, http_client, .{ .frame = frame });
    base.tail_hook = tailHook;
    return .{
        .frame = frame,
        .base = base,
        .frame_notified_of_completion = false,
    };
}

pub fn deinit(self: *ScriptManager) void {
    self.base.deinit();
}

pub fn reset(self: *ScriptManager) void {
    self.base.reset();
    self.frame_notified_of_completion = false;
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
    const frame = self.frame;

    const arena = try frame.getArena(.large, "SM.addFromElement");
    errdefer if (!handover) {
        frame.releaseArena(arena);
    };

    var source: Script.Source = undefined;
    var remote_url: ?[:0]const u8 = null;
    const base_url = frame.base();
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
            frame.releaseArena(arena);
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
        .manager = &self.base,
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
        defer self.base.is_evaluating = was_evaluating;

        const headers = try self.getHeaders();
        errdefer headers.deinit();

        if (is_blocking) {
            const response = try self.base.client.syncRequest(arena, .{
                .url = url,
                .method = .GET,
                .frame_id = frame._frame_id,
                .loader_id = frame._loader_id,
                .headers = headers,
                .cookie_jar = &frame._session.cookie_jar,
                .cookie_origin = frame.url,
                .resource_type = .script,
                .notification = frame._session.notification,
            });

            script.source = .{ .remote = response.body };
            script.status = response.status;
            script.complete = true;
        } else {
            errdefer {
                self.base.scriptList(script).remove(&script.node);
                // Let the outer errdefer handle releasing the arena if client.request fails
            }

            try self.base.client.request(.{
                .ctx = script,
                .params = .{
                    .url = url,
                    .method = .GET,
                    .frame_id = frame._frame_id,
                    .loader_id = frame._loader_id,
                    .headers = headers,
                    .cookie_jar = &frame._session.cookie_jar,
                    .cookie_origin = frame.url,
                    .resource_type = .script,
                    .notification = frame._session.notification,
                },
                .start_callback = if (log.enabled(.http, .debug)) Script.startCallback else null,
                .header_callback = Script.headerCallback,
                .data_callback = Script.dataCallback,
                .done_callback = Script.doneCallback,
                .error_callback = Script.errorCallback,
            });
        }

        handover = true;
    }

    if (is_blocking == false) {
        return;
    }

    if (script.status == 0) {
        // an error (that we already logged)
        script.deinit();
        return;
    }

    // could have already been evaluating if this is dynamically added
    const was_evaluating = self.base.is_evaluating;
    self.base.is_evaluating = true;
    defer {
        self.base.is_evaluating = was_evaluating;
        script.deinit();
    }

    script.eval(frame);
}

pub fn parseImportmap(self: *ScriptManager, script: *const Script) !void {
    const content = script.source.content();

    const Imports = struct {
        imports: std.json.ArrayHashMap([]const u8),
    };

    const imports = try std.json.parseFromSliceLeaky(
        Imports,
        self.frame.arena,
        content,
        .{ .allocate = .alloc_always },
    );

    var iter = imports.imports.map.iterator();
    while (iter.next()) |entry| {
        // > Relative URLs are resolved to absolute URL addresses using the
        // > base URL of the document containing the import map.
        // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules#importing_modules_using_import_maps
        const resolved_url = try URL.resolve(
            self.frame.arena,
            self.frame.base(),
            entry.value_ptr.*,
            .{},
        );

        try self.base.importmap.put(self.frame.arena, entry.key_ptr.*, resolved_url);
    }
}

pub fn staticScriptsDone(self: *ScriptManager) void {
    self.base.staticScriptsDone();
}

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
