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

//! Signing in to a site: rules decide what rules can decide, the model
//! decides the rest.
//!
//! A password field is `input[type=password]` and nothing else, and that is
//! also the only kind of field a password is ever typed into — so a page
//! cannot talk the credential somewhere else, whatever its text says. What
//! the model is for is the ambiguity rules cannot reach: which of several
//! text fields takes the identifier when there is no label to go by, and
//! which control signs in rather than registering, resetting the password or
//! handing the session to a third party.
//!
//! Every decision is asked before anything is filled. The semantic tree masks
//! `type=password` values (`Input.getRedactedValue`) but not a username typed
//! into a plain text field, so asking first is what keeps it out of the
//! request. The verification after the submit is the one call that sees the
//! page in its filled state, and only ever a username at that.

const std = @import("std");
const lp = @import("../lightpanda.zig");
const zenai = @import("zenai");

const choose = @import("choose.zig");
const interactive = @import("interactive.zig");
const DOMNode = @import("webapi/Node.zig");
const Element = @import("webapi/Element.zig");
const Form = @import("webapi/element/html/Form.zig");
const Frame = lp.Frame;

const Questions = zenai.typesafe.Questions;
const QuestionEntry = zenai.typesafe.QuestionEntry;
const ChoiceEntry = zenai.typesafe.ChoiceEntry;

/// The question ids, which also key the answers.
pub const wall_key = @tagName(lp.classify.Preset.isLoginWall);
pub const error_key = @tagName(lp.classify.Preset.isErrorPage);
pub const user_key = "userField";
pub const password_key = "passwordField";
pub const submit_key = "submit";
pub const multi_step_key = "isMultiStep";

/// The one submit option that is not an element.
pub const enter_key = "enter";
const enter_description = "Press Enter in the filled field instead; this form has no sign-in control of its own";

/// Identifier fields. A `search` input is a `searchbox`, not a `textbox`, so
/// the role filter already keeps a site's search box out.
pub const user_filter: choose.Filter = .{
    .roles = &.{"textbox"},
    .input_types = &.{ "text", "email", "tel" },
    .max = 12,
};

pub const password_filter: choose.Filter = .{
    .roles = &.{"textbox"},
    .input_types = &.{"password"},
    .max = 8,
};

/// Sign-in controls, and the ones next to them that must not be mistaken for
/// one. The keywords only decide what is worth offering; "create account" and
/// "forgot password" are offered precisely so the model can pass them over.
pub const submit_filter: choose.Filter = .{
    .roles = &.{ "button", "link" },
    .keywords = &.{
        "sign in",  "signin",  "log in",   "login",  "log on",
        "continue", "next",    "submit",   "enter",  "register",
        "sign up",  "create",  "forgot",   "reset",  "entrar",
        "iniciar",  "acceder", "conectar", "connex", "connecter",
        "anmelden", "einlogg", "accedi",   "inicia", "logga in",
        "kirjaudu", "zaloguj",
        "giriş",
    },
    .max = 16,
};

/// What the rules settled on their own. A question is only asked when more
/// than one candidate survives: a plain sign-in page therefore costs no model
/// call at all before the submit, and one after it to check the result.
pub const Plan = struct {
    user: choose.Set,
    password: choose.Set,
    submit: choose.Set,

    /// Every kind of candidate, off the page as it stands. Collected again
    /// after a step that changed the DOM: the old candidates point at nodes
    /// the navigation freed.
    pub fn collect(arena: std.mem.Allocator, root: *DOMNode, frame: *Frame) !Plan {
        const elements = try interactive.collectInteractiveElements(root, arena, frame);
        return .{
            .user = try choose.select(arena, elements, user_filter),
            .password = try choose.select(arena, elements, password_filter),
            .submit = try choose.select(arena, elements, submit_filter),
        };
    }

    /// The only candidate of its kind, which needs no question.
    pub fn only(set: choose.Set) ?choose.Candidate {
        return if (set.candidates.len == 1) set.candidates[0] else null;
    }
};

/// Everything ambiguous about the page, in one request — and nothing else, so
/// an unambiguous sign-in page asks no question at all and the model is paid
/// for once, after the submit, to say whether it worked.
///
/// Whether the page *is* a sign-in page is left to the rules: `isLoginWall`
/// asks whether a sign-in form stands in place of the content, which is false
/// on a home page whose corner holds a login box — a page we should still be
/// able to sign in to.
/// Which of the open questions are still worth their place in the request.
/// An answer that cannot change what we do is `false` here: the vendor
/// documents that detail unrelated to the decision distracts the model, so
/// dropping a question is a quality saving as much as a cost one.
pub const Wanted = struct {
    /// False when there is no username to type, or it was typed on an earlier
    /// step: which field takes it can no longer change anything.
    user: bool = true,
    /// False once we are on the page an identifier-first submit returned —
    /// we came looking for the password, so where it lives is not in doubt.
    multi_step: bool = true,
};

pub fn questions(arena: std.mem.Allocator, plan: Plan, wanted: Wanted) error{OutOfMemory}!Questions {
    var entries: std.ArrayList(QuestionEntry) = try .initCapacity(arena, 4);

    if (wanted.user and plan.user.candidates.len > 1) {
        entries.appendAssumeCapacity(.{
            .key = user_key,
            .value = try choose.question(
                arena,
                "Which field takes the username, email address or other identifier to sign in with?",
                plan.user.candidates,
                &.{},
            ),
        });
    }
    if (plan.password.candidates.len > 1) {
        entries.appendAssumeCapacity(.{
            .key = password_key,
            .value = try choose.question(
                arena,
                "Which field takes the password to sign in with? A field for choosing a new password, or for confirming one, is not it.",
                plan.password.candidates,
                &.{},
            ),
        });
    }
    if (plan.submit.candidates.len > 1) {
        const extra = [_]ChoiceEntry{.{ .key = enter_key, .value = .{ .text = enter_description } }};
        entries.appendAssumeCapacity(.{
            .key = submit_key,
            .value = try choose.question(
                arena,
                "Which control submits the sign-in form? Creating an account, recovering a password and signing in through another service are not it.",
                plan.submit.candidates,
                &extra,
            ),
        });
    }
    if (wanted.multi_step and plan.password.candidates.len == 0) {
        entries.appendAssumeCapacity(.{
            .key = multi_step_key,
            .value = .noulText("Does this page ask for the username or email first and the password on a later step?"),
        });
    }
    return .init(entries.items);
}

/// Which element plays which part. The rules' answer where they had one, the
/// model's where they did not.
pub const Picks = struct {
    user: ?choose.Candidate = null,
    password: ?choose.Candidate = null,
    submit: ?choose.Candidate = null,
    /// The password is on a later step, so the first submit is the username's.
    multi_step: bool = false,
};

/// What the rules alone settle: the only candidate of each kind, if there is
/// exactly one.
pub fn rulePicks(plan: Plan) Picks {
    return .{
        .user = Plan.only(plan.user),
        .password = Plan.only(plan.password),
        .submit = Plan.only(plan.submit),
    };
}

/// `rulePicks` with the model's answer filled in wherever a question was
/// asked. A question whose answer reads back as "none of these" leaves its
/// pick null, so the caller reports that instead of acting on a guess.
pub fn picks(
    arena: std.mem.Allocator,
    plan: Plan,
    asked: Questions,
    response: zenai.typesafe.types.AskResponse,
) choose.Error!Picks {
    var out = rulePicks(plan);
    if (asked.has(user_key)) {
        out.user = first(try choose.ranked(arena, plan.user.candidates, response, asked, user_key));
    }
    if (asked.has(password_key)) {
        out.password = first(try choose.ranked(arena, plan.password.candidates, response, asked, password_key));
    }
    if (asked.has(submit_key)) {
        // No candidate above "none of these" means the model chose `enter_key`
        // or nothing at all, and both come to the same act: Enter in the field.
        out.submit = first(try choose.ranked(arena, plan.submit.candidates, response, asked, submit_key));
    }
    if (asked.has(multi_step_key)) {
        out.multi_step = (response.noul(multi_step_key) orelse 0) >= lp.classify.gate;
    }
    return out;
}

fn first(order: []const choose.Scored) ?choose.Candidate {
    return if (order.len == 0) null else order[0].candidate;
}

/// The page after the submit: did the sign-in wall go, and did an error take
/// its place.
pub fn verifyQuestions(arena: std.mem.Allocator) error{OutOfMemory}!Questions {
    return lp.classify.presetQuestions(arena, &.{ .isLoginWall, .isErrorPage });
}

/// `input[type=password]` and nothing else. The one place a password is
/// allowed to go, checked again on a selector a caller handed us rather than
/// trusted because `password_filter` produced it.
pub fn isPasswordField(element: *Element) bool {
    const input = element.is(Element.Html.Input) orelse return false;
    return input._input_type == .password;
}

/// An https page whose form posts to a plaintext URL. A relative action
/// inherits the page's scheme, so only an absolute `http://` is a downgrade.
/// The model is not asked about this: the page's words are its own, the scheme
/// is not.
pub fn insecureAction(frame: *Frame, field: *Element) bool {
    if (!std.mem.startsWith(u8, frame.url, "https://")) return false;
    const form = Form.ownerOf(field) orelse return false;
    const action = form.asElement().getAttributeInterned("action") orelse return false;
    return std.ascii.startsWithIgnoreCase(action, "http://");
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
    /// Set when the form had no control of its own and Enter submitted it.
    pressedEnter: bool = false,
    /// The page as the verification found it, after the submit: still a
    /// sign-in wall, or an error page.
    loginWall: ?f64 = null,
    errorPage: ?f64 = null,
    /// Model calls this took, so the cost is visible in the result.
    calls: u8 = 0,
    /// Why nothing happened, when nothing did.
    reason: ?[]const u8 = null,
};

const testing = @import("../testing.zig");

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

test "browser.login: an unambiguous page asks nothing at all" {
    defer testing.test_session.closeAllPages();
    const frame = try testFrame(
        \\<form action="/login" method="post">
        \\  <label for="u">Username</label><input id="u" name="u">
        \\  <label for="p">Password</label><input id="p" name="p" type="password">
        \\  <button type="submit">Sign in</button>
        \\</form>
    );

    const arena = frame.call_arena;
    const plan = try Plan.collect(arena, frame.document.asNode(), frame);

    try testing.expectEqual(1, plan.user.candidates.len);
    try testing.expectEqual(1, plan.password.candidates.len);
    try testing.expectEqual(1, plan.submit.candidates.len);

    // Nothing to ask: the model is paid for once, after the submit.
    const asked = try questions(arena, plan, .{});
    try testing.expectEqual(0, asked.count());
}

test "browser.login: a page with a newsletter box asks which field is which" {
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
    const plan = try Plan.collect(arena, frame.document.asNode(), frame);

    try testing.expectEqual(2, plan.user.candidates.len);
    // The password field is still a rule: one input[type=password].
    try testing.expectEqual(1, plan.password.candidates.len);
    // Subscribe, Log in, Forgot, Create — the traps are offered so the model
    // can pass them over.
    try testing.expectEqual(4, plan.submit.candidates.len);

    const asked = try questions(arena, plan, .{});
    try testing.expect(asked.has(user_key));
    try testing.expect(asked.has(submit_key));
    try testing.expect(!asked.has(password_key));
    // A password field is on the page, so there is nothing multi-step about it.
    try testing.expect(!asked.has(multi_step_key));
    try testing.expect(asked.get(submit_key).?.choice.criteria.has(enter_key));
}

test "browser.login: an identifier-first page asks whether it is multi-step" {
    defer testing.test_session.closeAllPages();
    const frame = try testFrame(
        \\<form action="/signin"><input name="id" placeholder="Email"><button>Next</button></form>
    );

    const arena = frame.call_arena;
    const plan = try Plan.collect(arena, frame.document.asNode(), frame);
    try testing.expectEqual(0, plan.password.candidates.len);

    const asked = try questions(arena, plan, .{});
    try testing.expect(asked.has(multi_step_key));
    try testing.expect(asked.get(multi_step_key).? == .noul);
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

test "browser.login: an https page is not given a plaintext form action" {
    defer testing.test_session.closeAllPages();
    const frame = try testFrame(
        \\<form action="http://example.com/login"><input id="u" name="u"></form>
        \\<form action="/login"><input id="v" name="v"></form>
    );

    const doc = frame.window._document;
    const plaintext = (doc.getElementById("u")).?;
    const relative = (doc.getElementById("v")).?;

    // The test frame is not https, so nothing is a downgrade yet.
    try testing.expect(!insecureAction(frame, plaintext));

    frame.url = "https://example.com/account";
    try testing.expect(insecureAction(frame, plaintext));
    try testing.expect(!insecureAction(frame, relative));
}
