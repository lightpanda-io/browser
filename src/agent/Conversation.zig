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

/// Cap history growth: once it exceeds `prune_high`, keep the system prompt plus
/// the most recent `prune_keep` messages, snapped to a safe boundary so a
/// tool_call isn't split from its result.
pub fn prune(self: *Conversation) void {
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
