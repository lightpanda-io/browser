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

//! Clearing a cookie consent banner instead of reporting it.
//!
//! Whether this page is a consent wall and which control dismisses it are
//! both the model's call, asked in one request. Clicking the control and
//! re-reading the page is the answer key, which is why this needs no
//! labelled data, and the runners-up are a free second guess.

const std = @import("std");
const lp = @import("../lightpanda.zig");
const zenai = @import("zenai");

const choose = @import("choose.zig");
const Frame = lp.Frame;

const Questions = zenai.typesafe.Questions;
const QuestionEntry = zenai.typesafe.QuestionEntry;

/// The question ids, which also key the answers.
pub const wall_key = @tagName(lp.jev.Preset.isConsentWall);
pub const control_key = "control";

pub const Prefer = enum {
    accept,
    reject,

    fn instructions(self: Prefer) []const u8 {
        const not_it = " A link to a privacy or cookie policy, and a control that opens further settings, are not it.";
        return switch (self) {
            .accept => "Which control accepts the cookies and dismisses this banner?" ++ not_it,
            .reject => "Which control refuses all non-essential cookies and dismisses this banner?" ++ not_it,
        };
    }
};

/// The banner question and the pick, in one request: the gate costs no extra
/// round trip, and a `noul` carries no options to distract the choice.
pub fn questions(
    arena: std.mem.Allocator,
    candidates: []const choose.Candidate,
    prefer: Prefer,
) error{OutOfMemory}!Questions {
    const entries = try arena.alloc(QuestionEntry, 2);
    entries[0] = lp.jev.presetQuestion(.isConsentWall);
    entries[1] = .{ .key = control_key, .value = try choose.question(arena, prefer.instructions(), candidates, &.{}) };
    return .init(entries);
}

/// Just the banner question, for the re-read that verifies a click.
pub fn verifyQuestions(arena: std.mem.Allocator) error{OutOfMemory}!Questions {
    return lp.jev.presetQuestions(arena, &.{.isConsentWall});
}

/// What the tool reports. `dismissed` is what we did, `verified` is whether
/// the page agreed afterwards — they come apart, and a caller deciding
/// whether to trust the page it is about to read needs both.
pub const Outcome = struct {
    dismissed: bool = false,
    verified: bool = false,
    /// The control we clicked, as a selector that resolves to it again.
    selector: ?[]const u8 = null,
    /// Its accessible name, so a human reading the log sees what was clicked.
    control: ?[]const u8 = null,
    /// The model's probability for that control.
    confidence: ?f64 = null,
    /// How sure it was there was a banner, before and after the click.
    consentWall: ?f64 = null,
    consentWallAfter: ?f64 = null,
    /// Controls clicked, at most 2.
    attempts: u8 = 0,
    /// How many controls the question offered.
    candidates: ?usize = null,
    /// Why nothing happened, when nothing did.
    reason: ?[]const u8 = null,
};

const testing = @import("../testing.zig");

test "browser.consent: questions asks the banner and the pick in one request" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const candidates = [_]choose.Candidate{
        .{ .key = "c0", .element = undefined, .name = "accept", .info = .{ .string = "accept" } },
    };
    const asked = try questions(aa, &candidates, .accept);

    try testing.expectEqual(2, asked.count());
    try testing.expect(asked.get(wall_key).? == .noul);
    const pick = asked.get(control_key).?;
    try testing.expect(pick == .choice);
    // The candidate, plus a way to say the banner has no such control.
    try testing.expectEqual(2, pick.choice.criteria.count());
    try testing.expect(pick.choice.criteria.has(choose.none_key));
}
