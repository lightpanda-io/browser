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

//! The `search` tool: the engines, the cascade that picks one when the engine
//! is `auto`, and the hits each provider's response becomes. The one tool that
//! never looks at a page.

const std = @import("std");
const lp = @import("../../lightpanda.zig");
const zenai = @import("zenai");

const tools = @import("../tools.zig");
const ToolError = tools.ToolError;
const ToolResult = tools.ToolResult;
const Failure = tools.Failure;
const parseArgs = tools.parseArgs;
const writeFailure = tools.writeFailure;
const writeSingleLine = tools.writeSingleLine;

const log = lp.log;
const tavily = zenai.search.tavily;
const brave = zenai.search.brave;
const exa = zenai.search.exa;
const parallel = zenai.search.parallel;
const keenable = zenai.search.keenable;

const SearchParams = struct {
    query: []const u8,
    timeout: ?u32 = null,
};

/// Advertised by the `search` schema. The search clients have no connect
/// timeout, so this only starts once connected.
const default_search_timeout_ms: u32 = 10_000;

pub const Engine = enum { auto, brave, tavily, exa, parallel, keenable };

/// Only the agent REPL's `/searchEngine` mutates this.
pub var engine: Engine = .auto;

// In `.auto` preference order.
const api_engines = .{
    .{
        .tag = Engine.brave,
        .Client = brave.Client,
        .init_options = brave.Client.InitOptions{},
        // text_decorations=false: no <strong> markup in model-read snippets.
        .options = brave.types.SearchOptions{ .count = 10, .text_decorations = false },
        .collect = collectBrave,
    },
    .{
        .tag = Engine.tavily,
        .Client = tavily.Client,
        .init_options = tavily.Client.InitOptions{},
        .options = tavily.types.SearchOptions{ .max_results = 10 },
        .collect = collectTavily,
    },
    .{
        .tag = Engine.exa,
        .Client = exa.Client,
        .init_options = exa.Client.InitOptions{},
        // highlights: Exa returns no snippet text unless contents is requested;
        // capped at 3 sentences since the default excerpts run long.
        .options = exa.types.SearchOptions{ .numResults = 10, .contents = .{ .highlights = .{ .numSentences = 3 } } },
        .collect = collectExa,
    },
    .{
        .tag = Engine.parallel,
        .Client = parallel.Client,
        .init_options = parallel.Client.InitOptions{},
        // fast: ~1s budget instead of the ~3s default, well inside the tool timeout.
        .options = parallel.types.SearchOptions{
            .mode = .fast,
            .advanced_settings = .{ .max_results = 10, .excerpt_settings = .{ .max_chars_per_result = 500 } },
        },
        .collect = collectParallel,
    },
    .{
        .tag = Engine.keenable,
        .Client = keenable.Client,
        .init_options = keenable.Client.InitOptions{ .app_title = "lightpanda" },
        // snippet_max_length is a hint the API may round up to a word
        // boundary; 500 keeps ten results within a few KB of context.
        .options = keenable.types.SearchOptions{ .max_results = 10, .snippet_max_length = 500 },
        .collect = collectKeenable,
    },
};

// `.auto` relies on a keyless engine as the rung that is always attempted.
comptime {
    const has_keyless = for (api_engines) |e| {
        if (isKeyless(e.Client)) break true;
    } else false;
    if (!has_keyless) @compileError("api_engines needs a keyless engine");
}

/// A `null` key routes an optional-key client to its public endpoint.
fn isKeyless(comptime Client: type) bool {
    return @typeInfo(@FieldType(Client, "api_key")) == .optional;
}

/// `api_engines` rendered as prose.
fn joinEngines(comptime field: enum { tag, env_var }, comptime last_sep: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (api_engines, 0..) |e, i| {
            const sep = if (i == 0) "" else if (i + 1 == api_engines.len) last_sep else ", ";
            out = out ++ sep ++ switch (field) {
                .tag => @tagName(e.tag),
                .env_var => e.Client.env_var_name,
            };
        }
        return out;
    }
}

/// Shared by the `search` tool description and the `/searchEngine` help;
/// the keyless clause is the one part not generated from the table.
pub const cascade_prose = "tries " ++ joinEngines(.tag, ", then ") ++ " in order, each when its API key (" ++ joinEngines(.env_var, " or ") ++ ") is set; keenable also works without a key through its public endpoint (rate-limited per client IP)";

/// The key `engine` uses right now; `null` selects a keyless engine's
/// public endpoint.
fn engineKey(comptime e: anytype) error{MissingApiKey}!?[]const u8 {
    if (e.Client.envApiKey(lp.environ())) |key| return key;
    return if (comptime isKeyless(e.Client)) null else error.MissingApiKey;
}

const KeyStatus = struct {
    env_var: [:0]const u8,
    state: enum { set, keyless, missing },
};

fn keyStatusOf(comptime e: anytype) KeyStatus {
    return .{
        .env_var = e.Client.env_var_name,
        .state = if (engineKey(e)) |key| (if (key != null) .set else .keyless) else |_| .missing,
    };
}

/// For `.auto`, the rung the cascade would actually land on -- it has no key of
/// its own, but "which engine is about to serve, and on what terms" is the
/// question worth answering, and `.auto` is the default.
pub fn keyStatus(selected: Engine) ?KeyStatus {
    inline for (api_engines) |e| {
        if (selected == e.tag) return keyStatusOf(e);
    }
    if (selected != .auto) return null;
    inline for (api_engines) |e| {
        const status = keyStatusOf(e);
        if (status.state != .missing) return status;
    }
    return null;
}

pub fn exec(arena: std.mem.Allocator, session: *lp.Session, arguments: ?std.json.Value) ToolError!ToolResult {
    const args = try parseArgs(SearchParams, arena, arguments);
    if (args.query.len == 0) return ToolError.InvalidParams;
    // A search through a search engine's page carries the query in its URL,
    // so `--block-urls` already refuses a query that matches a pattern
    // (`*some-site*`). Treat API searches the same way.
    if (session.browser.http_client.blocksUrl(args.query)) return .{ .text = "No results." };

    const timeout_ms = args.timeout orelse default_search_timeout_ms;
    switch (engine) {
        .auto => {
            var last_err: ?anyerror = null;
            var last_label: []const u8 = "web";
            var last_detail: Failure = .{};
            inline for (api_engines) |e| {
                if (engineKey(e)) |api_key| {
                    // Fall through on any failure so one outage doesn't kill
                    // a whole benchmark run.
                    var detail: Failure = .{};
                    if (session.runPumped(apiSearch, .{ e, arena, api_key, timeout_ms, args.query, &detail, &session.browser.http_client })) |markdown_| {
                        return .{ .text = markdown_ };
                    } else |err| {
                        last_err = err;
                        last_label = @tagName(e.tag);
                        last_detail = detail;
                        log.debug(.browser, @tagName(e.tag) ++ " fallback", .{ .err = err });
                    }
                } else |_| {}
            }
            // The last engine's reason, not a generic one -- the model can act on it.
            return searchFailed(arena, last_label, last_err.?, last_detail);
        },
        inline else => |tag| {
            inline for (api_engines) |e| {
                if (e.tag == tag) return searchExplicit(arena, session, e, timeout_ms, args.query);
            }
            @compileError("engine missing from api_engines: " ++ @tagName(tag));
        },
    }
}

/// No fallback: a failed call or a missing key is an error result.
fn searchExplicit(arena: std.mem.Allocator, session: *lp.Session, comptime e: anytype, timeout_ms: u32, query: []const u8) ToolError!ToolResult {
    const label = @tagName(e.tag);
    const api_key = engineKey(e) catch return .{
        .text = "web search engine is set to " ++ label ++ " but " ++ e.Client.env_var_name ++ " is not set in the environment",
        .is_error = true,
    };
    var detail: Failure = .{};
    const markdown_ = session.runPumped(apiSearch, .{ e, arena, api_key, timeout_ms, query, &detail, &session.browser.http_client }) catch |err|
        return searchFailed(arena, label, err, detail);
    return .{ .text = markdown_ };
}

fn searchFailed(arena: std.mem.Allocator, label: []const u8, err: anyerror, detail: Failure) ToolError!ToolResult {
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeSearchFailure(&aw.writer, label, err, detail) catch return ToolError.OutOfMemory;
    return .{ .text = aw.written(), .is_error = true };
}

fn writeSearchFailure(w: *std.Io.Writer, label: []const u8, err: anyerror, detail: Failure) !void {
    try w.print("{s} search ", .{label});
    try writeFailure(w, err, detail);
    // The one failure where the right move is not "try another query".
    if (detail.status == 429) {
        try w.writeAll(". This engine is rate-limited right now; wait before retrying, or read the answer from a page instead.");
    }
}

/// `arena` owns the returned slice.
fn apiSearch(
    comptime e: anytype,
    arena: std.mem.Allocator,
    api_key: ?[]const u8,
    timeout_ms: u32,
    query: []const u8,
    detail: *Failure,
    url_filter: anytype,
) ![]const u8 {
    var init_options = e.init_options;
    // The cascade (or the model) is the retry; honoring a Retry-After (60 s
    // per sleep on the public endpoint) would stall the shared browser thread.
    init_options.retry_policy = .disabled;
    init_options.request_timeout_ms = timeout_ms;
    var client: e.Client = .init(
        lp.io,
        arena,
        if (comptime isKeyless(e.Client)) api_key else api_key.?,
        init_options,
    );
    defer client.deinit();

    var response = client.search(query, e.options) catch |err| {
        if (client.last_error.status) |status| {
            log.debug(.browser, @tagName(e.tag) ++ " non-2xx", .{
                .status = status,
                .message = client.last_error.message,
            });
            detail.* = try client.last_error.dupe(arena);
        }
        return err;
    };
    defer response.deinit();

    return renderResults(arena, try dropBlocked(arena, try e.collect(arena, response.value), url_filter));
}

/// Drops hits whose URL the browser's `--block-urls` patterns would refuse,
/// so a search can't hand the model a page it isn't allowed to open, or that
/// page's text in a snippet. A synthesized answer may draw on a dropped hit,
/// so it goes too. `url_filter` is anything with `blocksUrl(url) bool`.
fn dropBlocked(arena: std.mem.Allocator, results: SearchResults, url_filter: anytype) std.mem.Allocator.Error!SearchResults {
    var kept: std.ArrayList(Hit) = .empty;
    for (results.hits) |hit| {
        if (!url_filter.blocksUrl(hit.url)) try kept.append(arena, hit);
    }
    if (kept.items.len == results.hits.len) return results;
    return .{ .hits = kept.items };
}

const Hit = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,
};

const SearchResults = struct {
    /// Tavily's synthesized answer; empty for the engines that have none.
    answer: []const u8 = "",
    hits: []const Hit = &.{},
};

/// The engines agree on title and url and disagree only on which field holds
/// the snippet.
fn collectHits(arena: std.mem.Allocator, results: anytype, comptime snippet: []const u8) ![]Hit {
    const hits = try arena.alloc(Hit, results.len);
    for (results, hits) |r, *hit| hit.* = .{ .title = r.title, .url = r.url, .snippet = @field(r, snippet) };
    return hits;
}

fn collectTavily(arena: std.mem.Allocator, resp: tavily.types.SearchResponse) !SearchResults {
    return .{ .answer = resp.answer orelse "", .hits = try collectHits(arena, resp.results, "content") };
}

fn collectBrave(arena: std.mem.Allocator, resp: brave.types.SearchResponse) !SearchResults {
    const results: []const brave.types.Result = if (resp.web) |web| web.results else &.{};
    return .{ .hits = try collectHits(arena, results, "description") };
}

fn collectExa(arena: std.mem.Allocator, resp: exa.types.SearchResponse) !SearchResults {
    const hits = try arena.alloc(Hit, resp.results.len);
    for (resp.results, hits) |r, *hit| {
        const highlights = r.highlights orelse &[_][]const u8{};
        hit.* = .{
            .title = r.title orelse "",
            .url = r.url,
            .snippet = if (highlights.len > 0) highlights[0] else "",
        };
    }
    return .{ .hits = hits };
}

fn collectParallel(arena: std.mem.Allocator, resp: parallel.types.SearchResponse) !SearchResults {
    const hits = try arena.alloc(Hit, resp.results.len);
    for (resp.results, hits) |r, *hit| hit.* = .{
        .title = r.title orelse "",
        .url = r.url,
        .snippet = if (r.excerpts.len > 0) r.excerpts[0] else "",
    };
    return .{ .hits = hits };
}

fn collectKeenable(arena: std.mem.Allocator, resp: keenable.types.SearchResponse) !SearchResults {
    // `snippet` carries the page text; the wire format's always-empty
    // `description` is deliberately not even mapped by the client.
    return .{ .hits = try collectHits(arena, resp.results, "snippet") };
}

fn renderResults(arena: std.mem.Allocator, results: SearchResults) ToolError![]const u8 {
    if (results.answer.len == 0 and results.hits.len == 0) return "No results.";
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeResults(&aw.writer, results) catch return ToolError.OutOfMemory;
    return aw.written();
}

fn writeResults(w: *std.Io.Writer, results: SearchResults) !void {
    if (results.answer.len > 0) try w.print("**Answer:** {s}\n\n", .{results.answer});
    for (results.hits, 0..) |hit, i| try writeResultItem(w, i, hit.title, hit.url, hit.snippet);
}

/// An empty title (providers default it to "") would render as `****`.
fn writeResultItem(w: *std.Io.Writer, i: usize, title: []const u8, url: []const u8, snippet: []const u8) !void {
    try w.print("{d}. **", .{i + 1});
    try writeSingleLine(w, if (title.len == 0) url else title);
    try w.print("** — {s}\n   ", .{url});
    try writeSingleLine(w, snippet);
    try w.writeAll("\n\n");
}

test "tavily results render as markdown" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const resp: tavily.types.SearchResponse = .{
        .query = "capital of france",
        .answer = "Paris",
        .results = &.{
            .{ .title = "Paris - Wikipedia", .url = "https://en.wikipedia.org/wiki/Paris", .content = "Paris is the capital of France." },
            .{ .title = "France", .url = "https://example.org/fr", .content = "Country in Western Europe." },
        },
    };

    const md = try renderResults(aa, try collectTavily(aa, resp));
    try std.testing.expect(std.mem.find(u8, md, "**Answer:** Paris") != null);
    try std.testing.expect(std.mem.find(u8, md, "1. **Paris - Wikipedia**") != null);
    try std.testing.expect(std.mem.find(u8, md, "https://en.wikipedia.org/wiki/Paris") != null);
    try std.testing.expect(std.mem.find(u8, md, "Paris is the capital of France.") != null);
    try std.testing.expect(std.mem.find(u8, md, "2. **France**") != null);
}

test "tavily: no results render as a notice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try std.testing.expectEqualStrings("No results.", try renderResults(aa, try collectTavily(aa, .{})));
}

test "brave results render as markdown" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const resp: brave.types.SearchResponse = .{
        .web = .{
            .results = &.{
                .{ .title = "Paris - Wikipedia", .url = "https://en.wikipedia.org/wiki/Paris", .description = "Paris is the capital of France." },
                .{ .title = "France", .url = "https://example.org/fr", .description = "Country in Western Europe." },
            },
        },
    };

    const md = try renderResults(aa, try collectBrave(aa, resp));
    try std.testing.expect(std.mem.find(u8, md, "1. **Paris - Wikipedia**") != null);
    try std.testing.expect(std.mem.find(u8, md, "https://en.wikipedia.org/wiki/Paris") != null);
    try std.testing.expect(std.mem.find(u8, md, "Paris is the capital of France.") != null);
    try std.testing.expect(std.mem.find(u8, md, "2. **France**") != null);
}

test "brave: no results render as a notice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    try std.testing.expectEqualStrings("No results.", try renderResults(aa, try collectBrave(aa, .{})));

    try std.testing.expectEqualStrings("No results.", try renderResults(aa, try collectBrave(aa, .{ .web = .{} })));
}

test "parallel results render the first excerpt as the body" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const resp: parallel.types.SearchResponse = .{
        .results = &.{
            .{ .title = "Paris - Wikipedia", .url = "https://en.wikipedia.org/wiki/Paris", .excerpts = &.{ "Paris is the capital of France.", "## Geography" } },
            .{ .url = "https://example.org/fr" },
        },
    };

    const md = try renderResults(aa, try collectParallel(aa, resp));
    try std.testing.expect(std.mem.find(u8, md, "1. **Paris - Wikipedia**") != null);
    try std.testing.expect(std.mem.find(u8, md, "Paris is the capital of France.") != null);
    try std.testing.expect(std.mem.find(u8, md, "## Geography") == null);
    try std.testing.expect(std.mem.find(u8, md, "2. **https://example.org/fr**") != null);
}

test "keenable results render the snippet as the body" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const resp: keenable.types.SearchResponse = .{
        .query = "zig",
        .results = &.{
            .{ .title = "Zig (programming language)", .url = "https://en.wikipedia.org/wiki/Zig", .snippet = "Zig is a system programming language." },
            .{ .title = "Zig guide", .url = "https://example.org/zig", .snippet = "Compile-time execution." },
        },
    };

    const md = try renderResults(aa, try collectKeenable(aa, resp));
    try std.testing.expect(std.mem.find(u8, md, "1. **Zig (programming language)**") != null);
    try std.testing.expect(std.mem.find(u8, md, "Zig is a system programming language.") != null);
    try std.testing.expect(std.mem.find(u8, md, "2. **Zig guide**") != null);
    try std.testing.expect(std.mem.find(u8, md, "Compile-time execution.") != null);
}

test "writeResultItem uses the URL as title when the title is empty" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeResultItem(&aw.writer, 0, "", "https://example.org/x.pdf", "snippet");
    try std.testing.expectEqualStrings("1. **https://example.org/x.pdf** — https://example.org/x.pdf\n   snippet\n\n", aw.written());
}

test "keenable: no results render as a notice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("No results.", try renderResults(aa, try collectKeenable(aa, .{})));
}

test "brave titles and descriptions render on one line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const resp: brave.types.SearchResponse = .{
        .web = .{
            .results = &.{
                .{ .title = "Multi\nline title", .url = "https://example.org", .description = "line one\r\n\r\nline two" },
            },
        },
    };

    try std.testing.expectEqualStrings(
        "1. **Multi line title** — https://example.org\n   line one line two\n\n",
        try renderResults(aa, try collectBrave(aa, resp)),
    );
}

test "dropBlocked: blocked hits and the synthesized answer go, the rest stay in order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const Filter = struct {
        fn blocksUrl(_: @This(), url: []const u8) bool {
            return std.mem.find(u8, url, "huggingface.co/datasets/") != null;
        }
    };
    const results: SearchResults = .{ .answer = "42", .hits = &.{
        .{ .title = "a", .url = "https://example.org/a", .snippet = "" },
        .{ .title = "gold", .url = "https://huggingface.co/datasets/x/y", .snippet = "answer: 42" },
        .{ .title = "b", .url = "https://example.org/b", .snippet = "" },
    } };

    const filtered = try dropBlocked(aa, results, Filter{});
    try std.testing.expectEqual(2, filtered.hits.len);
    try std.testing.expectEqualStrings("https://example.org/a", filtered.hits[0].url);
    try std.testing.expectEqualStrings("https://example.org/b", filtered.hits[1].url);
    try std.testing.expectEqualStrings("", filtered.answer);

    const untouched = try dropBlocked(aa, .{ .answer = "42", .hits = results.hits[0..1] }, Filter{});
    try std.testing.expectEqualStrings("42", untouched.answer);

    const all_blocked = try dropBlocked(aa, .{ .hits = results.hits[1..2] }, Filter{});
    try std.testing.expectEqualStrings("No results.", try renderResults(aa, all_blocked));
}

test "searchFailed: a rate limit says so, a bare failure stays short" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const limited = try searchFailed(aa, "keenable", error.ApiError, .{
        .status = 429,
        .message = try aa.dupe(u8, "Public API hourly limit reached.\nWait 2 minutes to continue."),
    });
    try std.testing.expect(limited.is_error);
    try std.testing.expect(std.mem.find(u8, limited.text, "(HTTP 429)") != null);
    try std.testing.expect(std.mem.find(u8, limited.text, "Public API hourly limit reached.") != null);
    try std.testing.expect(std.mem.find(u8, limited.text, "rate-limited right now") != null);
    try std.testing.expect(std.mem.find(u8, limited.text, "\n") == null);

    const bare = try searchFailed(aa, "web", error.ConnectionRefused, .{});
    try std.testing.expectEqualStrings("web search failed: ConnectionRefused", bare.text);
    try std.testing.expect(bare.is_error);
}
