const std = @import("std");
const Command = @import("Command.zig");
const ToolExecutor = @import("ToolExecutor.zig");
const Terminal = @import("Terminal.zig");

const Self = @This();

tool_executor: *ToolExecutor,
terminal: *Terminal,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, tool_executor: *ToolExecutor, terminal: *Terminal) Self {
    return .{
        .allocator = allocator,
        .tool_executor = tool_executor,
        .terminal = terminal,
    };
}

pub const ExecResult = struct {
    output: []const u8,
    failed: bool,
};

/// Execute a command and return the result with success/failure status.
pub fn executeWithResult(self: *Self, a: std.mem.Allocator, cmd: Command.Command) ExecResult {
    const result = switch (cmd) {
        .goto => |url| self.execGoto(a, url),
        .click => |target| self.execClick(a, target),
        .type_cmd => |args| self.execType(a, args),
        .wait => |selector| self.tool_executor.call(a, "waitForSelector", buildJson(a, .{ .selector = selector })) catch "Error: wait failed",
        .tree => self.tool_executor.call(a, "semantic_tree", "") catch "Error: tree failed",
        .markdown => self.tool_executor.call(a, "markdown", "") catch "Error: markdown failed",
        .extract => |args| self.execExtract(a, args),
        .eval_js => |script| self.tool_executor.call(a, "evaluate", buildJson(a, .{ .script = script })) catch "Error: eval failed",
        .exit, .natural_language, .comment, .login, .accept_cookies => unreachable,
    };

    return .{
        .output = result,
        .failed = std.mem.startsWith(u8, result, "Error:"),
    };
}

pub fn execute(self: *Self, cmd: Command.Command) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    const result = self.executeWithResult(arena.allocator(), cmd);

    self.terminal.printAssistant(result.output);
    std.debug.print("\n", .{});
}

fn execGoto(self: *Self, arena: std.mem.Allocator, raw_url: []const u8) []const u8 {
    const url = substituteEnvVars(arena, raw_url);
    return self.tool_executor.call(arena, "goto", buildJson(arena, .{ .url = url })) catch "Error: goto failed";
}

fn execClick(self: *Self, arena: std.mem.Allocator, raw_target: []const u8) []const u8 {
    const target = substituteEnvVars(arena, raw_target);
    // Try as CSS selector via interactiveElements + click
    // First get interactive elements to find the target
    const elements_result = self.tool_executor.call(arena, "interactiveElements", "") catch
        return "Error: failed to get interactive elements";

    // Try to find a backendNodeId by searching the elements result for the target text
    if (findNodeIdByText(arena, elements_result, target)) |node_id| {
        const args = std.fmt.allocPrint(arena, "{{\"backendNodeId\":{d}}}", .{node_id}) catch
            return "Error: failed to build click args";
        return self.tool_executor.call(arena, "click", args) catch "Error: click failed";
    }

    return "Error: could not find element matching the target";
}

fn execType(self: *Self, arena: std.mem.Allocator, args: Command.TypeArgs) []const u8 {
    const selector = escapeJs(arena, substituteEnvVars(arena, args.selector));
    const value = escapeJs(arena, substituteEnvVars(arena, args.value));

    // Use JavaScript to set the value on the element matching the selector
    const script = std.fmt.allocPrint(arena,
        \\(function() {{
        \\  var el = document.querySelector("{s}");
        \\  if (!el) return "Error: element not found";
        \\  el.value = "{s}";
        \\  el.dispatchEvent(new Event("input", {{bubbles: true}}));
        \\  return "Typed into " + el.tagName;
        \\}})()
    , .{ selector, value }) catch return "Error: failed to build type script";

    return self.tool_executor.call(arena, "evaluate", buildJson(arena, .{ .script = script })) catch "Error: type failed";
}

fn execExtract(self: *Self, arena: std.mem.Allocator, args: Command.ExtractArgs) []const u8 {
    const selector = escapeJs(arena, substituteEnvVars(arena, args.selector));

    const script = std.fmt.allocPrint(arena,
        \\JSON.stringify(Array.from(document.querySelectorAll("{s}")).map(el => el.textContent.trim()))
    , .{selector}) catch return "Error: failed to build extract script";

    const result = self.tool_executor.call(arena, "evaluate", buildJson(arena, .{ .script = script })) catch
        return "Error: extract failed";

    if (args.file) |raw_file| {
        const file = sanitizePath(raw_file) orelse {
            self.terminal.printError("Invalid output path: must be relative and not traverse above working directory");
            return result;
        };
        std.fs.cwd().writeFile(.{
            .sub_path = file,
            .data = result,
        }) catch {
            self.terminal.printError("Failed to write to file");
            return result;
        };
        const msg = std.fmt.allocPrint(arena, "Extracted to {s}", .{file}) catch return "Extracted.";
        return msg;
    }

    return result;
}

/// Substitute $VAR_NAME references with values from the environment.
fn substituteEnvVars(arena: std.mem.Allocator, input: []const u8) []const u8 {
    // Quick scan: if no $ present, return as-is
    if (std.mem.indexOfScalar(u8, input, '$') == null) return input;

    var result: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '$') {
            // Find the end of the variable name (alphanumeric + underscore)
            const var_start = i + 1;
            var var_end = var_start;
            while (var_end < input.len and (std.ascii.isAlphanumeric(input[var_end]) or input[var_end] == '_')) {
                var_end += 1;
            }
            if (var_end > var_start) {
                const var_name = input[var_start..var_end];
                // We need a null-terminated string for getenv
                const var_name_z = arena.dupeZ(u8, var_name) catch return input;
                if (std.posix.getenv(var_name_z)) |env_val| {
                    result.appendSlice(arena, env_val) catch return input;
                } else {
                    // Keep the original $VAR if not found
                    result.appendSlice(arena, input[i..var_end]) catch return input;
                }
                i = var_end;
            } else {
                result.append(arena, '$') catch return input;
                i += 1;
            }
        } else {
            result.append(arena, input[i]) catch return input;
            i += 1;
        }
    }
    return result.toOwnedSlice(arena) catch input;
}

/// Escape a string for safe interpolation inside a JS double-quoted string literal.
fn escapeJs(arena: std.mem.Allocator, input: []const u8) []const u8 {
    // Quick scan: if nothing to escape, return as-is
    const needs_escape = for (input) |ch| {
        if (ch == '"' or ch == '\\' or ch == '\n' or ch == '\r' or ch == '\t') break true;
    } else false;
    if (!needs_escape) return input;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (input) |ch| {
        switch (ch) {
            '\\' => out.appendSlice(arena, "\\\\") catch return input,
            '"' => out.appendSlice(arena, "\\\"") catch return input,
            '\n' => out.appendSlice(arena, "\\n") catch return input,
            '\r' => out.appendSlice(arena, "\\r") catch return input,
            '\t' => out.appendSlice(arena, "\\t") catch return input,
            else => out.append(arena, ch) catch return input,
        }
    }
    return out.toOwnedSlice(arena) catch input;
}

/// Validate that a file path is safe: relative, no traversal above cwd.
fn sanitizePath(path: []const u8) ?[]const u8 {
    // Reject absolute paths
    if (path.len > 0 and path[0] == '/') return null;

    // Reject paths containing ".." components
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return null;
    }

    return path;
}

fn findNodeIdByText(arena: std.mem.Allocator, elements_json: []const u8, target: []const u8) ?u32 {
    _ = arena;
    // Simple text search in the JSON result for the target text
    // Look for patterns like "backendNodeId":N near the target text
    // This is a heuristic — search for the target text, then scan backwards for backendNodeId
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, elements_json, pos, target)) |idx| {
        // Search backwards from idx for "backendNodeId":
        const search_start = if (idx > 200) idx - 200 else 0;
        const window = elements_json[search_start..idx];
        if (std.mem.lastIndexOf(u8, window, "\"backendNodeId\":")) |bid_offset| {
            const num_start = search_start + bid_offset + "\"backendNodeId\":".len;
            const num_end = std.mem.indexOfAnyPos(u8, elements_json, num_start, ",}] \n") orelse continue;
            const num_str = elements_json[num_start..num_end];
            return std.fmt.parseInt(u32, num_str, 10) catch {
                pos = idx + 1;
                continue;
            };
        }
        pos = idx + 1;
    }
    return null;
}

fn buildJson(arena: std.mem.Allocator, value: anytype) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(value, .{}, &aw.writer) catch return "{}";
    return aw.written();
}
