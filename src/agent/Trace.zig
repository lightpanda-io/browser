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

//! `--trace`: one JSON line per model call and tool call, then a summary.

const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");

const ToolResult = lp.tools.ToolResult;

const Trace = @This();

file: std.Io.File,
offset: u64 = 0,
// Model calls report from `ModelCall`'s helper thread.
mutex: std.Io.Mutex = .init,
line: std.Io.Writer.Allocating,
started_ms: u64,
model_started_ms: u64 = 0,
model_calls: u32 = 0,
tool_calls: u32 = 0,

pub fn create(allocator: std.mem.Allocator, path: []const u8) !Trace {
    const file = try std.Io.Dir.cwd().createFile(lp.io, path, .{ .truncate = true });
    return .{ .file = file, .line = .init(allocator), .started_ms = now() };
}

pub fn deinit(self: *Trace) void {
    self.line.deinit();
    self.file.close(lp.io);
}

pub fn run(self: *Trace, provider: []const u8, model: []const u8, task: ?[]const u8) void {
    self.write(.{ .type = "run", .t = self.elapsed(), .provider = provider, .model = model, .task = task });
}

pub fn modelStarted(self: *Trace) void {
    self.model_started_ms = now();
}

pub fn modelCall(self: *Trace, phase: []const u8, result: *const zenai.provider.GenerateResult) void {
    self.model_calls += 1;
    self.write(.{
        .type = "model",
        .t = self.elapsed(),
        .step = self.model_calls,
        .phase = phase,
        .ms = now() - self.model_started_ms,
        .tokens = Tokens.of(result.usage),
        .finish = @tagName(result.finish_reason),
        .tool_calls = if (result.tool_calls) |calls| calls.len else 0,
    });
}

pub fn toolCall(self: *Trace, name: []const u8, arguments: ?std.json.Value, result: *const ToolResult, ms: u64, frame: ?*lp.Frame) void {
    self.tool_calls += 1;
    self.write(.{
        .type = "tool",
        .t = self.elapsed(),
        .step = self.tool_calls,
        .name = name,
        .args = arguments,
        .ms = ms,
        .result_bytes = result.text.len,
        .@"error" = result.is_error,
        .navigated = result.navigated,
        .page = if (frame) |f| lp.tools.pageState(f) else null,
    });
}

pub fn end(self: *Trace, usage: zenai.provider.Usage) void {
    self.write(.{
        .type = "end",
        .t = self.elapsed(),
        .model_calls = self.model_calls,
        .tool_calls = self.tool_calls,
        .tokens = Tokens.of(usage),
    });
}

/// Shared with the `$usage` line so both use the same names and meanings.
pub const Tokens = struct {
    input: i32,
    cached: i32,
    cache_creation: i32,
    output: i32,

    pub fn of(u: zenai.provider.Usage) Tokens {
        return .{
            .input = u.inputTokens(),
            .cached = u.cached_tokens orelse 0,
            .cache_creation = u.cache_creation_tokens orelse 0,
            .output = u.completion_tokens orelse 0,
        };
    }
};

fn now() u64 {
    return lp.datetime.milliTimestamp(.boot);
}

fn elapsed(self: *const Trace) u64 {
    return now() - self.started_ms;
}

/// Written as each step ends, so an interrupted run still leaves a usable file.
fn write(self: *Trace, record: anytype) void {
    self.mutex.lockUncancelable(lp.io);
    defer self.mutex.unlock(lp.io);
    self.line.clearRetainingCapacity();
    std.json.Stringify.value(record, .{ .emit_null_optional_fields = false }, &self.line.writer) catch return;
    self.line.writer.writeByte('\n') catch return;
    self.file.writePositionalAll(lp.io, self.line.written(), self.offset) catch return;
    self.offset += self.line.written().len;
}

const testing = @import("../testing.zig");

test "Trace writes one JSON line per step, arguments as given" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testing.tmpPath(&tmp, "trace.jsonl");

    var trace: Trace = try .create(std.testing.allocator, path);
    trace.run("openai", "gpt-test", "find courts");

    var response: zenai.provider.GenerateResult = .init(std.testing.allocator);
    defer response.deinit();
    response.finish_reason = .tool_call;
    response.usage = .{ .prompt_tokens = 30, .cached_tokens = 70, .completion_tokens = 5 };
    trace.modelStarted();
    trace.modelCall("turn", &response);

    const args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"selector":"#pw","value":"$LP_PASSWORD"}
    , .{});
    defer args.deinit();
    trace.toolCall("fill", args.value, &.{ .text = "Filled." }, 12, null);
    trace.end(response.usage);
    trace.deinit();

    const written = try std.Io.Dir.cwd().readFileAlloc(lp.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(written);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, written, "\n"), '\n');
    const expected_types = [_][]const u8{ "run", "model", "tool", "end" };
    var records: [expected_types.len]std.json.Parsed(std.json.Value) = undefined;
    for (&records, expected_types) |*record, expected| {
        record.* = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, lines.next().?, .{});
        try std.testing.expectEqualStrings(expected, record.value.object.get("type").?.string);
    }
    defer for (&records) |*record| record.deinit();
    try std.testing.expect(lines.next() == null);

    const tokens = records[1].value.object.get("tokens").?.object;
    try std.testing.expectEqual(100, tokens.get("input").?.integer);
    try std.testing.expectEqual(70, tokens.get("cached").?.integer);

    const tool = records[2].value.object;
    try std.testing.expectEqualStrings("$LP_PASSWORD", tool.get("args").?.object.get("value").?.string);
    try std.testing.expectEqual(7, tool.get("result_bytes").?.integer);
    try std.testing.expect(tool.get("page") == null);

    try std.testing.expectEqual(1, records[3].value.object.get("model_calls").?.integer);
}
