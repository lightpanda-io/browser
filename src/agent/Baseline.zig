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

//! Session-scoped record of what the agent's extract calls actually returned.
//! `/save` persists it into the script as a `// lp:baseline {...}` comment —
//! evidence for the replay verdict turn, which reads it in the script source
//! to judge whether empty output is breakage or record-time-normal sparseness.
//! Nothing parses it programmatically; the model is the only consumer.

const std = @import("std");
const lp = @import("lightpanda");
const ScriptRuntime = lp.Runtime;

const Baseline = @This();

pub const marker = "// lp:baseline ";

pub const FieldStat = struct {
    calls: u32 = 0,
    nonempty: u32 = 0,
};

/// Keyed by top-level result field name; "" for a whole-array result.
pub const Fields = std.StringArrayHashMapUnmanaged(FieldStat);

arena: std.heap.ArenaAllocator,
/// Reused per `noteExtractResult` for the transient parse tree; keeps pages
/// warm on the every-tool-call path instead of an init/deinit pair each time.
scratch: std.heap.ArenaAllocator,
fields: Fields = .empty,

pub fn init(allocator: std.mem.Allocator) Baseline {
    return .{ .arena = .init(allocator), .scratch = .init(allocator) };
}

pub fn deinit(self: *Baseline) void {
    self.arena.deinit();
    self.scratch.deinit();
}

pub fn reset(self: *Baseline) void {
    self.fields = .empty;
    _ = self.arena.reset(.retain_capacity);
}

/// Tally one successful extract result (the tool's JSON output). Malformed
/// output records nothing — this is best-effort telemetry.
pub fn noteExtractResult(self: *Baseline, result_text: []const u8) error{OutOfMemory}!void {
    _ = self.scratch.reset(.retain_capacity);
    const scratch = self.scratch.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch, result_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    for (try ScriptRuntime.classifyExtractFields(scratch, parsed)) |fc| {
        try self.bump(fc.field orelse "", !fc.empty);
    }
}

fn bump(self: *Baseline, field: []const u8, nonempty: bool) error{OutOfMemory}!void {
    const arena = self.arena.allocator();
    const gop = try self.fields.getOrPut(arena, field);
    if (!gop.found_existing) {
        // The probe key may live in caller scratch; own it.
        gop.key_ptr.* = try arena.dupe(u8, field);
        gop.value_ptr.* = .{};
    }
    gop.value_ptr.calls += 1;
    if (nonempty) gop.value_ptr.nonempty += 1;
}

/// The session's baseline as a full `// lp:baseline {...}` line, or null when
/// no extract ran.
pub fn serialize(self: *const Baseline, arena: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
    return fieldsToLine(arena, &self.fields);
}

/// Baseline line from a script run's extract stats (per-field totals folded
/// across schemas), for refreshing a healed script from its validation run.
pub fn serializeStats(arena: std.mem.Allocator, stats: []const ScriptRuntime.ExtractStat) error{OutOfMemory}!?[]const u8 {
    var fields: Fields = .empty;
    for (stats) |stat| {
        const gop = try fields.getOrPut(arena, stat.field orelse "");
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.calls += stat.calls;
        gop.value_ptr.nonempty += stat.calls - stat.empty;
    }
    return fieldsToLine(arena, &fields);
}

fn fieldsToLine(arena: std.mem.Allocator, fields: *const Fields) error{OutOfMemory}!?[]const u8 {
    if (fields.count() == 0) return null;
    var fields_obj: std.json.ObjectMap = .init(arena);
    var it = fields.iterator();
    while (it.next()) |entry| {
        var stat_obj: std.json.ObjectMap = .init(arena);
        try stat_obj.put("calls", .{ .integer = entry.value_ptr.calls });
        try stat_obj.put("nonempty", .{ .integer = entry.value_ptr.nonempty });
        try fields_obj.put(entry.key_ptr.*, .{ .object = stat_obj });
    }
    var root: std.json.ObjectMap = .init(arena);
    try root.put("fields", .{ .object = fields_obj });
    const json = try std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = root }, .{});
    return try std.mem.concat(arena, u8, &.{ marker, json });
}

/// `script` with any existing baseline lines dropped and `line` (a full
/// baseline line, or null) appended — synthesis may have copied a stale
/// baseline from the previous script verbatim.
pub fn withBaseline(arena: std.mem.Allocator, script: []const u8, line: ?[]const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var lines = std.mem.splitScalar(u8, script, '\n');
    var pending_newline = false;
    while (lines.next()) |script_line| {
        if (std.mem.startsWith(u8, std.mem.trim(u8, script_line, " \t\r"), marker)) continue;
        if (pending_newline) try aw.writer.writeByte('\n');
        try aw.writer.writeAll(script_line);
        pending_newline = true;
    }
    if (line) |l| {
        // A split of "a\nb\n" ends with an empty segment, so the writer is
        // already newline-terminated in the common case.
        if (aw.written().len != 0 and aw.written()[aw.written().len - 1] != '\n') {
            try aw.writer.writeByte('\n');
        }
        try aw.writer.writeAll(l);
        try aw.writer.writeByte('\n');
    }
    return aw.written();
}

test "baseline: note and serialize tally per-field data presence" {
    var baseline: Baseline = .init(std.testing.allocator);
    defer baseline.deinit();

    try baseline.noteExtractResult("{\"stories\":[{\"title\":\"a\"}],\"empty_list\":[],\"scalar\":\"x\"}");
    try baseline.noteExtractResult("{\"stories\":[],\"empty_list\":[]}");
    // Malformed results record nothing.
    try baseline.noteExtractResult("not json");

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const line = (try baseline.serialize(arena.allocator())).?;
    try std.testing.expectEqualStrings(
        marker ++ "{\"fields\":{\"stories\":{\"calls\":2,\"nonempty\":1},\"empty_list\":{\"calls\":2,\"nonempty\":0},\"scalar\":{\"calls\":1,\"nonempty\":1}}}",
        line,
    );
}

test "baseline: withBaseline strips stale lines and appends" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const script = "const x = 1;\n// lp:baseline {\"fields\":{}}\nreturn x;\n";
    const out = try withBaseline(aa, script, marker ++ "{\"fields\":{\"a\":{\"calls\":1,\"nonempty\":1}}}");
    try std.testing.expectEqualStrings(
        "const x = 1;\nreturn x;\n" ++ marker ++ "{\"fields\":{\"a\":{\"calls\":1,\"nonempty\":1}}}\n",
        out,
    );

    const stripped = try withBaseline(aa, script, null);
    try std.testing.expectEqualStrings("const x = 1;\nreturn x;\n", stripped);
}
