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

// The routes the src/browser/tests fixtures load from: their files under
// /src/browser/tests/ plus the endpoints below. Served by the test suite and
// by `zig build test-server`.

const std = @import("std");
const lp = @import("lightpanda");

const repeat = @import("string.zig").repeat;
const Frame = @import("browser/Frame.zig");
const TestHTTPServer = @import("TestHTTPServer.zig");

// Server-side state for the /sse/* endpoints. sse_flag proves progressive
// delivery (see /sse/streaming); sse_reconnect_hits makes /sse/reconnect
// serve a different stream on the second connection.
var sse_flag = std.atomic.Value(bool).init(false);
var sse_reconnect_hits = std.atomic.Value(usize).init(0);

// /serve-count/ counters; only ever touched from the test HTTP server thread.
var serve_counts = [_]struct { name: []const u8, count: u32 = 0 }{
    .{ .name = "defer" },
    .{ .name = "async" },
    .{ .name = "dynamic" },
    .{ .name = "prescan_blocking" },
    .{ .name = "prescan_defer" },
    .{ .name = "prescan_module" },
};

fn origin(req: *std.http.Server.Request) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.mem.eql(u8, "origin", h.name)) {
            return h.value;
        }
    }

    return null;
}

pub fn handle(req: *std.http.Server.Request) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const req_allocator = arena.allocator();

    const path = req.head.target;

    if (std.mem.eql(u8, path, "/reset")) {
        // A test process gets its own server, so this state starts fresh for
        // it. A long-lived `zig build test-server` is reset per fixture instead.
        for (&serve_counts) |*sc| sc.count = 0;
        sse_flag.store(false, .release);
        sse_reconnect_hits.store(0, .release);
        return req.respond("", .{});
    }

    if (std.mem.eql(u8, path, "/")) {
        return req.respond("<html><head></head><body></body></html>", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr")) {
        return req.respond(repeat("1234567890", 10), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/slow")) {
        // Long enough for a timer scheduled by the requester to fire first.
        lp.io.sleep(.fromMilliseconds(100), .awake) catch {};
        return req.respond("slow", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/hang")) {
        // For asserting a request didn't wait for its response
        lp.io.sleep(.fromMilliseconds(2000), .awake) catch {};
        return req.respond("hang", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr_empty")) {
        return req.respond("", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    const xhr_xml_body = "<?xml version=\"1.0\"?><catalog><item id=\"a\"/><item id=\"b\"/><pubDate>2026</pubDate></catalog>";

    if (std.mem.eql(u8, path, "/xhr/xml")) {
        return req.respond(xhr_xml_body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/xml" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/xml_as_text")) {
        return req.respond(xhr_xml_body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/json")) {
        return req.respond("{\"over\":\"9000!!!\",\"updated_at\":1765867200000}", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/redirect")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://127.0.0.1:9582/xhr" },
            },
        });
    }

    // Scripts, so a cross-origin (localhost) load doesn't depend on CORS.
    if (std.mem.eql(u8, path, "/resource-timing/tao")) {
        return req.respond("window.__rt_tao = true;", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/javascript" },
                .{ .name = "Timing-Allow-Origin", .value = "https://example.com, *" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/resource-timing/plain")) {
        return req.respond("window.__rt_plain = true;", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/javascript" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/resource-timing/redirect")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/resource-timing/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-no-fragment")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/redirect-target" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-cross-origin-x-hop")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/echo-x-hop" },
            },
        });
    }

    // Bounces to the same path on the other loopback host, e.g. for an iframe
    // whose origin must change between its request and its response.
    if (std.mem.startsWith(u8, path, "/redirect-cross-origin/")) {
        var location_buf: [1024]u8 = undefined;
        const location = try std.mem.print(&location_buf, "http://localhost:9582/{s}", .{path["/redirect-cross-origin/".len..]});
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = location },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo-x-hop")) {
        var it = req.iterateHeaders();
        var value: []const u8 = "NONE";
        while (it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-hop")) {
                value = header.value;
                break;
            }
        }
        return req.respond(value, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-target")) {
        return req.respond("<!DOCTYPE html><title>landed</title>", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/303-no-location")) {
        // 3xx WITHOUT a Location header: not a redirect, a final response
        // whose body must be delivered (RFC 9110 §15.4).
        return req.respond("<!DOCTYPE html><title>landed</title><p>see other body</p>", .{
            .status = .see_other,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/300-with-location")) {
        // A non-redirect 3xx (fetch's redirect statuses are only 301, 302,
        // 303, 307 and 308) carrying a Location header: the header is a
        // preference hint, not a redirect — the body must be delivered.
        return req.respond("<!DOCTYPE html><title>choices</title><p>multiple choices body</p>", .{
            .status = .multiple_choice,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Location", .value = "http://127.0.0.1:9582/hi.html" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-with-fragment")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/redirect-target#target_fragment" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/404")) {
        return req.respond("Not Found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/401")) {
        return req.respond("No", .{
            .status = .unauthorized,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/404.js")) {
        // Valid JS body served with a 404 status. Used to assert that
        // ScriptManager does NOT execute the body of a failed script
        // fetch — if it did, window.__404_body_executed would be set.
        return req.respond("window.__404_body_executed = true;", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/defer-marker.js")) {
        // A deferred script body. Used by the regression test for a
        // <script defer> whose completion is deferred by a later
        // <link rel=stylesheet>'s synchronous fetch — it must still execute.
        return req.respond("window.__deferRan = true;", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/serve-count/") and std.mem.endsWith(u8, path, ".js")) {
        // Serves `window.__serve_count_<name> = N;` where N counts how many
        // times this URL has been served. Lets a fixture assert a preloaded
        // script was fetched exactly once: the body the consumer executes
        // carries N == 1, while a duplicate fetch would execute N == 2.
        // no-store so the second fetch can't be satisfied by the HTTP cache.
        const name = path["/serve-count/".len .. path.len - ".js".len];
        const slot: *u32 = blk: {
            for (&serve_counts) |*sc| {
                if (std.mem.eql(u8, sc.name, name)) break :blk &sc.count;
            }
            return req.respond("unknown counter", .{ .status = .not_found });
        };
        slot.* += 1;
        var buf: [64]u8 = undefined;
        const body = try std.mem.print(&buf, "window.__serve_count_{s} = {d};", .{ name, slot.* });
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
                .{ .name = "Cache-Control", .value = "no-store" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/challenge/vercel")) {
        return req.respond("<title>Vercel Security Checkpoint</title>", .{
            .status = .too_many_requests,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "x-vercel-mitigated", .value = "challenge" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/status/")) {
        const code = try std.fmt.parseInt(u16, path["/status/".len..], 10);
        return req.respond("", .{ .status = @fromBackingInt(@intCast(code)) });
    }

    if (std.mem.eql(u8, path, "/xhr/reason")) {
        return req.respond("", .{
            .status = .service_unavailable,
            .reason = "HOUSTON WE HAVE A",
        });
    }

    if (std.mem.eql(u8, path, "/xhr/duplicate_headers")) {
        return req.respond("", .{
            .extra_headers = &.{
                .{ .name = "X-B", .value = "1" },
                .{ .name = "X-A", .value = "a" },
                .{ .name = "X-B", .value = "2, 3" },
                .{ .name = "X_C", .value = "c" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/401")) {
        return req.respond("No", .{
            .status = .unauthorized,
            .extra_headers = &.{
                .{ .name = "WWW-Authenticate", .value = "Basic realm=\"test\"" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/500")) {
        return req.respond("Internal Server Error", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/bad_gzip")) {
        return req.respond("not actually gzip", .{
            .extra_headers = &.{
                .{ .name = "Content-Encoding", .value = "gzip" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/no_content_type")) {
        return req.respond("untyped", .{});
    }

    if (std.mem.eql(u8, path, "/xhr/binary")) {
        return req.respond(&.{ 0, 0, 1, 2, 0, 0, 9 }, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/octet-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sse/simple")) {
        // A complete stream: default + custom event types, multi-line data,
        // an id, and a comment. The connection closes right after; the test
        // close()s before the (1s) reconnect fires.
        return req.respond("retry: 1000\ndata: first\n\n: comment\nid: 42\nevent: custom\ndata: a\ndata: b\n\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/stop_loading/streaming.html")) {
        var send_buffer: [1024]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            },
        });
        try res.writer.writeAll("<html><body><p id=first>first</p>");
        try res.writer.flush();
        try res.flush();
        lp.io.sleep(.fromMilliseconds(1500), .awake) catch {};
        try res.writer.writeAll("<p id=second>second</p></body></html>");
        try res.writer.flush();
        return res.end();
    }

    if (std.mem.eql(u8, path, "/sse/streaming")) {
        sse_flag.store(false, .release);
        var send_buffer: [1024]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/event-stream" },
                },
            },
        });
        try res.writer.writeAll("data: first\n\n");
        try res.writer.flush();
        try res.flush();

        // Proof of progressive delivery: "second" is only sent once the
        // client has reacted to "first" (by fetching /sse/flag), which it
        // can only do if "first" was delivered while this response was
        // still streaming.
        var waited: usize = 0;
        while (!sse_flag.load(.acquire) and waited < 5000) : (waited += 10) {
            lp.io.sleep(.fromMilliseconds(10), .awake) catch {};
        }
        if (sse_flag.load(.acquire)) {
            // split mid-line to exercise buffering across chunks
            try res.writer.writeAll("data: sec");
            try res.writer.flush();
            try res.flush();
            lp.io.sleep(.fromMilliseconds(20), .awake) catch {};
            try res.writer.writeAll("ond\n\n");
            try res.writer.flush();
            try res.flush();
        }
        return res.end();
    }

    if (std.mem.eql(u8, path, "/sse/flag")) {
        sse_flag.store(true, .release);
        return req.respond("", .{});
    }

    if (std.mem.eql(u8, path, "/sse/reconnect")) {
        if (sse_reconnect_hits.fetchAdd(1, .monotonic) == 0) {
            return req.respond("retry: 10\ndata: one\n\n", .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/event-stream" },
                },
            });
        }
        return req.respond("data: two\n\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sse/long_retry")) {
        return req.respond("retry: 60000\ndata: x\n\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sse/404")) {
        return req.respond("data: x\n\n", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/event-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/sse/badmime")) {
        return req.respond("data: x\n\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/important-cascade.css")) {
        return req.respond(".no-js-flex { display: none !important; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/visibility.css")) {
        // Used by css/external_stylesheet.html — drives the visibility
        // cascade through StyleManager via Frame.loadExternalStylesheet
        // so a `.ext-hide` element is observable to checkVisibility().
        return req.respond(".ext-hide { display: none; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/visibility2.css")) {
        // Second visibility sheet used by the href-change regression test:
        // mutating link.href must replace the cached sheet's rules in place,
        // not append a new entry to document.styleSheets.
        return req.respond(".ext-hide-2 { display: none; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    // Latin-1 bytes in the reason phrase, a header name and a header value.
    if (std.mem.eql(u8, path, "/latin1_response")) {
        return req.respond("latin1", .{
            .reason = "Caf\xE9",
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
                .{ .name = "X-Latin1", .value = "La\xA0Paz" },
                .{ .name = "X-Caf\xE9", .value = "1" },
            },
        });
    }

    // Latin-1 sheets for css/stylesheet_charset.html: undecoded, the 0xE9
    // swallows the bytes after it and the rule that follows is lost.
    if (std.mem.eql(u8, path, "/styles/latin1-header.css")) {
        return req.respond("/* caf\xE9 */ .by-header { display: none; --name: \"caf\xE9\"; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css; charset=iso-8859-1" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/latin1-at-charset.css")) {
        return req.respond("@charset \"windows-1252\"; /* caf\xE9 */ .by-at-charset { display: none; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/truncated-utf8.css")) {
        return req.respond(".before-truncated { display: none; } \xE2", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    // Latin-1 scripts for page/script_charset.html. /scripts/latin1/<name>.js
    // and /scripts/latin1-header/<name>.js set window[<name>], the latter
    // declaring its charset.
    if (std.mem.eql(u8, path, "/scripts/bom-over-header.js")) {
        return req.respond("\xEF\xBB\xBFwindow.byBom = 'caf\xC3\xA9';", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/javascript; charset=iso-8859-1" },
            },
        });
    }

    const declares_charset = std.mem.startsWith(u8, path, "/scripts/latin1-header/");
    if (declares_charset or std.mem.startsWith(u8, path, "/scripts/latin1/")) {
        const body = try std.fmt.allocPrint(req_allocator, "window['{s}'] = 'caf\xE9';", .{std.fs.path.stem(path)});
        const content_type = if (declares_charset) "text/javascript; charset=iso-8859-1" else "text/javascript";
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = content_type },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/404.css")) {
        return req.respond("/* unused */", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/large.css")) {
        // Over 2 MiB, with the rule under test last.
        const chunk = ".pad { color: #abcdef; } "; // 25 bytes
        const tail = ".large-hide { display: none; }";
        const repeats = 5 * 1024 * 1024 / 2 / chunk.len;
        var body = try std.ArrayList(u8).initCapacity(req_allocator, chunk.len * repeats + tail.len);
        for (0..repeats) |_| body.appendSliceAssumeCapacity(chunk);
        body.appendSliceAssumeCapacity(tail);
        return req.respond(body.items, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/oversize.css")) {
        // Body that exceeds Frame.MAX_STYLESHEET_BYTES — written as a
        // long sequence of valid declarations so the response itself parses
        // fine and the error path is exercised by the size cap, not by a
        // CSS parse failure.
        const chunk = ".pad { color: #abcdef; } "; // 25 bytes
        const repeats = (Frame.MAX_STYLESHEET_BYTES / chunk.len) + 1024;
        var body = try std.ArrayList(u8).initCapacity(req_allocator, chunk.len * repeats);
        for (0..repeats) |_| body.appendSliceAssumeCapacity(chunk);
        return req.respond(body.items, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    // Bodies are non-empty so that libcurl always reaches the write callback,
    // which is where a partial request decides whether to drain or abort.
    // ok.png takes the abort branch, small.png the drain branch; both must
    // behave identically as far as the DOM is concerned.
    if (std.mem.eql(u8, path, "/images/ok.png")) {
        // > HttpClient.Request.PARTIAL_DRAIN_MAX. The synthetic PNG
        // header advertises 1000 x 750 pixels; no bitmap is decoded.
        const body = try req_allocator.alloc(u8, 16 * 1024 + 1);
        @memset(body, 'x');
        @memcpy(body[0..24], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x03\xe8\x00\x00\x02\xee");
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/png" },
            },
        });
    }

    // startsWith, not eql: a caller can append a query string to get distinct
    // URLs (and so distinct transfers) off this one route.
    if (std.mem.startsWith(u8, path, "/images/small.png")) {
        const body = try req_allocator.alloc(u8, 1024);
        @memset(body, 'x');
        @memcpy(body[0..24], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x01\x40\x00\x00\x00\xf0");
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/png" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/images/photo.jpg")) {
        const body = "\xff\xd8\xff\xe1\x00\x04\x00\x00\xff\xc0\x00\x0b\x08\x02\xee\x03\xe8\x01\x01\x11\x00";
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/jpeg" },
            },
        });
    }

    // No Content-Length: whether the body is small enough to drain can only
    // be decided as it arrives.
    if (std.mem.eql(u8, path, "/images/chunked.png")) {
        var send_buffer: [1024]u8 = undefined;
        var res = try req.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "image/svg+xml" },
                },
            },
        });
        try res.writer.writeAll("<svg xmlns=\"http://www.w3.org/2000/svg\"/>");
        try res.writer.flush();
        return res.end();
    }

    if (std.mem.eql(u8, path, "/images/404.png")) {
        return req.respond("not here", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/images/500.png")) {
        return req.respond("boom", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/images/redirect.png")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/images/ok.png" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_referer")) {
        // Echo the request's Referer header back as HTML so tests can assert
        // what Referer the navigation sent. Used by the cross-page Referer test.
        var it = req.iterateHeaders();
        var referer: []const u8 = "NONE";
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Referer")) {
                referer = h.value;
                break;
            }
        }
        var html_buf: [512]u8 = undefined;
        const html = try std.mem.print(&html_buf, "<html><body>referer={s}</body></html>", .{referer});
        return req.respond(html, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Access-Control-Allow-Origin", .value = origin(req) orelse "*" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/referer_link.html")) {
        // Page with an anchor link to /echo_referer. The test clicks the link
        // via JS and asserts the resulting page reports Referer = this page.
        return req.respond(
            "<html><body><a id=\"link\" href=\"/echo_referer\">go</a></body></html>",
            .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            },
        );
    }

    if (std.mem.eql(u8, path, "/echo_method")) {
        // Echo the request method back as HTML so tests can assert on what
        // method the navigation used. Used by the Page.reload-replays-POST test.
        const method_name = @tagName(req.head.method);
        var html_buf: [128]u8 = undefined;
        const html = try std.mem.print(&html_buf, "<html><body>method={s}</body></html>", .{method_name});
        return req.respond(html, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_body")) {
        // Echo the request body back verbatim, so tests can assert on the bytes
        // a request actually sent rather than just on its status.
        var body_buf: [4096]u8 = undefined;
        const body = if (req.head.method.requestHasBody())
            try req.readerExpectNone(&body_buf).allocRemaining(req_allocator, .limited(body_buf.len))
        else
            "";
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_brotli")) {
        // Echo the request body back as `Content-Encoding: br`, so the HTTP
        // client decodes it; checks CompressionStream('brotli') output with a
        // decoder that isn't ours.
        var body_buf: [4096]u8 = undefined;
        const body = try req.readerExpectNone(&body_buf).allocRemaining(req_allocator, .limited(4 * 1024 * 1024));
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/octet-stream" },
                .{ .name = "Content-Encoding", .value = "br" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_headers")) {
        if (req.head.method == .OPTIONS) {
            return req.respond("", .{
                .extra_headers = &.{
                    .{ .name = "Access-Control-Allow-Origin", .value = origin(req) orelse "*" },
                    .{ .name = "Access-Control-Allow-Methods", .value = "GET" },
                    .{ .name = "Access-Control-Allow-Headers", .value = "x-hop" },
                },
            });
        }

        // Echo every request header back as "name: value" lines, so tests
        // can assert on the headers a request actually sent.
        var buf: [8192]u8 = undefined;
        var pos: usize = 0;
        var it = req.iterateHeaders();
        while (it.next()) |header| {
            const line = try std.mem.print(buf[pos..], "{s}: {s}\n", .{ header.name, header.value });
            pos += line.len;
        }
        return req.respond(buf[0..pos], .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
                .{ .name = "Access-Control-Allow-Origin", .value = origin(req) orelse "*" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/set_cookie")) {
        return req.respond("", .{
            .extra_headers = &.{
                .{ .name = "Set-Cookie", .value = "lp_hidden=1; Path=/set_cookie_scope" },
                .{ .name = "X-Visible", .value = "yes" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_same_echo_headers")) {
        // Same-origin 302 to /echo_headers: Authorization must survive the hop.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/echo_headers" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_cross_echo_headers")) {
        // 302 to /echo_headers on the localhost alias — a cross-origin hop, so
        // Authorization must be stripped before the request is re-sent.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/echo_headers" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_same_echo_referer")) {
        // Same-origin 302 to /echo_referer: the full Referer must survive the hop.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/echo_referer" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_cross_echo_referer")) {
        // 302 to /echo_referer on the localhost alias — a cross-origin hop, so
        // the Referer must be recomputed at the redirect (stripped to origin
        // under the default policy) rather than re-sent in full.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/echo_referer" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_to_echo")) {
        // 302 to /echo_method. Used by the Page.reload-after-redirect test to
        // confirm a POST→302→GET chain doesn't replay POST on reload.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/echo_method" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/download/report.csv")) {
        // A file download: Content-Disposition: attachment drives the
        // Browser.setDownloadBehavior path (issue #2701).
        return req.respond("col1,col2\nhello,world\n42,1337\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/csv" },
                .{ .name = "Content-Disposition", .value = "attachment; filename=\"report.csv\"" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/src/browser/tests/")) {
        if (std.mem.find(u8, path, "delay_ms=")) |pos| {
            const digits_start = pos + "delay_ms=".len;
            var end = digits_start;
            while (end < path.len and std.ascii.isDigit(path[end])) : (end += 1) {}
            const delay_ms = std.fmt.parseInt(u64, path[digits_start..end], 10) catch 0;
            lp.io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
        }
        // strip off leading / so that it's relative to CWD
        return TestHTTPServer.sendFile(req, path[1..]);
    }

    if (std.mem.eql(u8, path, "/favicon.ico")) {
        return req.respond("", .{ .status = .not_found });
    }

    std.debug.print("TestHTTPServer was asked to serve an unknown file: {s}\n", .{path});
    return req.respond("not found", .{ .status = .not_found });
}
