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

// Speculative script fetching: <link rel=preload/modulepreload> hints and the
// pre-parse scan of the raw HTML. All of it only starts downloads early —
// consumption happens in ScriptManager / ScriptManagerBase when the real
// <script> element or import shows up.

const std = @import("std");

const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Parser = @import("../parser/Parser.zig");
const Element = @import("../webapi/Element.zig");

const Allocator = std.mem.Allocator;

// start prefetching <link rel="preload" as="script" href=...>`. element is the
// hint <link> to fire load/error on, null when the hint came from the prescan.
pub fn scriptHint(frame: *Frame, element: ?*Element.Html, href: []const u8) bool {
    if (frame.isGoingAway() or frame._parse_mode == .fragment) {
        return false;
    }

    const arena = frame.getArena(.small, "preload.scriptHint") catch return false;
    defer frame.releaseArena(arena);

    const resolved = URL.resolve(arena, frame.base(), href, .{ .encoding = frame.charset }) catch return false;
    if (!isRemoteScheme(resolved)) {
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
    const resolved = URL.resolve(frame.arena, frame.base(), href, .{ .encoding = frame.charset }) catch return false;
    if (!isRemoteScheme(resolved)) {
        return false;
    }

    return frame._script_manager.base.preloadModuleHint(element, resolved, frame.url) catch false;
}

// Scan the HTML for <script src=...> before parsing so that we can start
// fetching them ASAP. The downside is we might accidentally fetch more than we
// should, but the upside can be a pretty significant performance improvement.
// Without this, N large blocking <script src=...> tags are downloaded serially.
// This essentially does the same thing as the <link preload/preloadModule> but
// without needing anything special from the HTML.
pub fn prescan(frame: *Frame, html: []const u8) void {
    if (frame.isGoingAway() or frame._parse_mode == .fragment) {
        return;
    }
    const arena = frame.getArena(.small, "preload.prescan") catch return;
    defer frame.releaseArena(arena);

    var scan = Prescan{ .frame = frame, .base = frame.base(), .arena = arena };
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
                if (isRemoteScheme(resolved) == false) {
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
                const resolved = URL.resolve(frame.arena, self.base, href, .{ .encoding = frame.charset }) catch return;
                if (isRemoteScheme(resolved) == false) {
                    return;
                }
                _ = frame._script_manager.base.preloadModuleHint(null, resolved, frame.url) catch {};
            },
            _ => {},
        }
    }
};

fn isRemoteScheme(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http:") or std.ascii.startsWithIgnoreCase(url, "https:");
}

// Non-http(s) scheme (e.g. data:, blob:) never resolve to a remote URL. We
// detect this upfront to prevent uncessary URL.resolves that would dupe the
// (potentially very lage) data.
fn hasNonRemoteScheme(href: []const u8) bool {
    if (isRemoteScheme(href)) {
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
    defer testing.reset();

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
        \\<script>var trap = "</scr" + "ipt><script src=/serve-count/unit_inline.js>";</script>
        \\<!-- <script src="/serve-count/unit_commented.js"></script> -->
        \\<template><script src="/serve-count/unit_templated.js"></script></template>
        \\<noscript><script src="/serve-count/unit_noscripted.js"></script></noscript>
        \\<style>p:before { content: "<script src=/serve-count/unit_styled.js></script>" }</style>
        \\<base href="/serve-count/sub/">
        \\<base href="/serve-count/ignored/">
        \\<script src="based.js"></script>
        \\</head><body></body></html>
    );

    const sm = &frame._script_manager;
    try testing.expectEqual(2, sm.preloaded_scripts.count());
    try testing.expectEqual(true, sm.preloaded_scripts.contains("http://127.0.0.1:9582/serve-count/unit_a.js"));
    try testing.expectEqual(true, sm.preloaded_scripts.contains("http://127.0.0.1:9582/serve-count/sub/based.js"));

    try testing.expectEqual(1, sm.base.imported_modules.count());
    const module = sm.base.imported_modules.get("http://127.0.0.1:9582/serve-count/unit_m.js") orelse return error.MissingModule;
    try testing.expectEqual(true, module.hint);
}
