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

    pub fn fromString(name: []const u8) ?Preset {
        if (std.mem.eql(u8, name, "isBlocked") or std.mem.eql(u8, name, "is_blocked")) return .isBlocked;
        if (std.mem.eql(u8, name, "isCaptcha") or std.mem.eql(u8, name, "is_captcha")) return .isCaptcha;
        if (std.mem.eql(u8, name, "isConsentWall") or std.mem.eql(u8, name, "is_consent_wall")) return .isConsentWall;
        if (std.mem.eql(u8, name, "isEmptyCatalog") or std.mem.eql(u8, name, "is_empty_catalog")) return .isEmptyCatalog;
        if (std.mem.eql(u8, name, "isErrorPage") or std.mem.eql(u8, name, "is_error_page")) return .isErrorPage;
        if (std.mem.eql(u8, name, "isLoginWall") or std.mem.eql(u8, name, "is_login_wall")) return .isLoginWall;
        if (std.mem.eql(u8, name, "isPaywall") or std.mem.eql(u8, name, "is_paywall")) return .isPaywall;
        if (std.mem.eql(u8, name, "isUnsupportedBrowser") or std.mem.eql(u8, name, "is_unsupported_browser")) return .isUnsupportedBrowser;
        if (std.mem.eql(u8, name, "isLoading") or std.mem.eql(u8, name, "is_loading")) return .isLoading;
        return null;
    }
};

pub const ResponseKind = enum {
    single_choice,
    questions_object,
};

pub const QuestionSpec = struct {
    key: []const u8,
    is_noul: bool,
    /// A score question's level labels, low to high; empty otherwise.
    levels: []const []const u8 = &.{},
};

pub const PreparedQuestions = struct {
    questions: zenai.typesafe.Questions,
    kind: ResponseKind,
    specs: []const QuestionSpec,
};

pub const PrepareError = error{
    InvalidQuestionsJson,
    EmptyQuestions,
    InvalidQuestionFormat,
    OutOfMemory,
};

pub fn prepareQuestions(arena: std.mem.Allocator, questions_json: []const u8) PrepareError!PreparedQuestions {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, questions_json, .{}) catch
        return error.InvalidQuestionsJson;

    switch (parsed) {
        .array => |arr| {
            if (arr.items.len == 0) return error.EmptyQuestions;

            // An array is always the categories of one choice question; presets
            // go through the object form.
            for (arr.items) |item| {
                if (item != .string) return error.InvalidQuestionFormat;
            }

            const choice_entries = try arena.alloc(zenai.typesafe.ChoiceEntry, arr.items.len);
            for (arr.items, 0..) |item, i| {
                choice_entries[i] = .{ .key = item.string, .value = null };
            }

            const entries = try arena.alloc(zenai.typesafe.QuestionEntry, 1);
            entries[0] = .{
                .key = "__category",
                .value = .choiceText("What kind of page is this?", .init(choice_entries)),
            };
            const specs = try arena.alloc(QuestionSpec, 1);
            specs[0] = .{
                .key = "__category",
                .is_noul = false,
            };

            return .{
                .questions = .init(entries),
                .kind = .single_choice,
                .specs = specs,
            };
        },
        .object => |obj| {
            if (obj.count() == 0) return preparePresets(arena);

            const entries = try arena.alloc(zenai.typesafe.QuestionEntry, obj.count());
            const specs = try arena.alloc(QuestionSpec, obj.count());

            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;

                var is_noul = false;
                var levels: []const []const u8 = &.{};
                var q: zenai.typesafe.Question = undefined;

                switch (val) {
                    .bool => |b| {
                        if (!b) return error.InvalidQuestionFormat;
                        const instructions = if (Preset.fromString(key)) |preset|
                            preset.description()
                        else
                            key;
                        q = .noulText(instructions);
                        is_noul = true;
                    },
                    .string => |s| {
                        const instructions = if (s.len == 0) blk: {
                            const preset = Preset.fromString(key) orelse return error.InvalidQuestionFormat;
                            break :blk preset.description();
                        } else s;
                        q = .noulText(instructions);
                        is_noul = true;
                    },
                    .array => |opt_arr| {
                        const choice_entries = try arena.alloc(zenai.typesafe.ChoiceEntry, opt_arr.items.len);
                        for (opt_arr.items, 0..) |opt_item, oi| {
                            if (opt_item != .string) return error.InvalidQuestionFormat;
                            choice_entries[oi] = .{ .key = opt_item.string, .value = null };
                        }
                        q = .choiceText(key, .init(choice_entries));
                        is_noul = false;
                    },
                    .object => |inner_obj| {
                        // Look for `question` or `instructions`
                        const instructions = blk: {
                            if (inner_obj.get("question")) |qv| {
                                if (qv == .string) break :blk qv.string;
                            }
                            if (inner_obj.get("instructions")) |iv| {
                                if (iv == .string) break :blk iv.string;
                            }
                            break :blk key;
                        };

                        if (inner_obj.get("levels")) |levels_val| {
                            if (levels_val != .array) return error.InvalidQuestionFormat;
                            const items = levels_val.array.items;
                            if (items.len < 2 or items.len > 10) return error.InvalidQuestionFormat;
                            const labels = try arena.alloc([]const u8, items.len);
                            const criteria = try arena.alloc(zenai.typesafe.Content, items.len);
                            for (items, labels, criteria) |item, *label, *level| {
                                if (item != .string) return error.InvalidQuestionFormat;
                                label.* = item.string;
                                level.* = .{ .text = item.string };
                            }
                            q = .scoreText(instructions, criteria);
                            levels = labels;
                        } else if (inner_obj.get("options") orelse inner_obj.get("criteria")) |opts_val| {
                            switch (opts_val) {
                                .array => |opt_arr| {
                                    const choice_entries = try arena.alloc(zenai.typesafe.ChoiceEntry, opt_arr.items.len);
                                    for (opt_arr.items, 0..) |opt_item, oi| {
                                        if (opt_item != .string) return error.InvalidQuestionFormat;
                                        choice_entries[oi] = .{ .key = opt_item.string, .value = null };
                                    }
                                    q = .choiceText(instructions, .init(choice_entries));
                                    is_noul = false;
                                },
                                .object => |crit_obj| {
                                    const choice_entries = try arena.alloc(zenai.typesafe.ChoiceEntry, crit_obj.count());
                                    var crit_it = crit_obj.iterator();
                                    var ci: usize = 0;
                                    while (crit_it.next()) |crit_entry| : (ci += 1) {
                                        const crit_val = crit_entry.value_ptr.*;
                                        const opt_content: ?zenai.typesafe.Content = if (crit_val == .string)
                                            .{ .text = crit_val.string }
                                        else
                                            null;
                                        choice_entries[ci] = .{ .key = crit_entry.key_ptr.*, .value = opt_content };
                                    }
                                    q = .choiceText(instructions, .init(choice_entries));
                                    is_noul = false;
                                },
                                else => return error.InvalidQuestionFormat,
                            }
                        } else {
                            q = .noulText(instructions);
                            is_noul = true;
                        }
                    },
                    else => return error.InvalidQuestionFormat,
                }

                entries[i] = .{ .key = key, .value = q };
                specs[i] = .{ .key = key, .is_noul = is_noul, .levels = levels };
            }

            return .{
                .questions = .init(entries),
                .kind = .questions_object,
                .specs = specs,
            };
        },
        else => return error.InvalidQuestionFormat,
    }
}

/// Every preset, keyed by its name: what an empty questions object asks.
fn preparePresets(arena: std.mem.Allocator) error{OutOfMemory}!PreparedQuestions {
    const presets = std.enums.values(Preset);
    const entries = try arena.alloc(zenai.typesafe.QuestionEntry, presets.len);
    const specs = try arena.alloc(QuestionSpec, presets.len);
    for (presets, entries, specs) |preset, *entry, *spec| {
        entry.* = .{ .key = @tagName(preset), .value = .noulText(preset.description()) };
        spec.* = .{ .key = @tagName(preset), .is_noul = true };
    }
    return .{
        .questions = .init(entries),
        .kind = .questions_object,
        .specs = specs,
    };
}

pub fn buildState(arena: std.mem.Allocator, page: *Frame, node: *DOMNode) !zenai.typesafe.Content {
    const title = page.getTitle() catch null;
    const render_state = lp.RenderTree.resolve(arena, node, .{}, page) catch return error.OutOfMemory;
    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.markdown.dump(render_state, .{ .max_bytes = 8192 }, &aw.writer, page) catch return error.InternalError;
    const text_content = aw.written();

    var buf: std.Io.Writer.Allocating = .init(arena);
    try buf.writer.writeAll("{\"url\":");
    try std.json.Stringify.value(page.url, .{}, &buf.writer);
    try buf.writer.writeAll(",\"title\":");
    try std.json.Stringify.value(title, .{}, &buf.writer);
    if (page._http_status) |status| {
        try buf.writer.print(",\"status\":{d}", .{status});
    }
    try buf.writer.writeAll(",\"content\":");
    try std.json.Stringify.value(text_content, .{}, &buf.writer);
    try buf.writer.writeAll("}");

    return .{ .text = buf.written() };
}

pub const FormatError = error{
    AnswerMissing,
    OutOfMemory,
    WriteFailed,
} || zenai.typesafe.types.ChoiceError;

pub fn formatResponse(
    arena: std.mem.Allocator,
    response: zenai.typesafe.types.AskResponse,
    prepared: PreparedQuestions,
) FormatError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const writer = &aw.writer;

    switch (prepared.kind) {
        .single_choice => {
            const chosen = try response.choice("__category", prepared.questions);
            try std.json.Stringify.value(chosen, .{}, writer);
        },
        .questions_object => {
            try writer.writeByte('{');
            for (prepared.specs, 0..) |spec, i| {
                if (i > 0) try writer.writeByte(',');
                try std.json.Stringify.value(spec.key, .{}, writer);
                try writer.writeByte(':');
                // A missing answer is null, not a confident "no".
                if (spec.is_noul) {
                    try std.json.Stringify.value(response.noul(spec.key), .{}, writer);
                } else {
                    const ans = response.answer(spec.key) orelse {
                        try writer.writeAll("null");
                        continue;
                    };
                    switch (ans) {
                        .choice => |c| {
                            try writer.writeAll("{\"choice\":");
                            try std.json.Stringify.value(c.choice, .{}, writer);
                            try writer.writeAll(",\"confidence\":");
                            try std.json.Stringify.value(c.confidence, .{}, writer);
                            try writer.writeAll(",\"probabilities\":{");
                            var first_prob = true;
                            for (c.probabilities.entries) |pe| {
                                if (!first_prob) try writer.writeByte(',');
                                first_prob = false;
                                try std.json.Stringify.value(pe.key, .{}, writer);
                                try writer.writeByte(':');
                                try std.json.Stringify.value(pe.value, .{}, writer);
                            }
                            try writer.writeAll("}}");
                        },
                        .noul => |n| {
                            try std.json.Stringify.value(n.noul, .{}, writer);
                        },
                        .score => |s| try writeScore(writer, s, spec.levels),
                    }
                }
            }
            try writer.writeByte('}');
        },
    }
    return aw.written();
}

/// A score answer with its level indices swapped for the labels asked, and
/// `level` naming the one nearest the score.
fn writeScore(writer: *std.Io.Writer, answer: zenai.typesafe.types.ScoreAnswer, levels: []const []const u8) !void {
    try writer.writeAll("{\"score\":");
    try std.json.Stringify.value(answer.score, .{}, writer);
    if (levels.len > 0) {
        const nearest: usize = @intFromFloat(std.math.clamp(@round(answer.score), 0, @as(f64, @floatFromInt(levels.len - 1))));
        try writer.writeAll(",\"level\":");
        try std.json.Stringify.value(levels[nearest], .{}, writer);
    }
    try writer.writeAll(",\"confidence\":");
    try std.json.Stringify.value(answer.confidence, .{}, writer);
    try writer.writeAll(",\"probabilities\":{");
    for (answer.probabilities.entries, 0..) |entry, i| {
        if (i > 0) try writer.writeByte(',');
        const index = std.fmt.parseInt(usize, entry.key, 10) catch null;
        const label = if (index != null and index.? < levels.len) levels[index.?] else entry.key;
        try std.json.Stringify.value(label, .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(entry.value, .{}, writer);
    }
    try writer.writeAll("}}");
}

const testing = @import("../testing.zig");

test "browser.classify: prepareQuestions presets in the object form" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), "{\"isBlocked\": true, \"isCaptcha\": true}");
    try testing.expectEqual(ResponseKind.questions_object, prepared.kind);
    try testing.expectEqual(2, prepared.specs.len);
    try testing.expect(prepared.specs[0].is_noul);
    try std.testing.expectEqualStrings("isBlocked", prepared.specs[0].key);
    try testing.expect(prepared.questions.has("isBlocked"));
    try testing.expect(prepared.questions.has("isCaptcha"));
}

test "browser.classify: prepareQuestions empty object asks every preset" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), "{}");
    try testing.expectEqual(ResponseKind.questions_object, prepared.kind);
    try testing.expectEqual(std.enums.values(Preset).len, prepared.specs.len);
    for (std.enums.values(Preset), prepared.specs) |preset, spec| {
        try std.testing.expectEqualStrings(@tagName(preset), spec.key);
        try testing.expect(spec.is_noul);
        try testing.expect(prepared.questions.has(@tagName(preset)));
    }
}

test "browser.classify: prepareQuestions rejects an empty array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.EmptyQuestions, prepareQuestions(arena.allocator(), "[]"));
}

test "browser.classify: prepareQuestions array of preset names is still categories" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), "[\"isBlocked\", \"isCaptcha\"]");
    try testing.expectEqual(ResponseKind.single_choice, prepared.kind);
    try testing.expect(prepared.questions.has("__category"));
}

test "browser.classify: prepareQuestions category array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), "[\"product\", \"catalog\", \"login\"]");
    try testing.expectEqual(ResponseKind.single_choice, prepared.kind);
    try testing.expectEqual(1, prepared.specs.len);
    try testing.expect(!prepared.specs[0].is_noul);
    try testing.expect(prepared.questions.has("__category"));
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
    const prepared = try prepareQuestions(arena.allocator(), json);
    try testing.expectEqual(ResponseKind.questions_object, prepared.kind);
    try testing.expectEqual(2, prepared.specs.len);
    try testing.expect(prepared.questions.has("is_blocked"));
    try testing.expect(prepared.questions.has("page_type"));
}

test "browser.classify: prepareQuestions score levels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const json =
        \\{"content": {"question": "How complete is the main content?", "levels": ["empty", "partial", "full"]}}
    ;
    const prepared = try prepareQuestions(arena.allocator(), json);
    try testing.expectEqual(1, prepared.specs.len);
    try testing.expect(!prepared.specs[0].is_noul);
    try testing.expectEqual(3, prepared.specs[0].levels.len);
    try testing.expect(prepared.questions.get("content").? == .score);
}

test "browser.classify: prepareQuestions rejects too few or too many levels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidQuestionFormat, prepareQuestions(arena.allocator(), "{\"a\": {\"levels\": [\"only\"]}}"));
    try testing.expectError(error.InvalidQuestionFormat, prepareQuestions(arena.allocator(), "{\"a\": {\"levels\": [\"1\",\"2\",\"3\",\"4\",\"5\",\"6\",\"7\",\"8\",\"9\",\"10\",\"11\"]}}"));
    try testing.expectError(error.InvalidQuestionFormat, prepareQuestions(arena.allocator(), "{\"a\": {\"levels\": [1, 2]}}"));
}

test "browser.classify: formatResponse score names the levels" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const prepared = try prepareQuestions(arena.allocator(), "{\"content\": {\"question\": \"How complete?\", \"levels\": [\"empty\", \"partial\", \"full\"]}}");
    const response: zenai.typesafe.types.AskResponse = .{
        .answers = .init(&.{
            .{ .key = "content", .value = .{ .score = .{
                .score = 1.2,
                .confidence = 0.8,
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

    const prepared = try prepareQuestions(arena.allocator(), "[\"product\", \"catalog\"]");
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

    const prepared = try prepareQuestions(arena.allocator(), "{\"isBlocked\": true, \"isCaptcha\": true}");
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

    const prepared = try prepareQuestions(arena.allocator(), "{\"isBlocked\": true, \"kind\": [\"a\", \"b\"]}");
    const response: zenai.typesafe.types.AskResponse = .{};

    const formatted = try formatResponse(arena.allocator(), response, prepared);
    try std.testing.expectEqualStrings("{\"isBlocked\":null,\"kind\":null}", formatted);
}
