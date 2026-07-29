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

//! Shared machinery for the attribute-reflecting SVG list interfaces whose
//! items are live, ref-counted objects (SVGPointList, SVGTransformList):
//! attribute-snapshot sync, the retire/release item lifetime protocol, and
//! the DOM list operations. The concrete list supplies the item specifics
//! via `hooks` and re-exports the operations as decl aliases.
//!
//! StringList reflects an attribute too but is deliberately not built on
//! this: its items are plain slices (no ref counting, no attach/retire) and
//! its commit path is list-authoritative rather than reparse-based.
//!
//! `List` must carry the `_frame`, `_element`, `_read_only`, `_synced`,
//! `_snapshot`, `_items` and `_retired` fields. `hooks` must provide:
//!   attrName(*const List) String
//!   parse([]const u8, *Frame) !std.ArrayList(*Item)   (SyntaxError -> empty list)
//!   writeItem(*Item, *std.Io.Writer) !void
//!   prepareItem(*List, *Item, *Frame) !*Item
//!   attach(*List, *Item) void
//!   detachItem(*Item, *List) void
//!   releaseItem(*Item, *Page) void
//!
//! The operations keep a strict commit order: reserve list capacity, write
//! the attribute, then apply the infallible list update — so a failed
//! setAttribute never leaves the mirror out of step with the attribute.

const std = @import("std");

const Frame = @import("../../Frame.zig");
const Page = @import("../../Page.zig");

pub fn Mixin(comptime List: type, comptime Item: type, comptime hooks: anytype) type {
    return struct {
        pub fn deinit(self: *List, page: *Page) void {
            for (self._items.items) |item| {
                hooks.detachItem(item, self);
                hooks.releaseItem(item, page);
            }
            self._items.clearRetainingCapacity();
            releaseRetired(self, page);
        }

        pub fn getLength(self: *List, frame: *Frame) !u32 {
            try sync(self, frame);
            return @intCast(self._items.items.len);
        }

        pub fn getNumberOfItems(self: *List, frame: *Frame) !u32 {
            return getLength(self, frame);
        }

        pub fn clear(self: *List, frame: *Frame) !void {
            try requireMutable(self);
            try sync(self, frame);
            try retireAll(self, frame);
            try setAttribute(self, &.{}, frame);
        }

        pub fn initialize(self: *List, item: *Item, frame: *Frame) !*Item {
            try requireMutable(self);
            try sync(self, frame);

            const prepared = try hooks.prepareItem(self, item, frame);
            errdefer hooks.releaseItem(prepared, frame._page);

            try retireAll(self, frame);
            try self._items.ensureTotalCapacity(frame.arena, 1);
            try setAttribute(self, &.{prepared}, frame);
            self._items.appendAssumeCapacity(prepared);
            hooks.attach(self, prepared);
            return prepared;
        }

        pub fn getItem(self: *List, index: u32, frame: *Frame) !*Item {
            try sync(self, frame);
            if (index >= self._items.items.len) return error.IndexSizeError;
            return self._items.items[index];
        }

        pub fn insertItemBefore(self: *List, item: *Item, index: u32, frame: *Frame) !*Item {
            try requireMutable(self);
            try sync(self, frame);

            const prepared = try hooks.prepareItem(self, item, frame);
            errdefer hooks.releaseItem(prepared, frame._page);
            const at = @min(@as(usize, index), self._items.items.len);
            const next = try frame.local_arena.alloc(*Item, self._items.items.len + 1);
            @memcpy(next[0..at], self._items.items[0..at]);
            next[at] = prepared;
            @memcpy(next[at + 1 ..], self._items.items[at..]);

            try self._items.ensureUnusedCapacity(frame.arena, 1);
            try setAttribute(self, next, frame);
            self._items.insertAssumeCapacity(at, prepared);
            hooks.attach(self, prepared);
            return prepared;
        }

        pub fn replaceItem(self: *List, item: *Item, index: u32, frame: *Frame) !*Item {
            try requireMutable(self);
            try sync(self, frame);
            if (index >= self._items.items.len) return error.IndexSizeError;

            const prepared = try hooks.prepareItem(self, item, frame);
            errdefer hooks.releaseItem(prepared, frame._page);
            const next = try frame.local_arena.dupe(*Item, self._items.items);
            next[index] = prepared;

            try self._retired.ensureUnusedCapacity(frame.arena, 1);
            try setAttribute(self, next, frame);
            const replaced = self._items.items[index];
            hooks.detachItem(replaced, self);
            self._retired.appendAssumeCapacity(replaced);
            self._items.items[index] = prepared;
            hooks.attach(self, prepared);
            return prepared;
        }

        pub fn removeItem(self: *List, index: u32, frame: *Frame) !*Item {
            try requireMutable(self);
            try sync(self, frame);
            if (index >= self._items.items.len) return error.IndexSizeError;

            const next = try frame.local_arena.alloc(*Item, self._items.items.len - 1);
            @memcpy(next[0..index], self._items.items[0..index]);
            @memcpy(next[index..], self._items.items[index + 1 ..]);

            try self._retired.ensureUnusedCapacity(frame.arena, 1);
            try setAttribute(self, next, frame);
            const removed = self._items.orderedRemove(index);
            hooks.detachItem(removed, self);
            self._retired.appendAssumeCapacity(removed);
            return removed;
        }

        pub fn appendItem(self: *List, item: *Item, frame: *Frame) !*Item {
            return insertItemBefore(self, item, std.math.maxInt(u32), frame);
        }

        pub fn requireMutable(self: *const List) !void {
            if (self._read_only) return error.NoModificationAllowed;
        }

        pub fn sync(self: *List, frame: *Frame) !void {
            releaseRetired(self, frame._page);

            const raw = self._element.getAttributeSafe(hooks.attrName(self)) orelse "";
            if (self._synced and std.mem.eql(u8, self._snapshot.items, raw)) {
                return;
            }

            self._synced = false;
            var parsed = hooks.parse(raw, frame) catch |err| switch (err) {
                error.SyntaxError => std.ArrayList(*Item).empty,
                else => return err,
            };
            errdefer for (parsed.items) |item| hooks.releaseItem(item, frame._page);

            self._snapshot.clearRetainingCapacity();
            try self._snapshot.appendSlice(frame.arena, raw);
            try retireAll(self, frame);
            try self._items.ensureTotalCapacity(frame.arena, parsed.items.len);
            for (parsed.items) |item| {
                self._items.appendAssumeCapacity(item);
                hooks.attach(self, item);
            }
            parsed.clearRetainingCapacity();
            self._synced = true;
        }

        // A retired item must outlive the operation that retired it:
        // removeItem's return value has no JS wrapper until the bridge wraps
        // it after we return. By the next operation, anything still reachable
        // holds its own ref.
        pub fn releaseRetired(self: *List, page: *Page) void {
            for (self._retired.items) |item| {
                hooks.releaseItem(item, page);
            }
            self._retired.clearRetainingCapacity();
        }

        pub fn retireAll(self: *List, frame: *Frame) !void {
            self._synced = false;
            try self._retired.ensureUnusedCapacity(frame.arena, self._items.items.len);
            for (self._items.items) |item| {
                hooks.detachItem(item, self);
                self._retired.appendAssumeCapacity(item);
            }
            self._items.clearRetainingCapacity();
        }

        pub fn setAttribute(self: *List, items: []const *Item, frame: *Frame) !void {
            var serialized: std.Io.Writer.Allocating = .init(frame.local_arena);
            const writer = &serialized.writer;
            for (items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(' ');
                try hooks.writeItem(item, writer);
            }
            try commitAttribute(self, serialized.written(), frame);
        }

        pub fn commitAttribute(self: *List, serialized: []const u8, frame: *Frame) !void {
            self._synced = false;
            try self._element.setAttributeSafe(hooks.attrName(self), .wrap(serialized), frame);
            self._snapshot.clearRetainingCapacity();
            try self._snapshot.appendSlice(frame.arena, serialized);
            self._synced = true;
        }
    };
}
