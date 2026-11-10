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

// Invalidation events. Every change that can make a cached read stale (live
// collections, the StyleManager memo, the layout observers) is reported here,
// saying what happened, and only here are the versions bumped. Each event
// still does a full bump through the primitives at the bottom (domChanged,
// styleChanged, ...); the arguments are what a narrower invalidation needs.
//
// Tree events fire from the leaves (Frame.removeNode, Frame._insertNodeRelative)
// right after the link/unlink and before anything that can run script, so
// script never reads a cache built before the mutation.

const lp = @import("lightpanda");

const Frame = @import("../Frame.zig");
const observers = @import("observers.zig");

const Node = @import("../webapi/Node.zig");
const CData = @import("../webapi/CData.zig");
const Element = @import("../webapi/Element.zig");

const String = lp.String;

pub fn attributeSet(element: *Element, name: String, old: ?String, new: String, frame: *Frame) void {
    _ = element;
    _ = name;
    _ = old;
    _ = new;
    domChanged(frame);
}

/// A style attribute write no selector can see (see Attribute.List.putInertStyle).
pub fn inertStyleSet(element: *Element, frame: *Frame) void {
    _ = element;
    layoutObserversChanged(frame);
}

pub fn attributeRemoved(element: *Element, name: String, old: String, frame: *Frame) void {
    _ = element;
    _ = name;
    _ = old;
    domChanged(frame);
}

pub fn childInserted(parent: *Node, child: *Node, frame: *Frame) void {
    _ = parent;
    _ = child;
    domChanged(frame);
}

pub fn childRemoved(parent: *Node, child: *Node, previous_sibling: ?*Node, next_sibling: ?*Node, frame: *Frame) void {
    _ = parent;
    _ = child;
    _ = previous_sibling;
    _ = next_sibling;
    domChanged(frame);
}

/// Not domChanged: live collections keep their cursors mid-parse, and the
/// parser's root memo stays valid (an insertion never changes an existing
/// node's root).
pub fn parserInserted(parent: *Node, child: *Node, frame: *Frame) void {
    _ = parent;
    _ = child;
    styleChanged(frame);
}

/// A fragment parse into `parent` finished (Frame.parse.fragment). Its
/// insertions went through parserInserted and the html5ever wrapper unwrap
/// relinks children outside the leaves, so the tree change is stamped here.
/// Matters when `parent` is live (innerHTML); a detached fragment's caller
/// inserts through the leaves anyway.
pub fn fragmentParsed(parent: *Node, frame: *Frame) void {
    _ = parent;
    domChanged(frame);
}

/// Text data can flip `:empty` but never a live collection, so only the style
/// stamp moves. Not renderingChanged: the layout observers only react to
/// connectivity, which a text edit can't change.
pub fn textChanged(cdata: *CData, old: String, frame: *Frame) void {
    _ = cdata;
    _ = old;
    styleChanged(frame);
}

pub const State = enum {
    // :placeholder-shown, :invalid, ...
    value,
    checked,
    indeterminate,
    defined,
    // These bump dom_version too: selectedOptions is a live collection, and
    // both move boxes, so the layout observers look.
    selectedness,
    popover_open,
};

pub fn stateChanged(element: *Element, state: State, frame: *Frame) void {
    _ = element;
    switch (state) {
        .value, .checked, .indeterminate, .defined => styleChanged(frame),
        .selectedness, .popover_open => domChanged(frame),
    }
}

pub fn focusChanged(old: ?*Element, new: ?*Element, frame: *Frame) void {
    _ = old;
    _ = new;
    styleChanged(frame);
}

pub const DocumentState = enum {
    // :read-write
    design_mode,
    // :target, from the URL's fragment
    target,
};

pub fn documentStateChanged(state: DocumentState, frame: *Frame) void {
    _ = state;
    styleChanged(frame);
}

/// The cascade's rules changed: a sheet was added, removed, edited or
/// rebuilt. An observed size can change without any element changing.
pub fn rulesChanged(frame: *Frame) void {
    styleChanged(frame);
    observers.scheduleResizeDelivery(frame);
}

/// The host's children leave the flat tree until a slot takes them.
pub fn shadowAttached(host: *Element, frame: *Frame) void {
    _ = host;
    renderingChanged(frame);
}

/// A slotted node inherits from its slot.
pub fn slotAssignmentChanged(slot: *Element.Html.Slot, frame: *Frame) void {
    _ = slot;
    renderingChanged(frame);
}

// The primitives.

fn domChanged(frame: *Frame) void {
    frame.page.dom_version += 1;
    renderingChanged(frame);
}

/// A style change that is also our "rendering opportunity": re-evaluate the
/// layout observers. Both are no-ops unless something they track changed.
fn renderingChanged(frame: *Frame) void {
    styleChanged(frame);
    layoutObserversChanged(frame);
}

/// A change that can move a box without changing any selector match or
/// cascaded value, like an inline transform: only the layout observers look.
fn layoutObserversChanged(frame: *Frame) void {
    observers.scheduleIntersectionChecks(frame);
    observers.scheduleResizeChecks(frame);
}

/// Stamps the cascade: any change that can alter a selector match or cascade
/// result, including non-tree state that live collections never see.
fn styleChanged(frame: *Frame) void {
    frame.page.style_version += 1;
}
