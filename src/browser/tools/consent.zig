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
//! labelled data. A click that leaves a banner up, a confirmation say, is
//! followed by a pick from what the page shows then.

const std = @import("std");
const lp = @import("../../lightpanda.zig");
const zenai = @import("zenai");

const choose = @import("choose.zig");
const jev = @import("jev.zig");

const tools = @import("../tools.zig");
const ToolError = tools.ToolError;
const ToolResult = tools.ToolResult;
const parseArgsOrDefault = tools.parseArgsOrDefault;
const renderJson = tools.renderJson;
const requireFrame = tools.requireFrame;
const resolveBySelector = tools.resolveBySelector;
const selectorFor = tools.selectorFor;
const NodeRegistry = lp.NodeRegistry;
const askPage = jev.askPage;
const internalUnlessOom = jev.internalUnlessOom;
const unusableAnswer = jev.unusableAnswer;
const compact = jev.compact;
const verdict = jev.verdict;
const unverified = jev.unverified;
const clickAndSettle = jev.clickAndSettle;

const Questions = zenai.typesafe.Questions;
const QuestionEntry = zenai.typesafe.QuestionEntry;

/// The question ids, which also key the answers.
pub const wall_key = @tagName(jev.Preset.isConsentWall);
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
    entries[0] = jev.presetQuestion(.isConsentWall);
    entries[1] = .{ .key = control_key, .value = try choose.question(arena, prefer.instructions(), candidates, &.{}) };
    return .init(entries);
}

/// Just the banner question, for the re-read that verifies a click.
pub fn verifyQuestions(arena: std.mem.Allocator) error{OutOfMemory}!Questions {
    return jev.presetQuestions(arena, &.{.isConsentWall});
}

/// What the tool reports. `dismissed` is what we did, `verified` is whether
/// the page agreed afterwards — they come apart, and a caller deciding
/// whether to trust the page it is about to read needs both.
pub const Outcome = struct {
    dismissed: bool = false,
    verified: bool = false,
    /// The controls we clicked, in order, as selectors that resolve to them
    /// again.
    selectors: ?[]const []const u8 = null,
    /// The last one's accessible name, so a human reading the log sees what
    /// was clicked.
    control: ?[]const u8 = null,
    /// The model's probability for that control.
    confidence: ?f64 = null,
    /// How sure it was there was a banner, before and after the click.
    consentWall: ?f64 = null,
    consentWallAfter: ?f64 = null,
    /// Controls clicked, at most 2.
    attempts: u8 = 0,
    candidates: ?usize = null,
    reason: ?[]const u8 = null,
};

/// Clicks before giving up. Each is decided on the page the one before it
/// left, so a confirmation the first click raises gets a pick of its own.
const max_consent_clicks = 2;

pub fn exec(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const Params = struct {
        prefer: Prefer = .accept,
        selectors: ?[]const []const u8 = null,
    };
    const args = try parseArgsOrDefault(Params, arena, arguments);
    var outcome: Outcome = .{};

    if (args.selectors) |selectors| {
        for (selectors) |selector| {
            // Most often the banner was already dismissed, by an earlier run's
            // cookie: a replay repeats a decision, it does not make a new one.
            const target = resolveBySelector(session, selector) catch |err| switch (err) {
                error.NodeNotFound => return verdict(arena, &outcome, if (outcome.attempts == 0)
                    "the control given is not on this page, so nothing was clicked"
                else
                    "the next control given is not on the page the last click left"),
                else => return err,
            };
            try clickAndSettle(session, registry, target.node, target.page);
            outcome.dismissed = true;
            outcome.attempts += 1;
        }
        outcome.selectors = selectors;
        return verdict(arena, &outcome, "clicked the controls given, without asking the model");
    }

    var clicked: std.ArrayList([]const u8) = try .initCapacity(arena, max_consent_clicks);

    while (true) {
        const page = try requireFrame(session);
        const candidates: []const choose.Candidate = if (outcome.attempts < max_consent_clicks)
            choose.collect(arena, page.document.asNode(), page, registry) catch |err| return internalUnlessOom(err)
        else
            &.{};
        if (outcome.attempts == 0) {
            if (candidates.len == 0) {
                return verdict(arena, &outcome, "no control on this page could be clicked");
            }
            outcome.candidates = candidates.len;
        }

        const asked = if (candidates.len > 0)
            try questions(arena, candidates, args.prefer)
        else
            try verifyQuestions(arena);
        var response = switch (try askPage(arena, session, registry, .{
            .tool = .acceptCookies,
            .questions = asked,
            .node = page.document.asNode(),
            .state = .{ .link_urls = false, .ids = candidates.len > 0 },
        })) {
            .failed => |failed| {
                if (outcome.attempts == 0) return failed;
                return unverified(arena, &outcome, consentVerdict, failed, "clicked, but could not check whether the banner went");
            },
            .ok => |ok| ok,
        };
        defer response.deinit();

        const wall = response.value.noul(wall_key);
        if (outcome.attempts == 0) {
            outcome.consentWall = wall;
            if ((wall orelse 0) < jev.gate) {
                return verdict(arena, &outcome, "those controls are not a consent banner");
            }
        } else {
            outcome.consentWallAfter = wall;
            if ((wall orelse 1) < jev.gate) {
                outcome.verified = true;
                return consentVerdict(arena, &outcome, null);
            }
        }
        if (candidates.len == 0) break;

        const best = choose.best(candidates, response.value, asked, control_key) catch |err| switch (err) {
            error.OutOfMemory => return ToolError.OutOfMemory,
            else => {
                const unusable = try unusableAnswer(arena, .acceptCookies, err);
                if (outcome.attempts == 0) return unusable;
                return unverified(arena, &outcome, consentVerdict, unusable, "clicked, but the banner is still there");
            },
        };
        const pick = best orelse {
            if (outcome.attempts == 0) return verdict(arena, &outcome, "no control here would dismiss the banner");
            break;
        };
        const selector = selectorFor(arena, page, pick.candidate.element) orelse {
            if (outcome.attempts == 0) return verdict(arena, &outcome, "no selector could be built for the control the model picked");
            break;
        };

        outcome.attempts += 1;
        clicked.appendAssumeCapacity(selector);
        outcome.selectors = clicked.items;
        outcome.control = pick.candidate.name;
        outcome.confidence = pick.probability;
        try clickAndSettle(session, registry, pick.candidate.element.asNode(), page);
        outcome.dismissed = true;
    }
    return consentVerdict(arena, &outcome, "clicked, but the banner is still there");
}

fn consentVerdict(arena: std.mem.Allocator, outcome: *Outcome, reason: ?[]const u8) ToolError!ToolResult {
    var result = try verdict(arena, outcome, reason);
    // Only a dismissal the re-read confirmed is worth repeating.
    if (outcome.verified) {
        result.replay_args = try renderJson(arena, .{ .selectors = outcome.selectors }, compact);
    }
    return result;
}

const testing = @import("../../testing.zig");
const call = tools.call;

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
    try testing.expectEqual(2, pick.choice.criteria.count());
    try testing.expect(pick.choice.criteria.has(choose.none_key));
}

test "acceptCookies: a page with nothing to click costs no model call" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("markdown_alternate_plain.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    // No TYPESAFE_API_KEY is set in the test environment, so reaching the
    // model at all would have said so here.
    try std.testing.expect(std.mem.find(u8, result.text, "could be clicked") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"dismissed\":false") != null);
}

test "acceptCookies: the recorded control is clicked without the model" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selectors":["#accept"]}
    , .{});
    const result = try call(aa, page.session, &registry, "acceptCookies", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"dismissed\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "without asking the model") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"verified\":false") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "Accept all cookies") == null);
    try std.testing.expect(std.mem.find(u8, tree.text, "Headline") != null);
}

test "acceptCookies: a recorded control that is gone clicks nothing and asks nothing" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selectors":["#gone"]}
    , .{});
    const result = try call(aa, page.session, &registry, "acceptCookies", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"dismissed\":false") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "not on this page") != null);
    try std.testing.expectEqual(null, result.replay_args);
}

test "acceptCookies: the control Jev picks is clicked and the re-read verifies it" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.start(aa);
    defer mock.stop();

    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"dismissed\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"verified\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "Accept all cookies") != null);
    // What `--save` writes into the script, so the next run clicks it directly.
    try std.testing.expectEqualStrings("{\"selectors\":[\"#accept\"]}", result.replay_args.?);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "Accept all cookies") == null);
    try std.testing.expect(std.mem.find(u8, tree.text, "Headline") != null);
}

test "acceptCookies: a click that moves the page is followed by a pick on the page it went to" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner_navigates.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.start(aa);
    defer mock.stop();

    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"attempts\":2") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"verified\":true") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "Accept all cookies") == null);
}

test "acceptCookies: a confirmation the first click raises is picked from afresh" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner_confirm.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.start(aa);
    defer mock.stop();

    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"attempts\":2") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"verified\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "Yes, accept them") != null);
    try std.testing.expectEqualStrings("{\"selectors\":[\"#accept\",\"#confirm\"]}", result.replay_args.?);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "Go back") == null);
    try std.testing.expect(std.mem.find(u8, tree.text, "Headline") != null);
}

test "acceptCookies: a missing key is reported so the REPL can ask a model instead" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("consent_banner.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    _ = testing.unsetenv(@constCast(zenai.typesafe.env_var_name));

    const result = try call(aa, page.session, &registry, "acceptCookies", null, .{ .source = .user });
    try std.testing.expect(result.is_error);
    // What `/acceptCookies` reads to fall back to the prompt it used to send.
    try std.testing.expectEqual(.missing_api_key, result.failure);
    try std.testing.expect(std.mem.find(u8, result.text, zenai.typesafe.env_var_name) != null);
}
