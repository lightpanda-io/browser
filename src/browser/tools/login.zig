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

//! Signing in to a site. The model picks the identifier field, the password
//! field and the control that submits them, out of every interactive element
//! on the page.
//!
//! Where a password may go is not its decision: `input[type=password]` and
//! nothing else, checked after the pick, so a page cannot talk the credential
//! somewhere else whatever its text says.
//!
//! Every decision is asked before anything is filled. The semantic tree masks
//! `type=password` values (`Input.getRedactedValue`) but not a username typed
//! into a plain text field, so asking first is what keeps it out of the
//! request. The verification after the submit is the one call that sees the
//! page in its filled state, and only ever a username at that.

const std = @import("std");
const lp = @import("../../lightpanda.zig");
const zenai = @import("zenai");

const choose = @import("choose.zig");
const jev = @import("jev.zig");
const interactive = @import("../interactive.zig");
const URL = @import("../URL.zig");
const Element = @import("../webapi/Element.zig");
const Form = @import("../webapi/element/html/Form.zig");

const tools = @import("../tools.zig");
const ToolError = tools.ToolError;
const ToolResult = tools.ToolResult;
const beginAction = tools.beginAction;
const mapActionError = tools.mapActionError;
const parseArgs = tools.parseArgs;
const renderJson = tools.renderJson;
const requireFrame = tools.requireFrame;
const resolveBySelector = tools.resolveBySelector;
const selectorFor = tools.selectorFor;
const settleAction = tools.settleAction;
const NodeRegistry = lp.NodeRegistry;
const askPage = jev.askPage;
const internalUnlessOom = jev.internalUnlessOom;
const unusableAnswer = jev.unusableAnswer;
const compact = jev.compact;
const verdict = jev.verdict;
const unverified = jev.unverified;
const settle = jev.settle;
const clickAndSettle = jev.clickAndSettle;
const Frame = lp.Frame;

const Questions = zenai.typesafe.Questions;
const QuestionEntry = zenai.typesafe.QuestionEntry;
const ChoiceEntry = zenai.typesafe.ChoiceEntry;

/// The question ids, which also key the answers.
pub const wall_key = @tagName(jev.Preset.isLoginWall);
pub const error_key = @tagName(jev.Preset.isErrorPage);
pub const user_key = "userField";
pub const password_key = "passwordField";
pub const submit_key = "submit";
pub const multi_step_key = "isMultiStep";

/// The one submit option that is not an element.
pub const enter_key = "enter";
const enter_description = "Press Enter in the filled field instead; this form has no sign-in control of its own";

/// A question whose answer cannot change what we do is dropped: unrelated
/// detail in a request distracts the model.
pub const Wanted = struct {
    /// False when there is no username to type, or it was typed on an earlier
    /// step: which field takes it can no longer change anything.
    user: bool = true,
    /// False once we are on the page an identifier-first submit returned —
    /// we came looking for the password, so where it lives is not in doubt.
    multi_step: bool = true,
};

pub fn questions(
    arena: std.mem.Allocator,
    candidates: []const choose.Candidate,
    wanted: Wanted,
) error{OutOfMemory}!Questions {
    var entries: std.ArrayList(QuestionEntry) = try .initCapacity(arena, 4);

    if (wanted.user) {
        entries.appendAssumeCapacity(.{
            .key = user_key,
            .value = try choose.question(
                arena,
                "Which field takes the username, email address or other identifier to sign in with?",
                candidates,
                &.{},
            ),
        });
    }
    entries.appendAssumeCapacity(.{
        .key = password_key,
        .value = try choose.question(
            arena,
            "Which field takes the password to sign in with? A field for choosing a new password, or for confirming one, is not it.",
            candidates,
            &.{},
        ),
    });

    const extra = [_]ChoiceEntry{.{ .key = enter_key, .value = .{ .text = enter_description } }};
    entries.appendAssumeCapacity(.{
        .key = submit_key,
        .value = try choose.question(
            arena,
            "Which control submits the sign-in form? Creating an account, recovering a password and signing in through another service are not it.",
            candidates,
            &extra,
        ),
    });
    if (wanted.multi_step) {
        entries.appendAssumeCapacity(.{
            .key = multi_step_key,
            .value = .noulText("Does this page ask for the username or email first and the password on a later step?"),
        });
    }
    return .init(entries.items);
}

/// Which element plays which part.
pub const Picks = struct {
    user: ?choose.Candidate = null,
    password: ?choose.Candidate = null,
    submit: ?choose.Candidate = null,
    /// The password is on a later step, so the first submit is the username's.
    multi_step: bool = false,
};

/// An answer that reads back as "none of these" leaves its pick null, so the
/// caller reports that instead of acting on a guess.
pub fn picks(
    candidates: []const choose.Candidate,
    asked: Questions,
    response: zenai.typesafe.types.AskResponse,
) choose.Error!Picks {
    var out: Picks = .{};
    if (asked.has(user_key)) {
        out.user = try pickOf(candidates, response, asked, user_key);
    }
    out.password = try pickOf(candidates, response, asked, password_key);
    // No candidate above "none of these" means the model chose `enter_key`
    // or nothing at all, and both come to the same act: Enter in the field.
    out.submit = try pickOf(candidates, response, asked, submit_key);
    if (asked.has(multi_step_key)) {
        out.multi_step = (response.noul(multi_step_key) orelse 0) >= jev.gate;
    }
    return out;
}

fn pickOf(candidates: []const choose.Candidate, response: zenai.typesafe.types.AskResponse, asked: Questions, key: []const u8) choose.Error!?choose.Candidate {
    const scored = try choose.best(candidates, response, asked, key) orelse return null;
    return scored.candidate;
}

/// The page after the submit: did the sign-in wall go, and did an error take
/// its place.
pub fn verifyQuestions(arena: std.mem.Allocator) error{OutOfMemory}!Questions {
    return jev.presetQuestions(arena, &.{ .isLoginWall, .isErrorPage });
}

/// `input[type=password]` and nothing else: the one place a password is
/// allowed to go, checked on the field the model picked and on a selector a
/// caller handed us alike.
pub fn isPasswordField(element: *Element) bool {
    const input = element.is(Element.Html.Input) orelse return false;
    return input._input_type == .password;
}

/// Whether a credential typed into `field` could leave over plaintext: the
/// page is not https or loopback (`URL.isPotentiallyTrustworthy`), or the URL
/// the form posts to is not. That URL is what `Frame.submitForm` uses: the
/// submitter's `formaction`, else the form's `action`; with no `submitter`,
/// Enter clicks the form's default button. A form-less field posts with
/// JavaScript, which leaves the page's own URL as all there is to check.
pub fn untrustedTarget(arena: std.mem.Allocator, frame: *Frame, field: *Element, submitter: ?*Element) error{OutOfMemory}!bool {
    if (!URL.isPotentiallyTrustworthy(frame.url)) return true;
    const form = Form.ownerOf(field) orelse return false;
    const button = submitter orelse form.getDefaultButton(frame);
    const action = blk: {
        if (button) |b| if (Form.isSubmitButton(b)) {
            if (b.getAttributeSafe(comptime .wrap("formaction"))) |fa| break :blk fa;
        };
        break :blk form.asElement().getAttributeInterned("action") orelse "";
    };
    if (action.len == 0) return false;
    const target = URL.resolve(arena, frame.base(), action, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return true,
    };
    return !URL.isPotentiallyTrustworthy(target);
}

/// Whether `control` would submit the same form as `field`. A control outside
/// it submits something else — a search box, a newsletter sign-up — however
/// it is labelled. Both outside any form is the single-field page that posts
/// with JavaScript, which is allowed.
pub fn sameForm(field: *Element, control: *Element) bool {
    return Form.ownerOf(field) == Form.ownerOf(control);
}

/// What the tool reports. `submitted` is what we did, `loggedIn` is whether
/// the page agreed afterwards.
pub const Outcome = struct {
    submitted: bool = false,
    loggedIn: bool = false,
    /// The fields we filled and the control we clicked, as selectors that
    /// resolve to them again — a recorded script replays these and asks
    /// nothing.
    usernameSelector: ?[]const u8 = null,
    passwordSelector: ?[]const u8 = null,
    submitSelector: ?[]const u8 = null,
    /// The control that submitted the username on an identifier-first page;
    /// null with `submitted` set means Enter did.
    nextSelector: ?[]const u8 = null,
    /// Set when the form had no control of its own and Enter submitted it.
    pressedEnter: bool = false,
    candidates: ?usize = null,
    /// The page as the verification found it, after the submit: still a
    /// sign-in wall, or an error page.
    loginWall: ?f64 = null,
    errorPage: ?f64 = null,
    /// Model calls this took, so the cost is visible in the result.
    calls: u8 = 0,
    reason: ?[]const u8 = null,
};

const LoginParams = struct {
    password: []const u8,
    username: ?[]const u8 = null,
    usernameSelector: ?[]const u8 = null,
    passwordSelector: ?[]const u8 = null,
    submitSelector: ?[]const u8 = null,
    nextSelector: ?[]const u8 = null,
    /// Report which fields would be used and type nothing, so the picks can
    /// be scored on a real page without sending credentials.
    decideOnly: bool = false,
};

/// Which element plays which part on the page as it stands, and where it is.
const Decided = union(enum) {
    ok: struct {
        page: *lp.Frame,
        picks: Picks,
        /// The identifier field, the password field and the control that
        /// submits them, as selectors resolved before anything is typed: a
        /// submit can navigate and free every node the picks point at.
        user: ?[]const u8 = null,
        password: ?[]const u8 = null,
        submit: ?[]const u8 = null,
        candidates: usize = 0,
    },
    failed: ToolResult,
};

/// Run again on the page an identifier-first submit returns, where the
/// password finally appears.
fn decideLogin(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    wanted: Wanted,
    outcome: *Outcome,
) ToolError!Decided {
    const page = try requireFrame(session);
    const candidates = choose.collect(arena, page.document.asNode(), page, registry) catch |err| return internalUnlessOom(err);
    if (candidates.len == 0) {
        return .{ .failed = try verdict(arena, outcome, "nothing on this page can be filled in") };
    }

    const asked = try questions(arena, candidates, wanted);
    var response = switch (try askPage(arena, session, registry, .{
        .tool = .login,
        .questions = asked,
        .node = page.document.asNode(),
        .state = .{ .link_urls = false, .ids = true },
    })) {
        .failed => |result| return .{ .failed = result },
        .ok => |ok| ok,
    };
    defer response.deinit();
    outcome.calls += 1;

    const chosen = picks(candidates, asked, response.value) catch |err| switch (err) {
        error.OutOfMemory => return ToolError.OutOfMemory,
        else => return .{ .failed = try unusableAnswer(arena, .login, err) },
    };

    return .{ .ok = .{
        .page = page,
        .picks = chosen,
        .user = if (chosen.user) |field| selectorFor(arena, page, field.element) else null,
        .password = if (chosen.password) |field| selectorFor(arena, page, field.element) else null,
        .submit = submitSelector(arena, page, chosen),
        .candidates = candidates.len,
    } };
}

/// The control that submits the sign-in form — null when Enter in the field is
/// the better act, because none was picked or the one picked sits outside the
/// field's own form and so submits something else, whatever it is labelled.
fn submitSelector(arena: std.mem.Allocator, page: *lp.Frame, chosen: Picks) ?[]const u8 {
    const control = chosen.submit orelse return null;
    const field = chosen.password orelse chosen.user orelse return null;
    if (!sameForm(field.element, control.element)) return null;
    return selectorFor(arena, page, control.element);
}

const plaintext_refusal = "the page or the URL its form posts to is not https; refusing to send credentials";

/// Not the model's decision to make, whatever it picked: a password goes into
/// an `input[type=password]` on a form that posts over TLS, or nowhere.
fn credentialRefusal(arena: std.mem.Allocator, page: *lp.Frame, chosen: Picks) error{OutOfMemory}!?[]const u8 {
    if (chosen.password) |field| {
        if (!isPasswordField(field.element)) {
            return "the field picked for the password is not an input[type=password]";
        }
    }
    if (chosen.user) |field| {
        if (isPasswordField(field.element)) {
            return "the field picked for the username is a password input";
        }
    }
    if (chosen.password orelse chosen.user) |field| {
        const submitter = if (chosen.submit) |control|
            (if (sameForm(field.element, control.element)) control.element else null)
        else
            null;
        if (try untrustedTarget(arena, page, field.element, submitter)) return plaintext_refusal;
    }
    return null;
}

pub fn exec(arena: std.mem.Allocator, session: *lp.Session, registry: *NodeRegistry, arguments: ?std.json.Value) ToolError!ToolResult {
    const args = try parseArgs(LoginParams, arena, arguments);
    var outcome: Outcome = .{};

    if (args.passwordSelector != null or args.usernameSelector != null) {
        return replayLogin(arena, session, registry, args, &outcome);
    }

    // Which field takes the identifier cannot matter when there is none to type.
    var decided = switch (try decideLogin(arena, session, registry, .{ .user = args.username != null }, &outcome)) {
        .failed => |result| return result,
        .ok => |ok| ok,
    };

    if (decided.picks.user == null and decided.picks.password == null) {
        return verdict(arena, &outcome, "no sign-in field on this page");
    }
    if (args.username != null and decided.picks.user == null) {
        return verdict(arena, &outcome, "could not tell which field takes the username");
    }
    outcome.candidates = decided.candidates;
    if (try credentialRefusal(arena, decided.page, decided.picks)) |reason| {
        return verdict(arena, &outcome, reason);
    }
    if (args.decideOnly) {
        outcome.usernameSelector = decided.user;
        outcome.passwordSelector = decided.password;
        outcome.submitSelector = decided.submit;
        return verdict(arena, &outcome, "decided only, nothing was typed or submitted");
    }
    if (decided.picks.password == null) {
        if (!decided.picks.multi_step) {
            return verdict(arena, &outcome, "no password field, and the page does not ask for one on a later step");
        }
        if (args.username == null) {
            return verdict(arena, &outcome, "the page asks for the username first, and none was given");
        }
    }

    if (args.username) |username| {
        const selector = decided.user orelse {
            return verdict(arena, &outcome, "no selector could be built for the username field");
        };
        if (try fillCredential(arena, session, registry, selector, username, .user, decided.submit)) |reason| {
            return verdict(arena, &outcome, reason);
        }
        outcome.usernameSelector = selector;
    }

    if (decided.picks.password == null) {
        if (try submitLogin(arena, session, registry, decided.submit, decided.user, &outcome)) |reason| {
            return verdict(arena, &outcome, reason);
        }
        outcome.nextSelector = outcome.submitSelector;
        outcome.submitSelector = null;
        outcome.pressedEnter = false;
        decided = switch (try decideLogin(arena, session, registry, .{ .user = false, .multi_step = false }, &outcome)) {
            .failed => |failed| return unverified(arena, &outcome, loginVerdict, failed, "submitted the username, but could not find the password field"),
            .ok => |ok| ok,
        };
        if (decided.picks.password == null) {
            return verdict(arena, &outcome, "submitted the username, but the next page shows no password field");
        }
        if (try credentialRefusal(arena, decided.page, decided.picks)) |reason| {
            return verdict(arena, &outcome, reason);
        }
    }

    const password_selector = decided.password orelse {
        return verdict(arena, &outcome, "no selector could be built for the password field");
    };
    if (try fillCredential(arena, session, registry, password_selector, args.password, .password, decided.submit)) |reason| {
        return verdict(arena, &outcome, reason);
    }
    outcome.passwordSelector = password_selector;

    if (try submitLogin(arena, session, registry, decided.submit, password_selector, &outcome)) |reason| {
        return verdict(arena, &outcome, reason);
    }
    return verifyLogin(arena, session, registry, &outcome);
}

/// Resolved by selector, so a replay repeats what we did, and checked on the
/// node it resolves to now rather than on the pick: filling the username
/// runs the page's input handlers, which can rebuild the form before the
/// password goes in. A null `value` checks and types nothing.
fn fillCredential(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    selector: []const u8,
    value: ?[]const u8,
    field: enum { user, password },
    submit: ?[]const u8,
) ToolError!?[]const u8 {
    const target = try resolveBySelector(session, selector);
    const element = target.node.is(Element) orelse return ToolError.InvalidParams;
    switch (field) {
        .user => if (isPasswordField(element)) return "the field for the username is a password input",
        .password => if (!isPasswordField(element)) return "the field for the password is not an input[type=password]",
    }
    if (try untrustedTarget(arena, target.page, element, try submitterAt(session, submit))) {
        return plaintext_refusal;
    }
    const text = value orelse return null;
    const scope = beginAction(session);
    lp.actions.fill(target.node, text, target.page) catch |err| return mapActionError(err);
    _ = try settleAction(session, registry, scope);
    return null;
}

/// Clicks `submit`, or presses Enter in `field` when there is no such control
/// on the page. Where the form posts is checked again first, on the form as
/// it stands after the fill.
fn submitLogin(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    submit: ?[]const u8,
    field: ?[]const u8,
    outcome: *Outcome,
) ToolError!?[]const u8 {
    const input = try resolveBySelector(session, field orelse return null);
    const input_element = input.node.is(Element) orelse return ToolError.InvalidParams;
    const control = try submitterAt(session, submit);
    if (try untrustedTarget(arena, input.page, input_element, control)) {
        return plaintext_refusal;
    }

    if (control) |element| {
        try clickAndSettle(session, registry, element.asNode(), input.page);
        outcome.submitSelector = submit;
        outcome.submitted = true;
        return null;
    }

    const scope = beginAction(session);
    lp.actions.press(input.node, "Enter", input.page) catch |err| return mapActionError(err);
    _ = try settleAction(session, registry, scope);
    try settle(session);
    outcome.pressedEnter = true;
    outcome.submitted = true;
    return null;
}

/// The page's own verdict on whether the sign-in worked. A failure is reported
/// and never retried: a second attempt on a wrong password is how accounts get
/// locked, and that call belongs to whoever owns the account.
fn verifyLogin(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    outcome: *Outcome,
) ToolError!ToolResult {
    var response = switch (try askPage(arena, session, registry, .{
        .tool = .login,
        .questions = try verifyQuestions(arena),
        .node = (try requireFrame(session)).document.asNode(),
        .state = .{ .link_urls = false },
    })) {
        .failed => |failed| return unverified(arena, outcome, loginVerdict, failed, "submitted, but could not check whether the sign-in worked"),
        .ok => |ok| ok,
    };
    defer response.deinit();
    outcome.calls += 1;

    outcome.loginWall = response.value.noul(wall_key);
    outcome.errorPage = response.value.noul(error_key);
    outcome.loggedIn = (outcome.loginWall orelse 1) < jev.gate and (outcome.errorPage orelse 1) < jev.gate;
    return loginVerdict(arena, outcome, if (outcome.loggedIn) null else "submitted, but the page still shows a sign-in form or an error");
}

fn loginVerdict(arena: std.mem.Allocator, outcome: *Outcome, reason: ?[]const u8) ToolError!ToolResult {
    var result = try verdict(arena, outcome, reason);
    if (outcome.passwordSelector != null or outcome.usernameSelector != null) {
        result.replay_args = try renderJson(arena, .{
            .usernameSelector = outcome.usernameSelector,
            .passwordSelector = outcome.passwordSelector,
            .submitSelector = outcome.submitSelector,
            .nextSelector = outcome.nextSelector,
        }, compact);
    }
    return result;
}

/// The recorded form: fill the fields a previous run named and submit, with no
/// model call and no verification — a replay repeats a decision, it does not
/// make one. With `decideOnly`, the fields are checked and nothing is typed.
fn replayLogin(
    arena: std.mem.Allocator,
    session: *lp.Session,
    registry: *NodeRegistry,
    args: LoginParams,
    outcome: *Outcome,
) ToolError!ToolResult {
    if (args.usernameSelector) |selector| {
        if (args.username == null and !args.decideOnly) {
            return verdict(arena, outcome, "usernameSelector was given without a username");
        }
        const value = if (args.decideOnly) null else args.username;
        if (try fillCredential(arena, session, registry, selector, value, .user, args.nextSelector orelse args.submitSelector)) |reason| {
            return verdict(arena, outcome, reason);
        }
        outcome.usernameSelector = selector;
    }
    if (args.passwordSelector) |selector| {
        // A recorded identifier-first login names both fields, and the
        // password's is not on this page yet: repeat the submit that raised it.
        if (!try onPage(session, selector) and outcome.usernameSelector != null) {
            if (args.decideOnly) {
                outcome.passwordSelector = selector;
                return verdict(arena, outcome, "decided only, nothing was typed or submitted; the password field is on a later step, so it was not checked");
            }
            if (try submitLogin(arena, session, registry, args.nextSelector, args.usernameSelector, outcome)) |reason| {
                return verdict(arena, outcome, reason);
            }
            outcome.nextSelector = outcome.submitSelector;
            outcome.submitSelector = null;
            outcome.pressedEnter = false;
        }
        const value = if (args.decideOnly) null else args.password;
        if (try fillCredential(arena, session, registry, selector, value, .password, args.submitSelector)) |reason| {
            return verdict(arena, outcome, reason);
        }
        outcome.passwordSelector = selector;
    }

    if (args.decideOnly) {
        outcome.submitSelector = args.submitSelector;
        outcome.nextSelector = args.nextSelector;
        return verdict(arena, outcome, "decided only, nothing was typed or submitted");
    }
    if (try submitLogin(arena, session, registry, args.submitSelector, args.passwordSelector orelse args.usernameSelector, outcome)) |reason| {
        return verdict(arena, outcome, reason);
    }
    return loginVerdict(arena, outcome, if (args.passwordSelector == null)
        "filled the username and submitted, without asking the model; no passwordSelector was given, so no password was typed"
    else
        "filled the fields given, without asking the model");
}

fn onPage(session: *lp.Session, selector: []const u8) ToolError!bool {
    _ = resolveBySelector(session, selector) catch |err| switch (err) {
        error.NodeNotFound => return false,
        else => return err,
    };
    return true;
}

/// The submit control, when it is on this page: its `formaction` is where the
/// credentials go.
fn submitterAt(session: *lp.Session, selector: ?[]const u8) ToolError!?*Element {
    const target = resolveBySelector(session, selector orelse return null) catch |err| switch (err) {
        error.NodeNotFound => return null,
        else => return err,
    };
    return target.node.is(Element);
}

const testing = @import("../../testing.zig");
const call = tools.call;

/// A frame whose document holds `html` inside one wrapper element, attached so
/// `<label for>` and form ownership both resolve.
fn testFrame(html: []const u8) !*Frame {
    const frame = try testing.createFrame();
    errdefer testing.test_session.closeAllPages();

    const doc = frame.window._document;
    const root = try doc.createElement("div", null, frame);
    _ = try doc.asNode().appendChild(root.asNode(), frame);
    try Frame.parse.htmlAsChildren(frame, root.asNode(), html);
    return frame;
}

test "browser.login: every part is asked over every element on the page" {
    defer testing.test_session.closeAllPages();
    const frame = try testFrame(
        \\<form action="/subscribe"><input name="email" placeholder="Your email">
        \\<button>Subscribe</button></form>
        \\<form action="/login" method="post">
        \\  <input name="user" placeholder="Email or username">
        \\  <input name="pw" type="password">
        \\  <button type="submit">Log in</button>
        \\  <a href="/reset">Forgot your password?</a>
        \\  <a href="/signup">Create an account</a>
        \\</form>
    );

    const arena = frame.call_arena;
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();
    const candidates = try choose.collect(arena, frame.document.asNode(), frame, &registry);

    try testing.expectEqual(7, candidates.len);

    const asked = try questions(arena, candidates, .{});
    try testing.expect(asked.has(user_key));
    try testing.expect(asked.has(password_key));
    try testing.expect(asked.has(submit_key));
    try testing.expect(asked.get(submit_key).?.choice.criteria.has(enter_key));
    // Nothing says a password field is on the page but the model's own answer.
    try testing.expect(asked.has(multi_step_key));
    try testing.expectEqual(candidates.len + 2, asked.get(submit_key).?.choice.criteria.count());
}

test "browser.login: nothing is asked about a username there is none to type" {
    defer testing.test_session.closeAllPages();
    const frame = try testFrame(
        \\<form action="/signin"><input name="id" placeholder="Email"><button>Next</button></form>
    );

    const arena = frame.call_arena;
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();
    const candidates = try choose.collect(arena, frame.document.asNode(), frame, &registry);

    const asked = try questions(arena, candidates, .{ .user = false, .multi_step = false });
    try testing.expect(!asked.has(user_key));
    try testing.expect(!asked.has(multi_step_key));
    try testing.expect(asked.has(password_key));
}

test "browser.login: a control outside the field's form submits something else" {
    defer testing.test_session.closeAllPages();
    const frame = try testFrame(
        \\<form id="f" action="/login"><input id="u" name="u"><button id="in">Sign in</button></form>
        \\<form id="g" action="/search"><button id="out">Go</button></form>
        \\<button id="loose">Sign in</button>
    );

    const doc = frame.window._document;
    const field = (doc.getElementById("u")).?;
    const inside = (doc.getElementById("in")).?;
    const outside = (doc.getElementById("out")).?;
    const loose = (doc.getElementById("loose")).?;

    try testing.expect(sameForm(field, inside));
    try testing.expect(!sameForm(field, outside));
    try testing.expect(!sameForm(field, loose));
}

test "browser.login: a credential goes only to https or loopback" {
    defer testing.test_session.closeAllPages();
    const frame = try testFrame(
        \\<form action="http://example.com/login"><input id="u" name="u"></form>
        \\<form action="/login"><input id="v" name="v"></form>
        \\<form action="/login"><input id="w" name="w"><button formaction="http://example.com/steal">Go</button></form>
        \\<input id="loose" name="loose">
    );
    const aa = testing.arena_allocator;

    const doc = frame.window._document;
    const plaintext = (doc.getElementById("u")).?;
    const relative = (doc.getElementById("v")).?;
    const overridden = (doc.getElementById("w")).?;
    const loose = (doc.getElementById("loose")).?;

    frame.url = "http://127.0.0.1:9582/account";
    // Loopback is as safe as https.
    try testing.expect(try untrustedTarget(aa, frame, plaintext, null));
    try testing.expect(!try untrustedTarget(aa, frame, relative, null));

    frame.url = "https://example.com/account";
    try testing.expect(try untrustedTarget(aa, frame, plaintext, null));
    try testing.expect(!try untrustedTarget(aa, frame, relative, null));
    // Enter clicks the default button, and its formaction wins over the form's.
    try testing.expect(try untrustedTarget(aa, frame, overridden, null));
    try testing.expect(!try untrustedTarget(aa, frame, loose, null));

    // A page that is itself plaintext, as a redirect can land on.
    frame.url = "http://example.com/account";
    try testing.expect(try untrustedTarget(aa, frame, relative, null));
    try testing.expect(try untrustedTarget(aa, frame, loose, null));
}

test "login: the recorded selectors are filled and submitted without the model" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2","usernameSelector":"#user","passwordSelector":"#pass","submitSelector":"#submit"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "without asking the model") != null);
    try std.testing.expectEqualStrings(
        "{\"usernameSelector\":\"#user\",\"passwordSelector\":\"#pass\",\"submitSelector\":\"#submit\"}",
        result.replay_args.?,
    );

    const status = try call(aa, page.session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#status"}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, status.text, "submitted") != null);

    // The identifier is on the page, the password is masked everywhere the
    // state is built — including the request a verification would send.
    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "ada") != null);
    try std.testing.expect(std.mem.find(u8, tree.text, "hunter2") == null);
    try std.testing.expect(std.mem.find(u8, tree.text, "*****") != null);
}

test "login: Jev picks the identifier, the password field and the submit control" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.start(aa);
    defer mock.stop();

    // decideOnly, so nothing is typed and the decoy newsletter form is the
    // only thing that could have been picked by mistake.
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2","decideOnly":true}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"usernameSelector\":\"#user\"") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"passwordSelector\":\"#pass\"") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitSelector\":\"#submit\"") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") == null);
}

test "login: the password waits for the step that asks for it" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_two_step.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.start(aa);
    defer mock.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"loggedIn\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"calls\":3") != null);
    try std.testing.expectEqualStrings(
        "{\"usernameSelector\":\"#user\",\"passwordSelector\":\"#pass\",\"submitSelector\":\"#signin-submit\"}",
        result.replay_args.?,
    );

    const status = try call(aa, page.session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#status"}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, status.text, "submitted") != null);
}

test "login: a later step that asks for the password in the clear is refused" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_two_step_cleartext.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.start(aa);
    defer mock.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, result.text, "input[type=password]") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"loggedIn\":false") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "hunter2") == null);
}

test "login: a recorded two-step login submits the identifier before the password" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_two_step.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2","usernameSelector":"#user","passwordSelector":"#pass","submitSelector":"#signin-submit","nextSelector":"#next"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "without asking the model") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"nextSelector\":\"#next\"") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitSelector\":\"#signin-submit\"") != null);

    const status = try call(aa, page.session, &registry, "markdown", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"selector":"#status"}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, status.text, "submitted") != null);
}

test "login: a verification that fails still reports that credentials went out" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.startFailingVerification(aa);
    defer mock.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "could not check whether the sign-in worked") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "HTTP 500") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":true") != null);
    try std.testing.expect(result.replay_args != null);
}

test "login: a recorded call with decideOnly checks the fields and types nothing" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2","usernameSelector":"#user","passwordSelector":"#pass","submitSelector":"#submit","decideOnly":true}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.find(u8, result.text, "decided only") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":false") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "ada") == null);

    const wrong = try call(aa, page.session, &registry, "login", try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"password":"hunter2","passwordSelector":"#user","decideOnly":true}
    , .{}), .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, wrong.text, "input[type=password]") != null);
}

test "login: the password field is checked again after the username went in" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_field_swap.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const mock = try testing.MockJev.start(aa);
    defer mock.stop();

    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"username":"ada","password":"hunter2"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, result.text, "input[type=password]") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":false") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "hunter2") == null);
}

test "login: a passwordSelector that is not a password field is refused" {
    var registry: NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("login_form.html", .{});
    defer page.close();

    const aa = testing.arena_allocator;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, aa,
        \\{"password":"hunter2","passwordSelector":"#user"}
    , .{});
    const result = try call(aa, page.session, &registry, "login", args, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, result.text, "input[type=password]") != null);
    try std.testing.expect(std.mem.find(u8, result.text, "\"submitted\":false") != null);

    const tree = try call(aa, page.session, &registry, "tree", null, .{ .source = .user });
    try std.testing.expect(std.mem.find(u8, tree.text, "hunter2") == null);
}
