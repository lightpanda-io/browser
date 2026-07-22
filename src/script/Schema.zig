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

//! Cached, schema-extracted view of a single browser tool. Per-tool
//! semantics (record / heal / locator / data) live on `BrowserTool`.
//! `Schema.all()` is the lazy process-wide cache.

const std = @import("std");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;
const string = @import("../string.zig");

const Schema = @This();

tool: BrowserTool,
tool_name: []const u8,
description: []const u8,
summary: []const u8,
required: []const []const u8,
/// Selector-first positional fields, shared by the marshaller and recorder so the
/// two can't drift. Empty for tools with no positional argument.
positional: []const []const u8,
fields: []const FieldEntry,
hints: []const HintSlot,
parameters: std.json.Value,

pub const FieldType = enum { string, integer, number, boolean, other };

pub const FieldEntry = struct {
    name: []const u8,
    field_type: FieldType,
    /// Used by `Command.format` to omit `checked=true` when emitting `/setChecked`.
    default_true: bool = false,
    /// Allowed values when the schema constrains the field with `enum`; empty
    /// otherwise. The REPL completer/hinter offers these as value suggestions.
    enum_values: []const []const u8 = &.{},
    /// The schema's per-parameter `description` string; empty when absent.
    description: []const u8 = "",

    /// `backendNodeId` is ephemeral, never replayable. Boolean fields
    /// matching the schema default are cosmetic noise.
    pub fn skipForFormat(self: FieldEntry, v: std.json.Value) bool {
        if (std.mem.eql(u8, self.name, "backendNodeId")) return true;
        return v == .bool and v.bool and self.default_true;
    }
};

/// REPL argument-syntax hint slot. `fragment` is pre-rendered as `<name>`
/// for required and `[name=…]` for optional.
pub const HintSlot = struct {
    name: []const u8,
    required: bool,
    fragment: []const u8,
};

/// Asserted at schema build time so adding a tool with more fields fails loud.
pub const max_hint_slots: usize = 16;

pub const ParseError = error{
    MissingName,
    UnknownTool,
    UnknownField,
    MissingRequired,
    DuplicateField,
    MalformedKv,
    PositionalNotAllowed,
    PositionalMustComeFirst,
    UnterminatedQuote,
    UnsupportedEscape,
    InvalidValue,
    OutOfMemory,
};

pub const Split = struct {
    name: []const u8,
    rest: []const u8,
};

/// Populated by `parseValueDiag` on `InvalidValue` so callers can surface
/// the offending field/type/value to the user.
pub const Diag = struct {
    bad_field: []const u8 = "",
    expected_type: FieldType = .other,
    bad_value: []const u8 = "",
};

/// Selector-first positional order for a tool's script builtin — the source of
/// truth `marshalArgs` and the recorder both read.
pub fn positionalFor(tool: BrowserTool) []const []const u8 {
    return switch (tool) {
        .goto => &.{"url"},
        .evaluate, .waitForScript => &.{"script"},
        .waitForSelector, .click, .hover => &.{"selector"},
        .waitForState => &.{"state"},
        .fill, .selectOption => &.{ "selector", "value" },
        .setChecked => &.{ "selector", "checked" },
        .press => &.{ "selector", "key" },
        // Only the recorder reads this; the runtime marshals extract separately.
        .extract => &.{"schema"},
        else => &.{},
    };
}

pub fn findField(self: Schema, key: []const u8) ?FieldEntry {
    for (self.fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, key)) return f;
    }
    return null;
}

/// Rename keys in `obj` to canonical casing. Unknown keys pass through;
/// keys that collide on the canonical form return `error.DuplicateField`.
pub fn normalizeKeys(self: Schema, arena: std.mem.Allocator, obj: *std.json.ObjectMap) !void {
    const Rename = struct { from: []const u8, to: []const u8 };
    var renames: std.ArrayList(Rename) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const field = self.findField(entry.key_ptr.*) orelse continue;
        if (!std.mem.eql(u8, field.name, entry.key_ptr.*)) {
            if (obj.contains(field.name)) return error.DuplicateField;
            for (renames.items) |r| {
                if (std.mem.eql(u8, r.to, field.name)) return error.DuplicateField;
            }
            try renames.append(arena, .{ .from = entry.key_ptr.*, .to = field.name });
        }
    }
    for (renames.items) |r| {
        const kv = obj.fetchSwapRemove(r.from) orelse continue;
        try obj.put(arena, r.to, kv.value);
    }
}

fn fieldType(self: Schema, key: []const u8) FieldType {
    if (self.findField(key)) |f| return f.field_type;
    return .other;
}

fn isFieldDefaultTrue(self: Schema, key: []const u8) bool {
    if (self.findField(key)) |f| return f.default_true;
    return false;
}

/// `backendNodeId` is ephemeral, never replayable. Boolean fields
/// matching the schema default are cosmetic noise.
pub fn skipForFormat(self: Schema, key: []const u8, v: std.json.Value) bool {
    if (self.findField(key)) |f| return f.skipForFormat(v);
    return std.mem.eql(u8, key, "backendNodeId");
}

pub fn visibleArgCount(self: Schema, args: std.json.ObjectMap) usize {
    var n: usize = 0;
    for (self.fields) |f| {
        const v = args.get(f.name) orelse continue;
        if (f.skipForFormat(v)) continue;
        n += 1;
    }
    return n;
}

/// True when a recorded call renders as bare `tool(value)` rather than the object
/// form: the lone required field is the tool's leading positional, the only visible
/// arg, and a string. False for press/fill/selectOption — their required field sits
/// behind `selector`, so they round-trip via the object form.
pub fn isBarePositional(self: Schema, args: std.json.ObjectMap) bool {
    if (self.required.len != 1 or self.positional.len == 0) return false;
    if (!std.mem.eql(u8, self.required[0], self.positional[0])) return false;
    if (self.visibleArgCount(args) != 1) return false;
    const v = args.get(self.required[0]) orelse return false;
    return v == .string;
}

/// The field a single leading positional binds to: the lone required field,
/// or — when nothing is required — the tool's only field (e.g. getEnv binds to
/// `name`). Null when there's no required field and more than one optional
/// field, since the target would be ambiguous (click's selector/backendNodeId).
pub fn leadingPositionalField(self: Schema) ?[]const u8 {
    if (self.required.len == 1) return self.required[0];
    if (self.required.len == 0 and self.fields.len == 1) return self.fields[0].name;
    return null;
}

/// Parse `rest` (args portion of a slash command) into a `std.json.Value`.
/// Returns null when the schema takes no args and `rest` is empty.
///
/// Argument-binding rules:
///   - Bare `{json}` payload returned as-is.
///   - Single leading positional binds to `required[0]` when there's
///     exactly one required. Otherwise positionals error.
///   - Everything else is `key=value` with type coercion.
pub fn parseValue(self: Schema, arena: std.mem.Allocator, rest: []const u8) ParseError!?std.json.Value {
    return self.parseValueDiag(arena, rest, null);
}

/// Same as `parseValue` but populates `diag` on `error.InvalidValue` so
/// callers can render a user-facing message like
/// "y: expected integer, got 'fast'".
pub fn parseValueDiag(self: Schema, arena: std.mem.Allocator, rest_raw: []const u8, diag: ?*Diag) ParseError!?std.json.Value {
    const rest = std.mem.trim(u8, rest_raw, &std.ascii.whitespace);
    if (rest.len == 0) {
        if (self.required.len > 0) return error.MissingRequired;
        return null;
    }

    if (rest[0] == '{') {
        var parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, rest, .{}) catch return error.MalformedKv;
        // Same validation the kv path applies: reject unknown keys and
        // fill default-true required fields when omitted.
        if (parsed != .object) return error.MalformedKv;
        try self.validateAndFillObject(arena, &parsed.object);
        return parsed;
    }

    const tokens = try tokenize(arena, rest);

    const leading_positional = tokens.len >= 1 and !looksLikeKv(tokens[0]);
    const positional_field = self.leadingPositionalField();
    if (leading_positional and positional_field == null) return error.PositionalNotAllowed;

    var list = try std.ArrayList(KvPair).initCapacity(arena, tokens.len + self.required.len);
    const kv_start: usize = if (leading_positional) 1 else 0;
    if (leading_positional) {
        list.appendAssumeCapacity(.{ .key = positional_field.?, .value = stripQuotes(tokens[0]) });
    }
    for (tokens[kv_start..]) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse {
            // `/extract save=x '{…}'` — the value would have bound fine as a
            // leading positional, so point at the ordering instead of the
            // generic kv complaint.
            if (positional_field != null and !leading_positional) return error.PositionalMustComeFirst;
            return error.MalformedKv;
        };
        if (eq == 0 or eq == tok.len - 1) return error.MalformedKv;
        const key = tok[0..eq];
        // Reject typos like `checke=false` that would otherwise be silently
        // absorbed while the actual required field gets default-filled.
        const field = self.findField(key) orelse return error.UnknownField;
        list.appendAssumeCapacity(.{ .key = field.name, .value = stripQuotes(tok[eq + 1 ..]) });
    }

    // Default-true booleans (e.g. setChecked.checked) so `/setChecked
    // selector='#a'` works without `checked=true`.
    required: for (self.required) |req| {
        for (list.items) |p| if (std.mem.eql(u8, p.key, req)) continue :required;
        if (!self.isFieldDefaultTrue(req)) return error.MissingRequired;
        list.appendAssumeCapacity(.{ .key = req, .value = "true" });
    }

    return try self.buildValue(arena, list.items, diag);
}

fn validateAndFillObject(self: Schema, arena: std.mem.Allocator, obj: *std.json.ObjectMap) ParseError!void {
    // Stricter than the LLM path: an unknown field is a user typo, not noise to drop.
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (self.findField(entry.key_ptr.*) == null) return error.UnknownField;
    }
    try self.normalizeKeys(arena, obj);
    for (self.required) |req| {
        if (obj.contains(req)) continue;
        if (!self.isFieldDefaultTrue(req)) return error.MissingRequired;
        try obj.put(arena, req, .{ .bool = true });
    }
}

const KvPair = struct {
    key: []const u8,
    value: []const u8,
};

fn buildValue(self: Schema, arena: std.mem.Allocator, pairs: []const KvPair, diag: ?*Diag) ParseError!std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.ensureTotalCapacity(arena, pairs.len);
    for (pairs) |p| {
        const v = try self.coerce(arena, p.key, p.value, diag);
        const gop = try obj.getOrPut(arena, p.key);
        if (gop.found_existing) return error.DuplicateField;
        gop.value_ptr.* = v;
    }
    return .{ .object = obj };
}

fn coerce(self: Schema, arena: std.mem.Allocator, key: []const u8, value: []const u8, diag: ?*Diag) ParseError!std.json.Value {
    const ft = self.fieldType(key);
    switch (ft) {
        .integer => {
            if (std.fmt.parseInt(i64, value, 10)) |n| return .{ .integer = n } else |_| {
                if (diag) |d| d.* = .{ .bad_field = key, .expected_type = ft, .bad_value = value };
                return error.InvalidValue;
            }
        },
        .number => {
            if (std.fmt.parseFloat(f64, value)) |n| return .{ .float = n } else |_| {
                if (diag) |d| d.* = .{ .bad_field = key, .expected_type = ft, .bad_value = value };
                return error.InvalidValue;
            }
        },
        .boolean => {
            if (std.mem.eql(u8, value, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, value, "false")) return .{ .bool = false };
            if (diag) |d| d.* = .{ .bad_field = key, .expected_type = ft, .bad_value = value };
            return error.InvalidValue;
        },
        else => {},
    }
    return .{ .string = try arena.dupe(u8, value) };
}

/// Split a slash-command body into `<name> <rest>`. Null on empty input.
pub fn splitNameRest(input: []const u8) ?Split {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const name_end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
    return .{
        .name = trimmed[0..name_end],
        .rest = std.mem.trimStart(u8, trimmed[name_end..], &std.ascii.whitespace),
    };
}

/// Parse input as a slash command, rejecting leading whitespace or spaces after '/'.
pub fn parseSlashCommand(input: []const u8) ?Split {
    if (input.len < 2 or input[0] != '/' or std.ascii.isWhitespace(input[1])) return null;
    return splitNameRest(input[1..]);
}

fn find(schemas: []const Schema, name: []const u8) ?*const Schema {
    if (std.meta.stringToEnum(BrowserTool, name)) |tool| {
        const idx = @intFromEnum(tool);
        if (idx < schemas.len) return &schemas[idx];
    }
    for (schemas) |*s| {
        if (std.ascii.eqlIgnoreCase(s.tool_name, name)) return s;
    }
    return null;
}

pub fn findByName(name: []const u8) ?*const Schema {
    return find(all(), name);
}

/// Lazy process-wide cache, keyed by `@intFromEnum(BrowserTool)`.
/// Panics on init failure — `tool_defs` is comptime-constant, so any
/// parse/build error is a build-time bug.
pub fn all() []const Schema {
    global_once.call();
    return global_storage[0..browser_tools.tool_defs.len];
}

var global_storage: [browser_tools.tool_defs.len]Schema = undefined;
var global_arena: std.heap.ArenaAllocator = undefined;
var global_once = lp.once(initGlobal);

fn initGlobal() void {
    global_arena = .init(std.heap.page_allocator);
    const a = global_arena.allocator();
    for (browser_tools.tool_defs, 0..) |td, i| {
        const tool: BrowserTool = @enumFromInt(i);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, td.input_schema, .{}) catch |err| {
            std.debug.panic("failed to parse schema for tool '{s}': {s}", .{ @tagName(tool), @errorName(err) });
        };
        global_storage[i] = buildOne(a, tool, td, parsed) catch |err| {
            std.debug.panic("failed to build schema for tool '{s}': {s}", .{ @tagName(tool), @errorName(err) });
        };
    }
}

fn buildOne(arena: std.mem.Allocator, tool: BrowserTool, td: BrowserTool.Definition, parsed: std.json.Value) !Schema {
    var info: Schema = .{
        .tool = tool,
        .tool_name = @tagName(tool),
        .description = td.description,
        .summary = td.summary,
        .required = &.{},
        .positional = positionalFor(tool),
        .fields = &.{},
        .hints = &.{},
        .parameters = parsed,
    };

    if (parsed != .object) return info;

    if (parsed.object.get("required")) |req| {
        info.required = try jsonStringArray(arena, req);
    }

    if (parsed.object.get("properties")) |props| {
        if (props == .object) {
            const map = props.object;
            const fields = try arena.alloc(FieldEntry, map.count());
            var it = map.iterator();
            for (fields) |*f| {
                const entry = it.next().?;
                f.* = .{
                    .name = entry.key_ptr.*,
                    .field_type = fieldTypeOf(entry.value_ptr.*),
                    .default_true = booleanDefaultTrue(entry.value_ptr.*),
                    .enum_values = try enumValuesOf(arena, entry.value_ptr.*),
                    .description = descriptionOf(entry.value_ptr.*),
                };
            }
            info.fields = fields;
        }
    }

    info.hints = try buildHints(arena, info.required, info.fields);
    std.debug.assert(info.hints.len <= max_hint_slots);

    return info;
}

fn buildHints(arena: std.mem.Allocator, required: []const []const u8, fields: []const FieldEntry) ![]const HintSlot {
    if (fields.len == 0 and required.len == 0) return &.{};
    var optional_count: usize = 0;
    for (fields) |f| {
        if (!string.isOneOf(f.name, required)) optional_count += 1;
    }
    const out = try arena.alloc(HintSlot, required.len + optional_count);
    var idx: usize = 0;
    defer std.debug.assert(idx == out.len);
    for (required) |name| {
        out[idx] = .{
            .name = name,
            .required = true,
            .fragment = try std.fmt.allocPrint(arena, "<{s}>", .{name}),
        };
        idx += 1;
    }
    for (fields) |f| {
        if (string.isOneOf(f.name, required)) continue;
        out[idx] = .{
            .name = f.name,
            .required = false,
            .fragment = try std.fmt.allocPrint(arena, "[{s}=…]", .{f.name}),
        };
        idx += 1;
    }
    return out;
}

fn fieldTypeOf(value: std.json.Value) FieldType {
    if (value != .object) return .other;
    const ty = value.object.get("type") orelse return .other;
    if (ty != .string) return .other;
    return std.meta.stringToEnum(FieldType, ty.string) orelse .other;
}

fn booleanDefaultTrue(value: std.json.Value) bool {
    if (value != .object) return false;
    const d = value.object.get("default") orelse return false;
    return d == .bool and d.bool;
}

fn descriptionOf(value: std.json.Value) []const u8 {
    if (value != .object) return "";
    const d = value.object.get("description") orelse return "";
    if (d != .string) return "";
    return d.string;
}

fn enumValuesOf(arena: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .object) return &.{};
    return jsonStringArray(arena, value.object.get("enum") orelse return &.{});
}

/// Collect a JSON array's string items into an arena-owned slice. Non-string
/// items are skipped; a non-array yields an empty slice.
fn jsonStringArray(arena: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    try out.ensureTotalCapacity(arena, value.array.items.len);
    for (value.array.items) |item| {
        if (item != .string) continue;
        out.appendAssumeCapacity(item.string);
    }
    return out.toOwnedSlice(arena);
}

/// Tokenize on whitespace. `"…"` and `'…'` (single or triple) are kept
/// whole; quote stripping happens later. Tokens may contain `=`.
fn tokenize(arena: std.mem.Allocator, input: []const u8) ParseError![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and std.ascii.isWhitespace(input[i])) i += 1;
        if (i >= input.len) break;

        const tok_start = i;
        while (i < input.len and !std.ascii.isWhitespace(input[i])) : (i += 1) {
            const ch = input[i];
            if (ch == '"' or ch == '\'') {
                const is_triple = i + 2 < input.len and input[i + 1] == ch and input[i + 2] == ch;
                if (is_triple) {
                    const triple_delim = input[i .. i + 3];
                    const close = std.mem.indexOfPos(u8, input, i + 3, triple_delim) orelse return error.UnterminatedQuote;
                    i = close + 2;
                } else {
                    // Odd run of `\` before the closer = escape attempt; even = literal.
                    var j = i + 1;
                    var pending_bs: usize = 0;
                    while (j < input.len) : (j += 1) {
                        if (input[j] == '\\') {
                            pending_bs += 1;
                            continue;
                        }
                        if (input[j] == ch) {
                            if (pending_bs % 2 == 1) return error.UnsupportedEscape;
                            break;
                        }
                        pending_bs = 0;
                    } else return error.UnterminatedQuote;
                    i = j;
                }
            }
        }
        try out.append(arena, input[tok_start..i]);
    }

    return try out.toOwnedSlice(arena);
}

fn stripQuotes(raw: []const u8) []const u8 {
    if (raw.len >= 6) {
        if (std.mem.startsWith(u8, raw, "'''") and std.mem.endsWith(u8, raw, "'''")) {
            return raw[3 .. raw.len - 3];
        }
        if (std.mem.startsWith(u8, raw, "\"\"\"") and std.mem.endsWith(u8, raw, "\"\"\"")) {
            return raw[3 .. raw.len - 3];
        }
    }
    if (raw.len >= 2) {
        const first = raw[0];
        const last = raw[raw.len - 1];
        if ((first == '\'' and last == '\'') or (first == '"' and last == '"')) {
            return raw[1 .. raw.len - 1];
        }
    }
    return raw;
}

/// True for unquoted `<identifier>=<value>` tokens. Quoted positionals
/// and URLs containing `=` fall through.
fn looksLikeKv(tok: []const u8) bool {
    if (tok.len == 0) return false;
    if (tok[0] == '\'' or tok[0] == '"') return false;
    const end = std.mem.indexOfAny(u8, tok, "'\"") orelse tok.len;
    const eq = std.mem.indexOfScalar(u8, tok[0..end], '=') orelse return false;
    if (eq == 0) return false;
    if (!std.ascii.isAlphabetic(tok[0]) and tok[0] != '_') return false;
    for (tok[1..eq]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// True when `input` opens a `'''` or `"""` block that hasn't been closed
/// yet. The REPL hinter/completer call this to silence arg ghost-text once
/// the user is typing inside a multi-line body.
pub fn hasUnclosedTripleQuote(input: []const u8) bool {
    var i: usize = 0;
    var open: ?u8 = null;
    while (i + 3 <= input.len) {
        const c0 = input[i];
        if ((c0 == '\'' or c0 == '"') and input[i + 1] == c0 and input[i + 2] == c0) {
            if (open) |q| {
                if (q == c0) open = null;
            } else {
                open = c0;
            }
            i += 3;
            continue;
        }
        i += 1;
    }
    return open != null;
}

/// End of the quoted run opening at `input[start]`, for the REPL's slash-arg
/// highlighting: recognizes this grammar's `'''…'''` triple delimiter
/// alongside plain quotes, mirroring `tokenize`'s quoting. Escapes are not
/// honored (`tokenize` rejects them); an unterminated run extends to the end.
pub fn quotedSpanEnd(input: []const u8, start: usize) usize {
    const ch = input[start];
    if (start + 2 < input.len and input[start + 1] == ch and input[start + 2] == ch) {
        const close = std.mem.indexOfPos(u8, input, start + 3, input[start .. start + 3]) orelse
            return input.len;
        return close + 3;
    }
    const close = std.mem.indexOfScalarPos(u8, input, start + 1, ch) orelse return input.len;
    return close + 1;
}

/// `body=true`: string is emitted as a `'''…'''` block (newlines OK).
/// `body=false`: single-line kv quoting (no newlines representable).
pub fn quotableInline(s: []const u8, body: bool) bool {
    const has_triple_single = std.mem.indexOf(u8, s, "'''") != null;
    const has_triple_double = std.mem.indexOf(u8, s, "\"\"\"") != null;
    if (body) return !(has_triple_single and has_triple_double);
    if (std.mem.indexOfScalar(u8, s, '\n') != null) return false;
    const has_single = std.mem.indexOfScalar(u8, s, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, s, '"') != null;
    if (has_single and has_double) return !(has_triple_single and has_triple_double);
    return true;
}

const testing = @import("../testing.zig");

test "all: comptime tool defs reduce cleanly" {
    const schemas = Schema.all();
    try testing.expect(schemas.len == browser_tools.tool_defs.len);
    const goto = Schema.find(schemas, "goto").?;
    try testing.expect(goto.tool.isRecorded());
    const scroll = Schema.find(schemas, "scroll").?;
    try testing.expect(scroll.tool.isRecorded());
    const tree = Schema.find(schemas, "tree").?;
    try testing.expect(!tree.tool.isRecorded());
    try testing.expect(tree.tool.producesData());
    const set_checked = Schema.find(schemas, "setChecked").?;
    var checked_default_true = false;
    for (set_checked.fields) |f| {
        if (std.mem.eql(u8, f.name, "checked")) checked_default_true = f.default_true;
    }
    try testing.expect(checked_default_true);
    const timeout = goto.findField("timeout").?;
    try testing.expect(timeout.description.len > 0);
}

test "parseValue: single-required positional binds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const goto = Schema.find(Schema.all(), "goto").?;
    const v = (try goto.parseValue(arena.allocator(), "https://example.com")).?;
    try testing.expectString("https://example.com", v.object.get("url").?.string);
}

test "parseValue: positional then kv tail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const goto = Schema.find(Schema.all(), "goto").?;
    const v = (try goto.parseValue(arena.allocator(), "https://example.com timeout=5000")).?;
    try testing.expectString("https://example.com", v.object.get("url").?.string);
    try testing.expectEqual(@as(i64, 5000), v.object.get("timeout").?.integer);
}

test "parseValue: unquoted URL with `=` in query string binds positional" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const goto = Schema.find(Schema.all(), "goto").?;
    const v = (try goto.parseValue(arena.allocator(), "https://example.com/?id=42")).?;
    try testing.expectString("https://example.com/?id=42", v.object.get("url").?.string);
}

test "parseValue: kv-only multi-required" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fill = Schema.find(Schema.all(), "fill").?;
    const v = (try fill.parseValue(arena.allocator(), "selector='#email' value='foo@x.com'")).?;
    try testing.expectString("#email", v.object.get("selector").?.string);
    try testing.expectString("foo@x.com", v.object.get("value").?.string);
}

test "parseValue: kv-only zero-required" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scroll = Schema.find(Schema.all(), "scroll").?;
    const v = (try scroll.parseValue(arena.allocator(), "y=200")).?;
    try testing.expectEqual(@as(i64, 200), v.object.get("y").?.integer);
}

test "parseValue: missing required errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const goto = Schema.find(Schema.all(), "goto").?;
    try testing.expectError(error.MissingRequired, goto.parseValue(arena.allocator(), ""));
}

test "parseValue: positional with zero-required schema errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const find_el = Schema.find(Schema.all(), "findElement").?;
    try testing.expectError(error.PositionalNotAllowed, find_el.parseValue(arena.allocator(), "button"));
}

test "parseValue: unknown field is rejected, not absorbed into default-true fill" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const set_checked = Schema.find(Schema.all(), "setChecked").?;
    // Typo `checke=false`: must error, not silently default `checked=true`.
    try testing.expectError(error.UnknownField, set_checked.parseValue(arena.allocator(), "selector='#x' checke=false"));
}

test "parseValue: arg keys are case-insensitive (kv path)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const click = Schema.find(Schema.all(), "click").?;
    const v = (try click.parseValue(arena.allocator(), "Selector='#btn'")).?;
    try testing.expectString("#btn", v.object.get("selector").?.string);
    try testing.expect(v.object.get("Selector") == null);
}

test "parseValue: arg keys are case-insensitive (json path)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const click = Schema.find(Schema.all(), "click").?;
    const v = (try click.parseValue(arena.allocator(), "{\"Selector\":\"#btn\"}")).?;
    try testing.expectString("#btn", v.object.get("selector").?.string);
    try testing.expect(v.object.get("Selector") == null);
}

test "parseValue: duplicate case-variants of the same field are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const click = Schema.find(Schema.all(), "click").?;
    try testing.expectError(
        error.DuplicateField,
        click.parseValue(arena.allocator(), "{\"Selector\":\"#a\",\"selector\":\"#b\"}"),
    );
    try testing.expectError(
        error.DuplicateField,
        click.parseValue(arena.allocator(), "Selector='#a' selector='#b'"),
    );
}

test "parseValue: setChecked defaults checked=true when omitted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const set_checked = Schema.find(Schema.all(), "setChecked").?;
    const v = (try set_checked.parseValue(arena.allocator(), "selector='#agree'")).?;
    try testing.expectString("#agree", v.object.get("selector").?.string);
    try testing.expect(v.object.get("checked").?.bool);
}

test "parseValue: zero-arg tool returns null when rest empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const get_cookies = Schema.find(Schema.all(), "getCookies").?;
    try testing.expect((try get_cookies.parseValue(arena.allocator(), "")) == null);
}

test "parseValue: quoted positional with '=' in body is not mistaken for kv" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const goto = Schema.find(Schema.all(), "goto").?;
    const v = (try goto.parseValue(arena.allocator(), "'https://example.com?id=42'")).?;
    try testing.expectString("https://example.com?id=42", v.object.get("url").?.string);
}

test "parseValue: bare JSON passthrough" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const find_el = Schema.find(Schema.all(), "findElement").?;
    const v = (try find_el.parseValue(arena.allocator(), "{\"role\":\"button\"}")).?;
    try testing.expectString("button", v.object.get("role").?.string);
}

test "parseValue: bare JSON enforces required, default-true, and unknown keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // `checked` is required but default-true: empty object fills it.
    const set_checked = Schema.find(Schema.all(), "setChecked").?;
    const filled = (try set_checked.parseValue(arena.allocator(), "{\"selector\":\"#x\"}")).?;
    try testing.expect(filled.object.get("checked").?.bool);

    // Unknown key in JSON must error.
    try testing.expectError(error.UnknownField, set_checked.parseValue(arena.allocator(), "{\"selector\":\"#x\",\"checke\":false}"));

    // Required field without a default must error MissingRequired.
    const goto = Schema.find(Schema.all(), "goto").?;
    try testing.expectError(error.MissingRequired, goto.parseValue(arena.allocator(), "{}"));
}

test "splitNameRest: trims and handles empty" {
    try testing.expect(Schema.splitNameRest("") == null);
    try testing.expect(Schema.splitNameRest("   ") == null);
    const r = Schema.splitNameRest("  goto  https://x ").?;
    try testing.expectString("goto", r.name);
    try testing.expectString("https://x", r.rest);
}

test "parseSlashCommand: validates command and rejects whitespace after slash" {
    try testing.expect(Schema.parseSlashCommand("") == null);
    try testing.expect(Schema.parseSlashCommand("/") == null);
    try testing.expect(Schema.parseSlashCommand("/   ") == null);
    try testing.expect(Schema.parseSlashCommand("/ foo") == null);
    try testing.expect(Schema.parseSlashCommand("  /foo") == null);

    const r1 = Schema.parseSlashCommand("/goto https://x").?;
    try testing.expectString("goto", r1.name);
    try testing.expectString("https://x", r1.rest);

    const r2 = Schema.parseSlashCommand("/help").?;
    try testing.expectString("help", r2.name);
    try testing.expectString("", r2.rest);
}

test "parseValue: double-quoted script with embedded single-quoted argument" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const evaluate = Schema.find(Schema.all(), "evaluate").?;
    const v = (try evaluate.parseValue(arena.allocator(), "\"setTimeout(() => document.querySelector('a'), 1000)\"")).?;
    try testing.expectString("setTimeout(() => document.querySelector('a'), 1000)", v.object.get("script").?.string);
}

test "tokenize: inline triple quotes with spaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), "selector='''hello world''' value=\"\"\"foo bar\"\"\"");
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectString("selector='''hello world'''", tokens[0]);
    try testing.expectString("value=\"\"\"foo bar\"\"\"", tokens[1]);
}

test "tokenize: rejects backslash-escaped quote inside same-style quote" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedEscape, tokenize(arena.allocator(), "value=\"hello \\\"world\\\"\""));
    try testing.expectError(error.UnsupportedEscape, tokenize(arena.allocator(), "value='it\\'s'"));
}

test "tokenize: bare backslash inside quotes is allowed (e.g. Windows paths)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), "value='C:\\Users\\bob'");
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectString("value='C:\\Users\\bob'", tokens[0]);
}

test "tokenize: even-count backslashes before close-quote are literal" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // `"\\"` is two literal backslashes (even run before the closer), not an escape.
    const tokens = try tokenize(arena.allocator(), "value=\"\\\\\"");
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expectString("value=\"\\\\\"", tokens[0]);
}

test "quotedSpanEnd" {
    try testing.expectEqual(@as(usize, 4), quotedSpanEnd("'ab' x", 0));
    try testing.expectEqual(@as(usize, 9), quotedSpanEnd("'''a b''' x", 0));
    try testing.expectEqual(@as(usize, 5), quotedSpanEnd("'open", 0));
    try testing.expectEqual(@as(usize, 7), quotedSpanEnd("'''open", 0));
}

test "hasUnclosedTripleQuote" {
    try testing.expect(!hasUnclosedTripleQuote(""));
    try testing.expect(!hasUnclosedTripleQuote("/goto https://x"));
    try testing.expect(!hasUnclosedTripleQuote("/evaluate '''const x = 1;'''"));
    try testing.expect(hasUnclosedTripleQuote("/evaluate '''\nconst x = 1;"));
    try testing.expect(hasUnclosedTripleQuote("/evaluate \"\"\"\nconst x = 1;"));
    try testing.expect(!hasUnclosedTripleQuote("/evaluate \"\"\"\nconst x = 1;\n\"\"\""));
    // Mismatched closer — still open.
    try testing.expect(hasUnclosedTripleQuote("/evaluate '''\nfoo\n\"\"\""));
}

test "parseValue: rejects non-object JSON payloads" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const goto = Schema.find(Schema.all(), "goto").?;
    try testing.expectError(error.MalformedKv, goto.parseValue(arena.allocator(), "[1, 2, 3]"));

    // "\"hello\"" is a valid positional argument, not a JSON payload, so it should succeed
    const v = (try goto.parseValue(arena.allocator(), "\"hello\"")).?;
    try testing.expectString("hello", v.object.get("url").?.string);
}
