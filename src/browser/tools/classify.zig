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
const lp = @import("../../lightpanda.zig");
const zenai = @import("zenai");
const jev = @import("jev.zig");
const classify_local = @import("classify_local.zig");
const truncateUtf8 = @import("../../string.zig").truncateUtf8;

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

pub fn exec(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        questions: std.json.Value,
        selector: ?[]const u8 = null,
        presets: bool = false,
        includeInput: bool = false,
    };
    const args = try parseArgs(Params, arena, arguments);
    const page = try requireFrame(session);

    const node = try resolveScope(session, registry, page, args.selector, null);
    const prepared = prepareQuestions(arena, args.questions, args.presets) catch |err| switch (err) {
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => return .{ .text = try arena.print("classify: invalid questions: {s}", .{@errorName(err)}), .is_error = true },
    };

    const read = jev.readState(arena, page, node, registry, .{}) catch |err| return internalUnlessOom(err);

    // With --classify-model, the presets it is sure of are answered locally,
    // and Jev gets the rest, if anything is left. It learned from whole
    // pages, so a selector's subtree always goes to Jev.
    var input: ?classify_local.Page = null;
    var local: ?Split = null;
    if (session.browser.app.classify_model) |model| {
        if (args.selector == null and prepared.kind == .questions_object) {
            input = localPage(arena, page, read) catch |err| return internalUnlessOom(err);
            local = try answerLocally(arena, model, input.?, prepared);
        }
    }
    const for_jev = if (local) |l| l.remaining else prepared.questions;

    var response: ?jev.AskedResponse = null;
    if (for_jev.count() > 0) response = switch (try askPage(arena, session, registry, .{
        .tool = .classify,
        .questions = for_jev,
        .node = node,
        .read = read,
    })) {
        .failed => |result| return result,
        .ok => |ok| ok,
    };
    defer if (response) |*r| r.deinit();

    var answered: zenai.typesafe.types.AskResponse = if (response) |r| r.value else .{};
    if (local) |l| answered.answers = try mergeAnswers(arena, answered.answers, l.local);

    const formatted = zenai.typesafe.json.formatAnswers(arena, answered, prepared) catch |err| return internalUnlessOom(err);
    if (!args.includeInput) return .{ .text = formatted };

    if (input == null) input = localPage(arena, page, read) catch |err| return internalUnlessOom(err);
    return .{ .text = try arena.print("{{\"answers\":{s},\"input\":{f}}}", .{ formatted, std.json.fmt(input.?, .{}) }) };
}

/// What the local model reads of a page: `read`, what Jev is sent, plus the
/// document's HTML as the html tool renders it. `includeInput` returns this,
/// which is how the model's training data is collected, so the model scores
/// the same text it learned from.
pub fn localPage(arena: std.mem.Allocator, page: *lp.Frame, read: jev.State) !classify_local.Page {
    const document = page.document.asNode();
    const render = try lp.RenderTree.resolve(arena, document, .{}, page);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try lp.dump.render(render, .{}, &aw.writer, page);
    return .{
        .url = read.url,
        .title = read.title orelse "",
        .status = read.status orelse 0,
        .tree = read.tree,
        .html = truncateUtf8(aw.written(), classify_local.max_html_bytes),
    };
}

/// The questions a local model answered, and the rest, for Jev.
pub const Split = struct {
    local: zenai.typesafe.types.Answers,
    remaining: zenai.typesafe.Questions,
};

/// Splits `prepared` in two: the presets asked in their own words that
/// `model` is sure of on `page`, answered with its calibrated scores, and
/// everything else, custom questions included, for Jev.
pub fn answerLocally(arena: std.mem.Allocator, model: *const classify_local.Model, page: classify_local.Page, prepared: json.Prepared) !Split {
    const scores = try arena.alloc(f64, model.presets.len);
    try model.score(arena, page, scores);
    var local: std.ArrayList(zenai.typesafe.types.Answers.Entry) = .empty;
    var remaining: std.ArrayList(zenai.typesafe.QuestionEntry) = .empty;
    for (prepared.questions.entries) |entry| {
        if (localScore(model, scores, entry)) |score| {
            try local.append(arena, .{ .key = entry.key, .value = .{ .noul = .{ .noul = score } } });
        } else {
            try remaining.append(arena, entry);
        }
    }
    return .{ .local = .init(local.items), .remaining = .init(remaining.items) };
}

/// The calibrated score of the preset `entry` asks, when it asks one in the
/// preset's own words and the model is sure of the answer.
fn localScore(model: *const classify_local.Model, scores: []const f64, entry: zenai.typesafe.QuestionEntry) ?f64 {
    const preset = jev.Preset.fromString(entry.key) orelse return null;
    const asked = switch (entry.value) {
        .noul => |q| q.criteria == null and q.instructions == .text and std.mem.eql(u8, q.instructions.text, preset.description()),
        else => false,
    };
    if (!asked) return null;
    for (model.presets, scores) |local, score| {
        if (jev.Preset.fromString(local.name) != preset) continue;
        const calibrated = local.calibrated(score);
        const sure = classify_local.sure;
        return if (calibrated < sure or calibrated > 1 - sure) calibrated else null;
    }
    return null;
}

/// Jev's answers and the local ones, as one set.
pub fn mergeAnswers(arena: std.mem.Allocator, from_jev: zenai.typesafe.types.Answers, local: zenai.typesafe.types.Answers) !zenai.typesafe.types.Answers {
    return .init(try std.mem.concat(arena, zenai.typesafe.types.Answers.Entry, &.{ from_jev.entries, local.entries }));
}

const testing = @import("../../testing.zig");

const tools = @import("../tools.zig");
const ToolError = tools.ToolError;
const ToolResult = tools.ToolResult;
const parseArgs = tools.parseArgs;
const requireFrame = tools.requireFrame;
const resolveScope = tools.resolveScope;
const NodeRegistry = lp.NodeRegistry;
const askPage = jev.askPage;
const internalUnlessOom = jev.internalUnlessOom;

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

test "browser.classify: answerLocally answers the presets the model is sure of" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A model of two constant presets: is_blocked surely not, is_paywall
    // anyone's guess.
    var bytes: std.Io.Writer.Allocating = .init(a);
    const w = &bytes.writer;
    try w.writeAll("LPCM");
    for ([_]u32{ 3, 20, 0, 2 }) |n| try w.writeInt(u32, n, .little);
    for ([_]struct { []const u8, f32 }{ .{ "is_blocked", 0.01 }, .{ "is_paywall", 0.5 } }) |preset| {
        try w.writeInt(u32, @intCast(preset[0].len), .little);
        try w.writeAll(preset[0]);
        try w.writeInt(u32, @bitCast(@as(f32, 0.5)), .little);
        try w.writeByte(1);
        try w.writeInt(u32, @bitCast(preset[1]), .little);
    }
    for (0..6) |_| try w.writeInt(u32, 0, .little); // matchers, literals, tags, words, chars, structure
    const model = try classify_local.Model.parse(testing.allocator, testing.test_app.regex_context, bytes.written());
    defer model.deinit();

    const prepared = try prepareQuestions(a, .{ .string = "{\"isBlocked\": true, \"isPaywall\": true, \"is_blocked\": \"Is it blocked?\", \"price\": \"Does it show a price?\"}" }, false);
    const page: classify_local.Page = .{ .url = "https://example.com/", .title = "", .status = 200, .tree = "", .html = "" };
    const split = try answerLocally(a, model, page, prepared);

    try testing.expectEqual(1, split.local.count());
    try testing.expectDelta(0.01, split.local.get("isBlocked").?.noul.noul, 1e-6);
    // Unsure, asked in other words, or no preset: all left for Jev.
    try testing.expect(split.remaining.has("isPaywall"));
    try testing.expect(split.remaining.has("is_blocked"));
    try testing.expect(split.remaining.has("price"));
    try testing.expectEqual(3, split.remaining.count());

    const merged = try mergeAnswers(a, .{}, split.local);
    try testing.expectEqual(1, merged.count());
}
