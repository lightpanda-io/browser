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

//! Classification using TypeSafe System One (Jev).
//! Evaluates semantic questions against page state (or DOM subtrees).

const std = @import("std");
const lp = @import("../lightpanda.zig");
const zenai = @import("zenai");

const Frame = lp.Frame;
const DOMNode = @import("webapi/Node.zig");
const NodeRegistry = lp.NodeRegistry;

const Question = zenai.typesafe.Question;
const Content = zenai.typesafe.Content;

pub const Preset = enum {
    isBlocked,
    isCaptcha,
    isConsentWall,
    isEmptyCatalog,
    isErrorPage,
    isLoginWall,
    isPaywall,
    isUnsupportedBrowser,
    isLoading,

    pub fn description(self: Preset) []const u8 {
        return switch (self) {
            .isBlocked => "Is the page behind a CAPTCHA, Cloudflare challenge, or bot block?",
            .isCaptcha => "Is the primary view obstructed by a CAPTCHA or human verification challenge?",
            .isConsentWall => "Is the primary view obstructed by a cookie consent banner?",
            .isEmptyCatalog => "Does the page say its search or filter found nothing (no results, no matches, 0 items)?",
            .isErrorPage => "Does the page show an error, such as page not found or server error, instead of its content? A search or listing with no results is not an error.",
            .isLoginWall => "Does the page show a sign-in form or prompt instead of its content?",
            .isPaywall => "Is the content hidden or cut off behind a subscription or payment prompt?",
            .isUnsupportedBrowser => "Does the page say this browser is unsupported or out of date, or that JavaScript must be enabled, instead of showing its content?",
            .isLoading => "Is the main content still loading, shown only as spinners, skeleton placeholders or loading text?",
        };
    }

    /// Accepts the camelCase name or its snake_case spelling.
    pub fn fromString(name: []const u8) ?Preset {
        inline for (comptime std.enums.values(Preset)) |preset| {
            if (std.mem.eql(u8, name, @tagName(preset)) or std.mem.eql(u8, name, comptime snakeCase(@tagName(preset)))) return preset;
        }
        return null;
    }

    /// Every preset name, comma-separated, for tool descriptions.
    pub const names = blk: {
        var out: []const u8 = "";
        for (std.enums.values(Preset), 0..) |preset, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ @tagName(preset);
        }
        break :blk out;
    };
};

fn snakeCase(comptime camel: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (camel) |c| {
            const part: []const u8 = if (std.ascii.isUpper(c)) &.{ '_', std.ascii.toLower(c) } else &.{c};
            out = out ++ part;
        }
        return out;
    }
}

pub const ResponseKind = enum {
    single_choice,
    questions_object,
};

pub const PreparedQuestions = struct {
    questions: zenai.typesafe.Questions,
    kind: ResponseKind,
};

pub const PrepareError = error{
    InvalidQuestionsJson,
    EmptyQuestions,
    InvalidQuestionFormat,
    OutOfMemory,
};

const category_key = "__category";

/// `questions` is the array or object itself, or a string holding its JSON.
pub fn prepareQuestions(arena: std.mem.Allocator, questions: std.json.Value) PrepareError!PreparedQuestions {
    const parsed = switch (questions) {
        .string => |source| std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{}) catch
            return error.InvalidQuestionsJson,
        else => questions,
    };

    switch (parsed) {
        .array => |arr| {
            if (arr.items.len == 0) return error.EmptyQuestions;

            // An array is always the categories of one choice question; presets
            // go through the object form.
            const entries = try arena.alloc(zenai.typesafe.QuestionEntry, 1);
            entries[0] = .{
                .key = category_key,
                .value = .choiceText("What kind of page is this?", try stringChoices(arena, arr.items)),
            };
            return .{ .questions = .init(entries), .kind = .single_choice };
        },
        .object => |obj| {
            if (obj.count() == 0) return preparePresets(arena);

            const entries = try arena.alloc(zenai.typesafe.QuestionEntry, obj.count());
            for (entries, obj.keys(), obj.values()) |*entry, key, val| {
                entry.* = .{ .key = key, .value = try prepareQuestion(arena, key, val) };
            }
            return .{ .questions = .init(entries), .kind = .questions_object };
        },
        else => return error.InvalidQuestionFormat,
    }
}

fn prepareQuestion(arena: std.mem.Allocator, key: []const u8, val: std.json.Value) PrepareError!Question {
    switch (val) {
        .bool => |b| {
            if (!b) return error.InvalidQuestionFormat;
            return .noulText(if (Preset.fromString(key)) |preset| preset.description() else key);
        },
        .string => |s| {
            if (s.len > 0) return .noulText(s);
            const preset = Preset.fromString(key) orelse return error.InvalidQuestionFormat;
            return .noulText(preset.description());
        },
        .array => |arr| return .choiceText(key, try stringChoices(arena, arr.items)),
        .object => |obj| return objectQuestion(arena, key, obj),
        else => return error.InvalidQuestionFormat,
    }
}

fn objectQuestion(arena: std.mem.Allocator, key: []const u8, obj: std.json.ObjectMap) PrepareError!Question {
    const instructions = blk: {
        if (obj.get("question")) |qv| if (qv == .string) break :blk qv.string;
        if (obj.get("instructions")) |iv| if (iv == .string) break :blk iv.string;
        break :blk key;
    };

    if (obj.get("levels")) |levels_val| {
        if (levels_val != .array) return error.InvalidQuestionFormat;
        const items = levels_val.array.items;
        if (items.len < 2 or items.len > 10) return error.InvalidQuestionFormat;
        const criteria = try arena.alloc(Content, items.len);
        for (items, criteria) |item, *level| {
            if (item != .string) return error.InvalidQuestionFormat;
            level.* = .{ .text = item.string };
        }
        return .scoreText(instructions, criteria);
    }

    const options = obj.get("options") orelse obj.get("criteria") orelse return .noulText(instructions);
    switch (options) {
        .array => |arr| return .choiceText(instructions, try stringChoices(arena, arr.items)),
        .object => |crit_obj| {
            const choice_entries = try arena.alloc(zenai.typesafe.ChoiceEntry, crit_obj.count());
            for (choice_entries, crit_obj.keys(), crit_obj.values()) |*entry, crit_key, crit_val| {
                entry.* = .{
                    .key = crit_key,
                    .value = if (crit_val == .string) .{ .text = crit_val.string } else null,
                };
            }
            return .choiceText(instructions, .init(choice_entries));
        },
        else => return error.InvalidQuestionFormat,
    }
}

fn stringChoices(arena: std.mem.Allocator, items: []const std.json.Value) PrepareError!zenai.typesafe.types.ChoiceCriteria {
    const entries = try arena.alloc(zenai.typesafe.ChoiceEntry, items.len);
    for (items, entries) |item, *entry| {
        if (item != .string) return error.InvalidQuestionFormat;
        entry.* = .{ .key = item.string, .value = null };
    }
    return .init(entries);
}

/// Every preset, keyed by its name: what an empty questions object asks.
fn preparePresets(arena: std.mem.Allocator) error{OutOfMemory}!PreparedQuestions {
    const presets = std.enums.values(Preset);
    const entries = try arena.alloc(zenai.typesafe.QuestionEntry, presets.len);
    for (presets, entries) |preset, *entry| {
        entry.* = .{ .key = @tagName(preset), .value = .noulText(preset.description()) };
    }
    return .{ .questions = .init(entries), .kind = .questions_object };
}

/// Most of the page `buildState` sends, in bytes.
const max_state_bytes = 8192;

/// The page as Jev sees it: url, title, status, and the semantic tree of
/// `node` as text. The tree keeps what markdown drops and the questions turn
/// on (form fields, dialogs, the title of an iframe holding a CAPTCHA) and,
/// without node ids, is about as long; links carry where they go.
pub fn buildState(arena: std.mem.Allocator, page: *Frame, node: *DOMNode, registry: *NodeRegistry) !Content {
    const tree = lp.SemanticTree.init(arena, node, registry, page, .{ .ids = false, .link_urls = true }) catch return error.InternalError;
    var aw: std.Io.Writer.Allocating = .init(arena);
    tree.textStringify(&aw.writer) catch return error.InternalError;

    var state: std.json.ObjectMap = .empty;
    try state.put(arena, "url", .{ .string = page.url });
    try state.put(arena, "title", if (page.getTitle() catch null) |title| .{ .string = title } else .null);
    if (page._http_status) |status| {
        try state.put(arena, "status", .{ .integer = status });
    }
    try state.put(arena, "content", .{ .string = truncateUtf8(aw.written(), max_state_bytes) });
    return .{ .json = .{ .object = state } };
}

/// At most `max` bytes of `text`, cut on a UTF-8 boundary.
fn truncateUtf8(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

pub const FormatError = error{
    OutOfMemory,
    WriteFailed,
} || zenai.typesafe.types.ChoiceError;

pub fn formatResponse(
    arena: std.mem.Allocator,
    response: zenai.typesafe.types.AskResponse,
    prepared: PreparedQuestions,
) FormatError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };

    switch (prepared.kind) {
        .single_choice => try jw.write(try response.choice(category_key, prepared.questions)),
        .questions_object => {
            try jw.beginObject();
            for (prepared.questions.entries) |entry| {
                try jw.objectField(entry.key);
                // A missing answer is null, not a confident "no".
                const answer = response.answer(entry.key) orelse {
                    try jw.write(null);
                    continue;
                };
                switch (answer) {
                    .noul => |n| try jw.write(n.noul),
                    .choice => |c| try jw.write(.{
                        .choice = c.choice,
                        .confidence = c.confidence,
                        .probabilities = c.probabilities,
                    }),
                    .score => |s| try writeScore(&jw, s),
                }
            }
            try jw.endObject();
        },
    }
    return aw.written();
}

/// A score answer with its level indices swapped for the legend's labels,
/// and `level` naming the one nearest the score.
fn writeScore(jw: *std.json.Stringify, answer: zenai.typesafe.types.ScoreAnswer) !void {
    try jw.beginObject();
    try jw.objectField("score");
    try jw.write(answer.score);
    if (answer.nearestLevel()) |nearest| {
        try jw.objectField("level");
        try jw.write(levelLabel(answer, nearest.key));
    }
    try jw.objectField("confidence");
    try jw.write(answer.confidence);
    try jw.objectField("probabilities");
    try jw.beginObject();
    for (answer.probabilities.entries) |entry| {
        try jw.objectField(levelLabel(answer, entry.key));
        try jw.write(entry.value);
    }
    try jw.endObject();
    try jw.endObject();
}

/// The text the legend gives level `index`, or the index itself.
fn levelLabel(answer: zenai.typesafe.types.ScoreAnswer, index: []const u8) []const u8 {
    const level = answer.legend.get(index) orelse return index;
    return switch (level) {
        .text => |text| text,
        .json => index,
    };
}

const testing = @import("../testing.zig");

test "browser.classify: prepareQuestions presets in the object form" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "{\"isBlocked\": true, \"isCaptcha\": true}" });
    try testing.expectEqual(ResponseKind.questions_object, prepared.kind);
    try testing.expectEqual(2, prepared.questions.entries.len);
    try testing.expect(prepared.questions.entries[0].value == .noul);
    try std.testing.expectEqualStrings("isBlocked", prepared.questions.entries[0].key);
    try testing.expect(prepared.questions.has("isBlocked"));
    try testing.expect(prepared.questions.has("isCaptcha"));
}

test "browser.classify: prepareQuestions empty object asks every preset" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "{}" });
    try testing.expectEqual(ResponseKind.questions_object, prepared.kind);
    try testing.expectEqual(std.enums.values(Preset).len, prepared.questions.entries.len);
    for (std.enums.values(Preset), prepared.questions.entries) |preset, entry| {
        try std.testing.expectEqualStrings(@tagName(preset), entry.key);
        try testing.expect(entry.value == .noul);
        try testing.expect(prepared.questions.has(@tagName(preset)));
    }
}

test "browser.classify: prepareQuestions rejects an empty array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.EmptyQuestions, prepareQuestions(arena.allocator(), .{ .string = "[]" }));
}

test "browser.classify: prepareQuestions takes the value or its JSON" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var obj: std.json.ObjectMap = .empty;
    try obj.put(aa, "isBlocked", .{ .bool = true });
    const prepared = try prepareQuestions(aa, .{ .object = obj });
    try testing.expect(prepared.questions.get("isBlocked").? == .noul);

    try testing.expectError(error.InvalidQuestionsJson, prepareQuestions(aa, .{ .string = "{isBlocked: true}" }));
    try testing.expectError(error.InvalidQuestionFormat, prepareQuestions(aa, .{ .integer = 1 }));
}

test "browser.classify: prepareQuestions array of preset names is still categories" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "[\"isBlocked\", \"isCaptcha\"]" });
    try testing.expectEqual(ResponseKind.single_choice, prepared.kind);
    try testing.expect(prepared.questions.has(category_key));
}

test "browser.classify: prepareQuestions category array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "[\"product\", \"catalog\", \"login\"]" });
    try testing.expectEqual(ResponseKind.single_choice, prepared.kind);
    try testing.expectEqual(1, prepared.questions.entries.len);
    try testing.expect(prepared.questions.entries[0].value == .choice);
    try testing.expect(prepared.questions.has(category_key));
}

test "browser.classify: prepareQuestions object with strings and options" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const json =
        \\{
        \\  "is_blocked": "Is the page blocked?",
        \\  "page_type": {
        \\    "question": "What kind of page is this?",
        \\    "options": ["product", "catalog"]
        \\  }
        \\}
    ;
    const prepared = try prepareQuestions(arena.allocator(), .{ .string = json });
    try testing.expectEqual(ResponseKind.questions_object, prepared.kind);
    try testing.expectEqual(2, prepared.questions.entries.len);
    try testing.expect(prepared.questions.has("is_blocked"));
    try testing.expect(prepared.questions.has("page_type"));
}

test "browser.classify: prepareQuestions score levels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const json =
        \\{"content": {"question": "How complete is the main content?", "levels": ["empty", "partial", "full"]}}
    ;
    const prepared = try prepareQuestions(arena.allocator(), .{ .string = json });
    try testing.expectEqual(1, prepared.questions.entries.len);
    try testing.expect(prepared.questions.get("content").? == .score);
    try testing.expectEqual(3, prepared.questions.entries[0].value.score.criteria.len);
}

test "browser.classify: prepareQuestions rejects too few or too many levels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidQuestionFormat, prepareQuestions(arena.allocator(), .{ .string = "{\"a\": {\"levels\": [\"only\"]}}" }));
    try testing.expectError(error.InvalidQuestionFormat, prepareQuestions(arena.allocator(), .{ .string = "{\"a\": {\"levels\": [\"1\",\"2\",\"3\",\"4\",\"5\",\"6\",\"7\",\"8\",\"9\",\"10\",\"11\"]}}" }));
    try testing.expectError(error.InvalidQuestionFormat, prepareQuestions(arena.allocator(), .{ .string = "{\"a\": {\"levels\": [1, 2]}}" }));
}

test "browser.classify: formatResponse score names the levels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "{\"content\": {\"question\": \"How complete?\", \"levels\": [\"empty\", \"partial\", \"full\"]}}" });
    const response: zenai.typesafe.types.AskResponse = .{
        .answers = .init(&.{
            .{ .key = "content", .value = .{ .score = .{
                .score = 1.2,
                .confidence = 0.8,
                .legend = .init(&.{
                    .{ .key = "0", .value = .{ .text = "empty" } },
                    .{ .key = "1", .value = .{ .text = "partial" } },
                    .{ .key = "2", .value = .{ .text = "full" } },
                }),
                .probabilities = .init(&.{
                    .{ .key = "0", .value = 0.05 },
                    .{ .key = "1", .value = 0.7 },
                    .{ .key = "2", .value = 0.25 },
                }),
            } } },
        }),
    };

    const formatted = try formatResponse(arena.allocator(), response, prepared);
    try std.testing.expectEqualStrings(
        \\{"content":{"score":1.2,"level":"partial","confidence":0.8,"probabilities":{"empty":0.05,"partial":0.7,"full":0.25}}}
    , formatted);
}

test "browser.classify: formatResponse single_choice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "[\"product\", \"catalog\"]" });
    const response: zenai.typesafe.types.AskResponse = .{
        .answers = .init(&.{
            .{ .key = "__category", .value = .{ .choice = .{
                .choice = "product",
                .confidence = 0.95,
                .probabilities = .init(&.{
                    .{ .key = "product", .value = 0.95 },
                    .{ .key = "catalog", .value = 0.05 },
                }),
            } } },
        }),
    };

    const formatted = try formatResponse(arena.allocator(), response, prepared);
    try std.testing.expectEqualStrings("\"product\"", formatted);
}

test "browser.classify: formatResponse presets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "{\"isBlocked\": true, \"isCaptcha\": true}" });
    const response: zenai.typesafe.types.AskResponse = .{
        .answers = .init(&.{
            .{ .key = "isBlocked", .value = .{ .noul = .{ .noul = 0.92 } } },
            .{ .key = "isCaptcha", .value = .{ .noul = .{ .noul = 0.08 } } },
        }),
    };

    const formatted = try formatResponse(arena.allocator(), response, prepared);
    try std.testing.expectEqualStrings("{\"isBlocked\":0.92,\"isCaptcha\":0.08}", formatted);
}

test "browser.classify: formatResponse writes null for a missing answer" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), .{ .string = "{\"isBlocked\": true, \"kind\": [\"a\", \"b\"]}" });
    const response: zenai.typesafe.types.AskResponse = .{};

    const formatted = try formatResponse(arena.allocator(), response, prepared);
    try std.testing.expectEqualStrings("{\"isBlocked\":null,\"kind\":null}", formatted);
}
