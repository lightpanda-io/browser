// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../../js/js.zig");
const Factory = @import("../../../Factory.zig");
const Frame = @import("../../../Frame.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Form = @import("Form.zig");
const Selection = @import("../../Selection.zig");
const Event = @import("../../Event.zig");
const ValidityState = @import("ValidityState.zig");
const popover = @import("../popover.zig");
const File = @import("../../File.zig");
const FileList = @import("../../FileList.zig");
const reflection = @import("../reflection.zig");
const text_entry = @import("../text_entry.zig");

const String = lp.String;

const Input = @This();

pub const Proto = HtmlElement;

pub const Type = enum {
    text,
    password,
    checkbox,
    radio,
    submit,
    reset,
    button,
    hidden,
    image,
    file,
    email,
    url,
    tel,
    search,
    number,
    range,
    date,
    time,
    @"datetime-local",
    month,
    week,
    color,

    pub fn fromString(str: []const u8) Type {
        // Longest type name is "datetime-local" at 14 chars
        if (str.len > 32) {
            return .text;
        }

        var buf: [32]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, str);
        return std.meta.stringToEnum(Type, lower) orelse .text;
    }

    pub fn toString(self: Type) []const u8 {
        return @tagName(self);
    }
};

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_default_value: ?[]const u8 = null,
_default_checked: bool = false,
_value: ?[]const u8 = null,
_checked: bool = false,
_checked_dirty: bool = false,
// Only user edits count for tooLong/tooShort; script and attribute values don't.
_user_edited: bool = false,
_input_type: Type = .text,
_indeterminate: bool = false,
_custom_validity: ?[]const u8 = null,
_validity: ?*ValidityState = null,
_popover_target: ?*Element = null,
_files: ?*FileList = null,

_selection_start: u32 = 0,
_selection_end: u32 = 0,
_selection_direction: Selection.SelectionDirection = .none,

_on_selectionchange: ?js.Function.Global = null,

pub fn getOnSelectionChange(self: *Input) ?js.Function.Global {
    return self._on_selectionchange;
}

pub fn setOnSelectionChange(self: *Input, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_selectionchange = try listen.persistWithThis(self);
    } else {
        self._on_selectionchange = null;
    }
}

pub fn asElement(self: *Input) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Input) *const Element {
    return Factory.protoOf(self).asElement();
}
pub fn asNode(self: *Input) *Node {
    return self.asElement().asNode();
}

pub fn getType(self: *const Input) []const u8 {
    return self._input_type.toString();
}

pub fn setType(self: *Input, typ: []const u8, frame: *Frame) !void {
    // Reflected verbatim; attributeChange derives the state from it
    try self.asElement().setAttributeSafe(comptime .wrap("type"), .wrap(typ), frame);
}

pub fn getValue(self: *const Input) []const u8 {
    if (self._input_type == .file) return "";
    return self._value orelse self._default_value orelse switch (self._input_type) {
        .checkbox, .radio => "on",
        else => "",
    };
}

// Spec-compliant `getValue` exposes the raw password to JS, FormData, CSS
// `:invalid` checks, etc. — but LLM-facing dumps (semantic tree, form
// detection, accessibility tree) must not echo what the agent just typed.
pub fn getRedactedValue(self: *const Input) []const u8 {
    if (self._input_type == .password) return "*****";
    return self.getValue();
}

pub fn setValue(self: *Input, value: []const u8, frame: *Frame) !void {
    // File inputs: setting to empty string is a no-op, anything else throws
    if (self._input_type == .file) {
        if (value.len == 0) return;
        return error.InvalidStateError;
    }
    // This should _not_ call setAttribute. It updates the current state only
    const sanitized = try self.sanitizeValue(false, value, frame);
    const changed = std.mem.eql(u8, self.getValue(), sanitized) == false;
    if (changed == false and self._value != null) {
        // _value itself isn't changing (not to be mixed up with setValue
        // being called with the same as the default value, which would need
        // to dupe)
        self._user_edited = false;
        return;
    }
    self._value = try frame.dupeString(sanitized);
    self._user_edited = false;

    // move the text entry cursor position to the end of the text control
    if (changed and self.selectionAvailable()) {
        self._selection_start = @intCast(sanitized.len);
        self._selection_end = @intCast(sanitized.len);
        self._selection_direction = .none;
    }
}

pub fn setUserValue(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.setValue(value, frame);
    self._user_edited = true;
}

pub fn getDefaultValue(self: *const Input) []const u8 {
    return self._default_value orelse "";
}

pub fn setDefaultValue(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("value"), .wrap(value), frame);
}

pub fn getChecked(self: *const Input) bool {
    return self._checked;
}

pub fn setChecked(self: *Input, checked: bool, frame: *Frame) !void {
    // If checking a radio button, uncheck others in the group first
    if (checked and self._input_type == .radio) {
        self.uncheckRadioGroup(frame);
    }
    // This should _not_ call setAttribute. It updates the current state only
    self._checked = checked;
    self._checked_dirty = true;
}

pub fn getIndeterminate(self: *const Input) bool {
    return self._indeterminate;
}

pub fn setIndeterminate(self: *Input, value: bool) !void {
    self._indeterminate = value;
}

pub fn getDefaultChecked(self: *const Input) bool {
    return self._default_checked;
}

pub fn setDefaultChecked(self: *Input, checked: bool, frame: *Frame) !void {
    if (checked) {
        try self.asElement().setAttributeSafe(comptime .wrap("checked"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("checked"), frame);
    }
}

pub fn getWillValidate(self: *const Input) bool {
    // An input element is barred from constraint validation if:
    // - type is hidden, button, or reset
    // - element is disabled
    // - element has a datalist ancestor
    return switch (self._input_type) {
        .hidden, .button, .reset => false,
        else => !self.asConstElement().isDisabled() and !self.hasDatalistAncestor(),
    };
}

fn hasDatalistAncestor(self: *const Input) bool {
    var node = self.asConstElement().asConstNode().parentElement();
    while (node) |parent| {
        if (parent.is(HtmlElement.DataList) != null) return true;
        node = parent.asConstNode().parentElement();
    }
    return false;
}

// Constraint validation API
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

pub fn getValidity(self: *Input, frame: *Frame) !*ValidityState {
    if (self._validity) |v| return v;
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

/// Lazily allocates this input's FileList and registers it with the frame so
/// the refcounted File objects it holds are released at frame teardown.
fn ensureFileList(self: *Input, frame: *Frame) !*FileList {
    if (self._files) |fl| {
        return fl;
    }

    const fl = try frame._factory.create(FileList{});
    try frame.trackFileList(fl);
    self._files = fl;
    return fl;
}

/// Returns the FileList for a `type="file"` input (lazily allocated, identity preserved).
/// Non-file inputs return null per HTMLInputElement IDL.
pub fn getFiles(self: *Input, frame: *Frame) !?*FileList {
    if (self._input_type != .file) {
        return null;
    }
    return try self.ensureFileList(frame);
}

/// Simulates the user selecting files: replaces the file list and fires
/// `input` + `change`. Used by CDP `DOM.setFileInputFiles`.
pub fn selectFiles(self: *Input, files: []const *File, frame: *Frame) !void {
    try self.replaceFiles(files, frame);

    // A file input fires `input` then `change`, both as plain bubbling Events
    // (not InputEvents — `inputType`/`data` only apply to editable text inputs).
    const input_evt = try Event.initTrusted(comptime .wrap("input"), .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), input_evt);
    const change_evt = try Event.initTrusted(comptime .wrap("change"), .{ .bubbles = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), change_evt);
}

/// The FileList holds a reference on each File (whose backing arena is reference
/// counted via its Blob proto), so we acquire on the incoming files and release
/// the outgoing ones; the frame releases whatever remains at teardown.
fn replaceFiles(self: *Input, files: []const *File, frame: *Frame) !void {
    if (self._input_type != .file) {
        return error.InvalidStateError;
    }

    const fl = try self.ensureFileList(frame);
    const dupe = try frame.arena.dupe(*File, files);

    for (dupe) |file| {
        file._proto.acquireRef();
    }

    for (fl._files) |old| {
        old._proto.releaseRef(frame._page);
    }

    fl._files = dupe;
}

/// The `files` IDL setter. Unlike a user picking files (selectFiles), an
/// assignment fires no input/change event.
pub fn setFiles(self: *Input, list_: ?*FileList, frame: *Frame) !void {
    if (self._input_type != .file) {
        return;
    }
    const list = list_ orelse return;
    if (self._files == list) {
        return;
    }
    return self.replaceFiles(list._files, frame);
}

/// JS-binding wrapper for the `value` getter: for type=file, return the spec
/// "C:\\fakepath\\<name>" string; otherwise delegate to plain getValue().
pub fn getValueForJS(self: *const Input, frame: *Frame) ![]const u8 {
    if (self._input_type != .file) {
        return self.getValue();
    }

    const fl = self._files orelse return "";
    if (fl._files.len == 0) {
        return "";
    }
    return try std.fmt.allocPrint(frame.local_arena, "C:\\fakepath\\{s}", .{fl._files[0]._name});
}

pub fn getValidationMessage(self: *Input, frame: *Frame) []const u8 {
    if (!self.getWillValidate()) return "";
    if (self._custom_validity) |msg| return msg;
    if (self.suffersValueMissing(frame)) return "Please fill out this field.";
    if (self.suffersTypeMismatch()) return switch (self._input_type) {
        .email => "Please enter an email address.",
        .url => "Please enter a URL.",
        else => "Please enter a valid value.",
    };
    if (self.suffersPatternMismatch(frame)) return "Please match the requested format.";
    if (self.suffersTooLong()) return "Please shorten this text.";
    if (self.suffersTooShort()) return "Please lengthen this text.";
    if (self.suffersRangeUnderflow()) return "Value is too small.";
    if (self.suffersRangeOverflow()) return "Value is too large.";
    return "";
}

pub fn checkValidity(self: *Input, frame: *Frame) !bool {
    if (!self.getWillValidate()) return true;
    const v = ValidityState{ ._owner = self.asElement() };
    if (v.getValid(frame)) return true;

    const event = try Event.initTrusted(comptime .wrap("invalid"), .{ .cancelable = true }, frame._page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
    return false;
}

pub fn reportValidity(self: *Input, frame: *Frame) !bool {
    // Headless: no UI to draw, so reportValidity matches checkValidity exactly.
    return self.checkValidity(frame);
}

pub fn setCustomValidity(self: *Input, message: []const u8, frame: *Frame) !void {
    if (message.len == 0) {
        self._custom_validity = null;
    } else {
        self._custom_validity = try frame.dupeString(message);
    }
}

pub fn hasCustomValidity(self: *const Input) bool {
    return self._custom_validity != null;
}

pub fn suffersValueMissing(self: *Input, frame: *Frame) bool {
    if (!self.getWillValidate()) return false;
    if (!self.getRequired()) return false;
    return switch (self._input_type) {
        .checkbox => !self._checked,
        .radio => !self.radioGroupHasChecked(frame),
        .file => if (self._files) |fl| fl._files.len == 0 else true,
        .text, .password, .email, .url, .tel, .search, .number, .date, .time, .@"datetime-local", .month, .week, .color => blk: {
            const v = self._value orelse self._default_value orelse "";
            break :blk v.len == 0;
        },
        // submit/reset/button/hidden/image/range never participate in valueMissing.
        .submit, .reset, .button, .hidden, .image, .range => false,
    };
}

pub fn suffersTypeMismatch(self: *const Input) bool {
    const value = self._value orelse return false;
    if (value.len == 0) return false;
    return switch (self._input_type) {
        .email => !isValidEmail(value),
        .url => !isValidAbsoluteURL(value),
        else => false,
    };
}

pub fn suffersPatternMismatch(self: *const Input, frame: *Frame) bool {
    if (!self.getWillValidate()) return false;
    // Per HTML §4.10.5.3.5, pattern only applies to text-like input types.
    switch (self._input_type) {
        .text, .search, .url, .tel, .email, .password => {},
        else => return false,
    }
    const value = self._value orelse return false;
    if (value.len == 0) return false;
    // An empty pattern is still a pattern: ^(?:)$ matches only "".
    const pattern = self.asConstElement().getAttributeSafe(comptime .wrap("pattern")) orelse return false;

    // Per HTML spec, anchor the pattern with ^(?:...)$ and compile under the
    // "v" (Unicode sets) flag. An invalid pattern is ignored — V8 throws and
    // we treat that as "no mismatch". TryCatch absorbs the exception so it
    // doesn't linger in the isolate.
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const wrapped = std.fmt.allocPrint(frame.call_arena, "^(?:{s})$", .{pattern}) catch return false;
    const re = js.RegExp.init(&ls.local, wrapped, js.RegExp.Flag.unicode_sets) catch return false;
    const matched = re.match(value) catch return false;

    return !matched;
}

pub fn suffersTooLong(self: *const Input) bool {
    if (!self._user_edited) return false;
    const value = self._value orelse return false;
    const max = self.getMaxLength();
    if (max < 0) return false;
    return codepointCount(value) > @as(usize, @intCast(max));
}

pub fn suffersTooShort(self: *const Input) bool {
    if (!self._user_edited) return false;
    const value = self._value orelse return false;
    if (value.len == 0) return false;
    const min = self.getMinLength();
    if (min < 0) return false;
    return codepointCount(value) < @as(usize, @intCast(min));
}

pub fn suffersRangeUnderflow(self: *const Input) bool {
    return numericRangeBreach(self, .underflow);
}

pub fn suffersRangeOverflow(self: *const Input) bool {
    return numericRangeBreach(self, .overflow);
}

fn numericRangeBreach(self: *const Input, comptime kind: enum { underflow, overflow }) bool {
    const typ = self._input_type;
    if (!hasNumericValue(typ)) return false;
    const value = valueToNumber(typ, self.getValue()) orelse return false;
    const bound = valueToNumber(typ, switch (kind) {
        .underflow => self.getMin(),
        .overflow => self.getMax(),
    }) orelse return false;
    return switch (kind) {
        .underflow => value < bound,
        .overflow => value > bound,
    };
}

fn radioGroupHasChecked(self: *Input, frame: *Frame) bool {
    if (self._checked) return true;
    var iter = self.radioGroupIterator() orelse return false;
    const my_form = self.getForm(frame);
    while (iter.next()) |other| {
        if (other == self) continue;
        if (!other._checked) continue;
        if (sameFormOwner(my_form, other, frame)) return true;
    }
    return false;
}

const TreeWalker = @import("../../TreeWalker.zig");

const RadioGroupIterator = struct {
    walker: TreeWalker.Full,
    name: []const u8,

    fn next(self: *@This()) ?*Input {
        while (self.walker.next()) |node| {
            const other_element = node.is(Element) orelse continue;
            const other_input = other_element.is(Input) orelse continue;
            if (other_input._input_type != .radio) continue;
            const other_name = other_element.getAttributeSafe(comptime .wrap("name")) orelse continue;
            if (!std.mem.eql(u8, self.name, other_name)) continue;
            return other_input;
        }
        return null;
    }
};

/// Walk same-named radio inputs in `self`'s tree. Returns null if the input
/// has no `name` (or empty `name`) — such radios don't participate in a
/// group. The `TreeWalker` only inspects nodes; the `@constCast` is safe
/// because nothing in the iteration mutates the tree.
fn radioGroupIterator(self: *const Input) ?RadioGroupIterator {
    const element = self.asConstElement();
    const name = element.getAttributeSafe(comptime .wrap("name")) orelse return null;
    if (name.len == 0) return null;
    const root = @constCast(element.asConstNode()).getRootNode(.{});
    return .{
        .walker = TreeWalker.Full.init(root, .{}),
        .name = name,
    };
}

fn sameFormOwner(self_form: ?*Form, other: *Input, frame: *Frame) bool {
    const other_form = other.getForm(frame);

    // Check if same form context
    if (self_form == null and other_form == null) {
        return true;
    }

    if (self_form) |mf| {
        if (other_form) |of| {
            if (mf == of) {
                return true;
            }
        }
    }

    return false;
}

/// Liberal email validation: ASCII local part + "@" + dotted ASCII host. Mirrors
/// the WHATWG "valid e-mail address" production loosely — sufficient for most
/// constraint-validation tests; HTML browsers themselves are permissive here.
fn isValidEmail(value: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, value, '@') orelse return false;
    if (at == 0 or at == value.len - 1) return false;
    const local = value[0..at];
    const host = value[at + 1 ..];
    for (local) |c| if (!isEmailLocalChar(c)) return false;
    if (std.mem.indexOfScalar(u8, host, '.') == null) return false;
    for (host) |c| if (!isEmailHostChar(c)) return false;
    if (host[0] == '.' or host[host.len - 1] == '.') return false;
    return true;
}

fn isEmailLocalChar(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return switch (c) {
        '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
        else => false,
    };
}

fn isEmailHostChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.';
}

/// Absolute URL check per the WHATWG URL parser: must include a scheme followed
/// by "://" and a non-empty authority. Relative URLs are typeMismatches per spec.
fn isValidAbsoluteURL(value: []const u8) bool {
    const scheme_end = std.mem.indexOfScalar(u8, value, ':') orelse return false;
    if (scheme_end == 0) return false;
    if (!std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..scheme_end]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    const rest = value[scheme_end + 1 ..];
    if (!std.mem.startsWith(u8, rest, "//")) return false;
    return rest.len > 2;
}

fn codepointCount(value: []const u8) usize {
    return std.unicode.utf8CountCodepoints(value) catch value.len;
}

pub fn getDisabled(self: *const Input) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("disabled")) != null;
}

pub fn setDisabled(self: *Input, disabled: bool, frame: *Frame) !void {
    if (disabled) {
        try self.asElement().setAttributeSafe(comptime .wrap("disabled"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("disabled"), frame);
    }
}

pub fn getMaxLength(self: *const Input) i32 {
    return reflection.getLimitedLong(self.asConstElement(), comptime .wrap("maxlength"));
}

pub fn getMinLength(self: *const Input) i32 {
    return reflection.getLimitedLong(self.asConstElement(), comptime .wrap("minlength"));
}

pub fn getSrc(self: *const Input, frame: *Frame) ![]const u8 {
    const src = self.asConstElement().getAttributeSafe(comptime .wrap("src")) orelse return "";
    return self.asConstElement().asConstNode().resolveURLReflect(src, frame, .{});
}

pub fn setSrc(self: *Input, src: []const u8, frame: *Frame) !void {
    const trimmed = std.mem.trim(u8, src, &std.ascii.whitespace);
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(trimmed), frame);
}

const entry = text_entry.TextEntry(Input);

pub const select = entry.select;
pub const innerInsert = entry.innerInsert;
pub const innerDelete = entry.innerDelete;
pub const moveCaret = entry.moveCaret;
pub const CaretMove = entry.CaretMove;
pub const getSelectionDirection = entry.getSelectionDirection;
pub const setSelectionStart = entry.setSelectionStart;
pub const setSelectionEnd = entry.setSelectionEnd;
pub const setSelectionRange = entry.setSelectionRange;

pub fn selectionAvailable(self: *const Input) bool {
    switch (self._input_type) {
        .text, .search, .url, .tel, .password => return true,
        else => return false,
    }
}

// Nullable here, unlike <textarea>'s, which is why these two aren't shared.
pub fn getSelectionStart(self: *const Input) !?u32 {
    if (!self.selectionAvailable()) return null;
    return self._selection_start;
}

pub fn getSelectionEnd(self: *const Input) !?u32 {
    if (!self.selectionAvailable()) return null;
    return self._selection_end;
}

pub fn getLabels(self: *Input, frame: *Frame) !js.Array {
    if (self._input_type == .hidden) {
        return frame.js.local.?.newArray(0);
    }
    return @import("Label.zig").getControlLabels(self.asElement(), frame);
}

pub fn getList(self: *Input, frame: *Frame) ?*HtmlElement.DataList {
    switch (self._input_type) {
        .hidden, .password, .checkbox, .radio, .file, .submit, .image, .reset, .button => return null,
        else => {},
    }

    const element = self.asElement();
    const list_id = element.getAttributeSafe(comptime .wrap("list")) orelse return null;

    // list= resolves in the input's own tree (shadow root or document).
    const target = frame.getElementByIdFromNode(element.asNode(), list_id) orelse return null;
    return target.is(HtmlElement.DataList);
}

pub fn getForm(self: *Input, frame: *Frame) ?*Form {
    const element = self.asElement();

    // If form attribute exists, ONLY use that (even if it references nothing)
    if (element.getAttributeSafe(comptime .wrap("form"))) |form_id| {
        // form= resolves in the control's own tree (shadow root or document),
        // not the calling realm's. @constCast: getElementByIdFromNode wants a
        // mutable *Node but doesn't mutate it (same idiom as radioGroupIterator);
        // keeping getForm const avoids a wide validity-path const cascade.
        if (frame.getElementByIdFromNode(element.asNode(), form_id)) |form_element| {
            return form_element.is(Form);
        }
        // form attribute present but invalid - no form owner
        return null;
    }

    // No form attribute - traverse ancestors looking for a <form>
    var node = element.asConstNode()._parent;
    while (node) |n| {
        if (n.is(Element.Html.Form)) |form| {
            return form;
        }
        node = n._parent;
    }

    return null;
}

// Form submission attribute overrides
// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#form-submission-0
// Mirrors Button's overrides — same spec semantics.

pub fn getFormAction(self: *Input, frame: *Frame) ![]const u8 {
    const element = self.asElement();
    const owner_url = element.ownerFrame(frame).url;
    const action = element.getAttributeSafe(comptime .wrap("formaction")) orelse return owner_url;
    if (action.len == 0) {
        return owner_url;
    }
    return element.asNode().resolveURLReflect(action, frame, .{});
}

pub fn setFormAction(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formaction"), .wrap(value), frame);
}

pub fn getFormEnctype(self: *const Input) []const u8 {
    return Form.normalizeEnctype(self.asConstElement().getAttributeSafe(comptime .wrap("formenctype")), "");
}

pub fn setFormEnctype(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formenctype"), .wrap(value), frame);
}

pub fn getFormMethod(self: *const Input) []const u8 {
    return Form.normalizeMethod(self.asConstElement().getAttributeSafe(comptime .wrap("formmethod")), "");
}

pub fn setFormMethod(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("formmethod"), .wrap(value), frame);
}

pub fn getFormNoValidate(self: *const Input) bool {
    return self.asConstElement().getAttributeSafe(.wrap("formnovalidate")) != null;
}

pub fn setFormNoValidate(self: *Input, value: bool, frame: *Frame) !void {
    if (value) {
        try self.asElement().setAttributeSafe(.wrap("formnovalidate"), .wrap(""), frame);
    } else {
        try self.asElement().removeAttribute(.wrap("formnovalidate"), frame);
    }
}

/// Sanitize the value according to the current input type
fn sanitizeValue(self: *Input, comptime dupe: bool, value: []const u8, frame: *Frame) ![]const u8 {
    switch (self._input_type) {
        .text, .search, .tel, .password, .url, .email => {
            const sanitized = blk: {
                const first = std.mem.indexOfAny(u8, value, "\r\n") orelse {
                    break :blk if (comptime dupe) try frame.dupeString(value) else value;
                };

                var result = try frame.arena.alloc(u8, value.len);
                @memcpy(result[0..first], value[0..first]);

                var i: usize = first;
                for (value[first + 1 ..]) |c| {
                    if (c != '\r' and c != '\n') {
                        result[i] = c;
                        i += 1;
                    }
                }
                break :blk result[0..i];
            };

            return switch (self._input_type) {
                .url, .email => std.mem.trim(u8, sanitized, &std.ascii.whitespace),
                else => sanitized,
            };
        },
        .date => return if (isValidDate(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .month => return if (isValidMonth(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .week => return if (isValidWeek(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .time => return if (isValidTime(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .@"datetime-local" => return try sanitizeDatetimeLocal(dupe, value, frame.arena),
        .number => return if (isValidFloatingPoint(value)) if (comptime dupe) try frame.dupeString(value) else value else "",
        .range => {
            const value_attr = self.asConstElement().getAttributeSafe(comptime .wrap("value")) orelse "";
            return try sanitizeRange(dupe, value, self.getMin(), self.getMax(), self.getStep(), value_attr, frame);
        },
        .color => {
            if (value.len == 7 and value[0] == '#') {
                var needs_lower = false;
                for (value[1..]) |c| {
                    if (!std.ascii.isHex(c)) {
                        return "#000000";
                    }
                    if (c >= 'A' and c <= 'F') {
                        needs_lower = true;
                    }
                }
                if (!needs_lower) {
                    return if (comptime dupe) try frame.dupeString(value) else value;
                }

                // Normalize to lowercase per spec
                const result = try frame.arena.alloc(u8, 7);
                result[0] = '#';
                for (value[1..], 1..) |c, j| {
                    result[j] = std.ascii.toLower(c);
                }
                return result;
            }
            return "#000000";
        },
        .file => return "", // File: always empty
        .checkbox, .radio, .submit, .image, .reset, .button, .hidden => return if (comptime dupe) try frame.dupeString(value) else value, // no sanitization
    }
}

const ms_per_day: f64 = 86_400_000;
// ECMAScript time value range; beyond it Date is invalid.
const max_time_value: f64 = 8.64e15;

fn hasNumericValue(typ: Type) bool {
    return switch (typ) {
        .number, .range, .date, .month, .week, .time, .@"datetime-local" => true,
        else => false,
    };
}

pub fn getValueAsNumber(self: *const Input) f64 {
    return valueToNumber(self._input_type, self.getValue()) orelse std.math.nan(f64);
}

pub fn setValueAsNumber(self: *Input, number: f64, frame: *Frame) !void {
    if (!hasNumericValue(self._input_type)) return error.InvalidStateError;
    if (std.math.isInf(number)) return error.TypeError;
    var buf: [64]u8 = undefined;
    const text = numberToValue(self._input_type, number, &buf) orelse "";
    return self.setValue(text, frame);
}

pub fn getValueAsDate(self: *const Input, exec: *const js.Execution) !?js.Value {
    const ms = switch (self._input_type) {
        .date, .week, .time => valueToNumber(self._input_type, self.getValue()),
        .month => if (valueToNumber(.month, self.getValue())) |months| monthsToMs(months) else null,
        else => null,
    } orelse return null;
    return try exec.js.local.?.newDate(ms);
}

pub fn setValueAsDate(self: *Input, value: js.Value, frame: *Frame) !void {
    switch (self._input_type) {
        .date, .month, .week, .time => {},
        else => return error.InvalidStateError,
    }
    if (value.isNull()) return self.setValue("", frame);
    if (!value.isDate()) return error.TypeError;
    const ms = value.dateValue();
    const number = if (self._input_type == .month and !std.math.isNan(ms)) msToMonths(ms) else ms;
    return self.setValueAsNumber(number, frame);
}

pub fn stepUp(self: *Input, n_: ?i32, frame: *Frame) !void {
    return self.stepBy(n_ orelse 1, frame);
}

pub fn stepDown(self: *Input, n_: ?i32, frame: *Frame) !void {
    return self.stepBy(-(n_ orelse 1), frame);
}

fn stepBy(self: *Input, n: i32, frame: *Frame) !void {
    const typ = self._input_type;
    if (!hasNumericValue(typ)) return error.InvalidStateError;
    const step = self.allowedValueStep() orelse return error.InvalidStateError;

    // A range with no value sits at its sanitized default, not at 0.
    const current = try self.sanitizeValue(false, self.getValue(), frame);
    const before = valueToNumber(typ, current) orelse 0;
    if (n == 0) return;
    const base = self.stepBase();
    const rungs = (before - base) / step;
    const steps: f64 = @floatFromInt(n);
    var value = if (@abs(rungs - @round(rungs)) > 1e-9)
        // Off the ladder: the snap to the next rung counts as the first step
        // (what browsers do; the spec text ignores n here).
        base + (if (n < 0) @floor(rungs) + steps + 1 else @ceil(rungs) + steps - 1) * step
    else
        before + steps * step;
    if (valueToNumber(typ, self.getMin())) |min| {
        if (value < min) value = base + @ceil((min - base) / step - 1e-9) * step;
    }
    if (valueToNumber(typ, self.getMax())) |max| {
        if (value > max) value = base + @floor((max - base) / step + 1e-9) * step;
    }
    // Clamping never moves against the direction of travel.
    if ((n < 0 and value > before) or (n > 0 and value < before)) return;
    return self.setValueAsNumber(value, frame);
}

/// HTML "step base": min, else the value content attribute, else the type's default.
fn stepBase(self: *const Input) f64 {
    const typ = self._input_type;
    if (valueToNumber(typ, self.getMin())) |min| return min;
    if (valueToNumber(typ, self.asConstElement().getAttributeSafe(comptime .wrap("value")) orelse "")) |v| return v;
    return if (typ == .week) -259_200_000 else 0;
}

/// The step in value-as-number units; null for step="any".
fn allowedValueStep(self: *const Input) ?f64 {
    const typ = self._input_type;
    const attr = self.getStep();
    if (std.ascii.eqlIgnoreCase(attr, "any")) return null;
    const default: f64 = switch (typ) {
        .time, .@"datetime-local" => 60,
        else => 1,
    };
    const scale: f64 = switch (typ) {
        .date => ms_per_day,
        .week => 7 * ms_per_day,
        .time, .@"datetime-local" => 1000,
        else => 1,
    };
    const parsed = if (isValidFloatingPoint(attr)) std.fmt.parseFloat(f64, attr) catch default else default;
    return (if (parsed > 0) parsed else default) * scale;
}

/// HTML "value as number": floats for number/range; for the date types,
/// milliseconds (months for type=month) since the epoch or midnight.
fn valueToNumber(typ: Type, value: []const u8) ?f64 {
    if (value.len == 0) return null;
    switch (typ) {
        .number, .range => return if (isValidFloatingPoint(value)) std.fmt.parseFloat(f64, value) catch null else null,
        .date => {
            if (!isValidDate(value)) return null;
            return dateToDays(value) * ms_per_day;
        },
        .month => {
            if (!isValidMonth(value)) return null;
            const year: i64 = parseAllDigits(value[0 .. value.len - 3]).?;
            const month: i64 = parseAllDigits(value[value.len - 2 ..]).?;
            return @floatFromInt((year - 1970) * 12 + month - 1);
        },
        .week => {
            if (!isValidWeek(value)) return null;
            const year: i64 = parseAllDigits(value[0 .. value.len - 4]).?;
            const week: i64 = parseAllDigits(value[value.len - 2 ..]).?;
            return @as(f64, @floatFromInt(isoWeekMonday(year, week))) * ms_per_day;
        },
        .time => {
            if (!isValidTime(value)) return null;
            return timeToMs(value);
        },
        .@"datetime-local" => {
            const sep = std.mem.indexOfAny(u8, value, "T ") orelse return null;
            const date = value[0..sep];
            const time = value[sep + 1 ..];
            if (!isValidDate(date) or !isValidTime(time)) return null;
            return dateToDays(date) * ms_per_day + timeToMs(time);
        },
        else => return null,
    }
}

fn numberToValue(typ: Type, number: f64, buf: []u8) ?[]const u8 {
    if (std.math.isNan(number) or @abs(number) > max_time_value) return null;
    switch (typ) {
        .number, .range => return std.fmt.bufPrint(buf, "{d}", .{number}) catch null,
        .date => {
            const days: i64 = @floor(number / ms_per_day);
            return formatDate(civilFromDays(days), buf);
        },
        .month => {
            const months: i64 = @floor(number);
            const year = 1970 + @divFloor(months, 12);
            if (year < 1) return null;
            return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}", .{ @as(u64, @intCast(year)), @as(u64, @intCast(@mod(months, 12) + 1)) }) catch null;
        },
        .week => {
            const days: i64 = @floor(number / ms_per_day);
            // The ISO week-year is the year of the week's Thursday.
            const thursday = days - @mod(days + 3, 7) + 3;
            const year = civilFromDays(thursday).year;
            if (year < 1) return null;
            const week = @divFloor(thursday - isoWeekMonday(year, 1), 7) + 1;
            return std.fmt.bufPrint(buf, "{d:0>4}-W{d:0>2}", .{ @as(u64, @intCast(year)), @as(u64, @intCast(week)) }) catch null;
        },
        .time => return formatTime(@mod(number, ms_per_day), buf),
        .@"datetime-local" => {
            const days: i64 = @floor(number / ms_per_day);
            const date = formatDate(civilFromDays(days), buf) orelse return null;
            buf[date.len] = 'T';
            const time = formatTime(number - @as(f64, @floatFromInt(days)) * ms_per_day, buf[date.len + 1 ..]) orelse return null;
            return buf[0 .. date.len + 1 + time.len];
        },
        else => return null,
    }
}

fn monthsToMs(months: f64) f64 {
    const m: i64 = @floor(months);
    return daysFromCivil(1970 + @divFloor(m, 12), @mod(m, 12) + 1, 1) * ms_per_day;
}

fn msToMonths(ms: f64) f64 {
    const days: i64 = @floor(ms / ms_per_day);
    const civil = civilFromDays(days);
    return @floatFromInt((civil.year - 1970) * 12 + civil.month - 1);
}

/// Days since 1970-01-01 of a valid date string (any year length).
fn dateToDays(value: []const u8) f64 {
    const year: i64 = parseAllDigits(value[0 .. value.len - 6]).?;
    const month: i64 = parseAllDigits(value[value.len - 5 .. value.len - 3]).?;
    const day: i64 = parseAllDigits(value[value.len - 2 ..]).?;
    return daysFromCivil(year, month, day);
}

/// Milliseconds since midnight of a valid time string.
fn timeToMs(value: []const u8) f64 {
    var ms: f64 = @floatFromInt(parseAllDigits(value[0..2]).? * 3_600_000 + parseAllDigits(value[3..5]).? * 60_000);
    if (value.len >= 8) ms += @floatFromInt(parseAllDigits(value[6..8]).? * 1000);
    if (value.len > 9) {
        var frac: u32 = parseAllDigits(value[9..]).?;
        var digits = value.len - 9;
        while (digits < 3) : (digits += 1) frac *= 10;
        ms += @floatFromInt(frac);
    }
    return ms;
}

const Civil = struct { year: i64, month: i64, day: i64 };

fn formatDate(civil: Civil, buf: []u8) ?[]const u8 {
    if (civil.year < 1) return null;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(civil.year)), @as(u64, @intCast(civil.month)), @as(u64, @intCast(civil.day)) }) catch null;
}

/// Normalized time string: seconds only when needed, fraction always 3 digits.
fn formatTime(ms_in_day: f64, buf: []u8) ?[]const u8 {
    const total: u64 = @floor(ms_in_day);
    const hour = total / 3_600_000;
    const minute = (total / 60_000) % 60;
    const second = (total / 1000) % 60;
    const millis = total % 1000;
    if (second == 0 and millis == 0) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hour, minute }) catch null;
    }
    if (millis == 0) {
        return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, minute, second }) catch null;
    }
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hour, minute, second, millis }) catch null;
}

// Howard Hinnant's civil-from-days and days-from-civil.
fn daysFromCivil(year: i64, month: i64, day: i64) f64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return @floatFromInt(era * 146_097 + doe - 719_468);
}

fn civilFromDays(days: i64) Civil {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(month <= 2), .month = month, .day = day };
}

/// Days since the epoch of the Monday starting ISO week `week` of `year`.
fn isoWeekMonday(year: i64, week: i64) i64 {
    const jan4: i64 = @intFromFloat(daysFromCivil(year, 1, 4));
    return jan4 - @mod(jan4 + 3, 7) + (week - 1) * 7;
}

/// WHATWG "valid floating-point number" grammar check + overflow detection.
/// Rejects "+1", "1.", "Infinity", "NaN", "2e308", leading whitespace, trailing junk.
fn isValidFloatingPoint(value: []const u8) bool {
    if (value.len == 0) return false;
    var pos: usize = 0;

    // Optional leading minus (no plus allowed)
    if (value[pos] == '-') {
        pos += 1;
        if (pos >= value.len) return false;
    }

    // Must have one or both of: digit-sequence, dot+digit-sequence
    var has_integer = false;
    var has_decimal = false;

    if (pos < value.len and std.ascii.isDigit(value[pos])) {
        has_integer = true;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
    }

    if (pos < value.len and value[pos] == '.') {
        pos += 1;
        if (pos < value.len and std.ascii.isDigit(value[pos])) {
            has_decimal = true;
            while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
        } else {
            return false; // dot without trailing digits ("1.")
        }
    }

    if (!has_integer and !has_decimal) return false;

    // Optional exponent: (e|E) [+|-] digits
    if (pos < value.len and (value[pos] == 'e' or value[pos] == 'E')) {
        pos += 1;
        if (pos >= value.len) return false;
        if (value[pos] == '+' or value[pos] == '-') {
            pos += 1;
            if (pos >= value.len) return false;
        }
        if (!std.ascii.isDigit(value[pos])) return false;
        while (pos < value.len and std.ascii.isDigit(value[pos])) : (pos += 1) {}
    }

    if (pos != value.len) return false; // trailing junk

    // Grammar is valid; now check the parsed value doesn't overflow
    const f = std.fmt.parseFloat(f64, value) catch return false;
    return !std.math.isInf(f) and !std.math.isNan(f);
}

/// Validate a WHATWG "valid date string": YYYY-MM-DD
fn isValidDate(value: []const u8) bool {
    // Minimum: 4-digit year + "-MM-DD" = 10 chars
    if (value.len < 10) return false;
    const year_len = value.len - 6; // "-MM-DD" is always 6 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-' or value[year_len + 3] != '-') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const month = parseAllDigits(value[year_len + 1 .. year_len + 3]) orelse return false;
    if (month < 1 or month > 12) return false;
    const day = parseAllDigits(value[year_len + 4 .. year_len + 6]) orelse return false;
    if (day < 1 or day > daysInMonth(@intCast(year), @intCast(month))) return false;
    return true;
}

/// Validate a WHATWG "valid month string": YYYY-MM
fn isValidMonth(value: []const u8) bool {
    if (value.len < 7) return false;
    const year_len = value.len - 3; // "-MM" is 3 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const month = parseAllDigits(value[year_len + 1 .. year_len + 3]) orelse return false;
    return month >= 1 and month <= 12;
}

/// Validate a WHATWG "valid week string": YYYY-Www
fn isValidWeek(value: []const u8) bool {
    if (value.len < 8) return false;
    const year_len = value.len - 4; // "-Www" is 4 chars from end
    if (year_len < 4) return false;
    if (value[year_len] != '-' or value[year_len + 1] != 'W') return false;

    const year = parseAllDigits(value[0..year_len]) orelse return false;
    if (year == 0) return false;
    const week = parseAllDigits(value[year_len + 2 .. year_len + 4]) orelse return false;
    if (week < 1) return false;
    return week <= maxWeeksInYear(@intCast(year));
}

/// Validate a WHATWG "valid time string": HH:MM[:SS[.s{1,3}]]
fn isValidTime(value: []const u8) bool {
    if (value.len < 5) return false;
    if (value[2] != ':') return false;
    const hour = parseAllDigits(value[0..2]) orelse return false;
    if (hour > 23) return false;
    const minute = parseAllDigits(value[3..5]) orelse return false;
    if (minute > 59) return false;
    if (value.len == 5) return true;

    // Optional seconds
    if (value.len < 8 or value[5] != ':') return false;
    const second = parseAllDigits(value[6..8]) orelse return false;
    if (second > 59) return false;
    if (value.len == 8) return true;

    // Optional fractional seconds: 1-3 digits
    if (value[8] != '.') return false;
    const frac_len = value.len - 9;
    if (frac_len < 1 or frac_len > 3) return false;
    for (value[9..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Sanitize datetime-local: validate and normalize, or return "".
/// Spec: if valid, normalize to "YYYY-MM-DDThh:mm" (shortest time form);
/// otherwise set to "".
fn sanitizeDatetimeLocal(comptime dupe: bool, value: []const u8, arena: std.mem.Allocator) ![]const u8 {
    if (value.len < 16) {
        return "";
    }

    // Find separator (T or space) by scanning for it before a valid time start
    var sep_pos: ?usize = null;
    if (value.len >= 16) {
        for (0..value.len - 4) |i| {
            if ((value[i] == 'T' or value[i] == ' ') and
                i + 3 < value.len and
                std.ascii.isDigit(value[i + 1]) and
                std.ascii.isDigit(value[i + 2]) and
                value[i + 3] == ':')
            {
                sep_pos = i;
                break;
            }
        }
    }
    const sep = sep_pos orelse return "";

    const date_part = value[0..sep];
    const time_part = value[sep + 1 ..];
    if (!isValidDate(date_part) or !isValidTime(time_part)) {
        return "";
    }

    // Already normalized? (T separator and no trailing :00 or :00.000)
    if (value[sep] == 'T' and time_part.len == 5) {
        return if (comptime dupe) arena.dupe(u8, value) else value;
    }

    // Parse time components for normalization
    const second: u32 = if (time_part.len >= 8) (parseAllDigits(time_part[6..8]) orelse return "") else 0;
    var has_nonzero_frac = false;
    var frac_end: usize = 0;
    if (time_part.len > 9 and time_part[8] == '.') {
        for (time_part[9..], 0..) |c, fi| {
            if (c != '0') has_nonzero_frac = true;
            frac_end = fi + 1;
        }
        // Strip trailing zeros from fractional part
        while (frac_end > 0 and time_part[9 + frac_end - 1] == '0') : (frac_end -= 1) {}
    }

    // Build shortest time: HH:MM, or HH:MM:SS, or HH:MM:SS.fff
    const need_seconds = second != 0 or has_nonzero_frac;
    const time_len: usize = if (need_seconds) (if (frac_end > 0) 9 + frac_end else 8) else 5;
    const total_len = date_part.len + 1 + time_len;

    const result = try arena.alloc(u8, total_len);
    @memcpy(result[0..date_part.len], date_part);
    result[date_part.len] = 'T';
    @memcpy(result[date_part.len + 1 ..][0..5], time_part[0..5]);

    if (need_seconds) {
        @memcpy(result[date_part.len + 6 ..][0..3], time_part[5..8]);
        if (frac_end > 0) {
            result[date_part.len + 9] = '.';
            @memcpy(result[date_part.len + 10 ..][0..frac_end], time_part[9..][0..frac_end]);
        }
    }
    return result[0..total_len];
}

/// Sanitize value for `<input type=range>` per WHATWG HTML spec:
/// https://html.spec.whatwg.org/multipage/input.html#range-state-(type=range)
///   1. If value is not a valid floating-point number, set it to
///      `min + (max - min) / 2`.
///   2. If value < min, set it to min.
///   3. If value > max, set it to max.
///   4. If value is not on the step ladder (`step base + step * n` for integer
///      `n`), round to nearest valid value, ties up. The rounded value must
///      stay in `[min, max]`; if rounding up exceeds max, use the rounded-down
///      neighbor instead.
/// `min`/`max` default to 0 and 100 respectively when the attribute is missing
/// or fails to parse as a valid floating-point number. `step` defaults to 1;
/// `step="any"` (case-insensitive) disables step matching. The step base
/// (https://html.spec.whatwg.org/multipage/input.html#concept-input-min) falls
/// back through `min` content attr → `value` content attr → 0.
fn sanitizeRange(
    comptime dupe: bool,
    value: []const u8,
    min_attr: []const u8,
    max_attr: []const u8,
    step_attr: []const u8,
    value_attr: []const u8,
    frame: *Frame,
) ![]const u8 {
    const min: f64 = if (isValidFloatingPoint(min_attr))
        std.fmt.parseFloat(f64, min_attr) catch 0
    else
        0;
    const max: f64 = if (isValidFloatingPoint(max_attr))
        std.fmt.parseFloat(f64, max_attr) catch 100
    else
        100;
    const step_base: f64 = if (isValidFloatingPoint(min_attr))
        std.fmt.parseFloat(f64, min_attr) catch 0
    else if (isValidFloatingPoint(value_attr))
        std.fmt.parseFloat(f64, value_attr) catch 0
    else
        0;

    if (!isValidFloatingPoint(value)) {
        return try formatFloat(frame.arena, snapToStep(min + (max - min) / 2, min, max, step_base, step_attr));
    }

    const v0 = std.fmt.parseFloat(f64, value) catch unreachable; // grammar already validated
    var v = v0;
    if (v < min) v = min;
    if (v > max) v = max;
    const snapped = snapToStep(v, min, max, step_base, step_attr);
    if (v == v0 and snapped == v) {
        // Already valid and on the ladder — preserve the original string so
        // assignments like `el.value = "1.0"` round-trip without canonicalizing.
        return if (comptime dupe) try frame.dupeString(value) else value;
    }
    return try formatFloat(frame.arena, snapped);
}

/// Snap `value` (already clamped to `[min, max]`) to the nearest value on the
/// step ladder `step_base + step * n`. Ties round up; if the rounded-up
/// neighbor exceeds `max`, use the rounded-down neighbor. Returns `value`
/// unchanged for `step="any"` (case-insensitive) or when no ladder rung lands
/// in `[min, max]`.
fn snapToStep(value: f64, min: f64, max: f64, step_base: f64, step_attr: []const u8) f64 {
    if (std.ascii.eqlIgnoreCase(step_attr, "any")) return value;

    const step: f64 = blk: {
        if (isValidFloatingPoint(step_attr)) {
            const s = std.fmt.parseFloat(f64, step_attr) catch break :blk 1;
            if (s > 0) break :blk s;
        }
        break :blk 1;
    };

    const diff = (value - step_base) / step;
    const n_floor = @floor(diff);
    const n_ceil = @ceil(diff);
    const n: f64 = if (n_floor == n_ceil) n_floor else blk: {
        const dist_floor = diff - n_floor;
        const dist_ceil = n_ceil - diff;
        if (dist_ceil < dist_floor) break :blk n_ceil;
        if (dist_floor < dist_ceil) break :blk n_floor;
        break :blk n_ceil; // tie -> round up
    };

    var candidate = step_base + n * step;
    if (candidate > max) candidate = step_base + (n - 1) * step;
    if (candidate < min) return value; // no valid rung in range; leave clamped value
    return candidate;
}

/// Format an f64 to its shortest decimal representation, arena-allocated.
fn formatFloat(arena: std.mem.Allocator, value: f64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{d}", .{value});
}

/// Parse a slice that must be ALL ASCII digits into a u32. Returns null if any non-digit or empty.
fn parseAllDigits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var result: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        result = result *% 10 +% (c - '0');
    }
    return result;
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) @as(u32, 29) else 28,
        else => 0,
    };
}

/// ISO 8601: a year has 53 weeks if Jan 1 is Thursday, or Jan 1 is Wednesday and leap year.
fn maxWeeksInYear(year: u32) u32 {
    // Gauss's algorithm for Jan 1 day-of-week
    // dow: 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat
    const y1 = year - 1;
    const dow = (1 + 5 * (y1 % 4) + 4 * (y1 % 100) + 6 * (y1 % 400)) % 7;
    if (dow == 4) return 53; // Jan 1 is Thursday
    if (dow == 3 and isLeapYear(year)) return 53; // Jan 1 is Wednesday + leap year
    return 52;
}

fn uncheckRadioGroup(self: *Input, frame: *Frame) void {
    var iter = self.radioGroupIterator() orelse return;
    const my_form = self.getForm(frame);
    while (iter.next()) |other| {
        if (other == self) continue;
        if (!sameFormOwner(my_form, other, frame)) continue;
        other._checked = false;
    }
}

pub fn getPopoverTargetElement(self: *Input, frame: *Frame) ?*Element {
    return popover.invokerTarget(self.asNode(), self._popover_target, frame);
}

pub fn setPopoverTargetElement(self: *Input, value: ?*Element, frame: *Frame) !void {
    self._popover_target = value;
    if (value == null) {
        try self.asElement().removeAttribute(.wrap("popovertarget"), frame);
    } else {
        try self.asElement().setAttribute(.wrap("popovertarget"), .wrap(""), frame);
    }
}

pub fn getPopoverTargetAction(self: *Input) []const u8 {
    return @tagName(popover.getInvokerAction(self.asElement()));
}

pub fn setPopoverTargetAction(self: *Input, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttribute(.wrap("popovertargetaction"), .wrap(value), frame);
}

pub fn getMax(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("max")) orelse "";
}

pub fn getMin(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("min")) orelse "";
}

pub fn getRequired(self: *const Input) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("required")) != null;
}

pub fn getStep(self: *const Input) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("step")) orelse "";
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Input);

    pub const Meta = struct {
        pub const name = "HTMLInputElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Input);
    pub const useMap = reflect.string("usemap");
    pub const dirName = reflect.string("dirname");
    pub const @"align" = reflect.string("align");

    /// Handles [LegacyNullToEmptyString]: null → "" per HTML spec.
    fn setValueFromJS(self: *Input, js_value: js.Value, frame: *Frame) !void {
        if (js_value.isNull()) {
            return self.setValue("", frame);
        }
        return self.setValue(try js_value.toZig([]const u8), frame);
    }

    pub const onselectionchange = bridge.accessor(Input.getOnSelectionChange, Input.setOnSelectionChange, .{});
    pub const @"type" = bridge.accessor(Input.getType, Input.setType, .{ .ce_reactions = true });
    pub const value = bridge.accessor(Input.getValueForJS, setValueFromJS, .{ .ce_reactions = true });
    pub const valueAsNumber = bridge.accessor(Input.getValueAsNumber, Input.setValueAsNumber, .{});
    pub const valueAsDate = bridge.accessor(Input.getValueAsDate, Input.setValueAsDate, .{});
    pub const stepUp = bridge.function(Input.stepUp, .{});
    pub const stepDown = bridge.function(Input.stepDown, .{});
    pub const files = bridge.accessor(Input.getFiles, Input.setFiles, .{});
    pub const defaultValue = bridge.accessor(Input.getDefaultValue, Input.setDefaultValue, .{ .ce_reactions = true });
    pub const checked = bridge.accessor(Input.getChecked, Input.setChecked, .{});
    pub const defaultChecked = bridge.accessor(Input.getDefaultChecked, Input.setDefaultChecked, .{ .ce_reactions = true });
    pub const disabled = bridge.accessor(Input.getDisabled, Input.setDisabled, .{ .ce_reactions = true });
    pub const name = reflect.string("name");
    pub const required = reflect.boolean("required");
    pub const accept = reflect.string("accept");
    pub const readOnly = reflect.boolean("readonly");
    pub const alt = reflect.string("alt");
    pub const maxLength = reflect.limitedLong("maxlength");
    pub const minLength = reflect.limitedLong("minlength");
    pub const size = reflect.unsignedLong("size", .{ .default = 20, .positive = true });
    pub const src = bridge.accessor(Input.getSrc, Input.setSrc, .{ .ce_reactions = true });
    pub const form = bridge.accessor(Input.getForm, null, .{});
    pub const list = bridge.accessor(Input.getList, null, .{});
    pub const formAction = bridge.accessor(Input.getFormAction, Input.setFormAction, .{});
    pub const formEnctype = bridge.accessor(Input.getFormEnctype, Input.setFormEnctype, .{});
    pub const formMethod = bridge.accessor(Input.getFormMethod, Input.setFormMethod, .{});
    pub const formNoValidate = bridge.accessor(Input.getFormNoValidate, Input.setFormNoValidate, .{});
    pub const formTarget = reflect.string("formtarget");
    pub const labels = bridge.accessor(Input.getLabels, null, .{});
    pub const popoverTargetElement = bridge.accessor(Input.getPopoverTargetElement, Input.setPopoverTargetElement, .{ .ce_reactions = true });
    pub const popoverTargetAction = bridge.accessor(Input.getPopoverTargetAction, Input.setPopoverTargetAction, .{ .ce_reactions = true });
    pub const indeterminate = bridge.accessor(Input.getIndeterminate, Input.setIndeterminate, .{});
    pub const placeholder = reflect.string("placeholder");
    pub const pattern = reflect.string("pattern");
    pub const min = reflect.string("min");
    pub const max = reflect.string("max");
    pub const step = reflect.string("step");
    pub const multiple = reflect.boolean("multiple");
    pub const autocomplete = reflect.string("autocomplete");
    pub const willValidate = bridge.accessor(Input.getWillValidate, null, .{});
    pub const validity = bridge.accessor(Input.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(Input.getValidationMessage, null, .{});
    pub const checkValidity = bridge.function(Input.checkValidity, .{});
    pub const reportValidity = bridge.function(Input.reportValidity, .{});
    pub const setCustomValidity = bridge.function(Input.setCustomValidity, .{});
    pub const select = bridge.function(Input.select, .{});

    pub const selectionStart = bridge.accessor(Input.getSelectionStart, Input.setSelectionStart, .{});
    pub const selectionEnd = bridge.accessor(Input.getSelectionEnd, Input.setSelectionEnd, .{});
    pub const selectionDirection = bridge.accessor(Input.getSelectionDirection, null, .{});
    pub const setSelectionRange = bridge.function(Input.setSelectionRange, .{});
};

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        var self = node.as(Input);
        const element = self.asElement();

        // Store initial values from attributes
        self._default_value = element.getAttributeSafe(comptime .wrap("value"));
        self._default_checked = element.getAttributeSafe(comptime .wrap("checked")) != null;

        self._checked = self._default_checked;

        self._input_type = if (element.getAttributeSafe(comptime .wrap("type"))) |type_attr|
            Type.fromString(type_attr)
        else
            .text;

        // Sanitize initial value per input type (e.g. date rejects "invalid-date").
        if (self._default_value) |dv| {
            self._value = try self.sanitizeValue(false, dv, frame);
        } else {
            self._value = null;
        }

        // If this is a checked radio button, uncheck others in its group
        if (self._checked and self._input_type == .radio) {
            self.uncheckRadioGroup(frame);
        }
    }

    pub fn attributeChange(element: *Element, name: String, value: String, frame: *Frame) !void {
        const attribute = std.meta.stringToEnum(enum { type, value, checked }, name.str()) orelse return;
        const self = element.as(Input);
        switch (attribute) {
            .type => {
                self._input_type = Type.fromString(value.str());
                // Sanitize the current value according to the new type
                if (self._value) |current_value| {
                    self._value = try self.sanitizeValue(false, current_value, frame);
                    // Apply default value for checkbox/radio if value is now empty
                    if (self._value.?.len == 0 and (self._input_type == .checkbox or self._input_type == .radio)) {
                        self._value = "on";
                    }
                }
            },
            .value => self._default_value = try frame.arena.dupe(u8, value.str()),
            .checked => {
                self._default_checked = true;
                // Only update checked state if it hasn't been manually modified
                if (!self._checked_dirty) {
                    self._checked = true;
                    // If setting a radio button to checked, uncheck others in the group
                    if (self._input_type == .radio) {
                        self.uncheckRadioGroup(frame);
                    }
                }
            },
        }
    }

    pub fn attributeRemove(element: *Element, name: String, _: *Frame) !void {
        const attribute = std.meta.stringToEnum(enum { type, value, checked }, name.str()) orelse return;
        const self = element.as(Input);
        switch (attribute) {
            .type => self._input_type = .text,
            .value => self._default_value = null,
            .checked => {
                self._default_checked = false;
                // Only update checked state if it hasn't been manually modified
                if (!self._checked_dirty) {
                    self._checked = false;
                }
            },
        }
    }

    pub fn cloned(source_element: *Element, cloned_element: *Element, deep: bool, _: *Frame) !void {
        _ = deep;
        const source = source_element.as(Input);
        const clone = cloned_element.as(Input);

        // Copy runtime state from source to clone
        clone._value = source._value;
        clone._checked = source._checked;
        clone._checked_dirty = source._checked_dirty;
        clone._user_edited = source._user_edited;
        clone._selection_direction = source._selection_direction;
        clone._selection_start = source._selection_start;
        clone._selection_end = source._selection_end;
        clone._indeterminate = source._indeterminate;
    }
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Input" {
    try testing.htmlRunner("element/html/input.html", .{});
    try testing.htmlRunner("element/html/input_click.html", .{});
    try testing.htmlRunner("element/html/input_image_submit.html", .{});
    try testing.htmlRunner("element/html/input_radio.html", .{});
    try testing.htmlRunner("element/html/input-attrs.html", .{});
    try testing.htmlRunner("element/html/input-validity.html", .{});
    try testing.htmlRunner("element/html/input_file.html", .{});
    try testing.htmlRunner("element/html/input-value-as.html", .{});
}

test "isValidFloatingPoint" {
    // Valid
    try testing.expect(isValidFloatingPoint("1"));
    try testing.expect(isValidFloatingPoint("0.5"));
    try testing.expect(isValidFloatingPoint("-1"));
    try testing.expect(isValidFloatingPoint("-0.5"));
    try testing.expect(isValidFloatingPoint("1e10"));
    try testing.expect(isValidFloatingPoint("1E10"));
    try testing.expect(isValidFloatingPoint("1e+10"));
    try testing.expect(isValidFloatingPoint("1e-10"));
    try testing.expect(isValidFloatingPoint("0.123"));
    try testing.expect(isValidFloatingPoint(".5"));
    // Invalid
    try testing.expect(!isValidFloatingPoint(""));
    try testing.expect(!isValidFloatingPoint("+1"));
    try testing.expect(!isValidFloatingPoint("1."));
    try testing.expect(!isValidFloatingPoint("Infinity"));
    try testing.expect(!isValidFloatingPoint("NaN"));
    try testing.expect(!isValidFloatingPoint(" 1"));
    try testing.expect(!isValidFloatingPoint("1 "));
    try testing.expect(!isValidFloatingPoint("1e"));
    try testing.expect(!isValidFloatingPoint("1e+"));
    try testing.expect(!isValidFloatingPoint("2e308")); // overflow
}

test "isValidDate" {
    try testing.expect(isValidDate("2024-01-01"));
    try testing.expect(isValidDate("2024-02-29")); // leap year
    try testing.expect(isValidDate("2024-12-31"));
    try testing.expect(isValidDate("10000-01-01")); // >4-digit year
    try testing.expect(!isValidDate("2024-02-30")); // invalid day
    try testing.expect(!isValidDate("2023-02-29")); // not leap year
    try testing.expect(!isValidDate("2024-13-01")); // invalid month
    try testing.expect(!isValidDate("2024-00-01")); // month 0
    try testing.expect(!isValidDate("0000-01-01")); // year 0
    try testing.expect(!isValidDate("2024-1-01")); // single-digit month
    try testing.expect(!isValidDate(""));
    try testing.expect(!isValidDate("not-a-date"));
}

test "isValidMonth" {
    try testing.expect(isValidMonth("2024-01"));
    try testing.expect(isValidMonth("2024-12"));
    try testing.expect(!isValidMonth("2024-00"));
    try testing.expect(!isValidMonth("2024-13"));
    try testing.expect(!isValidMonth("0000-01"));
    try testing.expect(!isValidMonth(""));
}

test "isValidWeek" {
    try testing.expect(isValidWeek("2024-W01"));
    try testing.expect(isValidWeek("2024-W52"));
    try testing.expect(isValidWeek("2020-W53")); // 2020 has 53 weeks
    try testing.expect(!isValidWeek("2024-W00"));
    try testing.expect(!isValidWeek("2024-W54"));
    try testing.expect(!isValidWeek("0000-W01"));
    try testing.expect(!isValidWeek(""));
}

test "isValidTime" {
    try testing.expect(isValidTime("00:00"));
    try testing.expect(isValidTime("23:59"));
    try testing.expect(isValidTime("12:30:45"));
    try testing.expect(isValidTime("12:30:45.1"));
    try testing.expect(isValidTime("12:30:45.12"));
    try testing.expect(isValidTime("12:30:45.123"));
    try testing.expect(!isValidTime("24:00"));
    try testing.expect(!isValidTime("12:60"));
    try testing.expect(!isValidTime("12:30:60"));
    try testing.expect(!isValidTime("12:30:45.1234")); // >3 frac digits
    try testing.expect(!isValidTime("12:30:45.")); // dot without digits
    try testing.expect(!isValidTime(""));
}

test "sanitizeDatetimeLocal" {
    const allocator = testing.allocator;
    // Already normalized — returns input slice, no allocation
    try testing.expectEqual("2024-01-01T12:30", try sanitizeDatetimeLocal(false, "2024-01-01T12:30", allocator));
    // Space separator → T (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01 12:30", allocator);
        try testing.expectEqual("2024-01-01T12:30", result);
        allocator.free(result);
    }
    // Strip trailing :00 (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:00", allocator);
        try testing.expectEqual("2024-01-01T12:30", result);
        allocator.free(result);
    }
    // Keep non-zero seconds (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:45", allocator);
        try testing.expectEqual("2024-01-01T12:30:45", result);
        allocator.free(result);
    }
    // Keep fractional seconds, strip trailing zeros (allocates)
    {
        const result = try sanitizeDatetimeLocal(false, "2024-01-01T12:30:45.100", allocator);
        try testing.expectEqual("2024-01-01T12:30:45.1", result);
        allocator.free(result);
    }
    // Invalid → "" (no allocation)
    try testing.expectEqual("", try sanitizeDatetimeLocal(false, "not-a-datetime", allocator));
    try testing.expectEqual("", try sanitizeDatetimeLocal(false, "", allocator));
}

test "parseAllDigits" {
    try testing.expectEqual(@as(?u32, 0), parseAllDigits("0"));
    try testing.expectEqual(@as(?u32, 123), parseAllDigits("123"));
    try testing.expectEqual(@as(?u32, 2024), parseAllDigits("2024"));
    try testing.expectEqual(@as(?u32, null), parseAllDigits(""));
    try testing.expectEqual(@as(?u32, null), parseAllDigits("12a"));
    try testing.expectEqual(@as(?u32, null), parseAllDigits("abc"));
}

test "daysInMonth" {
    try testing.expectEqual(@as(u32, 31), daysInMonth(2024, 1));
    try testing.expectEqual(@as(u32, 29), daysInMonth(2024, 2)); // leap
    try testing.expectEqual(@as(u32, 28), daysInMonth(2023, 2)); // non-leap
    try testing.expectEqual(@as(u32, 30), daysInMonth(2024, 4));
    try testing.expectEqual(@as(u32, 29), daysInMonth(2000, 2)); // century leap
    try testing.expectEqual(@as(u32, 28), daysInMonth(1900, 2)); // century non-leap
}

test "maxWeeksInYear" {
    try testing.expectEqual(@as(u32, 52), maxWeeksInYear(2024));
    try testing.expectEqual(@as(u32, 53), maxWeeksInYear(2020)); // Jan 1 = Wed + leap
    try testing.expectEqual(@as(u32, 53), maxWeeksInYear(2015)); // Jan 1 = Thu
    try testing.expectEqual(@as(u32, 52), maxWeeksInYear(2023));
}
