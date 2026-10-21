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

//! Picking one element on the page with TypeSafe System One (Jev).
//!
//! The candidates are the question's options, so the answer is always an
//! element the page offers: the model writes no text, and the state it reads
//! carries no node ids (`classify.buildState`), so an option id we mint here
//! is the only way it can point at anything.

const std = @import("std");
const lp = @import("../lightpanda.zig");
const zenai = @import("zenai");

const Element = @import("webapi/Element.zig");
const DOMNode = @import("webapi/Node.zig");
const Frame = lp.Frame;
const interactive = @import("interactive.zig");

const Question = zenai.typesafe.Question;
const ChoiceEntry = zenai.typesafe.ChoiceEntry;

/// Option id for "nothing here does that". A choice answer is validated as the
/// argmax over the options offered, so without this one the model has to name
/// an element even on a page that has none.
pub const none_key = "none";
const none_description = "Nothing on this page does that";

/// Longest accessible name worth offering: a paragraph-length name is body
/// text that happens to listen for clicks, not a control.
const max_name_bytes = 80;

/// Longest `href` worth sending to the model. A tracking URL is several
/// hundred bytes of detail unrelated to the decision.
const max_href_bytes = 120;

pub const Candidate = struct {
    /// The option id, `c0`, `c1`, … — ours, not the page's.
    key: []const u8,
    element: *Element,
    /// Its accessible name, empty when only a placeholder or a `name`
    /// attribute identifies it. For a result a human has to read.
    name: []const u8,
    /// What the model is told about it.
    info: std.json.Value,
};

pub const Filter = struct {
    /// Roles a candidate may have, unless its name matched a keyword. An
    /// element the accessibility tree gives no role at all never passes.
    roles: []const []const u8,
    /// Case-insensitive substrings that mark a candidate as likely. Matches
    /// come first and `Set.keyword_matches` counts them.
    keywords: []const []const u8 = &.{},
    /// `input` types a candidate may have, for a question about form fields.
    /// A missing `type` counts as `text`, as the HTML parser treats it.
    input_types: ?[]const []const u8 = null,
    /// How many options to offer. The vendor documents that detail unrelated
    /// to the decision distracts the model, so a page with 200 controls must
    /// not become a 200-option question.
    max: usize = 40,
};

pub const Set = struct {
    candidates: []const Candidate,
    /// How many matched `Filter.keywords`. They sort first, so these are
    /// `candidates[0..keyword_matches]`.
    keyword_matches: usize,
};

/// The interactive elements under `root` that `filter` offers the model,
/// keyword matches first, capped at `filter.max`.
pub fn collect(
    arena: std.mem.Allocator,
    root: *DOMNode,
    frame: *Frame,
    filter: Filter,
) !Set {
    return select(arena, try interactive.collectInteractiveElements(root, arena, frame), filter);
}

/// `collect` over elements already walked, so several questions about one page
/// cost one walk between them — the walk resolves an accessible name per
/// element, which is the expensive part.
pub fn select(
    arena: std.mem.Allocator,
    elements: []const interactive.InteractiveElement,
    filter: Filter,
) !Set {
    var matched: std.ArrayList(Candidate) = .empty;
    var rest: std.ArrayList(Candidate) = .empty;
    for (elements) |el| {
        if (el.disabled) continue;
        const role = el.role orelse continue;
        if (filter.input_types) |types| {
            if (!matchesAny(types, el.input_type orelse "text")) continue;
        }
        const name = std.mem.trim(u8, el.name orelse "", &std.ascii.whitespace);
        if (name.len > max_name_bytes) continue;
        // Something has to tell one candidate from another. A field often has
        // no accessible name at all — an unlabelled password box — and then
        // its placeholder or its `name` attribute is what a reader goes by.
        if (name.len == 0 and el.placeholder == null and el.element_name == null) continue;

        // A keyword match is offered whatever its role: the keywords are the
        // question's own vocabulary, and a banner built out of clickable divs
        // still has an Accept.
        const keyword = hasKeyword(name, filter.keywords);
        if (!keyword and !matchesAny(filter.roles, role)) continue;

        const list = if (keyword) &matched else &rest;
        // Past the cap the rest would only be dropped below, undescribed.
        if (list.items.len == filter.max) continue;
        const element = el.node.is(Element) orelse continue;
        try list.append(arena, .{
            .key = "",
            .element = element,
            .name = name,
            .info = try describe(arena, el, role, name),
        });
    }

    const total = @min(matched.items.len + rest.items.len, filter.max);
    const candidates = try arena.alloc(Candidate, total);
    for (candidates, 0..) |*slot, i| {
        slot.* = if (i < matched.items.len) matched.items[i] else rest.items[i - matched.items.len];
        slot.key = try arena.print("c{d}", .{i});
    }
    return .{ .candidates = candidates, .keyword_matches = @min(matched.items.len, total) };
}

/// All the model is told about a candidate. Keys follow the
/// `interactiveElements` tool's, so one vocabulary describes an element
/// whoever is reading.
fn describe(
    arena: std.mem.Allocator,
    el: interactive.InteractiveElement,
    role: []const u8,
    name: []const u8,
) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "role", .{ .string = role });
    if (name.len > 0) try obj.put(arena, "name", .{ .string = name });
    if (el.input_type) |t| try obj.put(arena, "inputType", .{ .string = t });
    if (el.placeholder) |p| try obj.put(arena, "placeholder", .{ .string = p });
    if (el.element_name) |n| try obj.put(arena, "elementName", .{ .string = n });
    if (el.href) |h| if (h.len <= max_href_bytes) try obj.put(arena, "href", .{ .string = h });
    return .{ .object = obj };
}

/// A `choice` over `candidates`, plus any `extra` options of the caller's own
/// (an action that is not an element, such as pressing Enter) and `none_key`.
pub fn question(
    arena: std.mem.Allocator,
    instructions: []const u8,
    candidates: []const Candidate,
    extra: []const ChoiceEntry,
) error{OutOfMemory}!Question {
    const entries = try arena.alloc(ChoiceEntry, candidates.len + extra.len + 1);
    for (candidates, entries[0..candidates.len]) |candidate, *entry| {
        entry.* = .{ .key = candidate.key, .value = .{ .json = candidate.info } };
    }
    @memcpy(entries[candidates.len..][0..extra.len], extra);
    entries[entries.len - 1] = .{ .key = none_key, .value = .{ .text = none_description } };
    return .choiceText(instructions, .init(entries));
}

pub const Scored = struct {
    candidate: Candidate,
    probability: f64,
};

pub const Error = zenai.typesafe.types.ChoiceError || error{OutOfMemory};

/// The candidates the model ranked above `none_key`, most probable first: an
/// option it likes less than "nothing here does that" is not worth acting on.
/// Empty when `none` or one of the `extra` options won, so the caller acts on
/// nothing and the runners-up are a free second guess when the first fails.
pub fn ranked(
    arena: std.mem.Allocator,
    candidates: []const Candidate,
    response: zenai.typesafe.types.AskResponse,
    questions: zenai.typesafe.Questions,
    id: []const u8,
) Error![]const Scored {
    // Validates that the answer is one of the options we offered and is the
    // argmax of its own probabilities.
    _ = try response.choice(id, questions);
    const answer = response.answer(id) orelse return error.AnswerMissing;
    const floor = answer.probability(none_key) orelse 0;

    var out: std.ArrayList(Scored) = .empty;
    try out.ensureTotalCapacity(arena, candidates.len);
    for (candidates) |candidate| {
        const probability = answer.probability(candidate.key) orelse continue;
        if (probability <= floor) continue;
        out.appendAssumeCapacity(.{ .candidate = candidate, .probability = probability });
    }
    std.mem.sort(Scored, out.items, {}, moreProbable);
    return out.items;
}

fn moreProbable(_: void, a: Scored, b: Scored) bool {
    return a.probability > b.probability;
}

fn matchesAny(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, needle)) return true;
    }
    return false;
}

fn hasKeyword(name: []const u8, keywords: []const []const u8) bool {
    for (keywords) |keyword| {
        if (std.ascii.findIgnoreCase(name, keyword) != null) return true;
    }
    return false;
}

const testing = @import("../testing.zig");

/// Attached to the document, so `<label for>` resolves for field candidates.
fn testCollect(html: []const u8, filter: Filter) !Set {
    const frame = try testing.createFrame();
    errdefer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    _ = try doc.asNode().appendChild(div.asNode(), frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html);

    return collect(frame.call_arena, div.asNode(), frame, filter);
}

test "browser.choose: collect keeps named controls, keyword matches first" {
    defer testing.test_session.closeAllPages();
    const set = try testCollect(
        \\<button>Save</button>
        \\<button>Accept all cookies</button>
        \\<button disabled>Accept and close</button>
        \\<a href="/privacy">Privacy policy</a>
        \\<p>Accept all cookies</p>
    , .{
        .roles = &.{ "button", "link" },
        .keywords = &.{"cookie"},
    });

    // The disabled button and the paragraph are not offered; the keyword match
    // leads.
    try testing.expectEqual(3, set.candidates.len);
    try testing.expectEqual(1, set.keyword_matches);
    try std.testing.expectEqualStrings("c0", set.candidates[0].key);
    try std.testing.expectEqualStrings("Accept all cookies", set.candidates[0].info.object.get("name").?.string);
    try std.testing.expectEqualStrings("Accept all cookies", set.candidates[0].name);
}

test "browser.choose: collect caps the options it offers" {
    defer testing.test_session.closeAllPages();
    const set = try testCollect(
        "<button>one</button><button>two</button><button>three</button>",
        .{ .roles = &.{"button"}, .max = 2 },
    );
    try testing.expectEqual(2, set.candidates.len);
}

test "browser.choose: collect filters fields by input type" {
    defer testing.test_session.closeAllPages();
    const set = try testCollect(
        \\<label for="u">Username</label><input id="u">
        \\<label for="p">Password</label><input id="p" type="password">
        \\<input type="checkbox" aria-label="Remember me">
    , .{
        .roles = &.{"textbox"},
        .input_types = &.{ "text", "email" },
    });

    try testing.expectEqual(1, set.candidates.len);
    try std.testing.expectEqualStrings("Username", set.candidates[0].info.object.get("name").?.string);
}

test "browser.choose: question offers every candidate plus none" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const candidates = [_]Candidate{
        .{ .key = "c0", .element = undefined, .name = "a", .info = .{ .string = "a" } },
        .{ .key = "c1", .element = undefined, .name = "b", .info = .{ .string = "b" } },
    };
    const extra = [_]ChoiceEntry{.{ .key = "enter", .value = .{ .text = "Press Enter" } }};
    const q = try question(aa, "Which one?", &candidates, &extra);

    try testing.expectEqual(4, q.choice.criteria.count());
    try testing.expect(q.choice.criteria.has("c0"));
    try testing.expect(q.choice.criteria.has("enter"));
    try testing.expect(q.choice.criteria.has(none_key));
    try std.testing.expectEqualStrings("Which one?", q.choice.instructions.text);
}

test "browser.choose: ranked drops the options none outranks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const candidates = [_]Candidate{
        .{ .key = "c0", .element = undefined, .name = "a", .info = .{ .string = "a" } },
        .{ .key = "c1", .element = undefined, .name = "b", .info = .{ .string = "b" } },
        .{ .key = "c2", .element = undefined, .name = "c", .info = .{ .string = "c" } },
    };
    const q = try question(aa, "Which one?", &candidates, &.{});
    const questions: zenai.typesafe.Questions = .init(&.{.{ .key = "pick", .value = q }});

    const response = try answerFixture(aa, "pick", "c1", &.{
        .{ .key = "c0", .value = 0.05 },
        .{ .key = "c1", .value = 0.6 },
        .{ .key = "c2", .value = 0.25 },
        .{ .key = none_key, .value = 0.1 },
    });

    const order = try ranked(aa, &candidates, response, questions, "pick");
    // c0 scored below "nothing here does that", so it is not a second guess.
    try testing.expectEqual(2, order.len);
    try std.testing.expectEqualStrings("c1", order[0].candidate.key);
    try std.testing.expectEqualStrings("c2", order[1].candidate.key);
}

test "browser.choose: ranked rejects an answer that is not the argmax" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const candidates = [_]Candidate{
        .{ .key = "c0", .element = undefined, .name = "a", .info = .{ .string = "a" } },
    };
    const q = try question(aa, "Which one?", &candidates, &.{});
    const questions: zenai.typesafe.Questions = .init(&.{.{ .key = "pick", .value = q }});

    const response = try answerFixture(aa, "pick", "c0", &.{
        .{ .key = "c0", .value = 0.2 },
        .{ .key = none_key, .value = 0.8 },
    });
    try std.testing.expectError(error.ChoiceNotArgmax, ranked(aa, &candidates, response, questions, "pick"));
}

/// A choice answer as the API would return it.
fn answerFixture(
    arena: std.mem.Allocator,
    id: []const u8,
    choice: []const u8,
    probabilities: []const zenai.typesafe.types.Probabilities.Entry,
) !zenai.typesafe.types.AskResponse {
    const answers = try arena.alloc(zenai.typesafe.types.Answers.Entry, 1);
    answers[0] = .{ .key = id, .value = .{ .choice = .{
        .choice = choice,
        .probabilities = .init(probabilities),
        .confidence = 0.9,
    } } };
    return .{ .answers = .init(answers) };
}
