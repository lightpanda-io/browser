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

//! Classification of one script replay and its serializable report, shared by
//! the agent CLI and the MCP server: what ran, what came back, and whether
//! the output looks dry (`suspicionOf`). Self-heal (verdict prompts, the cure
//! check, the commit) builds on this in heal.zig.

const std = @import("std");
const lp = @import("lightpanda");
const ScriptRuntime = lp.Runtime;
const extract = @import("extract.zig");
const string = @import("../string.zig");

/// What a completed run returned, judged from its display text — what the
/// model saw is what is judged. Computed on demand by `returned`, so a plain
/// replay never parses its result.
pub const Returned = enum {
    /// No `return`, or a value whose display form couldn't be computed.
    none,
    /// A value carrying data.
    data,
    /// A deep-empty value.
    empty,
};

/// Facts about a run that completed without throwing — suspicion is judged by
/// the model, never here. Duped into the caller's arena — the runtime dies
/// with the run.
pub const RunFacts = struct {
    /// Display text of the returned value — uncapped, so `returned` judges the
    /// whole value; null when the run returned nothing.
    completion: ?[]const u8,
    extract_stats: []const extract.ExtractStat,
    source: []const u8,
};

/// `allocator` only backs the throwaway parse; nothing is retained. Non-JSON
/// display text (a function, a circular object's fallback coercion) counts as
/// data.
pub fn returned(allocator: std.mem.Allocator, facts: RunFacts) error{OutOfMemory}!Returned {
    const text = facts.completion orelse return .none;
    if (text.len == 0) return .empty;
    const parsed = (try extract.parseJsonLenient(allocator, text)) orelse return .data;
    return if (extract.jsonIsEmpty(parsed)) .empty else .data;
}

/// The failure with the text that produced it. `source` is the exact text
/// that ran, so a heal diagnoses what actually failed instead of re-reading a
/// possibly-changed file; the failure's slices are duped into the caller's
/// arena.
pub const ScriptError = struct {
    failure: WireFailure,
    source: []const u8,
};

pub const Classified = union(enum) {
    facts: RunFacts,
    script_error: ScriptError,
};

/// Map a run's raw result to facts or a `threw` finding. The error text and
/// stats are duped into `arena` — they live in the runtime's per-call arena —
/// but `source` is stored as given: the caller owns it and it must outlive
/// the outcome. Presentation (terminal output, cancellation policy) stays
/// with the caller.
pub fn classifyRun(arena: std.mem.Allocator, result: ScriptRuntime.RunResult, source: []const u8) error{OutOfMemory}!Classified {
    switch (result) {
        .err => |message| return .{ .script_error = .{
            .failure = .{ .kind = .threw, .detail = try arena.dupe(u8, message) },
            .source = source,
        } },
        .ok => |ok| return .{ .facts = .{
            .completion = if (ok.completion) |c| try arena.dupe(u8, c) else null,
            .extract_stats = try dupeExtractStats(arena, ok.extract_stats),
            .source = source,
        } },
    }
}

fn dupeExtractStats(arena: std.mem.Allocator, stats: []const extract.ExtractStat) error{OutOfMemory}![]const extract.ExtractStat {
    const out = try arena.alloc(extract.ExtractStat, stats.len);
    for (stats, out) |stat, *o| {
        o.* = .{
            .schema = try arena.dupe(u8, stat.schema),
            .field = try arena.dupe(u8, stat.field),
            .calls = stat.calls,
            .nonempty = stat.nonempty,
        };
    }
    return out;
}

/// Bound a value or schema echoed into a finding; a degenerate empty-ish
/// result (hundreds of all-null rows) would otherwise bloat the LLM turn.
const detail_max_bytes: usize = 2048;

fn capDetail(arena: std.mem.Allocator, text: []const u8) []const u8 {
    return string.capBytes(arena, text, detail_max_bytes);
}

/// A finding worth a verdict, not yet confirmed: the return value was
/// deep-empty, or some extract field came back empty on every call — any field,
/// scalar or list, baseline or not. Whether that is breakage or legitimate
/// sparseness is the model's judgment, not encoded here.
pub fn suspicionOf(arena: std.mem.Allocator, facts: RunFacts) ?ScriptError {
    switch (returned(arena, facts) catch return null) {
        .empty => return .{
            .failure = .{
                .kind = .empty,
                .detail = std.fmt.allocPrint(arena, "its return value carries no data: {s}", .{capDetail(arena, facts.completion.?)}) catch return null,
            },
            .source = facts.source,
        },
        .none, .data => {},
    }
    return dryExtractsFinding(arena, facts.source, facts.extract_stats) catch return null;
}

/// A `dry_extracts` finding with one detail line per extract field that came
/// back empty on every call, plus the field names for the cure check. Null when
/// no field was dry.
fn dryExtractsFinding(arena: std.mem.Allocator, source: []const u8, stats: []const extract.ExtractStat) error{OutOfMemory}!?ScriptError {
    var out: std.ArrayList(u8) = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    for (stats) |stat| {
        if (stat.nonempty != 0) continue;
        if (fields.items.len == 0) try out.appendSlice(arena, "some extracts came back empty on every call:\n");
        // `stat.field` already lives in `arena` (facts were duped into it).
        try fields.append(arena, stat.field);
        try writeDryExtractLine(arena, &out, stat);
    }
    if (fields.items.len == 0) return null;
    return .{ .failure = .{ .kind = .dry_extracts, .detail = out.items, .dry_fields = fields.items }, .source = source };
}

/// One detail line for an extract field that came back empty on every call.
/// Shared with heal's cure check, which reports the fields still dry.
pub fn writeDryExtractLine(arena: std.mem.Allocator, out: *std.ArrayList(u8), stat: extract.ExtractStat) error{OutOfMemory}!void {
    const schema = capDetail(arena, stat.schema);
    if (stat.field.len != 0) {
        try out.print(arena, "- the \"{s}\" field in extract({s}) came back empty", .{ stat.field, schema });
    } else {
        try out.print(arena, "- extract({s}) returned no data", .{schema});
    }
    if (stat.calls != 1) try out.print(arena, " in all {d} calls", .{stat.calls});
    try out.append(arena, '\n');
}

/// Bound for script source echoed into reports and LLM turns — a script is
/// human-scale, but a synthesized one with an embedded blob shouldn't balloon
/// them.
const source_max_bytes = 64 * 1024;

/// `source` bounded for a report or an LLM turn; the input itself when it
/// fits.
pub fn cappedSource(arena: std.mem.Allocator, source: []const u8) []const u8 {
    return string.capBytes(arena, source, source_max_bytes);
}

const max_script_bytes = 10 * 1024 * 1024;

/// The script at `path`, bounded. Shared by both replay surfaces.
pub fn readScriptFile(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(lp.io, path, arena, .limited(max_script_bytes));
}

/// Overwrite `path` with `content`, newline-terminated. Shared by the MCP
/// `save` tool and heal's commit.
pub fn writeScriptFile(path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(lp.io, path, .{ .truncate = true });
    defer file.close(lp.io);
    try file.writeStreamingAll(lp.io, content);
    if (content.len > 0 and content[content.len - 1] != '\n') try file.writeStreamingAll(lp.io, "\n");
}

/// `failure` as it rides in reports — the wire-serializable core of
/// `ScriptError`, whose `source` reports echo separately.
pub const WireFailure = struct {
    kind: Kind,
    /// Formatted error (line, stack) — or, for `empty`, what came back.
    detail: []const u8 = "",
    /// For `dry_extracts`: the field names that were empty on every call
    /// ("" = a whole-array schema). The cure check requires each one to
    /// come back with data before a heal may replace the file.
    dry_fields: []const []const u8 = &.{},

    /// `empty` is a run that completed but returned a value with no data in
    /// it; `dry_extracts` one whose return value had data, but where some
    /// extract list field came back empty on every call. Both are the usual
    /// symptom of a stale selector, which matches nothing instead of throwing.
    /// Only heal treats them as failures; a plain replay still exits 0, since
    /// an empty answer can be the right answer.
    pub const Kind = enum { threw, empty, dry_extracts };
};

pub const ConsoleLine = struct {
    level: []const u8,
    text: []const u8,
};

/// One replay, serializable: what ran, what came back, and — when the run
/// failed or looks dry — the finding and how to proceed.
pub const RunReport = struct {
    status: Status,
    path: []const u8,
    returned: Returned = .none,
    extracts: []const extract.ExtractStat = &.{},
    failure: ?WireFailure = null,
    console: []const ConsoleLine = &.{},
    console_truncated: bool = false,
    /// Scrubbed source that actually ran; set on suspicious/failed so the
    /// client can diagnose without re-reading a possibly-changed file.
    source: ?[]const u8 = null,
    guidance: ?[]const u8 = null,

    pub const Status = enum { ok, suspicious, failed };
};

const testing = @import("../testing.zig");

pub fn testFacts(completion: ?[]const u8, stats: []const extract.ExtractStat) RunFacts {
    return .{ .completion = completion, .extract_stats = stats, .source = "" };
}

test "returned: judges the display text; numbers and booleans are data" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // The shapes a stale extract selector produces: an empty list, or rows
    // whose every field missed.
    const empty = [_][]const u8{ "[]", "{}", "null", "{\"stories\":[]}", "[{\"id\":null,\"title\":\"\"}]", "" };
    for (empty) |text| try std.testing.expectEqual(Returned.empty, try returned(aa, testFacts(text, &.{})));

    // Plain strings display without quotes, so they aren't JSON — still data.
    const data = [_][]const u8{ "[{\"id\":null,\"title\":\"HN\"}]", "text", "0", "false", "[object Object]" };
    for (data) |text| try std.testing.expectEqual(Returned.data, try returned(aa, testFacts(text, &.{})));

    try std.testing.expectEqual(Returned.none, try returned(aa, testFacts(null, &.{})));
}

test "suspicionOf: any all-empty field is suspect, none is not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const sparse: []const extract.ExtractStat = &.{
        .{ .schema = "{}", .field = "comments", .calls = 5, .nonempty = 3 },
    };
    try std.testing.expectEqual(null, suspicionOf(aa, testFacts("[1]", sparse)));

    // Scalar all-empty is suspect too — judgment belongs to the model now.
    const dry_scalar: []const extract.ExtractStat = &.{
        .{ .schema = "{}", .field = "title", .calls = 3, .nonempty = 0 },
    };
    const s = suspicionOf(aa, testFacts("[1]", dry_scalar)).?;
    try std.testing.expectEqual(WireFailure.Kind.dry_extracts, s.failure.kind);
    try std.testing.expectEqual(1, s.failure.dry_fields.len);

    const empty_facts = testFacts("[]", &.{});
    const e = suspicionOf(aa, empty_facts).?;
    try std.testing.expectEqual(WireFailure.Kind.empty, e.failure.kind);
    try std.testing.expect(std.mem.endsWith(u8, e.failure.detail, ": []"));
}

test "classifyRun: maps err to threw, dupes the completion text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const threw = try classifyRun(aa, .{ .err = "boom at line 2" }, "return 1;");
    try std.testing.expectEqual(WireFailure.Kind.threw, threw.script_error.failure.kind);
    try std.testing.expectEqualStrings("boom at line 2", threw.script_error.failure.detail);
    try std.testing.expectEqualStrings("return 1;", threw.script_error.source);

    const text: []const u8 = "[]";
    const empty = try classifyRun(aa, .{ .ok = .{ .completion = text, .extract_stats = &.{} } }, "return [];");
    try std.testing.expectEqualStrings("[]", empty.facts.completion.?);
    try std.testing.expect(empty.facts.completion.?.ptr != text.ptr);
    try std.testing.expectEqual(Returned.empty, try returned(aa, empty.facts));

    const data = try classifyRun(aa, .{ .ok = .{
        .completion = "[1]",
        .extract_stats = &.{.{ .schema = "{}", .field = "a", .calls = 1, .nonempty = 1 }},
    } }, "return [1];");
    try std.testing.expectEqual(Returned.data, try returned(aa, data.facts));
    try std.testing.expectEqual(1, data.facts.extract_stats.len);

    const none = try classifyRun(aa, .{ .ok = .{ .completion = null, .extract_stats = &.{} } }, "1;");
    try std.testing.expectEqual(Returned.none, try returned(aa, none.facts));
}

test "RunReport serializes to the wire shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const report: RunReport = .{
        .status = .suspicious,
        .path = "hn.js",
        .returned = .data,
        .extracts = &.{.{ .schema = "{}", .field = "title", .calls = 3, .nonempty = 0 }},
        .failure = .{ .kind = .dry_extracts, .detail = "dry", .dry_fields = &.{"title"} },
        .console = &.{.{ .level = "log", .text = "hello" }},
    };
    const json = try std.json.Stringify.valueAlloc(aa, report, .{ .emit_null_optional_fields = false });
    try testing.expectJson(.{
        .status = "suspicious",
        .path = "hn.js",
        .returned = "data",
        .extracts = .{.{ .schema = "{}", .field = "title", .calls = 3, .nonempty = 0 }},
        .failure = .{ .kind = "dry_extracts", .detail = "dry", .dry_fields = .{"title"} },
        .console = .{.{ .level = "log", .text = "hello" }},
        .console_truncated = false,
    }, json);
}
