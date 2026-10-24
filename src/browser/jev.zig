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

//! The TypeSafe System One (Jev) substrate: what a page looks like to it, the
//! presets every caller asks about, and the one confidence gate. The question
//! DSL that the `classify` tool exposes lives in classify.zig, which is one
//! consumer of this among several — consent and login ask their own questions
//! and classify nothing.

const std = @import("std");
const lp = @import("../lightpanda.zig");
const zenai = @import("zenai");
const truncateUtf8 = @import("../string.zig").truncateUtf8;

const Frame = lp.Frame;
const DOMNode = @import("webapi/Node.zig");
const NodeRegistry = lp.NodeRegistry;
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
        if (std.meta.stringToEnum(Preset, name)) |preset| return preset;
        inline for (comptime std.enums.values(Preset)) |preset| {
            if (std.mem.eql(u8, name, comptime snakeCase(@tagName(preset)))) return preset;
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

/// The question text for a preset named by key alone, for
/// `zenai.typesafe.json`'s `Vocabulary`. Null for a key that names no preset.
pub fn presetDescription(key: []const u8) ?[]const u8 {
    const preset = Preset.fromString(key) orelse return null;
    return preset.description();
}

/// What an empty questions object asks for.
pub fn allPresetQuestions(arena: std.mem.Allocator) error{OutOfMemory}!zenai.typesafe.Questions {
    return presetQuestions(arena, std.enums.values(Preset));
}

/// How sure the model has to be before a caller acts on a preset answer. The
/// midpoint and nothing finer: on our own data a calibrated-looking confidence
/// does not order correctness across question types (two consent walls we got
/// wrong came back at 0.99), so what settles a decision is re-reading the page
/// after acting, not a finer threshold here.
pub const gate = 0.5;

/// One preset as a question, keyed by its own name so the answer comes back
/// under `@tagName(preset)` and no caller has to spell the key itself.
pub fn presetQuestion(preset: Preset) zenai.typesafe.QuestionEntry {
    return .{ .key = @tagName(preset), .value = .noulText(preset.description()) };
}

/// Just these presets and nothing else — the shape a caller wants when it is
/// checking one specific thing rather than classifying a page.
pub fn presetQuestions(
    arena: std.mem.Allocator,
    presets: []const Preset,
) error{OutOfMemory}!zenai.typesafe.Questions {
    const entries = try arena.alloc(zenai.typesafe.QuestionEntry, presets.len);
    for (presets, entries) |preset, *entry| entry.* = presetQuestion(preset);
    return .init(entries);
}

/// How much of the page `buildState` sends. The options budget in choose.zig
/// is sized against it.
const max_state_bytes = 8192;

pub const StateOpts = struct {
    /// Where each link goes. Worth the room it takes within
    /// `max_state_bytes` only for a question that can turn on it.
    link_urls: bool = true,
    /// Number every node, so a question can offer one of them as an option
    /// and the model can place it in the page it is reading.
    ids: bool = false,
};

/// The page as Jev sees it: url, title, status, and the semantic tree of
/// `node` as text. The tree keeps what markdown drops and the questions turn
/// on (form fields, dialogs, the title of an iframe holding a CAPTCHA) and,
/// without node ids, is about as long.
pub fn buildState(arena: std.mem.Allocator, page: *Frame, node: *DOMNode, registry: *NodeRegistry, opts: StateOpts) !Content {
    const tree = lp.SemanticTree.init(arena, node, registry, page, .{ .ids = opts.ids, .link_urls = opts.link_urls }) catch return error.InternalError;
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
