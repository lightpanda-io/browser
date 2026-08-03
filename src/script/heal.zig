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
const WireFailure = replay.WireFailure;

/// Null when the validation run cured the original finding; otherwise the
/// message fed to the next heal attempt. Running clean is not a cure on its
/// own — a revision that deletes the failing extract (or the `return`) also
/// runs clean.
pub fn cureFailure(arena: std.mem.Allocator, first: WireFailure, facts: RunFacts) error{OutOfMemory}!?[]const u8 {
    switch (first.kind) {
        .threw => return null,
        .empty => return if (facts.returned == .data)
            null
        else
            "The revised script ran, but still returns no data (or no longer returns anything) — the original returned a value.",
        .dry_extracts => {
            for (first.dry_fields) |dry| {
                const cured = for (facts.extract_stats) |stat| {
                    if (std.mem.eql(u8, stat.field, dry) and stat.nonempty > 0) break true;
                } else false;
                if (!cured) return try std.fmt.allocPrint(arena, "The revised script ran, but the \"{s}\" extract still came back empty on every call (or was removed) — keep it and fix its selector.", .{if (dry.len == 0) "<whole result>" else dry});
            }
            return null;
        },
    }
}

/// Suffix of the on-disk file `commitValidated` swaps through.
pub const tmp_suffix = ".heal.js";

/// Atomically swap the validated revision into `path`, its baseline refreshed
/// from the validation run — synthesis may have copied the stale one from the
/// broken script. Returns the failure message, or null once `path` holds the
/// revision; after a failed rename the revision is deliberately kept on disk.
pub fn commitValidated(arena: std.mem.Allocator, path: []const u8, script: []const u8, stats: []const extract.ExtractStat) error{OutOfMemory}!?[]const u8 {
    const line = try Baseline.serializeStats(arena, stats);
    const final = Baseline.withBaseline(arena, script, line) catch return error.OutOfMemory;
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
    ++ diagnose_instructions, .{ path, string.capBytes(arena, source, replay.source_max_bytes), error_detail });
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
    \\heal_commit with the revised script and this report's `failure` object
    \\echoed back verbatim.
;

/// Shared by the CLI verdict prompt and the MCP suspicious-replay guidance.
pub const baseline_evidence_note =
    \\A `
++ std.mem.trimEnd(u8, Baseline.marker, " ") ++
    \\` comment in the script, when present, records how
    \\often each output field carried data when the script was saved — weigh
    \\it as evidence.
;

pub const replay_suspicious_guidance =
    \\The replay completed without errors, but its output looks dry — decide
    \\whether the script is broken (stale selectors after a site change) or
    \\the result is legitimate (the page genuinely has no such data right
    \\now).
    \\
++ baseline_evidence_note ++
    \\
    \\If legitimate, stop: the empty answer is the answer. If broken,
    \\diagnose against the live session (tree, findElement, markdown), prove
    \\the corrected step(s) with tools, then call heal_commit with the
    \\revised script and this report's `failure` object echoed back verbatim.
;

/// One `heal_commit` validation, serializable. `failure` is the residual cure
/// failure (or the validation run's own error); null when cured. The script's
/// path rides in `run.path`.
pub const HealReport = struct {
    cured: bool,
    committed: bool,
    failure: ?[]const u8 = null,
    run: replay.RunReport,
};

fn testFacts(returned: replay.Returned, stats: []const extract.ExtractStat) RunFacts {
    return .{ .returned = returned, .extract_stats = stats, .source = "" };
}

test "cureFailure: running clean is not a cure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const dry: WireFailure = .{
        .kind = .dry_extracts,
        .dry_fields = &.{ "comments", "" },
    };
    const cured_stats: []const extract.ExtractStat = &.{
        .{ .schema = "{}", .field = "comments", .calls = 5, .nonempty = 3 },
        .{ .schema = "[]", .field = "", .calls = 1, .nonempty = 1 },
    };
    try std.testing.expectEqual(null, try cureFailure(aa, dry, testFacts(.data, cured_stats)));

    // Fix-by-deletion: the dry field is simply gone from the revised run.
    const deleted = (try cureFailure(aa, dry, testFacts(.data, cured_stats[1..]))).?;
    try std.testing.expect(std.mem.indexOf(u8, deleted, "\"comments\"") != null);

    // Still dry counts as uncured.
    const still_dry_stats: []const extract.ExtractStat = &.{
        .{ .schema = "{}", .field = "comments", .calls = 5, .nonempty = 0 },
        cured_stats[1],
    };
    try std.testing.expect((try cureFailure(aa, dry, testFacts(.data, still_dry_stats))) != null);

    // .empty is cured only by a data-carrying return.
    const empty: WireFailure = .{ .kind = .empty };
    try std.testing.expectEqual(null, try cureFailure(aa, empty, testFacts(.data, &.{})));
    try std.testing.expect((try cureFailure(aa, empty, testFacts(.none, &.{}))) != null);

    // .threw needs nothing beyond running clean.
    const threw: WireFailure = .{ .kind = .threw };
    try std.testing.expectEqual(null, try cureFailure(aa, threw, testFacts(.none, &.{})));
}
