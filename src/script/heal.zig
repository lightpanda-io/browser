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

//! Deterministic core of script self-heal, shared by the agent CLI and the
//! MCP server: breakage suspicion over a replay's facts, the cure check that
//! gates a healed script's commit, and the serializable run/heal reports.
//! Model judgment (verdict, diagnosis, revision) stays with the caller — the
//! agent's own LLM on the CLI path, the MCP client's model over MCP.

const std = @import("std");
const lp = @import("lightpanda");
const ScriptRuntime = lp.Runtime;
const Baseline = lp.Baseline;
const string = @import("../string.zig");

/// What a completed run returned, as far as heal cares.
pub const Returned = union(enum) {
    /// No `return`, or a value whose display form couldn't be computed.
    none,
    /// A value carrying data.
    data,
    /// A deep-empty value, carrying its capped display text.
    empty: []const u8,
};

/// Facts about a run that completed without throwing — suspicion is judged by
/// the model, never here. Duped into the caller's arena — the runtime dies
/// with the run.
pub const RunFacts = struct {
    returned: Returned,
    extract_stats: []const ScriptRuntime.ExtractStat,
    source: []const u8,
};

/// Both slices are duped into the caller's arena. `source` is the exact text
/// that ran, so a heal diagnoses what actually failed instead of re-reading a
/// possibly-changed file.
pub const ScriptError = struct {
    kind: Kind,
    /// Formatted error (line, stack) — or, for `empty`, what came back.
    detail: []const u8,
    source: []const u8,
    /// For `dry_extracts`: the field names that were empty on every call
    /// (null = a whole-array schema). The cure check requires each one to
    /// come back with data before a heal may replace the file.
    dry_fields: []const ?[]const u8 = &.{},

    /// `empty` is a run that completed but returned a value with no data in
    /// it; `dry_extracts` one whose return value had data, but where some
    /// extract list field came back empty on every call. Both are the usual
    /// symptom of a stale selector, which matches nothing instead of throwing.
    /// Only heal treats them as failures; a plain replay still exits 0, since
    /// an empty answer can be the right answer.
    pub const Kind = enum { threw, empty, dry_extracts };
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
            .kind = .threw,
            .detail = try arena.dupe(u8, message),
            .source = source,
        } },
        .ok => |ok| {
            const returned: Returned = if (ok.completion) |c|
                (if (c.empty) .{ .empty = try capDetail(arena, c.text) } else .data)
            else
                .none;
            return .{ .facts = .{
                .returned = returned,
                .extract_stats = try dupeExtractStats(arena, ok.extract_stats),
                .source = source,
            } };
        },
    }
}

fn dupeExtractStats(arena: std.mem.Allocator, stats: []const ScriptRuntime.ExtractStat) error{OutOfMemory}![]const ScriptRuntime.ExtractStat {
    const out = try arena.alloc(ScriptRuntime.ExtractStat, stats.len);
    for (stats, out) |stat, *o| {
        o.* = .{
            .schema = try arena.dupe(u8, stat.schema),
            .field = if (stat.field) |f| try arena.dupe(u8, f) else null,
            .calls = stat.calls,
            .empty = stat.empty,
        };
    }
    return out;
}

/// Bound a value or schema echoed into a heal message; a degenerate empty-ish
/// result (hundreds of all-null rows) would otherwise bloat the LLM turn.
const detail_max_bytes: usize = 2048;

/// `string.capBytes` at `detail_max_bytes`, always duped — `RunFacts` details
/// must outlive the runtime whose arena the text came from.
fn capDetail(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    return arena.dupe(u8, string.capBytes(arena, text, detail_max_bytes));
}

/// A finding worth a verdict, not yet confirmed: the return value was
/// deep-empty, or some extract field came back empty on every call — any field,
/// scalar or list, baseline or not. Whether that is breakage or legitimate
/// sparseness is the model's judgment, not encoded here.
pub fn suspicionOf(arena: std.mem.Allocator, facts: RunFacts) ?ScriptError {
    switch (facts.returned) {
        .empty => |text| return .{
            .kind = .empty,
            .detail = std.fmt.allocPrint(arena, "its return value carries no data: {s}", .{text}) catch return null,
            .source = facts.source,
        },
        .none, .data => {},
    }
    return dryExtractsFinding(arena, facts.source, facts.extract_stats) catch return null;
}

/// A `dry_extracts` finding with one detail line per extract field that came
/// back empty on every call, plus the field names for the cure check. Null when
/// no field was dry.
fn dryExtractsFinding(arena: std.mem.Allocator, source: []const u8, stats: []const ScriptRuntime.ExtractStat) !?ScriptError {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var fields: std.ArrayList(?[]const u8) = .empty;
    for (stats) |stat| {
        if (stat.empty != stat.calls) continue;
        if (fields.items.len == 0) {
            try aw.writer.writeAll("some extracts came back empty on every call:\n");
        }
        // `stat.field` already lives in `arena` (facts were duped into it).
        try fields.append(arena, stat.field);
        const schema = try capDetail(arena, stat.schema);
        if (stat.field) |field| {
            try aw.writer.print("- the \"{s}\" field in extract({s}) came back empty", .{ field, schema });
        } else {
            try aw.writer.print("- extract({s}) returned no data", .{schema});
        }
        if (stat.calls != 1) try aw.writer.print(" in all {d} calls", .{stat.calls});
        try aw.writer.writeAll("\n");
    }
    if (fields.items.len == 0) return null;
    return .{ .kind = .dry_extracts, .detail = aw.written(), .source = source, .dry_fields = fields.items };
}

/// Null when the validation run cured the original finding; otherwise the
/// message fed to the next heal attempt. Running clean is not a cure on its
/// own — a revision that deletes the failing extract (or the `return`) also
/// runs clean.
pub fn cureFailure(arena: std.mem.Allocator, first: ScriptError, facts: RunFacts) error{OutOfMemory}!?[]const u8 {
    switch (first.kind) {
        .threw => return null,
        .empty => return if (facts.returned == .data)
            null
        else
            "The revised script ran, but still returns no data (or no longer returns anything) — the original returned a value.",
        .dry_extracts => {
            for (first.dry_fields) |dry| {
                const cured = for (facts.extract_stats) |stat| {
                    if (ScriptRuntime.fieldEql(stat.field, dry) and stat.empty < stat.calls) break true;
                } else false;
                if (!cured) return try std.fmt.allocPrint(arena, "The revised script ran, but the \"{s}\" extract still came back empty on every call (or was removed) — keep it and fix its selector.", .{dry orelse "<whole result>"});
            }
            return null;
        },
    }
}

pub fn refreshedBaselineScript(arena: std.mem.Allocator, revised: []const u8, stats: []const ScriptRuntime.ExtractStat) ?[]const u8 {
    const line = Baseline.serializeStats(arena, stats) catch return null;
    return Baseline.withBaseline(arena, revised, line) catch null;
}

pub fn buildDiagnoseMessage(arena: std.mem.Allocator, path: []const u8, source: []const u8, error_detail: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\Replaying the saved script {s} failed. The browser session is still
        \\at the failure state.
        \\
        \\The script (its comments and structure carry the intent):
        \\```js
        \\{s}
        \\```
        \\
        \\The error:
        \\{s}
        \\
        \\Diagnose the failure: inspect the live page (tree, findElement,
        \\markdown) to see how the site differs from what the script expects,
        \\then perform the corrected step(s) with tools to prove they work —
        \\verify selectors against the live page, never guess. If the failing
        \\step gated the rest of the script (a login, a navigation), carry on
        \\far enough to show the script's goal is reachable again.
    , .{ path, source, error_detail });
}

/// Heal synthesis instruction; rides on the regular save revision system prompt.
pub const heal_revision_prompt =
    \\Fix the script so it replays successfully against the current site: the
    \\error names what broke, and the diagnosis tool calls above that
    \\succeeded against the live page show the repair. Keep
    \\every step, selector, and output shape that still works unchanged.
    \\Preserve the script's `//` intent comments; where you change a block,
    \\update its comment so it still describes what the revised code does, and
    \\add one for any block that lacks it.
;

// Fixed next-step guidance embedded in MCP replay reports. Templates only —
// page-derived content rides in the report's data fields, never here.

pub const replay_failed_guidance =
    \\The replay failed and the session is still at the failure state.
    \\Diagnose the failure: inspect the live page (tree, findElement,
    \\markdown) to see how the site differs from what the script expects —
    \\`source` carries the intent in its comments and structure — then
    \\perform the corrected step(s) with tools to prove they work: verify
    \\selectors against the live page, never guess. If the failing step gated
    \\the rest of the script (a login, a navigation), carry on far enough to
    \\show the script's goal is reachable again. Then call heal_commit with
    \\the revised script and this report's `failure` object echoed back
    \\verbatim.
;

pub const replay_suspicious_guidance =
    \\The replay completed without errors, but its output looks dry — decide
    \\whether the script is broken (stale selectors after a site change) or
    \\the result is legitimate (the page genuinely has no such data right
    \\now). A `
++ std.mem.trimEnd(u8, Baseline.marker, " ") ++
    \\` comment in `source`, when present, records how often
    \\each output field carried data when the script was saved — weigh it as
    \\evidence. If legitimate, stop: the empty answer is the answer. If
    \\broken, diagnose against the live session (tree, findElement,
    \\markdown), prove the corrected step(s) with tools, then call
    \\heal_commit with the revised script and this report's `failure` object
    \\echoed back verbatim.
;

/// `failure` as it rides in reports and back through `heal_commit`: same
/// shape as the model-facing verdict wire, with "" standing in for a
/// whole-array extract (JSON has no place for null-in-a-string-array).
pub const WireFailure = struct {
    kind: ScriptError.Kind,
    detail: []const u8 = "",
    dry_fields: []const []const u8 = &.{},
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
    returned: std.meta.Tag(Returned) = .none,
    extracts: []const ScriptRuntime.ExtractStat = &.{},
    failure: ?WireFailure = null,
    console: []const ConsoleLine = &.{},
    console_truncated: bool = false,
    /// Scrubbed source that actually ran; set on suspicious/failed so the
    /// client can diagnose without re-reading a possibly-changed file.
    source: ?[]const u8 = null,
    guidance: ?[]const u8 = null,

    pub const Status = enum { ok, suspicious, failed };
};

/// One `heal_commit` validation, serializable. `failure` is the residual cure
/// failure (or the validation run's own error); null when cured. The script's
/// path rides in `run.path`.
pub const HealReport = struct {
    cured: bool,
    committed: bool,
    failure: ?[]const u8 = null,
    run: RunReport,
};

pub fn wireFailure(arena: std.mem.Allocator, e: ScriptError) error{OutOfMemory}!WireFailure {
    const fields = try arena.alloc([]const u8, e.dry_fields.len);
    for (e.dry_fields, fields) |f, *out| out.* = f orelse "";
    return .{ .kind = e.kind, .detail = e.detail, .dry_fields = fields };
}

pub fn scriptErrorFromWire(arena: std.mem.Allocator, w: WireFailure) error{OutOfMemory}!ScriptError {
    const fields = try arena.alloc(?[]const u8, w.dry_fields.len);
    for (w.dry_fields, fields) |f, *out| out.* = if (f.len == 0) null else f;
    return .{ .kind = w.kind, .detail = w.detail, .source = "", .dry_fields = fields };
}

const testing = @import("../testing.zig");

fn testFacts(returned: Returned, stats: []const ScriptRuntime.ExtractStat) RunFacts {
    return .{ .returned = returned, .extract_stats = stats, .source = "" };
}

test "cureFailure: running clean is not a cure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const dry: ScriptError = .{
        .kind = .dry_extracts,
        .detail = "",
        .source = "",
        .dry_fields = &.{ @as(?[]const u8, "comments"), null },
    };
    const cured_stats: []const ScriptRuntime.ExtractStat = &.{
        .{ .schema = "{}", .field = "comments", .calls = 5, .empty = 2 },
        .{ .schema = "[]", .field = null, .calls = 1, .empty = 0 },
    };
    try std.testing.expectEqual(null, try cureFailure(aa, dry, testFacts(.data, cured_stats)));

    // Fix-by-deletion: the dry field is simply gone from the revised run.
    const deleted = (try cureFailure(aa, dry, testFacts(.data, cured_stats[1..]))).?;
    try std.testing.expect(std.mem.indexOf(u8, deleted, "\"comments\"") != null);

    // Still dry counts as uncured.
    const still_dry_stats: []const ScriptRuntime.ExtractStat = &.{
        .{ .schema = "{}", .field = "comments", .calls = 5, .empty = 5 },
        cured_stats[1],
    };
    try std.testing.expect((try cureFailure(aa, dry, testFacts(.data, still_dry_stats))) != null);

    // .empty is cured only by a data-carrying return.
    const empty: ScriptError = .{ .kind = .empty, .detail = "", .source = "" };
    try std.testing.expectEqual(null, try cureFailure(aa, empty, testFacts(.data, &.{})));
    try std.testing.expect((try cureFailure(aa, empty, testFacts(.none, &.{}))) != null);

    // .threw needs nothing beyond running clean.
    const threw: ScriptError = .{ .kind = .threw, .detail = "", .source = "" };
    try std.testing.expectEqual(null, try cureFailure(aa, threw, testFacts(.none, &.{})));
}

test "suspicionOf: any all-empty field is suspect, none is not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const sparse: []const ScriptRuntime.ExtractStat = &.{
        .{ .schema = "{}", .field = "comments", .calls = 5, .empty = 2 },
    };
    try std.testing.expectEqual(null, suspicionOf(aa, testFacts(.data, sparse)));

    // Scalar all-empty is suspect too — judgment belongs to the model now.
    const dry_scalar: []const ScriptRuntime.ExtractStat = &.{
        .{ .schema = "{}", .field = "title", .calls = 3, .empty = 3 },
    };
    const s = suspicionOf(aa, testFacts(.data, dry_scalar)).?;
    try std.testing.expectEqual(ScriptError.Kind.dry_extracts, s.kind);
    try std.testing.expectEqual(1, s.dry_fields.len);

    const empty_facts = testFacts(.{ .empty = "[]" }, &.{});
    try std.testing.expectEqual(ScriptError.Kind.empty, suspicionOf(aa, empty_facts).?.kind);
}

test "classifyRun: maps err to threw, completion emptiness to returned" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const threw = try classifyRun(aa, .{ .err = "boom at line 2" }, "return 1;");
    try std.testing.expectEqual(ScriptError.Kind.threw, threw.script_error.kind);
    try std.testing.expectEqualStrings("boom at line 2", threw.script_error.detail);
    try std.testing.expectEqualStrings("return 1;", threw.script_error.source);

    const empty = try classifyRun(aa, .{ .ok = .{
        .completion = .{ .text = "[]", .empty = true },
        .extract_stats = &.{},
    } }, "return [];");
    try std.testing.expectEqualStrings("[]", empty.facts.returned.empty);

    const data = try classifyRun(aa, .{ .ok = .{
        .completion = .{ .text = "[1]", .empty = false },
        .extract_stats = &.{.{ .schema = "{}", .field = "a", .calls = 1, .empty = 0 }},
    } }, "return [1];");
    try std.testing.expectEqual(Returned.data, data.facts.returned);
    try std.testing.expectEqual(1, data.facts.extract_stats.len);

    const none = try classifyRun(aa, .{ .ok = .{ .completion = null, .extract_stats = &.{} } }, "1;");
    try std.testing.expectEqual(Returned.none, none.facts.returned);
}

test "wire failure round-trips, empty string standing in for null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const original: ScriptError = .{
        .kind = .dry_extracts,
        .detail = "dry",
        .source = "return 1;",
        .dry_fields = &.{ @as(?[]const u8, "comments"), null },
    };
    const wire = try wireFailure(aa, original);
    try std.testing.expectEqualStrings("comments", wire.dry_fields[0]);
    try std.testing.expectEqualStrings("", wire.dry_fields[1]);

    const back = try scriptErrorFromWire(aa, wire);
    try std.testing.expectEqual(original.kind, back.kind);
    try std.testing.expectEqualStrings("comments", back.dry_fields[0].?);
    try std.testing.expectEqual(null, back.dry_fields[1]);
}

test "RunReport serializes to the wire shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const report: RunReport = .{
        .status = .suspicious,
        .path = "hn.js",
        .returned = .data,
        .extracts = &.{.{ .schema = "{}", .field = "title", .calls = 3, .empty = 3 }},
        .failure = .{ .kind = .dry_extracts, .detail = "dry", .dry_fields = &.{"title"} },
        .console = &.{.{ .level = "log", .text = "hello" }},
    };
    const json = try std.json.Stringify.valueAlloc(aa, report, .{ .emit_null_optional_fields = false });
    try testing.expectJson(.{
        .status = "suspicious",
        .path = "hn.js",
        .returned = "data",
        .extracts = .{.{ .schema = "{}", .field = "title", .calls = 3, .empty = 3 }},
        .failure = .{ .kind = "dry_extracts", .detail = "dry", .dry_fields = .{"title"} },
        .console = .{.{ .level = "log", .text = "hello" }},
        .console_truncated = false,
    }, json);
}
