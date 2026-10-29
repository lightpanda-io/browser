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

// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#the-constraint-validation-api

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");

const Event = @import("../../Event.zig");
const Element = @import("../../Element.zig");
const ElementInternals = @import("../../ElementInternals.zig");

const Input = @import("Input.zig");
const Select = @import("Select.zig");
const Button = @import("Button.zig");
const Custom = @import("Custom.zig");
const TextArea = @import("TextArea.zig");

const ValidityState = @This();

// The form control whose validity flags this object reflects. Stored as a
// generic *Element; each getter dispatches on the concrete element type
// because the flag definitions are per-type in the HTML spec.
_owner: *Element,

fn getValueMissing(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.valueMissing;
    if (self._owner.is(Input)) |input| return input.suffersValueMissing();
    if (self._owner.is(Select)) |select| return select.suffersValueMissing();
    if (self._owner.is(TextArea)) |textarea| return textarea.suffersValueMissing();
    return false;
}

fn getTypeMismatch(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.typeMismatch;
    if (self._owner.is(Input)) |input| return input.suffersTypeMismatch();
    return false;
}

fn getPatternMismatch(self: *const ValidityState, frame: *Frame) bool {
    if (self.customFlags()) |flags| return flags.patternMismatch;
    if (self._owner.is(Input)) |input| return input.suffersPatternMismatch(frame);
    return false;
}

fn getTooLong(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.tooLong;
    if (self._owner.is(Input)) |input| return input.suffersTooLong();
    if (self._owner.is(TextArea)) |textarea| return textarea.suffersTooLong();
    return false;
}

fn getTooShort(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.tooShort;
    if (self._owner.is(Input)) |input| return input.suffersTooShort();
    if (self._owner.is(TextArea)) |textarea| return textarea.suffersTooShort();
    return false;
}

fn getRangeUnderflow(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.rangeUnderflow;
    if (self._owner.is(Input)) |input| return input.suffersRangeUnderflow();
    return false;
}

fn getRangeOverflow(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.rangeOverflow;
    if (self._owner.is(Input)) |input| return input.suffersRangeOverflow();
    return false;
}

fn getStepMismatch(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.stepMismatch;
    if (self._owner.is(Input)) |input| return input.suffersStepMismatch();
    return false;
}

fn getBadInput(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.badInput;
    // badInput flips when the UA cannot convert a user-typed string (e.g. the
    // user typed "abc" into <input type=number>). Headless Lightpanda receives
    // values via attributes or JS assignment, never raw keystrokes — there is
    // no user input to be "bad". Always false.
    return false;
}

fn getCustomError(self: *const ValidityState) bool {
    if (self.customFlags()) |flags| return flags.customError;
    if (self._owner.is(Input)) |input| return input.hasCustomValidity();
    if (self._owner.is(Select)) |select| return select.hasCustomValidity();
    if (self._owner.is(TextArea)) |textarea| return textarea.hasCustomValidity();
    if (self._owner.is(Button)) |button| return button.hasCustomValidity();
    return false;
}

pub fn getValid(self: *const ValidityState, frame: *Frame) bool {
    if (self.customFlags()) |flags| return !flags.any();
    return !self.getValueMissing() and
        !self.getTypeMismatch() and
        !self.getPatternMismatch(frame) and
        !self.getTooLong() and
        !self.getTooShort() and
        !self.getRangeUnderflow() and
        !self.getRangeOverflow() and
        !self.getStepMismatch() and
        !self.getBadInput() and
        !self.getCustomError();
}

// Whether the element satisfies its constraints, or null when it is not a
// candidate for constraint validation (it then matches neither :valid nor
// :invalid).
pub fn isValid(element: *Element, frame: *Frame) ?bool {
    const will_validate = if (element.is(Input)) |input|
        input.getWillValidate()
    else if (element.is(Select)) |select|
        select.getWillValidate()
    else if (element.is(TextArea)) |textarea|
        textarea.getWillValidate()
    else if (element.is(Button)) |button|
        button.getWillValidate()
    else if (element.is(Custom)) |custom|
        custom.isFormAssociated() and custom.willValidate()
    else
        return null;
    if (will_validate == false) {
        return null;
    }
    const validity: ValidityState = .{ ._owner = element };
    return validity.getValid(frame);
}

// https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#check-validity-steps
pub fn checkValidity(element: *Element, frame: *Frame) !bool {
    if (isValid(element, frame) orelse true) {
        return true;
    }
    const event = try Event.initTrusted(comptime .wrap("invalid"), .{ .cancelable = true }, frame.page);
    try frame._event_manager.dispatch(element.asEventTarget(), event);
    return false;
}

// A form-associated custom element's flags are whatever its ElementInternals
// last passed to setValidity().
fn customFlags(self: *const ValidityState) ?ElementInternals.ValidityFlags {
    const custom = self._owner.is(Custom) orelse return null;
    const internals = custom._internals orelse return .{};
    return internals._flags;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ValidityState);

    pub const Meta = struct {
        pub const name = "ValidityState";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const valueMissing = bridge.accessor(ValidityState.getValueMissing, null, .{});
    pub const typeMismatch = bridge.accessor(ValidityState.getTypeMismatch, null, .{});
    pub const patternMismatch = bridge.accessor(ValidityState.getPatternMismatch, null, .{});
    pub const tooLong = bridge.accessor(ValidityState.getTooLong, null, .{});
    pub const tooShort = bridge.accessor(ValidityState.getTooShort, null, .{});
    pub const rangeUnderflow = bridge.accessor(ValidityState.getRangeUnderflow, null, .{});
    pub const rangeOverflow = bridge.accessor(ValidityState.getRangeOverflow, null, .{});
    pub const stepMismatch = bridge.accessor(ValidityState.getStepMismatch, null, .{});
    pub const badInput = bridge.accessor(ValidityState.getBadInput, null, .{});
    pub const customError = bridge.accessor(ValidityState.getCustomError, null, .{});
    pub const valid = bridge.accessor(ValidityState.getValid, null, .{});
};
