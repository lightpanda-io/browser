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

//! Shape policy for extract results, shared by the script runtime, the
//! session baseline, and heal: how a result splits into top-level fields,
//! and what counts as empty. "" names the whole result of an array schema —
//! everywhere, including the wire (`dry_fields`, the verdict, baselines).

const std = @import("std");

/// One top-level field of a parsed extract result: an object yields an entry
/// per key, an array (an array schema's result) the single "" field. Slices
/// reference the parsed value.
pub const ExtractField = struct {
    field: []const u8,
    empty: bool,
};

/// One extract schema's top-level result field, tallied across a run. Counts
/// data presence — the same polarity as the persisted baseline lines.
pub const ExtractStat = struct {
    /// Schema JSON as the script wrote it.
    schema: []const u8,
    /// Top-level field of the result; "" when the schema itself is a list.
    field: []const u8,
    calls: u32,
    nonempty: u32,
};

/// Null for anything but valid JSON — extract output is best-effort telemetry
/// for every consumer; only OOM is an error.
pub fn parseJsonLenient(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}!?std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

pub fn classifyExtractFields(arena: std.mem.Allocator, result: std.json.Value) error{OutOfMemory}![]const ExtractField {
    switch (result) {
        .array => {
            const out = try arena.alloc(ExtractField, 1);
            out[0] = .{ .field = "", .empty = jsonIsEmpty(result) };
            return out;
        },
        .object => |obj| {
            const out = try arena.alloc(ExtractField, obj.count());
            var it = obj.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                out[i] = .{
                    .field = entry.key_ptr.*,
                    .empty = jsonIsEmpty(entry.value_ptr.*),
                };
            }
            return out;
        },
        else => return &.{},
    }
}

/// Null, "", and arrays/objects all of whose members are empty carry no data;
/// numbers and booleans always do (0 and false are answers).
pub fn jsonIsEmpty(value: std.json.Value) bool {
    switch (value) {
        .null => return true,
        .string => |s| return s.len == 0,
        .array => |a| return for (a.items) |item| {
            if (!jsonIsEmpty(item)) break false;
        } else true,
        .object => |o| {
            var it = o.iterator();
            return while (it.next()) |entry| {
                if (!jsonIsEmpty(entry.value_ptr.*)) break false;
            } else true;
        },
        else => return false,
    }
}
