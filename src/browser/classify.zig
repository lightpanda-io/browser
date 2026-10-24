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

//! The `classify` tool's end of `zenai.typesafe.json`: the page presets a
//! caller can name instead of wording a question, and what an empty questions
//! object means. The question shapes themselves, and the answers coming back
//! as JSON, are zenai's.

const std = @import("std");
const zenai = @import("zenai");
const jev = @import("jev.zig");

const json = zenai.typesafe.json;

/// A preset can be named by key alone; an empty object asks every one of them.
/// `presets` adds every preset the questions do not already ask, so a caller
/// deciding whether a page is worth reading skips a second round trip for its
/// own questions.
pub fn prepareQuestions(
    arena: std.mem.Allocator,
    questions: std.json.Value,
    presets: bool,
) json.PrepareError!json.Prepared {
    const prepared: json.Prepared = json.prepareQuestions(arena, questions, .{
        .vocabulary = jev.presetDescription,
        .category_instructions = "What kind of page is this?",
    }) catch |err| switch (err) {
        error.EmptyObject => .{ .questions = try jev.allPresetQuestions(arena), .kind = .questions_object },
        else => return err,
    };
    if (!presets) return prepared;
    return json.addQuestions(arena, prepared, try jev.allPresetQuestions(arena));
}

const testing = @import("../testing.zig");

test "browser.classify: a preset can be named by key alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "{\"isBlocked\": true, \"isCaptcha\": true}" }, false);
    try testing.expectEqual(json.ResponseKind.questions_object, prepared.kind);
    try testing.expectEqual(2, prepared.questions.count());
    try testing.expectString(jev.Preset.isBlocked.description(), prepared.questions.get("isBlocked").?.noul.instructions.text);
    try testing.expect(prepared.questions.has("isCaptcha"));
}

test "browser.classify: an empty object asks every preset" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "{}" }, false);
    try testing.expectEqual(json.ResponseKind.questions_object, prepared.kind);
    try testing.expectEqual(std.enums.values(jev.Preset).len, prepared.questions.count());
    for (std.enums.values(jev.Preset)) |preset| {
        try testing.expect(prepared.questions.has(@tagName(preset)));
    }
}

test "browser.classify: the presets are added beside the caller's own wording" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const with = try prepareQuestions(aa, .{ .string = "{\"kind\": [\"a\", \"b\"], \"isPaywall\": \"Is it paywalled?\"}" }, true);
    const presets = std.enums.values(jev.Preset);
    // isPaywall was already asked, so it is not asked twice.
    try testing.expectEqual(2 + presets.len - 1, with.questions.count());
    try testing.expect(with.questions.has("kind"));
    for (presets) |preset| try testing.expect(with.questions.has(@tagName(preset)));
    try testing.expectString("Is it paywalled?", with.questions.get("isPaywall").?.noul.instructions.text);

    // A bare category array answers with one unkeyed choice, so there is
    // nowhere to put the presets.
    try testing.expectError(error.InvalidQuestionFormat, prepareQuestions(aa, .{ .string = "[\"a\", \"b\"]" }, true));
}

test "browser.classify: a category array asks about the page" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "[\"product\", \"catalog\"]" }, false);
    try testing.expectEqual(json.ResponseKind.single_choice, prepared.kind);
    const question = prepared.questions.get(json.category_key).?;
    try testing.expectString("What kind of page is this?", question.choice.instructions.text);
    try testing.expect(question.choice.criteria.has("product"));
}
