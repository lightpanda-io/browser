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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Blob = @import("Blob.zig");
const File = @import("File.zig");
const FileList = @import("FileList.zig");
const ShadowRoot = @import("ShadowRoot.zig");
const CustomStateSet = @import("CustomStateSet.zig");

const FormData = @import("net/FormData.zig");

const HtmlElement = @import("element/Html.zig");
const Custom = @import("element/html/Custom.zig");
const Form = @import("element/html/Form.zig");
const Label = @import("element/html/Label.zig");
const ValidityState = @import("element/html/ValidityState.zig");

const String = lp.String;

const ElementInternals = @This();

_host: *Custom,
_states: ?*CustomStateSet = null,
_aria: std.StringHashMapUnmanaged([]const u8) = .empty,

_submission: Submission = .none,
// Holds a ref on each File in _submission, released at frame teardown.
_files: ?*FileList = null,

_flags: ValidityFlags = .{},
_validation_message: []const u8 = "",
_validity: ?*ValidityState = null,

pub const Submission = union(enum) {
    none,
    string: []const u8,
    file: *File,
    entries: []const FormData.Entry,
};

pub const ValidityFlags = struct {
    badInput: bool = false,
    customError: bool = false,
    patternMismatch: bool = false,
    rangeOverflow: bool = false,
    rangeUnderflow: bool = false,
    stepMismatch: bool = false,
    tooLong: bool = false,
    tooShort: bool = false,
    typeMismatch: bool = false,
    valueMissing: bool = false,

    pub fn any(self: ValidityFlags) bool {
        inline for (@typeInfo(ValidityFlags).@"struct".field_names) |name| {
            if (@field(self, name)) {
                return true;
            }
        }
        return false;
    }
};

pub fn init(host: *Custom, frame: *Frame) !*ElementInternals {
    return frame._factory.create(ElementInternals{ ._host = host });
}

fn asElement(self: *const ElementInternals) *Element {
    return self._host.asElement();
}

pub fn getAria(self: *const ElementInternals, comptime name: []const u8) ?[]const u8 {
    return self._aria.get(name);
}

fn getShadowRoot(self: *const ElementInternals, frame: *Frame) ?*ShadowRoot {
    const shadow_root = self.asElement().hostedShadowRoot(frame) orelse return null;
    if (!shadow_root._available_to_internals) {
        return null;
    }
    return shadow_root;
}

fn getStates(self: *ElementInternals, frame: *Frame) !*CustomStateSet {
    if (self._states) |s| {
        return s;
    }
    const s = try frame._factory.create(CustomStateSet{});
    self._states = s;
    return s;
}

fn assertFormAssociated(self: *const ElementInternals) !void {
    if (!self._host.isFormAssociated()) {
        return error.NotSupported;
    }
}

const FormValue = union(enum) {
    blob: *Blob, // only a File is a File; any other Blob stringifies
    form_data: *FormData,
    string: []const u8, // must be last, everything can coerce to a string
};

// The `state` argument is only used to restore a control after navigation,
// which we never do, so it's ignored.
fn setFormValue(self: *ElementInternals, value_: ?FormValue, frame: *Frame) !void {
    try self.assertFormAssociated();

    const value = value_ orelse {
        try self.replaceFiles(&.{}, frame);
        self._submission = .none;
        return;
    };

    switch (value) {
        .string => |s| {
            try self.replaceFiles(&.{}, frame);
            self._submission = .{ .string = try frame.dupeString(s) };
        },
        .blob => |blob| {
            if (blob._type != .file) {
                try self.replaceFiles(&.{}, frame);
                self._submission = .{ .string = "[object Blob]" };
                return;
            }
            const file = blob._type.file;
            try self.replaceFiles(&.{file}, frame);
            self._submission = .{ .file = file };
        },
        .form_data => |form_data| {
            const arena = frame.page_arena;
            const source = form_data._entries.items;

            var files: std.ArrayList(*File) = .empty;
            const copy = try arena.alloc(FormData.Entry, source.len);
            for (source, copy) |entry, *c| {
                c.* = .{
                    .name = try String.init(arena, entry.name.str(), .{}),
                    .value = switch (entry.value) {
                        .string => |s| .{ .string = try String.init(arena, s.str(), .{}) },
                        .file => |file| blk: {
                            try files.append(frame.local_arena, file);
                            break :blk .{ .file = file };
                        },
                        .no_file => .no_file,
                    },
                };
            }
            try self.replaceFiles(files.items, frame);
            self._submission = .{ .entries = copy };
        },
    }
}

fn replaceFiles(self: *ElementInternals, files: []const *File, frame: *Frame) !void {
    const fl = self._files orelse blk: {
        if (files.len == 0) {
            return;
        }
        const fl = try frame._factory.create(FileList{});
        try frame.trackFileList(fl);
        self._files = fl;
        break :blk fl;
    };

    const dupe = try frame.page_arena.dupe(*File, files);
    for (dupe) |file| {
        file._proto.acquireRef();
    }
    for (fl._files) |old| {
        old._proto.releaseRef(frame.page);
    }
    fl._files = dupe;
}

fn getForm(self: *const ElementInternals) !?*Form {
    try self.assertFormAssociated();
    return Form.ownerOf(self.asElement());
}

fn getLabels(self: *const ElementInternals, frame: *Frame) !js.Array {
    try self.assertFormAssociated();
    return Label.getControlLabels(self.asElement(), frame);
}

fn willValidate(self: *const ElementInternals) bool {
    return self._host.willValidate();
}

fn getWillValidate(self: *const ElementInternals) !bool {
    try self.assertFormAssociated();
    return self.willValidate();
}

fn getValidity(self: *ElementInternals, frame: *Frame) !*ValidityState {
    try self.assertFormAssociated();
    if (self._validity) |v| {
        return v;
    }
    const v = try frame._factory.create(ValidityState{ ._owner = self.asElement() });
    self._validity = v;
    return v;
}

fn getValidationMessage(self: *const ElementInternals) ![]const u8 {
    try self.assertFormAssociated();
    if (!self.willValidate()) {
        return "";
    }
    return self._validation_message;
}

fn setValidity(self: *ElementInternals, flags_: ?ValidityFlags, message_: ?[]const u8, anchor_: ?*HtmlElement, frame: *Frame) !void {
    try self.assertFormAssociated();

    const flags = flags_ orelse ValidityFlags{};
    const message = message_ orelse "";
    if (flags.any() and message.len == 0) {
        return error.TypeError;
    }

    if (anchor_) |anchor| {
        // The anchor must be a shadow-including inclusive descendant of the host.
        if (!isShadowIncludingInclusiveDescendant(anchor.asNode(), self.asElement().asNode())) {
            return error.NotFound;
        }
    }

    self._flags = flags;
    self._validation_message = if (flags.any()) try normalizeNewlines(message, frame) else "";
}

fn isShadowIncludingInclusiveDescendant(node: *Node, ancestor: *Node) bool {
    var current: ?*Node = node;
    while (current) |n| {
        if (n == ancestor) {
            return true;
        }
        if (n._parent) |parent| {
            current = parent;
        } else if (n.is(ShadowRoot)) |shadow_root| {
            current = shadow_root.getHost().asNode();
        } else {
            return false;
        }
    }
    return false;
}

fn normalizeNewlines(message: []const u8, frame: *Frame) ![]const u8 {
    if (std.mem.indexOfScalar(u8, message, '\r') == null) {
        return frame.dupeString(message);
    }
    var out: std.ArrayList(u8) = try .initCapacity(frame.page_arena, message.len);
    var i: usize = 0;
    while (i < message.len) : (i += 1) {
        const c = message[i];
        if (c == '\r') {
            out.appendAssumeCapacity('\n');
            if (i + 1 < message.len and message[i + 1] == '\n') {
                i += 1;
            }
        } else {
            out.appendAssumeCapacity(c);
        }
    }
    return out.items;
}

fn checkValidity(self: *ElementInternals, frame: *Frame) !bool {
    try self.assertFormAssociated();
    return ValidityState.checkValidity(self.asElement(), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ElementInternals);

    pub const Meta = struct {
        pub const name = "ElementInternals";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const shadowRoot = bridge.accessor(ElementInternals.getShadowRoot, null, .{});
    pub const states = bridge.accessor(ElementInternals.getStates, null, .{});

    pub const setFormValue = bridge.function(ElementInternals.setFormValue, .{});
    pub const form = bridge.accessor(ElementInternals.getForm, null, .{});
    pub const labels = bridge.accessor(ElementInternals.getLabels, null, .{});
    pub const setValidity = bridge.function(ElementInternals.setValidity, .{});
    pub const willValidate = bridge.accessor(ElementInternals.getWillValidate, null, .{});
    pub const validity = bridge.accessor(ElementInternals.getValidity, null, .{});
    pub const validationMessage = bridge.accessor(ElementInternals.getValidationMessage, null, .{});
    pub const checkValidity = bridge.function(ElementInternals.checkValidity, .{});
    pub const reportValidity = bridge.function(ElementInternals.checkValidity, .{});

    // ARIAMixin
    pub const role = ariaAccessor("role");
    pub const ariaAtomic = ariaAccessor("aria-atomic");
    pub const ariaAutoComplete = ariaAccessor("aria-autocomplete");
    pub const ariaBrailleLabel = ariaAccessor("aria-braillelabel");
    pub const ariaBrailleRoleDescription = ariaAccessor("aria-brailleroledescription");
    pub const ariaBusy = ariaAccessor("aria-busy");
    pub const ariaChecked = ariaAccessor("aria-checked");
    pub const ariaColCount = ariaAccessor("aria-colcount");
    pub const ariaColIndex = ariaAccessor("aria-colindex");
    pub const ariaColIndexText = ariaAccessor("aria-colindextext");
    pub const ariaColSpan = ariaAccessor("aria-colspan");
    pub const ariaCurrent = ariaAccessor("aria-current");
    pub const ariaDescription = ariaAccessor("aria-description");
    pub const ariaDisabled = ariaAccessor("aria-disabled");
    pub const ariaExpanded = ariaAccessor("aria-expanded");
    pub const ariaHasPopup = ariaAccessor("aria-haspopup");
    pub const ariaHidden = ariaAccessor("aria-hidden");
    pub const ariaInvalid = ariaAccessor("aria-invalid");
    pub const ariaKeyShortcuts = ariaAccessor("aria-keyshortcuts");
    pub const ariaLabel = ariaAccessor("aria-label");
    pub const ariaLevel = ariaAccessor("aria-level");
    pub const ariaLive = ariaAccessor("aria-live");
    pub const ariaModal = ariaAccessor("aria-modal");
    pub const ariaMultiLine = ariaAccessor("aria-multiline");
    pub const ariaMultiSelectable = ariaAccessor("aria-multiselectable");
    pub const ariaOrientation = ariaAccessor("aria-orientation");
    pub const ariaPlaceholder = ariaAccessor("aria-placeholder");
    pub const ariaPosInSet = ariaAccessor("aria-posinset");
    pub const ariaPressed = ariaAccessor("aria-pressed");
    pub const ariaReadOnly = ariaAccessor("aria-readonly");
    pub const ariaRelevant = ariaAccessor("aria-relevant");
    pub const ariaRequired = ariaAccessor("aria-required");
    pub const ariaRoleDescription = ariaAccessor("aria-roledescription");
    pub const ariaRowCount = ariaAccessor("aria-rowcount");
    pub const ariaRowIndex = ariaAccessor("aria-rowindex");
    pub const ariaRowIndexText = ariaAccessor("aria-rowindextext");
    pub const ariaRowSpan = ariaAccessor("aria-rowspan");
    pub const ariaSelected = ariaAccessor("aria-selected");
    pub const ariaSetSize = ariaAccessor("aria-setsize");
    pub const ariaSort = ariaAccessor("aria-sort");
    pub const ariaValueMax = ariaAccessor("aria-valuemax");
    pub const ariaValueMin = ariaAccessor("aria-valuemin");
    pub const ariaValueNow = ariaAccessor("aria-valuenow");
    pub const ariaValueText = ariaAccessor("aria-valuetext");

    fn ariaAccessor(comptime attr: []const u8) js.bridge.Accessor {
        const R = struct {
            pub fn get(self: *const ElementInternals) ?[]const u8 {
                return self._aria.get(attr);
            }

            pub fn set(self: *ElementInternals, value_: ?[]const u8, frame: *Frame) !void {
                const value = value_ orelse {
                    _ = self._aria.remove(attr);
                    return;
                };
                try self._aria.put(frame.page_arena, attr, try frame.dupeString(value));
            }
        };
        return bridge.accessor(R.get, R.set, .{});
    }
};
