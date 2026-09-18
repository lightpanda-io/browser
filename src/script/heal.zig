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
//! MCP server: the cure check that gates a healed script's commit, the atomic
//! commit itself, and the prompt/guidance text. Replay classification and
//! suspicion live in replay.zig. Model judgment (verdict, diagnosis, revision)
//! stays with the caller — the agent's own LLM on the CLI path, the MCP
//! client's model over MCP.

const std = @import("std");
const lp = @import("lightpanda");
const Baseline = lp.Baseline;
const extract = @import("extract.zig");
const replay = @import("replay.zig");
const string = @import("../string.zig");

const RunFacts = replay.RunFacts;
const Failure = replay.Failure;

/// Outcome of one heal validation run against the original failure.
pub const ValidationOutcome = union(enum) {
    /// The validation run's own `threw`, or — for a clean run that did not
    /// cure `first` — `.empty` for a still-empty return, `.dry_extracts`
    /// naming every field still dry (or gone).
    uncured: Failure,
    /// Cured, but swapping the file failed; the message names the leftover
    /// `.heal.js` path.
    cured_uncommitted: []const u8,
    committed,
};

/// `first` narrowed to the dry fields a verdict judged broken — the fields a
/// model or client omits are accepted as legitimately empty. Never widens or
/// retargets: the kind is fixed, names outside `first.dry_fields` are dropped
/// (a hallucinated name could never be cured), and an empty or all-unknown
/// `judged` leaves `first` unchanged.
pub fn narrowTarget(arena: std.mem.Allocator, first: Failure, judged: []const []const u8) error{OutOfMemory}!Failure {
    if (first.kind != .dry_extracts or judged.len == 0) return first;
    var kept: std.ArrayList([]const u8) = .empty;
    for (first.dry_fields) |dry| {
        if (string.isOneOf(dry, judged)) try kept.append(arena, dry);
    }
    if (kept.items.len == 0) return first;
    return .{ .kind = first.kind, .detail = first.detail, .dry_fields = kept.items };
}

/// Judge a validation run of `script` against the `first` failure it was
/// meant to cure, and commit it into `path` when — and only when — it cured.
/// Callers pass the same (possibly `narrowTarget`ed) finding on every attempt,
/// never a residual — attempt two could otherwise delete a field attempt one
/// fixed.
pub fn validationOutcome(arena: std.mem.Allocator, path: []const u8, script: []const u8, first: Failure, outcome: replay.RunOutcome) error{OutOfMemory}!ValidationOutcome {
    switch (outcome.run) {
        .threw => |failure| return .{ .uncured = failure },
        .facts => |facts| {
            if (try cureFailure(arena, first, facts)) |residual| return .{ .uncured = residual };
            if (try commitValidated(arena, path, script, facts.extract_stats)) |failure| return .{ .cured_uncommitted = failure };
            return .committed;
        },
    }
}

/// Null when the validation run cured the original finding; otherwise the
/// residual fed to the next heal attempt. Running clean is not a cure on its
/// own — a revision that deletes the failing extract (or the `return`) also
/// runs clean.
fn cureFailure(arena: std.mem.Allocator, first: Failure, facts: RunFacts) error{OutOfMemory}!?Failure {
    switch (first.kind) {
        .threw => return null,
        .empty => {
            if (facts.returned == .data) return null;
            return .{
                .kind = .empty,
                .detail = "The revised script ran, but still returns no data (or no longer returns anything) — the original returned a value.",
            };
        },
        .dry_extracts => {
            var out: std.ArrayList(u8) = .empty;
            var fields: std.ArrayList([]const u8) = .empty;
            for (first.dry_fields) |dry| {
                var seen = false;
                const cured = for (facts.extract_stats) |stat| {
                    if (!std.mem.eql(u8, stat.field, dry)) continue;
                    seen = true;
                    if (stat.nonempty > 0) break true;
                } else false;
                if (cured) continue;
                if (fields.items.len == 0) try out.appendSlice(arena, "The revised script ran, but did not cure it — keep every listed extract and fix its selector:\n");
                try fields.append(arena, dry);
                if (!seen) {
                    try out.print(arena, "- the \"{s}\" extract is gone from the revised script\n", .{if (dry.len == 0) "<whole result>" else dry});
                    continue;
                }
                for (facts.extract_stats) |stat| {
                    if (std.mem.eql(u8, stat.field, dry)) try replay.writeDryExtractLine(arena, &out, stat);
                }
            }
            if (fields.items.len == 0) return null;
            return .{ .kind = .dry_extracts, .detail = out.items, .dry_fields = fields.items };
        },
    }
}

/// Suffix of the on-disk file `commitValidated` swaps through.
pub const tmp_suffix = ".heal.js";

/// Atomically swap the validated revision into `path`, its baseline refreshed
/// from the validation run — synthesis may have copied the stale one from the
/// broken script. Returns the failure message, or null once `path` holds the
/// revision; after a failed rename the revision is deliberately kept on disk.
fn commitValidated(arena: std.mem.Allocator, path: []const u8, script: []const u8, stats: []const extract.ExtractStat) error{OutOfMemory}!?[]const u8 {
    const line = try Baseline.serializeStats(arena, stats);
    const final = try Baseline.withBaseline(arena, script, line);
    const tmp_path = try std.mem.concat(arena, u8, &.{ path, tmp_suffix });
    replay.writeScriptFile(tmp_path, final) catch |err| {
        std.Io.Dir.cwd().deleteFile(lp.io, tmp_path) catch {};
        return try std.fmt.allocPrint(arena, "validated, but writing {s} failed: {s}", .{ tmp_path, @errorName(err) });
    };
    const cwd = std.Io.Dir.cwd();
    cwd.rename(tmp_path, cwd, path, lp.io) catch |err| {
        return try std.fmt.allocPrint(arena, "validated, but replacing {s} failed: {s} (revision left at {s})", .{ path, @errorName(err), tmp_path });
    };
    return null;
}

/// fmt fragment taking the script source as its one argument; shared by the
/// diagnose message and the CLI verdict turn.
pub const script_intent_block =
    \\The script (its comments and structure carry the intent):
    \\```js
    \\{s}
    \\```
;

/// The diagnose protocol, shared by the CLI heal turn and the MCP
/// failed-replay guidance.
pub const diagnose_instructions =
    \\Diagnose the failure: inspect the live page (tree, findElement,
    \\markdown) to see how the site differs from what the script expects,
    \\then perform the corrected step(s) with tools to prove they work —
    \\verify selectors against the live page, never guess. If the failing
    \\step gated the rest of the script (a login, a navigation), carry on
    \\far enough to show the script's goal is reachable again.
;

pub fn buildDiagnoseMessage(arena: std.mem.Allocator, path: []const u8, source: []const u8, error_detail: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\Replaying the saved script {s} failed. The browser session is still
        \\at the failure state.
        \\
        \\
    ++ script_intent_block ++
        \\
        \\
        \\The error:
        \\{s}
        \\
        \\
    ++ diagnose_instructions, .{ path, replay.cappedSource(arena, source), error_detail });
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
    \\`source` carries the script's intent in its comments and structure.
    \\
++ diagnose_instructions ++
    \\ Then call
    \\heal_commit with the revised script; it is validated against this
    \\report's `failure` before the file is replaced.
;

/// Shared by the CLI verdict prompt and the MCP suspicious-replay guidance.
pub const baseline_evidence_note =
    \\A `
++ std.mem.trimEnd(u8, Baseline.marker, " ") ++
    \\` comment in the script, when present, records how
    \\often each output field carried data when the script was saved — weigh
    \\it as evidence.
;

/// The broken-vs-legitimate decision, shared by both judgment surfaces.
pub const broken_or_legitimate_question =
    \\the script is broken (stale selectors after a site change) or the empty
    \\output is legitimate (the page genuinely has no such data right now).
;

pub const replay_suspicious_guidance =
    \\The replay completed without errors, but its output looks dry — decide
    \\whether
    \\
++ broken_or_legitimate_question ++
    \\
    \\
++ baseline_evidence_note ++
    \\
    \\If legitimate, stop: the empty answer is the answer. If broken,
    \\diagnose against the live session (tree, findElement, markdown), prove
    \\the corrected step(s) with tools, then call heal_commit with the
    \\revised script; it is validated against this report's `failure` before
    \\the file is replaced.
;

/// The next-step guidance a replay report carries for its status.
pub fn guidanceFor(status: replay.RunReport.Status) ?[]const u8 {
    return switch (status) {
        .ok => null,
        .failed => replay_failed_guidance,
        .suspicious => replay_suspicious_guidance,
    };
}

/// One `heal_commit` validation, serializable. The script's path rides in
/// `run.path`.
pub const HealReport = struct {
    cured: bool = false,
    committed: bool = false,
    /// The residual finding — or the validation run's own `threw`; null when
    /// cured.
    failure: ?Failure = null,
    /// Cured, but the file swap failed; names the leftover `.heal.js`.
    commit_error: ?[]const u8 = null,
    run: replay.RunReport,

    pub fn init(outcome: ValidationOutcome, run: replay.RunReport) HealReport {
        return switch (outcome) {
            .uncured => |failure| .{ .failure = failure, .run = run },
            .cured_uncommitted => |message| .{ .cured = true, .commit_error = message, .run = run },
            .committed => .{ .cured = true, .committed = true, .run = run },
        };
    }
};

test "validationOutcome: failed run and uncured facts never reach the commit" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const dry: Failure = .{ .kind = .dry_extracts, .dry_fields = &.{"comments"} };

    const failed = try validationOutcome(aa, "s.js", "return 1;", dry, .{
        .source = "return 1;",
        .run = .{ .threw = .{ .kind = .threw, .detail = "boom at line 2" } },
    });
    try std.testing.expectEqual(Failure.Kind.threw, failed.uncured.kind);
    try std.testing.expectEqualStrings("boom at line 2", failed.uncured.detail);

    const still_dry: replay.RunOutcome = .{ .source = "return 1;", .run = .{ .facts = .{
        .completion = "1",
        .returned = .data,
        .extract_stats = &.{.{ .schema = "{}", .field = "comments", .calls = 3, .nonempty = 0 }},
    } } };
    const uncured = try validationOutcome(aa, "s.js", "return 1;", dry, still_dry);
    try std.testing.expectEqual(Failure.Kind.dry_extracts, uncured.uncured.kind);
    try std.testing.expectEqual(1, uncured.uncured.dry_fields.len);
    try std.testing.expectEqualStrings("comments", uncured.uncured.dry_fields[0]);
    try std.testing.expect(std.mem.indexOf(u8, uncured.uncured.detail, "\"comments\"") != null);
}

test "narrowTarget: keeps the judged subset, never widens or retargets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const first: Failure = .{ .kind = .dry_extracts, .detail = "dry", .dry_fields = &.{ "comments", "score", "" } };

    const narrowed = try narrowTarget(aa, first, &.{"comments"});
    try std.testing.expectEqual(1, narrowed.dry_fields.len);
    try std.testing.expectEqualStrings("comments", narrowed.dry_fields[0]);
    try std.testing.expectEqualStrings("dry", narrowed.detail);

    // Unknown names are dropped; the order is the target's, not the verdict's.
    const mixed = try narrowTarget(aa, first, &.{ "", "nonexistent", "comments" });
    try std.testing.expectEqual(2, mixed.dry_fields.len);
    try std.testing.expectEqualStrings("comments", mixed.dry_fields[0]);
    try std.testing.expectEqualStrings("", mixed.dry_fields[1]);

    // All unknown, or nothing judged: the full target, not an empty one.
    try std.testing.expectEqual(3, (try narrowTarget(aa, first, &.{"bogus"})).dry_fields.len);
    try std.testing.expectEqual(first.dry_fields.ptr, (try narrowTarget(aa, first, &.{})).dry_fields.ptr);

    const threw: Failure = .{ .kind = .threw };
    try std.testing.expectEqual(Failure.Kind.threw, (try narrowTarget(aa, threw, &.{"comments"})).kind);
}

test "cureFailure: running clean is not a cure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const dry: Failure = .{
        .kind = .dry_extracts,
        .dry_fields = &.{ "comments", "" },
    };
    const cured_stats: []const extract.ExtractStat = &.{
        .{ .schema = "{}", .field = "comments", .calls = 5, .nonempty = 3 },
        .{ .schema = "[]", .field = "", .calls = 1, .nonempty = 1 },
    };
    try std.testing.expectEqual(null, try cureFailure(aa, dry, .{ .completion = null, .returned = .data, .extract_stats = cured_stats }));

    // Fix-by-deletion: the dry field is simply gone from the revised run.
    const deleted = (try cureFailure(aa, dry, .{ .completion = null, .returned = .data, .extract_stats = cured_stats[1..] })).?;
    try std.testing.expectEqual(Failure.Kind.dry_extracts, deleted.kind);
    try std.testing.expectEqual(1, deleted.dry_fields.len);
    try std.testing.expectEqualStrings("comments", deleted.dry_fields[0]);
    try std.testing.expect(std.mem.indexOf(u8, deleted.detail, "\"comments\" extract is gone") != null);

    // Still dry counts as uncured, and every dry field is reported, not the first.
    const still_dry_stats: []const extract.ExtractStat = &.{
        .{ .schema = "{}", .field = "comments", .calls = 5, .nonempty = 0 },
        .{ .schema = "[]", .field = "", .calls = 2, .nonempty = 0 },
    };
    const still_dry = (try cureFailure(aa, dry, .{ .completion = null, .returned = .data, .extract_stats = still_dry_stats })).?;
    try std.testing.expectEqual(2, still_dry.dry_fields.len);
    try std.testing.expectEqualStrings("", still_dry.dry_fields[1]);
    try std.testing.expect(std.mem.indexOf(u8, still_dry.detail, "in all 5 calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, still_dry.detail, "extract([]) returned no data in all 2 calls") != null);

    // .empty is cured only by a data-carrying return.
    const empty: Failure = .{ .kind = .empty };
    const with_data: RunFacts = .{ .completion = "[1]", .returned = .data, .extract_stats = &.{} };
    const without: RunFacts = .{ .completion = null, .returned = .none, .extract_stats = &.{} };
    try std.testing.expectEqual(null, try cureFailure(aa, empty, with_data));
    try std.testing.expectEqual(Failure.Kind.empty, (try cureFailure(aa, empty, without)).?.kind);

    // .threw needs nothing beyond running clean.
    const threw: Failure = .{ .kind = .threw };
    try std.testing.expectEqual(null, try cureFailure(aa, threw, without));
}
