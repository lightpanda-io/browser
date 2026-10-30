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
//! presets every caller asks about, the one confidence gate, and what the
//! tools built on it share — `askPage`, their JSON verdicts, and letting the
//! page settle after a click. The question DSL that the `classify` tool
//! exposes lives in classify.zig, which is one consumer of this among several
//! — consent and login ask their own questions and classify nothing.

const std = @import("std");
const lp = @import("../../lightpanda.zig");
const zenai = @import("zenai");
const truncateUtf8 = @import("../../string.zig").truncateUtf8;

const Frame = lp.Frame;
const DOMNode = @import("../webapi/Node.zig");

const tools = @import("../tools.zig");
const Tool = tools.Tool;
const ToolError = tools.ToolError;
const ToolResult = tools.ToolResult;
const Failure = tools.Failure;
const apiFailed = tools.apiFailed;
const beginAction = tools.beginAction;
const mapActionError = tools.mapActionError;
const renderJson = tools.renderJson;
const requireFrame = tools.requireFrame;
const settleAction = tools.settleAction;
const log = lp.log;
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
    // Copied: a helper thread serializes these while page JS frees them.
    try state.put(arena, "url", .{ .string = try arena.dupe(u8, page.url) });
    const title = page.getTitle() catch null;
    try state.put(arena, "title", if (title) |t| .{ .string = try arena.dupe(u8, t) } else .null);
    if (page._http_status) |status| {
        try state.put(arena, "status", .{ .integer = status });
    }
    try state.put(arena, "content", .{ .string = truncateUtf8(aw.written(), max_state_bytes) });
    return .{ .json = .{ .object = state } };
}

pub const AskedResponse = zenai.typesafe.Client.Response(zenai.typesafe.types.AskResponse);

/// One Jev request about the current page: `.failed` carries what to tell the
/// caller, so a key that is not set or an API that is down reads the same
/// whichever tool asked.
pub const Asked = union(enum) {
    ok: AskedResponse,
    failed: ToolResult,
};

pub const Ask = struct {
    /// Names the request in an error message, and nothing else.
    tool: Tool,
    questions: zenai.typesafe.Questions,
    /// The subtree the model is shown.
    node: *DOMNode,
    state: StateOpts = .{},
};

pub fn askPage(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    ask: Ask,
) ToolError!Asked {
    const page = try requireFrame(session);
    const loader_id = page._loader_id;
    const state = buildState(arena, page, ask.node, registry, ask.state) catch |err| return internalUnlessOom(err);

    var detail: Failure = .{};
    // On a helper thread, pumping here until it answers: a blocking read on
    // this thread stops the page's timers and leaves its transfers
    // unserviced while curl's own timeout keeps counting against them.
    const options: zenai.typesafe.types.AskOptions = .{};
    const pool = &session.browser.app.typesafe;
    var response = session.runPumped(zenai.typesafe.Pool.ask, .{ pool, arena, state, ask.questions, options, &detail }) catch |err| switch (err) {
        error.MissingApiKey => return .{ .failed = .{
            .text = arena.print("{s}: " ++ zenai.typesafe.env_var_name ++ " environment variable is not set", .{@tagName(ask.tool)}) catch return ToolError.OutOfMemory,
            .is_error = true,
            .failure = .missing_api_key,
        } },
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => return .{ .failed = try apiFailed(arena, @tagName(ask.tool), err, detail) },
    };

    if (session.isCancelled()) {
        response.deinit();
        return ToolError.Cancelled;
    }

    // Pumping runs the page's own scripts, and a navigation among them tears
    // down the Page that every candidate element and node id points into (see
    // `settleAction`). The answer describes a page that is no longer here. By
    // loader id: a new frame can reuse the old one's address.
    const now = session.currentFrame();
    if (now == null or now.?._loader_id != loader_id) {
        response.deinit();
        registry.reset();
        return .{ .failed = .{
            .text = arena.print("{s}: the page navigated while the model was asked", .{@tagName(ask.tool)}) catch return ToolError.OutOfMemory,
            .is_error = true,
        } };
    }
    return .{ .ok = response };
}

/// Anything but OOM out of one of these helpers is a bug, not a user error.
pub fn internalUnlessOom(err: anyerror) ToolError {
    return if (err == error.OutOfMemory) ToolError.OutOfMemory else ToolError.InternalError;
}

/// An answer we cannot read back — not one of the options we offered, or not
/// the argmax of its own probabilities.
pub fn unusableAnswer(arena: std.mem.Allocator, tool: Tool, err: anyerror) ToolError!ToolResult {
    return .{
        .text = arena.print("{s}: the model's answer was unusable: {s}", .{ @tagName(tool), @errorName(err) }) catch return ToolError.OutOfMemory,
        .is_error = true,
    };
}

/// Dropped rather than written as null, so a verdict reads as what happened
/// rather than as every question that could have been answered.
pub const compact: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

/// A tool's own JSON verdict, with `reason` filled in when there is one to
/// give.
pub fn verdict(arena: std.mem.Allocator, outcome: anytype, reason: ?[]const u8) ToolError!ToolResult {
    if (reason) |r| outcome.reason = r;
    return .{ .text = try renderJson(arena, outcome.*, compact) };
}

/// A verification ask that fails leaves us knowing what we did but not whether
/// it worked: a caller told only "ApiError" would not learn that credentials
/// went out, so the outcome is reported with the failure as its reason.
pub fn unverified(
    arena: std.mem.Allocator,
    outcome: anytype,
    comptime render: fn (std.mem.Allocator, @TypeOf(outcome), ?[]const u8) ToolError!ToolResult,
    failed: ToolResult,
    did: []const u8,
) ToolError!ToolResult {
    var result = try render(arena, outcome, try arena.print("{s}: {s}", .{ did, failed.text }));
    result.is_error = failed.is_error;
    result.failure = failed.failure;
    return result;
}

const settle_timeout_ms: u32 = 2000;

/// Let the page act on a click: a consent banner removes itself from a
/// handler or after a request of its own, and a sign-in form navigates. A page
/// that never goes idle is not a failure here, only one we stop waiting for.
pub fn settle(session: *lp.Session) ToolError!void {
    const frame = session.currentFrame() orelse return;
    lp.actions.waitForState(.networkidle, settle_timeout_ms, frame._frame_id, session) catch |err| switch (err) {
        error.Cancelled => return ToolError.Cancelled,
        error.Timeout => {},
        else => {
            log.debug(.browser, "settle error", .{ .err = @errorName(err) });
            return ToolError.InternalError;
        },
    };
}

pub fn clickAndSettle(
    session: *lp.Session,
    registry: *NodeRegistry,
    node: *DOMNode,
    page: *lp.Frame,
) ToolError!void {
    const scope = beginAction(session);
    lp.actions.click(node, page) catch |err| return mapActionError(err);
    _ = try settleAction(session, registry, scope);
    try settle(session);
}

const testing = @import("../../testing.zig");
const call = tools.call;

test "classify: the page is still serviced while the model is asked" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("ticking.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.startSlow(aa);
    defer mock.stop();

    const before = try tickCount(aa, page.session, &registry);
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"questions":{"isBlocked":true}}
    , .{});
    const result = try call(aa, page.session, &registry, "classify", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);

    // Pumping gives the page a turn per quiet slice (250ms, see
    // `Session.idleSlice`), so a 400ms answer buys it about two. Asking on
    // this thread instead buys it none at all, whatever the interval.
    const after = try tickCount(aa, page.session, &registry);
    try std.testing.expect(after > before);
}

test "classify: a page that navigates while the model is asked is not answered for" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("late_redirect.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.startSlow(aa);
    defer mock.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"questions":{"isBlocked":true}}
    , .{});
    const result = try call(aa, page.session, &registry, "classify", args, .{ .source = .user });
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "navigated while the model was asked") != null);

    const url = try call(aa, page.session, &registry, "getUrl", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, url.text, "consent_banner.html") != null);
}

/// The counter `ticking.html` advances from a 20ms interval.
fn tickCount(aa: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry) !u32 {
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#ticks"}
    , .{});
    const result = try call(aa, session, registry, "markdown", args, .{ .source = .user });
    return std.fmt.parseInt(u32, std.mem.trim(u8, result.text, &std.ascii.whitespace), 10);
}
