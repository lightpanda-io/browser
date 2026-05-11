const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");
const browser_tools = lp.tools;

pub const FieldType = enum { string, integer, number, boolean, other };

pub const FieldEntry = struct {
    name: []const u8,
    field_type: FieldType,
};

/// One slot of the REPL's argument-syntax hint, in display order: required
/// fields first, then optionals. Renderer wraps required as `<name>` and
/// optionals as `[name=…]`.
pub const HintSlot = struct {
    name: []const u8,
    required: bool,
};

/// Cached, schema-extracted view of a single browser tool.
pub const SchemaInfo = struct {
    tool_name: []const u8,
    description: []const u8,
    input_schema_raw: []const u8,
    required: []const []const u8,
    fields: []const FieldEntry,
    hints: []const HintSlot,
};

/// Meta slash commands handled directly by the agent (not by ToolExecutor).
/// Kept in sync with `handleSlash` in Agent.zig.
pub const meta_names = [_][:0]const u8{ "help", "quit" };

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
                };
            }
            info.fields = fields;
        }
    }

    info.hints = try buildHints(arena, info.required, info.fields);

    return info;
}

fn buildHints(arena: std.mem.Allocator, required: []const []const u8, fields: []const FieldEntry) ![]const HintSlot {
    if (fields.len == 0) return &.{};
    const out = try arena.alloc(HintSlot, fields.len);
    var idx: usize = 0;
    for (required) |name| {
        out[idx] = .{ .name = name, .required = true };
        idx += 1;
    }
    for (fields) |f| {
        if (containsName(required, f.name)) continue;
        out[idx] = .{ .name = f.name, .required = false };
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

pub fn findSchema(schemas: []const SchemaInfo, name: []const u8) ?*const SchemaInfo {
    for (schemas) |*s| {
        if (std.ascii.eqlIgnoreCase(s.tool_name, name)) return s;
    }
    return null;
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

/// Parse the args portion of a slash command for an already-resolved schema.
pub fn parseArgs(arena: std.mem.Allocator, schema: *const SchemaInfo, rest: []const u8) ParseError![]const u8 {
    if (rest.len == 0) {
        if (schema.required.len > 0) return error.MissingRequired;
        return "";
    }

    if (rest[0] == '{') return rest;

    const tokens = try tokenize(arena, rest);

    // A leading token without `=` binds positionally to the single required
    // field; the rest must be `key=value`. Only allowed when the schema has
    // exactly one required field — otherwise the binding would be ambiguous.
    const leading_positional = tokens.len >= 1 and std.mem.indexOfScalar(u8, tokens[0], '=') == null;
    if (leading_positional and schema.required.len != 1) return error.PositionalNotAllowed;

    var pairs = try arena.alloc(KvPair, tokens.len);
    const kv_start: usize = if (leading_positional) 1 else 0;
    if (leading_positional) {
        pairs[0] = .{ .key = schema.required[0], .value = tokens[0] };
    }
    for (tokens[kv_start..], kv_start..) |tok, i| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.MalformedKv;
        if (eq == 0 or eq == tok.len - 1) return error.MalformedKv;
        pairs[i] = .{ .key = tok[0..eq], .value = tok[eq + 1 ..] };
    }

    for (schema.required) |req| {
        var found = false;
        for (pairs) |p| if (std.mem.eql(u8, p.key, req)) {
            found = true;
            break;
        };
        if (!found) return error.MissingRequired;
    }

    return try buildJson(arena, schema, pairs);
}

const KvPair = struct {
    key: []const u8,
    value: []const u8,
};

/// Split `input` into tokens, treating "..." and '...' as single tokens
/// (the surrounding quotes are stripped). Tokens may contain `=`.
fn tokenize(arena: std.mem.Allocator, input: []const u8) ParseError![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and std.ascii.isWhitespace(input[i])) i += 1;
        if (i >= input.len) break;

        const tok_start = i;
        var has_quote = false;
        while (i < input.len and !std.ascii.isWhitespace(input[i])) : (i += 1) {
            const ch = input[i];
            if (ch == '"' or ch == '\'') {
                has_quote = true;
                const close = std.mem.indexOfScalarPos(u8, input, i + 1, ch) orelse return error.UnterminatedQuote;
                i = close;
            }
        }

        // Common case: no quotes — slice directly from input. Only build a
        // separate buffer when we actually need to splice quoted segments in.
        const slice = if (has_quote)
            try stripQuotes(arena, input[tok_start..i])
        else
            input[tok_start..i];
        try out.append(arena, slice);
    }

    return try out.toOwnedSlice(arena);
}

fn stripQuotes(arena: std.mem.Allocator, raw: []const u8) ParseError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.ensureTotalCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        const ch = raw[i];
        if (ch == '"' or ch == '\'') {
            i += 1;
            const start = i;
            while (i < raw.len and raw[i] != ch) i += 1;
            try buf.appendSlice(arena, raw[start..i]);
            i += 1;
            continue;
        }
        try buf.append(arena, ch);
        i += 1;
    }
    return try buf.toOwnedSlice(arena);
}

fn buildJson(arena: std.mem.Allocator, schema: *const SchemaInfo, pairs: []const KvPair) error{OutOfMemory}![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    return buildJsonInner(&aw, schema, pairs) catch error.OutOfMemory;
}

fn buildJsonInner(aw: *std.Io.Writer.Allocating, schema: *const SchemaInfo, pairs: []const KvPair) ![]const u8 {
    try aw.writer.writeByte('{');
    for (pairs, 0..) |p, i| {
        if (i > 0) try aw.writer.writeByte(',');
        try std.json.Stringify.value(p.key, .{}, &aw.writer);
        try aw.writer.writeByte(':');
        try writeCoercedValue(&aw.writer, schema, p.key, p.value);
    }
    try aw.writer.writeByte('}');
    return aw.written();
}

fn writeCoercedValue(writer: *std.Io.Writer, schema: *const SchemaInfo, key: []const u8, value: []const u8) !void {
    const ft = lookupFieldType(schema, key);
    switch (ft) {
        .integer => {
            const n = std.fmt.parseInt(i64, value, 10) catch {
                try std.json.Stringify.value(value, .{}, writer);
                return;
            };
            try writer.print("{d}", .{n});
        },
        .number => {
            const n = std.fmt.parseFloat(f64, value) catch {
                try std.json.Stringify.value(value, .{}, writer);
                return;
            };
            try writer.print("{d}", .{n});
        },
        .boolean => {
            if (std.mem.eql(u8, value, "true")) {
                try writer.writeAll("true");
            } else if (std.mem.eql(u8, value, "false")) {
                try writer.writeAll("false");
            } else {
                try std.json.Stringify.value(value, .{}, writer);
            }
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}

fn lookupFieldType(schema: *const SchemaInfo, key: []const u8) FieldType {
    for (schema.fields) |f| {
        if (std.mem.eql(u8, f.name, key)) return f.field_type;
    }
    return .other;
}

// ---------- tests ----------

const testing = std.testing;

const ParsedTest = struct {
    schema: *const SchemaInfo,
    args_json: []const u8,
};

fn parseWithCache(arena: std.mem.Allocator, input: []const u8) !ParsedTest {
    const tools = try arena.alloc(zenai.provider.Tool, browser_tools.tool_defs.len);
    for (browser_tools.tool_defs, 0..) |td, i| {
        tools[i] = .{
            .name = td.name,
            .description = td.description,
            .parameters = try std.json.parseFromSliceLeaky(std.json.Value, arena, td.input_schema, .{}),
        };
    }
    const schemas = try buildSchemas(arena, tools);
    const split = splitNameRest(input) orelse return error.MissingName;
    const schema = findSchema(schemas, split.name) orelse return error.UnknownTool;
    return .{ .schema = schema, .args_json = try parseArgs(arena, schema, split.rest) };
}

fn expectParse(input: []const u8, expected_tool: []const u8, expected_json: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseWithCache(arena.allocator(), input);
    try testing.expectEqualStrings(expected_tool, r.schema.tool_name);
    try testing.expectEqualStrings(expected_json, r.args_json);
}

fn expectParseError(comptime expected: anyerror, input: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(expected, parseWithCache(arena.allocator(), input));
}

test "parse zero-arg tool" {
    try expectParse("getCookies", "getCookies", "");
}

test "parse positional shortcut for single required field" {
    try expectParse("eval document.title", "eval", "{\"script\":\"document.title\"}");
}

test "parse getEnv with no args is valid (list mode)" {
    // getEnv's `name` is optional; no args returns the list of LP_* names.
    try expectParse("getEnv", "getEnv", "");
}

test "parse leading positional with key=value tail" {
    try expectParse(
        "goto https://example.com timeout=5000",
        "goto",
        "{\"url\":\"https://example.com\",\"timeout\":5000}",
    );
}

test "parse key=value pairs" {
    try expectParse("findElement role=button", "findElement", "{\"role\":\"button\"}");
}

test "parse quoted value with whitespace" {
    try expectParse(
        "findElement role=button name=\"Click Me\"",
        "findElement",
        "{\"role\":\"button\",\"name\":\"Click Me\"}",
    );
}

test "parse JSON fallback" {
    try expectParse("findElement {\"role\":\"button\"}", "findElement", "{\"role\":\"button\"}");
}

test "parse coerces integer field" {
    try expectParse("scroll x=0 y=200", "scroll", "{\"x\":0,\"y\":200}");
}

test "parse coerces boolean field" {
    try expectParse(
        "setChecked selector=#a checked=true",
        "setChecked",
        "{\"selector\":\"#a\",\"checked\":true}",
    );
}

test "parse rejects unknown tool" {
    try expectParseError(error.UnknownTool, "bogus");
}

test "parse rejects missing required field" {
    try expectParseError(error.MissingRequired, "eval");
}

test "parse rejects malformed key=value" {
    try expectParseError(error.MalformedKv, "findElement role=button name");
}

test "parse rejects positional when not single-required" {
    // findElement has zero required fields; a bare positional is ambiguous.
    try expectParseError(error.PositionalNotAllowed, "findElement button");
}

test "parse handles single-quoted values" {
    try expectParse("click selector='#login-btn'", "click", "{\"selector\":\"#login-btn\"}");
}

test "parse matches tool name case-insensitively" {
    try expectParse("EVAL document.title", "eval", "{\"script\":\"document.title\"}");
}

test "parse rejects malformed kv after leading positional" {
    try expectParseError(error.MalformedKv, "goto https://example.com bare");
}

test "parse treats first token with = as kv (not positional)" {
    // `a=b` looks like kv, so the leading-positional shortcut doesn't fire and
    // the schema's required `url` is missing.
    try expectParseError(error.MissingRequired, "goto a=b");
}
