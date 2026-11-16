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

// Speculative fetching: <link rel=preload/modulepreload> hints and the
// pre-parse scan of the raw HTML. All of it only starts downloads early —
// consumption happens in ScriptManager / ScriptManagerBase when the real
// <script> element or import shows up, and in Frame.loadExternalStylesheet
// when the real <link rel=stylesheet> does.

const std = @import("std");
const lp = @import("lightpanda");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Parser = @import("../parser/Parser.zig");
const Element = @import("../webapi/Element.zig");
const HttpClient = @import("../../network/HttpClient.zig");

const log = lp.log;
const Allocator = std.mem.Allocator;

// start prefetching <link rel="preload" as="script" href=...>`. element is the
// hint <link> to fire load/error on, null when the hint came from the prescan.
pub fn scriptHint(frame: *Frame, element: ?*Element.Html, href: []const u8) bool {
    if (frame.isGoingAway() or frame._parse_mode == .fragment) {
        return false;
    }

    const arena = frame.getArena(.small, "preload.scriptHint") catch return false;
    defer arena.release();

    const resolved = URL.resolve(arena.allocator(), frame.base(), href, .{ .encoding = frame.charset }) catch return false;
    if (!URL.isRemoteScheme(resolved)) {
        return false;
    }
    return frame._script_manager.preloadScript(element, resolved) catch false;
}

// start prefetching <link rel="modulepreload" href=...>. element is the hint
// <link> to fire load/error on, null when the hint came from the prescan.
pub fn moduleHint(frame: *Frame, element: ?*Element.Html, href: []const u8) bool {
    if (frame.isGoingAway() or frame._parse_mode == .fragment) {
        return false;
    }

    if (hasNonRemoteScheme(href)) {
        return false;
    }

    // The url becomes the imported_modules key, which must outlive the fetch
    // so it lives on the frame arena
    const resolved = URL.resolve(frame.page_arena, frame.base(), href, .{ .encoding = frame.charset }) catch return false;
    if (!URL.isRemoteScheme(resolved)) {
        return false;
    }

    return frame._script_manager.base.preloadModuleHint(element, resolved, frame.url) catch false;
}

// Scan the HTML for <script src=...> and <link rel=stylesheet href=...> before
// parsing so that we can start fetching them ASAP. The downside is we might
// accidentally fetch more than we should, but the upside can be a pretty
// significant performance improvement. Without this, N large blocking
// resources are downloaded serially. This essentially does the same thing as
// the <link preload/preloadModule> but without needing anything special from
// the HTML.
pub fn prescan(frame: *Frame, html: []const u8) void {
    if (frame.isGoingAway() or frame._parse_mode == .fragment) {
        return;
    }
    const arena = frame.getArena(.small, "preload.prescan") catch return;
    defer arena.release();

    var scan = Prescan{ .frame = frame, .base = frame.base(), .arena = arena.allocator() };
    Parser.prescan(html, frame.charset, &scan, Prescan.callback);
}

const Prescan = struct {
    frame: *Frame,
    arena: Allocator,
    base: [:0]const u8,

    fn callback(ctx: *anyopaque, kind: Parser.PrescanResource, url_ptr: [*c]const u8, url_len: usize) callconv(.c) void {
        const self: *Prescan = @ptrCast(@alignCast(ctx));
        if (url_len == 0) {
            return;
        }
        const href = url_ptr[0..url_len];
        const frame = self.frame;
        switch (kind) {
            .base => {
                self.base = URL.resolve(self.arena, self.base, href, .{ .encoding = frame.charset }) catch return;
            },
            .script => {
                if (hasNonRemoteScheme(href)) {
                    return;
                }
                const resolved = URL.resolve(self.arena, self.base, href, .{ .encoding = frame.charset }) catch return;
                if (URL.isRemoteScheme(resolved) == false) {
                    return;
                }
                _ = frame._script_manager.preloadScript(null, resolved) catch {};
            },
            .module => {
                if (hasNonRemoteScheme(href)) {
                    return;
                }
                // The url becomes the imported_modules key, which must
                // outlive the fetch so it lives on the frame arena.
                const resolved = URL.resolve(frame.page_arena, self.base, href, .{ .encoding = frame.charset }) catch return;
                if (URL.isRemoteScheme(resolved) == false) {
                    return;
                }
                _ = frame._script_manager.base.preloadModuleHint(null, resolved, frame.url) catch {};
            },
            .stylesheet => {
                if (frame._session.load_resources.stylesheet == false or hasNonRemoteScheme(href)) {
                    return;
                }
                Stylesheet.fetch(frame, self.base, href) catch |err| {
                    log.debug(.http, "stylesheet preload", .{ .err = err, .href = href });
                };
            },
            _ => {},
        }
    }
};

// Hands over the response to the stylesheet fetch the prescan started for
// `url`, waiting for it when it's still in flight.
const TakeResult = union(enum) {
    none,
    err: anyerror,
    response: HttpClient.SyncResponse,
};
pub fn takeStylesheet(frame: *Frame, url: []const u8) TakeResult {
    const map = &frame._preloaded_stylesheets;
    const client = &frame._session.browser.http_client;

    var blocked: ?u32 = null;
    defer if (blocked) |frame_id| {
        client.releaseBlocking(frame_id);
    };

    while (true) {
        // The tick below can settle the fetch, look it up each time
        const sheet = map.get(url) orelse return .none;

        switch (sheet.state) {
            .running => {
                if (blocked == null) {
                    client.blockOn(sheet.frame_id, sheet.transfer_id) catch return .none;
                    blocked = sheet.frame_id;
                }
                client.tickSync(200) catch return .none;
            },
            .response => {
                _ = map.remove(url);
                return .{ .response = .{
                    .status = sheet.status,
                    .status_text = .{},
                    .body = sheet.body,
                    .headers = &.{},
                    .content_type = sheet.content_type,
                    .script_cache = null,
                    .arena = sheet.arena,
                    .cross_origin = false,
                } };
            },
            .err => |err| {
                _ = map.remove(url);
                sheet.deinit();
                return .{ .err = err };
            },
        }
    }
}

pub const Stylesheet = struct {
    frame: *Frame,
    arena: *lp.Arena,
    url: [:0]const u8,
    frame_id: u32, // HttpClient.blockOn's key
    transfer_id: u32,
    state: union(enum) { running, response, err: anyerror } = .running,
    status: u16 = 0,
    content_type: ?[]const u8 = null,
    body: HttpClient.Body = .empty,

    fn fetch(frame: *Frame, base: [:0]const u8, href: []const u8) !void {
        const arena = try frame.getArena(.small, "preload.Stylesheet");
        errdefer arena.release();

        const url = try URL.resolve(arena.allocator(), base, href, .{ .encoding = frame.charset });

        const map = &frame._preloaded_stylesheets;
        if (URL.isRemoteScheme(url) == false or map.contains(url)) {
            arena.release();
            return;
        }

        const self = try arena.create(Stylesheet);

        const transfer = try frame.stylesheetRequest(url);
        {
            // `deinit` fires no callback: the errdefer above frees `self`
            errdefer transfer.deinit();
            const req = &transfer.req;
            req.ctx = self;
            req.done_callback = doneCallback;
            req.error_callback = errorCallback;
            req.shutdown_callback = shutdownCallback;
            self.* = .{
                .frame = frame,
                .arena = arena,
                .url = url,
                .frame_id = transfer.req.frame_id,
                .transfer_id = transfer.id,
            };
            try map.put(frame.page_arena, url, self);
        }

        if (comptime lp.IS_DEBUG) {
            log.debug(.http, "stylesheet queue", .{ .url = url, .ctx = "preload" });
        }

        transfer.submit() catch {};
    }

    pub fn deinit(self: *Stylesheet) void {
        self.body.deinit();
        self.arena.release();
    }

    fn doneCallback(transfer: *HttpClient.Transfer) !void {
        const self: *Stylesheet = @ptrCast(@alignCast(transfer.req.ctx));
        if (transfer.contentType()) |content_type| {
            self.content_type = try self.arena.dupe(u8, content_type);
        }
        self.status = transfer.responseStatus() orelse 0;
        self.body = transfer.takeBody();
        self.state = .response;
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *Stylesheet = @ptrCast(@alignCast(ctx));
        log.debug(.http, "stylesheet preload", .{ .err = err, .url = self.url });
        self.state = .{ .err = err };
    }

    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *Stylesheet = @ptrCast(@alignCast(ctx));
        self.drop();
    }

    fn drop(self: *Stylesheet) void {
        _ = self.frame._preloaded_stylesheets.remove(self.url);
        self.deinit();
    }
};

// Non-http(s) scheme (e.g. data:, blob:) never resolve to a remote URL. We
// detect this upfront to prevent uncessary URL.resolves that would dupe the
// (potentially very lage) data.
fn hasNonRemoteScheme(href: []const u8) bool {
    if (URL.isRemoteScheme(href)) {
        return false;
    }
    if (href.len == 0 or !std.ascii.isAlphabetic(href[0])) {
        return false;
    }
    for (href[1..]) |c| {
        switch (c) {
            ':' => return true,
            'a'...'z', 'A'...'Z', '0'...'9', '+', '-', '.' => {},
            else => return false,
        }
    }
    return false;
}

const testing = @import("../../testing.zig");

test "preload: prescan" {
    const page = try testing.pageTest("mcp_nav.html", .{});
    defer page.close();
    const frame = page.frame().?;

    // The fetches this starts stay in flight (nothing ticks the client before
    // page.close aborts them), so the maps hold exactly what the scan found.
    // All srcs sit under /serve-count/ because the test server panics on
    // unknown paths elsewhere; unknown names there get a plain 404.
    prescan(frame,
        \\<html><head>
        \\<script src="/serve-count/unit_a.js"></script>
        \\<script src="/serve-count/unit_a.js"></script>
        \\<script type="module" src="/serve-count/unit_m.js"></script>
        \\<script src="/serve-count/unit_skipped.js" nomodule></script>
        \\<script type="application/json" src="/serve-count/unit_data.js"></script>
        \\<script src="data:text/javascript,window.unit_data_url = 1;"></script>
        \\<script type="module" src="data:text/javascript,window.unit_data_module = 1;"></script>
        \\<script src=" "></script>
        \\<script type="module" src=" "></script>
        \\<script>var trap = "</scr" + "ipt><script src=/serve-count/unit_inline.js>";</script>
        \\<!-- <script src="/serve-count/unit_commented.js"></script> -->
        \\<template><script src="/serve-count/unit_templated.js"></script></template>
        \\<noscript><script src="/serve-count/unit_noscripted.js"></script></noscript>
        \\<style>p:before { content: "<script src=/serve-count/unit_styled.js></script>" }</style>
        \\<base href="/serve-count/sub/">
        \\<base href="/serve-count/ignored/">
        \\<script src="based.js"></script>
        \\<link rel="stylesheet" href="unit_sheet.css">
        \\</head><body></body></html>
    );

    const sm = &frame._script_manager;
    try testing.expectEqual(2, sm.preloaded_scripts.count());
    try testing.expectEqual(true, sm.preloaded_scripts.contains("http://127.0.0.1:9582/serve-count/unit_a.js"));
    try testing.expectEqual(true, sm.preloaded_scripts.contains("http://127.0.0.1:9582/serve-count/sub/based.js"));

    try testing.expectEqual(1, sm.base.imported_modules.count());
    const module = sm.base.imported_modules.get("http://127.0.0.1:9582/serve-count/unit_m.js") orelse return error.MissingModule;
    try testing.expectEqual(true, module.hint);

    // Stylesheets aren't loaded unless asked for
    try testing.expectEqual(0, frame._preloaded_stylesheets.count());

    frame._session.load_resources.stylesheet = true;
    defer frame._session.load_resources.stylesheet = false;
    prescan(frame,
        \\<base href="/serve-count/sub/">
        \\<link rel="stylesheet" href="unit_sheet.css">
        \\<link rel="stylesheet" href="unit_sheet.css">
        \\<link rel="alternate stylesheet" href="unit_alternate.css">
        \\<link rel="preload" as="style" href="unit_hinted.css">
        \\<link rel="stylesheet" href="data:text/css,p{}">
        \\<link rel="stylesheet">
        \\<template><link rel="stylesheet" href="unit_templated.css"></template>
        \\<noscript><link rel="stylesheet" href="unit_noscripted.css"></noscript>
    );
    try testing.expectEqual(1, frame._preloaded_stylesheets.count());
    try testing.expectEqual(true, frame._preloaded_stylesheets.contains("http://127.0.0.1:9582/serve-count/sub/unit_sheet.css"));
}
