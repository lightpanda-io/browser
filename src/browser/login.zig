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
const lp = @import("../lightpanda.zig");
const zenai = @import("zenai");

const choose = @import("choose.zig");
const interactive = @import("interactive.zig");
const URL = @import("URL.zig");
const Element = @import("webapi/Element.zig");
const Form = @import("webapi/element/html/Form.zig");
const Frame = lp.Frame;

const Questions = zenai.typesafe.Questions;
const QuestionEntry = zenai.typesafe.QuestionEntry;
const ChoiceEntry = zenai.typesafe.ChoiceEntry;

/// The question ids, which also key the answers.
pub const wall_key = @tagName(lp.jev.Preset.isLoginWall);
pub const error_key = @tagName(lp.jev.Preset.isErrorPage);
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
        out.multi_step = (response.noul(multi_step_key) orelse 0) >= lp.jev.gate;
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
    return lp.jev.presetQuestions(arena, &.{ .isLoginWall, .isErrorPage });
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
