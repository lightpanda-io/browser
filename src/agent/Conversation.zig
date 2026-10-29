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

//! The agent's chat history paired with the arena backing every message's
//! bytes: prune and rollback re-home the surviving messages into a fresh arena,
//! freeing dropped turns' bytes in one shot. The system prompt at index 0 lives
//! outside the arena so those rebuilds never disturb it. `Agent` appends turns
//! and reads `messages` / `arena` directly; lifecycle (seed, prune, rollback)
//! lives here.

const std = @import("std");
const zenai = @import("zenai");

const Conversation = @This();
const Message = zenai.provider.Message;

// Once history exceeds `prune_high` messages, drop the middle and keep the
// system prompt plus the most recent `prune_keep`.
const prune_high = 30;
const prune_keep = 20;
// Stale results are stubbed in batches, past `elide_trigger`: each rewrite of
// history invalidates the provider's prompt cache.
const image_keep = 2;
const elide_keep = 3;
const elide_min_bytes = 2048;
const elide_trigger = 60 * 1024;

allocator: std.mem.Allocator,
/// Seeded as `messages[0]` on the first turn. Lives outside `arena` (static or
/// caller-owned), so the arena rebuilds below never touch it.
system_prompt: []const u8,
messages: std.ArrayList(Message),
/// Backs every message's content/parts. Rebuilt — not just reset — on prune and
/// rollback so dropped turns' bytes don't accumulate.
arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator, system_prompt: []const u8) Conversation {
    return .{
        .allocator = allocator,
        .system_prompt = system_prompt,
        .messages = .empty,
        .arena = .init(allocator),
    };
}

pub fn deinit(self: *Conversation) void {
    self.arena.deinit();
    self.messages.deinit(self.allocator);
}

/// Seed the system prompt as `messages[0]` when the history is empty. Idempotent
/// and called every turn, so a cleared conversation re-seeds lazily.
pub fn ensureSystemPrompt(self: *Conversation) !void {
    if (self.messages.items.len == 0) {
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = self.system_prompt,
        });
    }
}

const ToolResult = zenai.provider.ToolResult;

/// `prune` only runs between turns; a run re-sends its whole history on every
/// request.
pub fn compactForRequest(self: *Conversation) void {
    self.expireImages();
    if (self.forStale(elide_keep, isElidable, null) >= elide_trigger) {
        _ = self.forStale(elide_keep, isElidable, stubResult);
    }
}

fn expireImages(self: *Conversation) void {
    _ = self.forStale(image_keep, hasImage, dropImage);
}

/// Total size of the candidate results older than the newest `keep`; with
/// `rewrite`, also replaces them, in a copy since tool results are immutable.
fn forStale(
    self: *Conversation,
    keep: usize,
    comptime isCandidate: fn (ToolResult) bool,
    comptime rewrite: ?fn (std.mem.Allocator, ToolResult) ToolResult,
) usize {
    const arena = self.arena.allocator();
    var budget = keep;
    var stale_bytes: usize = 0;
    var i = self.messages.items.len;
    while (i > 0) {
        i -= 1;
        const msg = &self.messages.items[i];
        const results = msg.tool_results orelse continue;
        var copy: ?[]ToolResult = null;
        var n = results.len;
        while (n > 0) {
            n -= 1;
            if (!isCandidate(results[n])) continue;
            if (budget > 0) {
                budget -= 1;
                continue;
            }
            stale_bytes += results[n].content.len;
            const rewriteFn = rewrite orelse continue;
            const rewritten = copy orelse arena.dupe(ToolResult, results) catch return stale_bytes;
            copy = rewritten;
            rewritten[n] = rewriteFn(arena, results[n]);
        }
        if (copy) |c| msg.tool_results = c;
    }
    return stale_bytes;
}

fn hasImage(res: ToolResult) bool {
    return zenai.provider.hasImage(res.parts orelse return false);
}

fn dropImage(arena: std.mem.Allocator, res: ToolResult) ToolResult {
    var dropped = res;
    dropped.parts = null;
    dropped.content = std.mem.concat(arena, u8, &.{ res.content, " (image dropped from context; call the tool again to look)" }) catch res.content;
    return dropped;
}

/// `extract` output is usually the answer, and small.
fn isElidable(res: ToolResult) bool {
    return res.content.len >= elide_min_bytes and !std.mem.eql(u8, res.name, "extract");
}

fn stubResult(arena: std.mem.Allocator, res: ToolResult) ToolResult {
    var stub = res;
    stub.parts = null;
    stub.content = arena.print("[{s} result ({d} bytes) dropped from context; call the tool again to look]", .{ res.name, res.content.len }) catch return res;
    return stub;
}

/// Cap history growth: expire stale images, then once history exceeds
/// `prune_high`, keep the system prompt plus the most recent `prune_keep`
/// messages, snapped to a safe boundary so a tool_call isn't split from its
/// result.
pub fn prune(self: *Conversation) void {
    self.expireImages();
    const msgs = self.messages.items;
    if (msgs.len <= prune_high) return;
    const tail_start = zenai.provider.safeTruncationStart(msgs, msgs.len - prune_keep) orelse return;
    self.repackTail(msgs[tail_start..]);
}

/// Shrink history back to `baseline` and rebuild the arena. Used after a failed
/// turn (API error, synthesis) so the next turn doesn't replay the dropped
/// messages and the arena doesn't accumulate their bytes.
pub fn rollback(self: *Conversation, baseline: usize) void {
    self.messages.shrinkRetainingCapacity(baseline);
    const msgs = self.messages.items;
    if (msgs.len <= 1) {
        // Only the system prompt (or nothing) remains — it lives outside the
        // arena, so a plain reset suffices.
        _ = self.arena.reset(.retain_capacity);
        return;
    }
    self.repackTail(msgs[1..]);
}

/// Re-home `tail` (a suffix of `messages`) into a fresh arena, placing it right
/// after the preserved system prompt at index 0, then swap arenas so the old
/// turns' bytes are freed at once. A dupe failure leaves the conversation as-is.
fn repackTail(self: *Conversation, tail: []const Message) void {
    var new_arena: std.heap.ArenaAllocator = .init(self.allocator);
    // Dupe into the new arena before mutating `messages` — a partial failure
    // would otherwise leave items pointing into a freed arena.
    const duped = zenai.provider.dupeMessages(new_arena.allocator(), tail) catch {
        new_arena.deinit();
        return;
    };
    @memcpy(self.messages.items[1..][0..duped.len], duped);
    self.messages.shrinkRetainingCapacity(1 + duped.len);
    self.arena.deinit();
    self.arena = new_arena;
}

fn appendResult(conv: *Conversation, name: []const u8, len: usize) !void {
    const a = conv.arena.allocator();
    const results = try a.alloc(ToolResult, 1);
    const content = try a.alloc(u8, len);
    @memset(content, 'x');
    results[0] = .{ .id = "c", .name = name, .content = content };
    try conv.messages.append(std.testing.allocator, .{ .role = .tool, .tool_results = results });
}

fn contentOf(conv: *const Conversation, i: usize) []const u8 {
    return conv.messages.items[i].tool_results.?[0].content;
}

test "compactForRequest waits for the trigger, then stubs all stale results at once" {
    var conv: Conversation = .init(std.testing.allocator, "sys");
    defer conv.deinit();

    for (0..6) |_| try appendResult(&conv, "markdown", 18 * 1024);
    conv.compactForRequest();
    try std.testing.expectEqual(18 * 1024, contentOf(&conv, 0).len);

    try appendResult(&conv, "markdown", 18 * 1024);
    conv.compactForRequest();
    const stub = "[markdown result (18432 bytes) dropped from context; call the tool again to look]";
    for (0..4) |i| try std.testing.expectEqualStrings(stub, contentOf(&conv, i));
    for (4..7) |i| try std.testing.expectEqual(18 * 1024, contentOf(&conv, i).len);
}

test "compactForRequest keeps small and extract results, and doesn't count them as recent" {
    var conv: Conversation = .init(std.testing.allocator, "sys");
    defer conv.deinit();

    try appendResult(&conv, "extract", 32 * 1024);
    for (0..6) |_| try appendResult(&conv, "html", 20 * 1024);
    for (0..3) |_| try appendResult(&conv, "click", 100);
    conv.compactForRequest();

    try std.testing.expectEqual(32 * 1024, contentOf(&conv, 0).len);
    for (1..4) |i| try std.testing.expect(std.mem.startsWith(u8, contentOf(&conv, i), "[html result"));
    for (4..7) |i| try std.testing.expectEqual(20 * 1024, contentOf(&conv, i).len);
    for (7..10) |i| try std.testing.expectEqual(100, contentOf(&conv, i).len);
}

test "expireImages keeps the newest images and annotates the rest" {
    var conv: Conversation = .init(std.testing.allocator, "sys");
    defer conv.deinit();
    const a = conv.arena.allocator();

    const image = [_]zenai.provider.ContentPart{.{ .image = .{ .data = "AAAA", .mime_type = "image/png" } }};
    for (0..4) |n| {
        const results = try a.alloc(ToolResult, 1);
        results[0] = .{ .id = "c", .name = "screenshot", .content = try a.print("shot {d}", .{n}), .parts = &image };
        try conv.messages.append(std.testing.allocator, .{ .role = .tool, .tool_results = results });
    }

    conv.expireImages();

    try std.testing.expect(conv.messages.items[0].tool_results.?[0].parts == null);
    try std.testing.expectEqualStrings("shot 0 (image dropped from context; call the tool again to look)", conv.messages.items[0].tool_results.?[0].content);
    try std.testing.expect(conv.messages.items[1].tool_results.?[0].parts == null);
    try std.testing.expect(conv.messages.items[2].tool_results.?[0].parts != null);
    try std.testing.expect(conv.messages.items[3].tool_results.?[0].parts != null);
    try std.testing.expectEqualStrings("shot 3", conv.messages.items[3].tool_results.?[0].content);
}
