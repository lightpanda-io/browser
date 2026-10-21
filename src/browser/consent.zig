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
//! A keyword rule decides whether the page has a banner at all, so a page
//! without one costs nothing; the model only picks which of the banner's
//! controls to click. Clicking it and re-reading the page is the answer key,
//! which is why this needs no labelled data: the page says whether the pick
//! was right, and the runners-up are a free second guess.

const std = @import("std");
const lp = @import("../lightpanda.zig");
const zenai = @import("zenai");

const choose = @import("choose.zig");
const Frame = lp.Frame;

const Questions = zenai.typesafe.Questions;
const QuestionEntry = zenai.typesafe.QuestionEntry;

/// The question ids, which also key the answers.
pub const wall_key = @tagName(lp.classify.Preset.isConsentWall);
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

/// What a banner's controls are named, in the languages the first page of
/// Tranco actually serves. Recall first: a name here only makes an element
/// worth offering the model, which then picks among them. The list doubles as
/// the trigger, so a page whose controls mention none of this is reported as
/// having no banner without a model call — which is also where a rule beats
/// the model, since the walls we have measured it missing were in Spanish.
/// Substring matches, so a word here covers its inflections ("consent" covers
/// "consentir" and "consentement"). Nothing redundant: "accept" already
/// carries "accepter", "acceptera" and "acceptar".
pub const keywords = [_][]const u8{
    // en
    "cookie",   "consent",    "accept",     "agree",       "allow",
    "reject",   "decline",    "refuse",     "essential",   "necessary",
    "got it",   "understand",
    // es, fr, it, pt
    "aceptar",    "acepto",      "rechazar",
    "rejeter",  "accetta",    "acconsento", "rifiuta",     "aceitar",
    "recusar",  "concordo",
    // de, nl
      "zustimmen",  "akzeptieren", "einverstanden",
    "ablehnen", "einwillig",  "akkoord",    "weigeren",
    // da, no, sv, fi
       "godta",
    "aksepter", "tillad",     "godkend",
    "godkänn",
    "hyväksy",
    "avvis",
    // pl, cs, hu, ro, tr
       "zgadzam",    "akceptuj",
    "odrzuć",
    "souhlas",
    "přijmout",
    "odmítnout",
    "elfogad",  "de acord",   "kabul",
    "çerez",
};

/// Only clickables, and only what a banner's controls look like: a checkbox
/// toggles a purpose rather than dismissing the banner.
pub const filter: choose.Filter = .{
    .roles = &.{ "button", "link" },
    .keywords = &keywords,
    .max = 24,
};

/// The banner question and the pick, in one request: the gate costs no extra
/// round trip, and a `noul` carries no options to distract the choice.
pub fn questions(
    arena: std.mem.Allocator,
    candidates: []const choose.Candidate,
    prefer: Prefer,
) error{OutOfMemory}!Questions {
    const entries = try arena.alloc(QuestionEntry, 2);
    entries[0] = lp.classify.presetQuestion(.isConsentWall);
    entries[1] = .{ .key = control_key, .value = try choose.question(arena, prefer.instructions(), candidates, &.{}) };
    return .init(entries);
}

/// Just the banner question, for the re-read that verifies a click.
pub fn verifyQuestions(arena: std.mem.Allocator) error{OutOfMemory}!Questions {
    return lp.classify.presetQuestions(arena, &.{.isConsentWall});
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

test "browser.consent: the keyword rule is what triggers a call" {
    defer testing.test_session.closeAllPages();

    const frame = try testing.createFrame();
    const doc = frame.window._document;
    const root = try doc.createElement("div", null, frame);
    _ = try doc.asNode().appendChild(root.asNode(), frame);

    const page = try doc.createElement("div", null, frame);
    _ = try root.asNode().appendChild(page.asNode(), frame);
    try Frame.parse.htmlAsChildren(frame, page.asNode(),
        \\<nav><a href="/about">About</a><a href="/jobs">Jobs</a></nav>
        \\<button>Añadir al carrito</button>
    );

    const quiet = try choose.collect(frame.call_arena, root.asNode(), frame, filter);
    try testing.expectEqual(0, quiet.keyword_matches);

    // The Spanish wall the model scored at 0.99 the wrong way.
    const banner = try doc.createElement("div", null, frame);
    _ = try root.asNode().appendChild(banner.asNode(), frame);
    try Frame.parse.htmlAsChildren(frame, banner.asNode(),
        \\<button>Aceptar todo</button><button>Configurar cookies</button>
    );
    const loud = try choose.collect(frame.call_arena, root.asNode(), frame, filter);
    try testing.expectEqual(2, loud.keyword_matches);
}
