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

//! Slash-command schema: the parsed view of `browser_tools.tool_defs` that
//! both PandaScript (`Command.parse`/`format`) and the REPL Terminal consume.
//!
//! Each tool's JSON schema is reduced to a flat `SchemaInfo` (required names,
//! field types, hint slots, recording flags) so callers don't re-parse the
//! input_schema string. `globalSchemas()` is the lazy process-wide cache used
//! by `Command.parse`/`format` when no agent-scoped cache is plumbed (script
//! replay, recorder format, tests).

const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");
const browser_tools = lp.tools;

pub const FieldType = enum { string, integer, number, boolean, other };

pub const FieldEntry = struct {
    name: []const u8,
    field_type: FieldType,
    /// Default for booleans declared with `"default": true` in the JSON schema.
    /// Used by `Command.format` to omit `checked=true` when emitting `/setChecked`.
    default_true: bool = false,
};

/// One slot of the REPL's argument-syntax hint, in display order: required
/// fields first, then optionals. `fragment` is pre-rendered as `<name>` for
/// required and `[name=…]` for optional so the renderer can hand it directly
/// to the shared writer.
pub const HintSlot = struct {
    name: []const u8,
    required: bool,
    fragment: []const u8,
};

/// Upper bound on per-schema hint slots; lets the renderer use a stack array.
/// Asserted at schema build time so adding a tool with more fields fails loud.
pub const max_hint_slots: usize = 16;

/// Cached, schema-extracted view of a single browser tool.
pub const SchemaInfo = struct {
    tool_name: []const u8,
    description: []const u8,
    input_schema_raw: []const u8,
    required: []const []const u8,
    fields: []const FieldEntry,
    hints: []const HintSlot,
    /// Mirrors `ToolDef.recorded` — kept on SchemaInfo so the script layer
    /// doesn't have to re-resolve via `tool_defs` for every command.
    recorded: bool,
    can_heal: bool,
    produces_data: bool,

    /// True when this tool's args fit a multi-line `/<name> '''…'''` opener:
    /// exactly one required field, and that field is a string. Used by
    /// `Command.ScriptIterator` to detect block openers.
    pub fn isMultiLineCapable(self: *const SchemaInfo) bool {
        if (self.required.len != 1) return false;
        return self.fieldType(self.required[0]) == .string;
    }

    pub fn fieldType(self: *const SchemaInfo, key: []const u8) FieldType {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, key)) return f.field_type;
        }
        return .other;
    }

    pub fn isFieldDefaultTrue(self: *const SchemaInfo, key: []const u8) bool {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, key)) return f.default_true;
        }
        return false;
    }
};

pub const ParseError = error{
    MissingName,
    UnknownTool,
    MissingRequired,
    MalformedKv,
    PositionalNotAllowed,
    UnterminatedQuote,
    OutOfMemory,
};

/// Build schema cache from already-parsed tools (typically from
/// `ToolExecutor.getTools`) so the JSON isn't parsed twice. `tools` must be
/// parallel to `browser_tools.tool_defs`. Allocates into `arena`, which must
/// outlive the returned slice.
pub fn buildSchemas(arena: std.mem.Allocator, tools: []const zenai.provider.Tool) ![]const SchemaInfo {
    std.debug.assert(tools.len == browser_tools.tool_defs.len);
    const out = try arena.alloc(SchemaInfo, tools.len);
    for (browser_tools.tool_defs, tools, 0..) |td, t, i| {
        out[i] = try buildOne(arena, td, t.parameters);
    }
    return out;
}

fn buildOne(arena: std.mem.Allocator, td: browser_tools.ToolDef, parsed: std.json.Value) !SchemaInfo {
    var info: SchemaInfo = .{
        .tool_name = td.name,
        .description = td.description,
        .input_schema_raw = td.input_schema,
        .required = &.{},
        .fields = &.{},
        .hints = &.{},
        .recorded = td.recorded,
        .can_heal = td.can_heal,
        .produces_data = td.produces_data,
    };

    if (parsed != .object) return info;

    if (parsed.object.get("required")) |req| {
        if (req == .array) {
            var reqs: std.ArrayList([]const u8) = .empty;
            try reqs.ensureTotalCapacity(arena, req.array.items.len);
            for (req.array.items) |item| {
                if (item != .string) continue;
                reqs.appendAssumeCapacity(item.string);
            }
            info.required = try reqs.toOwnedSlice(arena);
        }
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
    if (fields.len == 0) return &.{};
    const out = try arena.alloc(HintSlot, fields.len);
    var idx: usize = 0;
    for (required) |name| {
        out[idx] = .{
            .name = name,
            .required = true,
            .fragment = try std.fmt.allocPrint(arena, "<{s}>", .{name}),
        };
        idx += 1;
    }
    for (fields) |f| {
        if (containsName(required, f.name)) continue;
        out[idx] = .{
            .name = f.name,
            .required = false,
            .fragment = try std.fmt.allocPrint(arena, "[{s}=…]", .{f.name}),
        };
        idx += 1;
    }
    return out[0..idx];
}

fn containsName(names: []const []const u8, target: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, target)) return true;
    return false;
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

pub fn findSchema(schemas: []const SchemaInfo, name: []const u8) ?*const SchemaInfo {
    for (schemas) |*s| {
        if (std.ascii.eqlIgnoreCase(s.tool_name, name)) return s;
    }
    return null;
}

pub fn findSchemaCanonical(schemas: []const SchemaInfo, name: []const u8) ?*const SchemaInfo {
    std.debug.assert(schemas.len == browser_tools.tool_defs.len);
    const action = std.meta.stringToEnum(browser_tools.Action, name) orelse return null;
    return &schemas[@intFromEnum(action)];
}

pub const Split = struct {
    name: []const u8,
    rest: []const u8,
};

/// Split a slash-command body into `<name> <rest>`. Returns null on empty input.
pub fn splitNameRest(input: []const u8) ?Split {
    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (trimmed.len == 0) return null;
    const name_end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
    return .{
        .name = trimmed[0..name_end],
        .rest = std.mem.trim(u8, trimmed[name_end..], &std.ascii.whitespace),
    };
}

/// Parse `rest` (the args portion of a slash command) into a `std.json.Value`
/// shaped for the tool. Returns null when the schema takes no args and `rest`
/// is empty; that lets the caller pass `null` straight to `tool_executor.call`
/// without allocating an empty object.
///
/// Argument-binding rules:
///   - Bare `{json}` payload — returned as-is after JSON parse. Pass-through
///     avoids re-stringifying the blob the LLM emitted.
///   - A single leading positional token binds to the schema's sole required
///     field when `schema.required.len == 1`. Multiple positionals (or one
///     positional with `required.len != 1`) error.
///   - Everything else is `key=value`. Coercion: integer/number/boolean
///     fields parse their respective types; anything else stays a string.
pub fn parseValue(arena: std.mem.Allocator, schema: *const SchemaInfo, rest: []const u8) ParseError!?std.json.Value {
    if (rest.len == 0) {
        if (schema.required.len > 0) return error.MissingRequired;
        return null;
    }

    if (rest[0] == '{') {
        return std.json.parseFromSliceLeaky(std.json.Value, arena, rest, .{}) catch return error.MalformedKv;
    }

    const tokens = try tokenize(arena, rest);

    const leading_positional = tokens.len >= 1 and std.mem.indexOfScalar(u8, tokens[0], '=') == null;
    if (leading_positional and schema.required.len != 1) return error.PositionalNotAllowed;

    var pairs = try arena.alloc(KvPair, tokens.len);
    const kv_start: usize = if (leading_positional) 1 else 0;
    if (leading_positional) {
        pairs[0] = .{ .key = schema.required[0], .value = stripQuotes(tokens[0]) };
    }
    for (tokens[kv_start..], kv_start..) |tok, i| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.MalformedKv;
        if (eq == 0 or eq == tok.len - 1) return error.MalformedKv;
        pairs[i] = .{ .key = tok[0..eq], .value = stripQuotes(tok[eq + 1 ..]) };
    }

    // Default-true required booleans (e.g. setChecked.checked) are filled in
    // when omitted, so `/setChecked selector='#a'` works without `checked=true`.
    var missing_defaults: usize = 0;
    for (schema.required) |req| {
        var found = false;
        for (pairs) |p| if (std.mem.eql(u8, p.key, req)) {
            found = true;
            break;
        };
        if (found) continue;
        const has_default = blk: for (schema.fields) |f| {
            if (std.mem.eql(u8, f.name, req) and f.default_true) break :blk true;
        } else false;
        if (!has_default) return error.MissingRequired;
        missing_defaults += 1;
    }

    if (missing_defaults == 0) return try buildValue(arena, schema, pairs);

    const with_defaults = try arena.alloc(KvPair, pairs.len + missing_defaults);
    @memcpy(with_defaults[0..pairs.len], pairs);
    var next = pairs.len;
    for (schema.required) |req| {
        var found = false;
        for (pairs) |p| if (std.mem.eql(u8, p.key, req)) {
            found = true;
            break;
        };
        if (found) continue;
        with_defaults[next] = .{ .key = req, .value = "true" };
        next += 1;
    }

    return try buildValue(arena, schema, with_defaults);
}

const KvPair = struct {
    key: []const u8,
    value: []const u8,
};

/// Split `input` into tokens, treating `"…"` and `'…'` as a single token (the
/// surrounding quotes are stripped at value-extraction time, not here).
/// Tokens may contain `=`.
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
                    const close = std.mem.indexOfScalarPos(u8, input, i + 1, ch) orelse return error.UnterminatedQuote;
                    i = close;
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

fn buildValue(arena: std.mem.Allocator, schema: *const SchemaInfo, pairs: []const KvPair) error{OutOfMemory}!std.json.Value {
    var obj: std.json.ObjectMap = .init(arena);
    try obj.ensureTotalCapacity(pairs.len);
    for (pairs) |p| {
        const v = try coerce(arena, schema, p.key, p.value);
        try obj.put(p.key, v);
    }
    return .{ .object = obj };
}

fn coerce(arena: std.mem.Allocator, schema: *const SchemaInfo, key: []const u8, value: []const u8) error{OutOfMemory}!std.json.Value {
    switch (schema.fieldType(key)) {
        .integer => {
            if (std.fmt.parseInt(i64, value, 10)) |n| return .{ .integer = n } else |_| {}
        },
        .number => {
            if (std.fmt.parseFloat(f64, value)) |n| return .{ .float = n } else |_| {}
        },
        .boolean => {
            if (std.mem.eql(u8, value, "true")) return .{ .bool = true };
            if (std.mem.eql(u8, value, "false")) return .{ .bool = false };
        },
        else => {},
    }
    return .{ .string = try arena.dupe(u8, value) };
}

// --- Global lazy schema cache ---
//
// Single-threaded REPL only — if multi-threaded usage emerges, swap the guard
// for `std.Once` semantics.

var global_failed: bool = false;
var global_schemas_storage: [browser_tools.tool_defs.len]SchemaInfo = undefined;
var global_arena: std.heap.ArenaAllocator = undefined;
var global_once = std.once(initGlobal);

/// Process-lifetime schema cache. Returns an empty slice if init fails (OOM
/// or malformed input_schema), in which case parse/format fall back to a
/// best-effort form rather than crashing.
pub fn globalSchemas() []const SchemaInfo {
    global_once.call();
    if (global_failed) return &.{};
    return global_schemas_storage[0..browser_tools.tool_defs.len];
}

fn initGlobal() void {
    global_arena = .init(std.heap.page_allocator);
    const a = global_arena.allocator();
    for (browser_tools.tool_defs, 0..) |td, i| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, td.input_schema, .{}) catch {
            global_failed = true;
            return;
        };
        global_schemas_storage[i] = buildOne(a, td, parsed) catch {
            global_failed = true;
            return;
        };
    }
}

// --- Tests ---

const testing = std.testing;

test "globalSchemas: comptime tool defs reduce cleanly" {
    const schemas = globalSchemas();
    try testing.expect(schemas.len == browser_tools.tool_defs.len);
    // /goto has one required string field — multi-line capable.
    const goto = findSchema(schemas, "goto").?;
    try testing.expect(goto.isMultiLineCapable());
    try testing.expect(goto.recorded);
    // /scroll has zero required fields — not multi-line capable.
    const scroll = findSchema(schemas, "scroll").?;
    try testing.expect(!scroll.isMultiLineCapable());
    try testing.expect(scroll.recorded);
    // /tree is read-only; should not be recorded.
    const tree = findSchema(schemas, "tree").?;
    try testing.expect(!tree.recorded);
    try testing.expect(tree.produces_data);
    // /setChecked's `checked` field carries default=true.
    const set_checked = findSchema(schemas, "setChecked").?;
    var checked_default_true = false;
    for (set_checked.fields) |f| {
        if (std.mem.eql(u8, f.name, "checked")) checked_default_true = f.default_true;
    }
    try testing.expect(checked_default_true);

    // canonical lookup matches search lookup
    try testing.expect(findSchemaCanonical(schemas, "goto") == goto);
    try testing.expect(findSchemaCanonical(schemas, "unknown_tool") == null);
}

test "parseValue: single-required positional binds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const goto = findSchema(schemas, "goto").?;
    const v = (try parseValue(arena.allocator(), goto, "https://example.com")).?;
    try testing.expectEqualStrings("https://example.com", v.object.get("url").?.string);
}

test "parseValue: positional then kv tail" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const goto = findSchema(schemas, "goto").?;
    const v = (try parseValue(arena.allocator(), goto, "https://example.com timeout=5000")).?;
    try testing.expectEqualStrings("https://example.com", v.object.get("url").?.string);
    try testing.expectEqual(@as(i64, 5000), v.object.get("timeout").?.integer);
}

test "parseValue: kv-only multi-required" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const fill = findSchema(schemas, "fill").?;
    const v = (try parseValue(arena.allocator(), fill, "selector='#email' value='foo@x.com'")).?;
    try testing.expectEqualStrings("#email", v.object.get("selector").?.string);
    try testing.expectEqualStrings("foo@x.com", v.object.get("value").?.string);
}

test "parseValue: kv-only zero-required" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const scroll = findSchema(schemas, "scroll").?;
    const v = (try parseValue(arena.allocator(), scroll, "y=200")).?;
    try testing.expectEqual(@as(i64, 200), v.object.get("y").?.integer);
}

test "parseValue: missing required errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const goto = findSchema(schemas, "goto").?;
    try testing.expectError(error.MissingRequired, parseValue(arena.allocator(), goto, ""));
}

test "parseValue: positional with zero-required schema errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const find = findSchema(schemas, "findElement").?;
    try testing.expectError(error.PositionalNotAllowed, parseValue(arena.allocator(), find, "button"));
}

test "parseValue: setChecked defaults checked=true when omitted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const set_checked = findSchema(schemas, "setChecked").?;
    const v = (try parseValue(arena.allocator(), set_checked, "selector='#agree'")).?;
    try testing.expectEqualStrings("#agree", v.object.get("selector").?.string);
    try testing.expect(v.object.get("checked").?.bool);
}

test "parseValue: zero-arg tool returns null when rest empty" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const get_cookies = findSchema(schemas, "getCookies").?;
    try testing.expect((try parseValue(arena.allocator(), get_cookies, "")) == null);
}

test "parseValue: bare JSON passthrough" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const schemas = globalSchemas();
    const find = findSchema(schemas, "findElement").?;
    const v = (try parseValue(arena.allocator(), find, "{\"role\":\"button\"}")).?;
    try testing.expectEqualStrings("button", v.object.get("role").?.string);
}

test "splitNameRest: trims and handles empty" {
    try testing.expect(splitNameRest("") == null);
    try testing.expect(splitNameRest("   ") == null);
    const r = splitNameRest("  goto  https://x ").?;
    try testing.expectEqualStrings("goto", r.name);
    try testing.expectEqualStrings("https://x", r.rest);
}

test "tokenize: inline triple quotes with spaces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const tokens = try tokenize(arena.allocator(), "selector='''hello world''' value=\"\"\"foo bar\"\"\"");
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectEqualStrings("selector='''hello world'''", tokens[0]);
    try testing.expectEqualStrings("value=\"\"\"foo bar\"\"\"", tokens[1]);
}
