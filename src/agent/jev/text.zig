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
// along with this program.  See <https://www.gnu.org/licenses/>.

//! The only place an ordinary language model runs in this loop: turning the
//! goal into one field value, when and only when the decider chose TYPE_TEXT.

const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const table = @import("table.zig");
const save = @import("../save.zig");

pub const Error = error{ GeneratorFailed, OutOfMemory };

/// Returns null when the model declined to invent a value.
pub const Generator = struct {
    context: *anyopaque,
    generateFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) Error!?[]const u8,

    pub fn generate(
        self: Generator,
        arena: std.mem.Allocator,
        system: []const u8,
        payload: []const u8,
    ) Error!?[]const u8 {
        return self.generateFn(self.context, arena, system, payload);
    }
};

/// The production generator. `Agent.oneShotCompletion` is what carries the
/// auth refresh, interrupt reset, spinner and cancellation that a call outside
/// the conversation would otherwise skip — and a jev run makes one of these
/// per typing step over minutes, so a stale subscription token is a real
/// prospect.
pub const ChatModel = struct {
    agent: *lp.Agent,

    pub fn generator(self: *ChatModel) Generator {
        return .{ .context = self, .generateFn = generate };
    }

    fn generate(
        context: *anyopaque,
        arena: std.mem.Allocator,
        system: []const u8,
        payload: []const u8,
    ) Error!?[]const u8 {
        const self: *ChatModel = @ptrCast(@alignCast(context));
        // No temperature: some models reject it outright, and the reply shape
        // is pinned by `response_format` anyway.
        // Thinking tokens count against the budget, so a reasoning model spends
        // a small one before the JSON closes and the reply arrives truncated.
        // Neither a field value nor a search query needs deliberation, but
        // `.minimal` is rejected outright by some models where `.low` is not.
        const reply = self.agent.oneShotCompletion(arena, system, payload, .{
            .max_tokens = 1024,
            .effort = .low,
            .response_format = .json,
        }) orelse return error.GeneratorFailed;
        return parseValue(arena, reply) catch return error.GeneratorFailed;
    }
};

pub const ParseError = error{ MalformedReply, OutOfMemory };

/// The helper's contract is exactly `{"text": "..."}` or `{"text": null}`.
/// Anything else is a malformed reply, never a value to type — a model that
/// answers in prose must not have its prose typed into a password field.
/// Models fence JSON even in JSON mode, so the fence is stripped first.
pub fn parseValue(arena: std.mem.Allocator, reply: []const u8) ParseError!?[]const u8 {
    const Reply = struct { text: ?[]const u8 = null };
    const body = save.stripCodeFence(reply);
    const parsed = std.json.parseFromSlice(Reply, arena, body, .{ .ignore_unknown_fields = true }) catch
        return error.MalformedReply;
    defer parsed.deinit();
    const text = parsed.value.text orelse return null;
    if (text.len == 0) return null;
    return try arena.dupe(u8, text);
}

/// Everything the helper sees. Hashed in full as the reuse key: a value may
/// survive a stale-page retry only when nothing it was derived from moved.
pub fn input(
    arena: std.mem.Allocator,
    goal: []const u8,
    element: *const table.Element,
    page: table.Table,
    history: []const table.Step,
) std.mem.Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    writeInput(arena, &jw, goal, element, page, history) catch return error.OutOfMemory;
    return aw.written();
}

fn writeInput(
    arena: std.mem.Allocator,
    jw: *std.json.Stringify,
    goal: []const u8,
    element: *const table.Element,
    page: table.Table,
    history: []const table.Step,
) !void {
    try jw.beginObject();
    try jw.objectField("goal");
    try jw.write(goal);

    try jw.objectField("field");
    try jw.beginObject();
    try jw.objectField("label");
    try jw.write(element.label);
    try jw.objectField("role");
    try jw.write(element.role);
    try jw.objectField("value");
    try jw.write(element.value orelse "");
    try jw.endObject();

    try jw.objectField("page");
    try jw.beginObject();
    try jw.objectField("title");
    try jw.write(page.title);
    try jw.objectField("text");
    try jw.write(page.text);
    try jw.endObject();

    try jw.objectField("recent_actions");
    try jw.beginArray();
    const start = history.len -| table.recent_actions;
    for (history[start..]) |entry| {
        try jw.beginObject();
        try jw.objectField("op");
        try jw.write(@tagName(entry.op));
        if (entry.text) |t| {
            try jw.objectField("text");
            try jw.write(t);
        }
        try jw.endObject();
    }
    try jw.endArray();

    // Names only. The browser expands `$LP_*` itself, so the helper never
    // needs — and never receives — a secret's value.
    try jw.objectField("secrets");
    try jw.beginArray();
    const names = try lp.tools.lpEnvNames(arena);
    for (names) |name| {
        try jw.write(try std.fmt.allocPrint(arena, "${s}", .{name}));
    }
    try jw.endArray();
    try jw.endObject();
}

/// A value survives a stale-page retry only if every byte the helper saw is
/// unchanged, which is what makes reuse safe rather than merely cheap.
///
/// Owns its copy of the value: the input it was derived from lives in a
/// per-turn arena, and the whole point is to outlive that turn.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    key: ?u64 = null,
    value: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
    }

    pub fn get(self: Cache, helper_input: []const u8) ?[]const u8 {
        const key = self.key orelse return null;
        if (key != std.hash.Wyhash.hash(0, helper_input)) return null;
        return self.value;
    }

    pub fn put(self: *Cache, helper_input: []const u8, value: []const u8) std.mem.Allocator.Error!void {
        const copy = try self.allocator.dupe(u8, value);
        self.clear();
        self.key = std.hash.Wyhash.hash(0, helper_input);
        self.value = copy;
    }

    pub fn clear(self: *Cache) void {
        if (self.value) |v| self.allocator.free(v);
        self.key = null;
        self.value = null;
    }
};

test "parseValue accepts the contract and rejects everything else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("ramen", (try parseValue(a, "{\"text\":\"ramen\"}")).?);
    try std.testing.expectEqualStrings("ramen", (try parseValue(a, "```json\n{\"text\":\"ramen\"}\n```")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try parseValue(a, "{\"text\":null}"));
    try std.testing.expectEqual(@as(?[]const u8, null), try parseValue(a, "{\"text\":\"\"}"));
    try std.testing.expectError(error.MalformedReply, parseValue(a, "Sure! Type \"ramen\" in the box."));
    try std.testing.expectError(error.MalformedReply, parseValue(a, "{\"text\":42}"));
}

test "Cache returns a value only for an identical input" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), cache.get("a"));
    try cache.put("a", "ramen");
    try std.testing.expectEqualStrings("ramen", cache.get("a").?);
    try std.testing.expectEqual(@as(?[]const u8, null), cache.get("a "));
    cache.clear();
    try std.testing.expectEqual(@as(?[]const u8, null), cache.get("a"));
}
