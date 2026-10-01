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

    pub fn description(self: Preset) []const u8 {
        return switch (self) {
            .isBlocked => "Is the page behind a CAPTCHA, Cloudflare challenge, or bot block?",
            .isCaptcha => "Is the primary view obstructed by a CAPTCHA or human verification challenge?",
            .isConsentWall => "Is the primary view obstructed by a cookie consent banner?",
            .isEmptyCatalog => "Does the page indicate no matching products were found?",
        };
    }

    pub fn fromString(name: []const u8) ?Preset {
        if (std.mem.eql(u8, name, "isBlocked") or std.mem.eql(u8, name, "is_blocked")) return .isBlocked;
        if (std.mem.eql(u8, name, "isCaptcha") or std.mem.eql(u8, name, "is_captcha")) return .isCaptcha;
        if (std.mem.eql(u8, name, "isConsentWall") or std.mem.eql(u8, name, "is_consent_wall")) return .isConsentWall;
        if (std.mem.eql(u8, name, "isEmptyCatalog") or std.mem.eql(u8, name, "is_empty_catalog")) return .isEmptyCatalog;
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
            if (obj.count() == 0) return error.EmptyQuestions;

            const entries = try arena.alloc(zenai.typesafe.QuestionEntry, obj.count());
            const specs = try arena.alloc(QuestionSpec, obj.count());

            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;

                var is_noul = false;
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

                        if (inner_obj.get("options") orelse inner_obj.get("criteria")) |opts_val| {
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
                specs[i] = .{ .key = key, .is_noul = is_noul };
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
                        .score => |s| {
                            try writer.writeAll("{\"score\":");
                            try std.json.Stringify.value(s.score, .{}, writer);
                            try writer.writeAll(",\"confidence\":");
                            try std.json.Stringify.value(s.confidence, .{}, writer);
                            try writer.writeAll("}");
                        },
                    }
                }
            }
            try writer.writeByte('}');
        },
    }
    return aw.written();
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
