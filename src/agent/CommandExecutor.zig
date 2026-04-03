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

pub fn execute(self: *Self, cmd: Command.Command) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const result = switch (cmd) {
        .goto => |url| self.tool_executor.call(a, "goto", buildJson(a, .{ .url = url })) catch "Error: goto failed",
        .click => |target| self.execClick(a, target),
        .type_cmd => |args| self.execType(a, args),
        .wait => |selector| self.tool_executor.call(a, "waitForSelector", buildJson(a, .{ .selector = selector })) catch "Error: wait failed",
        .tree => self.tool_executor.call(a, "semantic_tree", "") catch "Error: tree failed",
        .extract => |args| self.execExtract(a, args),
        .eval_js => |script| self.tool_executor.call(a, "evaluate", buildJson(a, .{ .script = script })) catch "Error: eval failed",
        .exit, .natural_language => unreachable,
    };

    self.terminal.printAssistant(result);
    std.debug.print("\n", .{});
}

fn execClick(self: *Self, arena: std.mem.Allocator, target: []const u8) []const u8 {
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
    // Use JavaScript to set the value on the element matching the selector
    const script = std.fmt.allocPrint(arena,
        \\(function() {{
        \\  var el = document.querySelector("{s}");
        \\  if (!el) return "Error: element not found";
        \\  el.value = "{s}";
        \\  el.dispatchEvent(new Event("input", {{bubbles: true}}));
        \\  return "Typed into " + el.tagName;
        \\}})()
    , .{ args.selector, args.value }) catch return "Error: failed to build type script";

    return self.tool_executor.call(arena, "evaluate", buildJson(arena, .{ .script = script })) catch "Error: type failed";
}

fn execExtract(self: *Self, arena: std.mem.Allocator, args: Command.ExtractArgs) []const u8 {
    const script = std.fmt.allocPrint(arena,
        \\JSON.stringify(Array.from(document.querySelectorAll("{s}")).map(el => el.textContent.trim()))
    , .{args.selector}) catch return "Error: failed to build extract script";

    const result = self.tool_executor.call(arena, "evaluate", buildJson(arena, .{ .script = script })) catch
        return "Error: extract failed";

    if (args.file) |file| {
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
