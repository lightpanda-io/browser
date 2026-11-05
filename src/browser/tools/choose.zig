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
//! The candidates are the question's options, keyed by the node id the state
//! carries too. The model writes no text, so an option id is the only way it
//! can point at an element, and `none` the only way it can point at nothing.
//!
//! An option carries its own description as well as its id: `buildState`
//! truncates the tree at `max_state_bytes`, and a candidate below that cut
//! would otherwise be an option the model cannot resolve.

const std = @import("std");
const lp = @import("../../lightpanda.zig");
const zenai = @import("zenai");

const Element = @import("../webapi/Element.zig");
const DOMNode = @import("../webapi/Node.zig");
const Frame = lp.Frame;
const NodeRegistry = lp.NodeRegistry;
const interactive = @import("../interactive.zig");
const truncateUtf8 = @import("../../string.zig").truncateUtf8;

const Question = zenai.typesafe.Question;
const ChoiceEntry = zenai.typesafe.ChoiceEntry;

/// Option id for "nothing here does that". A choice answer is validated as the
/// argmax over the options offered, so without this one the model has to name
/// an element even on a page that has none.
pub const none_key = "none";
const none_description = "Nothing on this page does that";

/// How many options a question may offer. The API's limit is 255, but the
/// vendor documents that detail unrelated to the decision distracts the
/// model, and the options are the bulk of the request: 200 of them run to
/// 13 KB against an 8 KB state. Over the budget, `overlay` decides who keeps
/// a place.
const max_options = 50;

/// Longest accessible name worth sending: the model reads the whole of it in
/// the state anyway.
const max_name_bytes = 120;

/// Longest `href` worth sending to the model. A tracking URL is several
/// hundred bytes of detail unrelated to the decision.
const max_href_bytes = 120;

pub const Candidate = struct {
    /// The element's node id, which the state carries too.
    key: []const u8,
    element: *Element,
    /// Its accessible name, empty when only a placeholder or a `name`
    /// attribute identifies it. For a result a human has to read.
    name: []const u8,
    /// What the model is told about it.
    info: std.json.Value,
};

/// Every interactive element under `root`, in document order, up to
/// `max_options`. Over the budget, an element drawn over the page keeps its
/// place and one behind it gives way. Nothing is reordered, so an option's
/// place in the question still means nothing.
pub fn collect(
    arena: std.mem.Allocator,
    root: *DOMNode,
    frame: *Frame,
    registry: *NodeRegistry,
) ![]const Candidate {
    const elements = try interactive.collectInteractiveElements(root, arena, frame);

    var pinned: usize = 0;
    for (elements) |*el| {
        if (!el.disabled and el.overlay.any()) pinned += 1;
    }
    var others: usize = max_options -| pinned;

    var out: std.ArrayList(Candidate) = try .initCapacity(arena, @min(elements.len, max_options));
    for (elements) |el| {
        // Not a decision: a disabled control cannot be clicked at all.
        if (el.disabled) continue;
        if (out.items.len == max_options) break;
        const element = el.node.is(Element) orelse continue;
        if (!el.overlay.any()) {
            if (others == 0) continue;
            others -= 1;
        }
        const node = try registry.register(element.asNode());
        const label = try arena.dupe(u8, name(el));
        out.appendAssumeCapacity(.{
            .key = try arena.print("{d}", .{node.id}),
            .element = element,
            .name = label,
            .info = try describe(arena, el, label),
        });
    }
    return out.items;
}

fn name(el: interactive.InteractiveElement) []const u8 {
    return std.mem.trim(u8, el.name orelse "", &std.ascii.whitespace);
}

/// Keys follow the `interactiveElements` tool's, so one vocabulary describes
/// an element whoever is reading. Every string is copied: the request is
/// serialized on a helper thread while page JS runs and can free the
/// attribute values these point into.
fn describe(arena: std.mem.Allocator, el: interactive.InteractiveElement, label: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    if (el.role) |role| try obj.put(arena, "role", .{ .string = try arena.dupe(u8, role) });
    if (label.len > 0) {
        try obj.put(arena, "name", .{ .string = truncateUtf8(label, max_name_bytes) });
    }
    if (el.input_type) |t| try obj.put(arena, "inputType", .{ .string = try arena.dupe(u8, t) });
    if (el.placeholder) |p| try obj.put(arena, "placeholder", .{ .string = try arena.dupe(u8, p) });
    if (el.element_name) |n| try obj.put(arena, "elementName", .{ .string = try arena.dupe(u8, n) });
    if (el.href) |h| if (h.len <= max_href_bytes) try obj.put(arena, "href", .{ .string = try arena.dupe(u8, h) });
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

/// The candidate the model chose, or null when it chose `none_key` or one of
/// the caller's `extra` options: nothing on the page is what it wants done.
/// `choice` has already checked the pick is the argmax, so it outranks `none`.
pub fn best(
    candidates: []const Candidate,
    response: zenai.typesafe.types.AskResponse,
    questions: zenai.typesafe.Questions,
    id: []const u8,
) Error!?Scored {
    const chosen = try response.choice(id, questions);
    const answer = response.answer(id) orelse return error.AnswerMissing;
    for (candidates) |candidate| {
        if (!std.mem.eql(u8, candidate.key, chosen)) continue;
        return .{ .candidate = candidate, .probability = answer.probability(chosen) orelse return error.AnswerMissing };
    }
    return null;
}

const testing = @import("../../testing.zig");

/// Attached to the document, so `<label for>` resolves for field candidates.
fn testCollect(html: []const u8) ![]const Candidate {
    const frame = try testing.createFrame();
    errdefer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const div = try doc.createElement("div", null, frame);
    _ = try doc.asNode().appendChild(div.asNode(), frame);
    try Frame.parse.htmlAsChildren(frame, div.asNode(), html);

    // The option ids are copied into the arena, so the registry that minted
    // them is done once `collect` returns.
    var registry: NodeRegistry = .init(testing.allocator);
    defer registry.deinit();
    return collect(frame.call_arena, div.asNode(), frame, &registry);
}

test "browser.choose: collect offers every interactive element by node id" {
    defer testing.test_session.closeAllPages();
    const candidates = try testCollect(
        \\<button>Accept all cookies</button>
        \\<button disabled>Accept and close</button>
        \\<div onclick="go()">A clickable div with no role at all</div>
        \\<a href="/privacy">Privacy policy</a>
        \\<p>Accept all cookies</p>
    );

    // The role-less div is offered too: what it is, is the model's call.
    try testing.expectEqual(3, candidates.len);
    try testing.expectString("Accept all cookies", candidates[0].name);
    try testing.expectString("Accept all cookies", candidates[0].info.object.get("name").?.string);
    try testing.expect(std.fmt.parseInt(NodeRegistry.Id, candidates[0].key, 10) catch null != null);
}

test "browser.choose: collect describes a field with no label of its own" {
    defer testing.test_session.closeAllPages();
    const candidates = try testCollect(
        \\<input name="pw" type="password">
        \\<input placeholder="you@example.com">
    );

    try testing.expectEqual(2, candidates.len);
    const pw = candidates[0].info.object;
    try testing.expectString("password", pw.get("inputType").?.string);
    try testing.expectString("pw", pw.get("elementName").?.string);
    try testing.expectEqual(null, pw.get("name"));
    try testing.expectString(
        "you@example.com",
        candidates[1].info.object.get("placeholder").?.string,
    );
}

test "browser.choose: question offers every candidate plus none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const candidates = [_]Candidate{
        .{ .key = "11", .element = undefined, .name = "a", .info = .{ .string = "a" } },
        .{ .key = "12", .element = undefined, .name = "b", .info = .{ .string = "b" } },
    };
    const extra = [_]ChoiceEntry{.{ .key = "enter", .value = .{ .text = "Press Enter" } }};
    const q = try question(aa, "Which one?", &candidates, &extra);

    try testing.expectEqual(4, q.choice.criteria.count());
    try testing.expect(q.choice.criteria.has("11"));
    try testing.expect(q.choice.criteria.has("enter"));
    try testing.expect(q.choice.criteria.has(none_key));
    try testing.expectString("Which one?", q.choice.instructions.text);
}

test "browser.choose: best is the candidate the model chose, or none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const candidates = [_]Candidate{
        .{ .key = "11", .element = undefined, .name = "a", .info = .{ .string = "a" } },
        .{ .key = "12", .element = undefined, .name = "b", .info = .{ .string = "b" } },
    };
    const q = try question(aa, "Which one?", &candidates, &.{});
    const questions: zenai.typesafe.Questions = .init(&.{.{ .key = "pick", .value = q }});

    const picked = try answerFixture(aa, "pick", "12", &.{
        .{ .key = "11", .value = 0.25 },
        .{ .key = "12", .value = 0.65 },
        .{ .key = none_key, .value = 0.1 },
    });
    const pick = (try best(&candidates, picked, questions, "pick")).?;
    try testing.expectString("12", pick.candidate.key);
    try testing.expectEqual(0.65, pick.probability);

    const nothing = try answerFixture(aa, "pick", none_key, &.{
        .{ .key = "11", .value = 0.25 },
        .{ .key = "12", .value = 0.15 },
        .{ .key = none_key, .value = 0.6 },
    });
    try testing.expectEqual(null, try best(&candidates, nothing, questions, "pick"));
}

test "browser.choose: best rejects an answer that is not the argmax" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const candidates = [_]Candidate{
        .{ .key = "11", .element = undefined, .name = "a", .info = .{ .string = "a" } },
    };
    const q = try question(aa, "Which one?", &candidates, &.{});
    const questions: zenai.typesafe.Questions = .init(&.{.{ .key = "pick", .value = q }});

    const response = try answerFixture(aa, "pick", "11", &.{
        .{ .key = "11", .value = 0.2 },
        .{ .key = none_key, .value = 0.8 },
    });
    try testing.expectError(error.ChoiceNotArgmax, best(&candidates, response, questions, "pick"));
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

test "browser.choose: over the budget, a control over the page keeps its place" {
    defer testing.test_session.closeAllPages();

    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(testing.allocator);
    for (0..max_options + 10) |i| {
        try html.print(testing.allocator, "<button>page {d}</button>", .{i});
    }
    try html.appendSlice(testing.allocator,
        \\<div style="position: fixed"><button>Accept</button><button>Reject</button></div>
    );

    const candidates = try testCollect(html.items);

    try testing.expectEqual(max_options, candidates.len);
    try testing.expectEqual("Accept", candidates[max_options - 2].name);
    try testing.expectEqual("Reject", candidates[max_options - 1].name);
    try testing.expectEqual("page 0", candidates[0].name);
    try testing.expectEqual("page 1", candidates[1].name);
}
