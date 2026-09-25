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

//! The decision loop: observe, decide once, execute, repeat. It knows nothing
//! about the `Agent`, the terminal or any provider — a `Decider` and a
//! `Generator` are all it needs, which is what makes it runnable offline
//! against scripted answers.

const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const decider_mod = @import("decider.zig");
const prompts = @import("prompts.zig");
const table = @import("table.zig");
const DomInput = @import("../../browser/webapi/element/html/Input.zig");
const text = @import("text.zig");

const Decider = decider_mod.Decider;
const Operation = table.Operation;
const Step = table.Step;
const Table = table.Table;

pub const Outcome = enum {
    done,
    /// The decider gave up, or the page stopped responding.
    blocked,
    budget,
    cancelled,
};

pub const Result = struct {
    outcome: Outcome,
    steps: u32,
    /// Where the run ended up. Upstream leaves verifying the goal to the
    /// caller, and so does this.
    url: []const u8,
};

/// `NoTextGenerator` is TYPE_TEXT coming up with no text model configured.
pub const Error = table.ObserveError || decider_mod.Error || error{NoTextGenerator};

/// Lets a caller watch the loop without the loop knowing what it is talking to.
pub const Hooks = struct {
    context: *anyopaque,
    /// After a step executed.
    onStep: ?*const fn (*anyopaque, Step) void = null,
    /// Polled before each decision and before each execution.
    cancelled: ?*const fn (*anyopaque) bool = null,
};

/// How many consecutive non-WAIT steps may leave the page untouched before
/// the run is called stuck. jev-ultrafast uses the same three.
pub const default_max_actions = 60;

const stuck_streak = 3;

pub const Runner = struct {
    allocator: std.mem.Allocator,
    session: *lp.Session,
    registry: *lp.NodeRegistry,
    decider: Decider,
    /// Absent when no chat model is configured; TYPE_TEXT then fails loudly
    /// rather than typing a guess.
    generator: ?text.Generator = null,
    goal: []const u8,
    max_actions: u32 = default_max_actions,
    hooks: ?Hooks = null,

    /// Decider tokens across the whole run, for the `$usage` line.
    usage: zenai.typesafe.types.Usage = .{},

    history: std.ArrayList(Step) = .empty,
    /// Backs the strings inside `history`, which outlive the turn arenas they
    /// were observed in but die with the run.
    history_arena: std.heap.ArenaAllocator,
    cache: text.Cache,

    pub fn init(allocator: std.mem.Allocator, session: *lp.Session, registry: *lp.NodeRegistry, dec: Decider, goal: []const u8) Runner {
        return .{
            .allocator = allocator,
            .session = session,
            .registry = registry,
            .decider = dec,
            .goal = goal,
            .history_arena = .init(allocator),
            .cache = .init(allocator),
        };
    }

    pub fn deinit(self: *Runner) void {
        self.history.deinit(self.allocator);
        self.history_arena.deinit();
        self.cache.deinit();
    }

    pub fn run(self: *Runner) Error!Result {
        // The turn's observation after acting is the next turn's observation
        // before deciding — the page cannot move in between. Carrying it needs
        // two arenas: the one holding the carried table stays alive while the
        // other is reset, so each is two turns old when it is reused.
        var arenas: [2]std.heap.ArenaAllocator = .{ .init(self.allocator), .init(self.allocator) };
        defer for (&arenas) |*a| a.deinit();
        var scratch: usize = 0;
        var carried: ?Table = null;

        while (true) {
            if (self.cancelled()) return self.finish(.cancelled, carried);
            if (self.history.items.len >= self.max_actions) return self.finish(.budget, carried);
            if (isStuck(self.history.items)) return self.finish(.blocked, carried);

            _ = arenas[scratch].reset(.retain_capacity);
            const arena = arenas[scratch].allocator();

            const before = carried orelse
                try table.observe(arena, self.session, self.registry, .{});
            const ask = try table.ask(arena, before, .{ .can_type = self.generator != null });
            const state = try table.stateJson(arena, before, self.goal, @intCast(self.history.items.len + 1), self.history.items);

            const decision = try self.decider.decide(arena, state, ask);
            self.usage.input_tokens += decision.usage.input_tokens;
            self.usage.output_tokens += decision.usage.output_tokens;
            switch (decision.operation) {
                // The turn's observation is the closing page.
                .DONE => return self.finish(.done, before),
                .BLOCKED => return self.finish(.blocked, before),
                else => {},
            }

            var target: ?table.Target = null;
            if (decision.operation.needsTarget()) {
                const raw = decision.target orelse return error.InvalidDecision;
                target = before.parseTarget(decision.operation, raw) catch return error.InvalidDecision;
            }

            var typed: ?[]const u8 = null;
            if (decision.operation == .TYPE_TEXT) {
                const generator = self.generator orelse return error.NoTextGenerator;
                const helper_input = try text.input(arena, self.goal, target.?.element, before, self.history.items);

                if (self.cache.get(helper_input)) |cached| {
                    typed = cached;
                } else if (generator.generate(arena, prompts.text_value, helper_input) catch null) |value| {
                    try self.cache.put(helper_input, value);
                    typed = value;
                } else {
                    // The helper declined to invent a value. Record the dead
                    // end so the decider stops proposing this field.
                    var step = try self.stepFrom(decision, target);
                    step.ok = false;
                    try self.record(step);
                    // Not `before`: it may live in this turn's arena, which
                    // the next turn resets. Only a table observed into the
                    // arena a turn *keeps* can be carried.
                    carried = null;
                    continue;
                }

                // The helper call is the one gap wide enough for the page to
                // move under a decision; re-read and drop the decision if it
                // did. The value stays cached for the retry.
                if (try self.moved(arena, before)) {
                    carried = null;
                    continue;
                }
            }

            if (self.cancelled()) return self.finish(.cancelled, before);
            if (!before.live(self.registry)) {
                // Every id in `before` was evicted; nothing here is addressable.
                carried = null;
                continue;
            }

            const invocation = try toolCall(arena, decision.operation, target, typed);
            const result = lp.tools.call(arena, self.session, self.registry, invocation.tool, invocation.arguments, .{}) catch |err| blk: {
                break :blk lp.tools.ToolResult{ .text = lp.tools.errorMessage(err), .is_error = true };
            };

            // Let the page answer the action before looking at it. Upstream
            // waits two animation frames; the equivalent here is to give the
            // io loop a brief turn, which costs far less than spending a whole
            // model round to discover the page was mid-update.
            self.settle();

            const after = try table.observe(arena, self.session, self.registry, .{});
            var step = try self.stepFrom(decision, target);
            step.text = if (typed) |t| try self.history_arena.allocator().dupe(u8, t) else null;
            step.ok = !result.is_error;
            step.page_changed = table.changed(before, after);
            try self.record(step);
            self.cache.clear();

            // `after` lives in this turn's arena, which the next turn leaves
            // alone and the one after that resets.
            carried = after;
            scratch = 1 - scratch;
        }
    }

    /// `closing` is the turn's observation when the loop ends mid-turn, which
    /// saves re-walking a page already in hand; the guard paths have none.
    /// Must outlive the turn arenas, so the result owns its copies.
    fn finish(self: *Runner, outcome: Outcome, closing: ?Table) Error!Result {
        const url = if (closing) |c| c.url else if (self.session.currentFrame()) |f| f.url else "";
        return .{
            .outcome = outcome,
            .steps = @intCast(self.history.items.len),
            .url = try self.allocator.dupe(u8, url),
        };
    }

    fn record(self: *Runner, step: Step) Error!void {
        try self.history.append(self.allocator, step);
        const hooks = self.hooks orelse return;
        if (hooks.onStep) |hook| hook(hooks.context, step);
    }

    fn cancelled(self: *Runner) bool {
        const hooks = self.hooks orelse return false;
        const hook = hooks.cancelled orelse return false;
        return hook(hooks.context);
    }

    /// Drain whatever the action set in motion before observing the result.
    /// With no conditions the tick waits on nothing: it runs pending tasks,
    /// waits out v8's background work, and returns. The timeout is a ceiling
    /// that is never reached, not a sleep.
    ///
    /// Deliberately not `waitForState`: that waits on a frame reaching a
    /// navigation state, which a click that only mutates the DOM never
    /// reaches, so it blocks until its own timeout — or, where no frame event
    /// is coming at all, indefinitely.
    /// The fields both record sites share. Whatever a step reports about its
    /// outcome, the caller sets.
    fn stepFrom(self: *Runner, decision: decider_mod.Decision, target: ?table.Target) Error!Step {
        const kept = self.history_arena.allocator();
        return .{
            .number = @intCast(self.history.items.len + 1),
            .op = decision.operation,
            .target = if (decision.target) |t| try kept.dupe(u8, t) else null,
            .label = if (target) |t| try kept.dupe(u8, t.element.label) else "",
            .probability = decision.probability,
            .confidence = decision.confidence,
            .latency_ms = decision.latency_ms,
        };
    }

    fn settle(self: *Runner) void {
        var pump = self.session.runner(.{});
        _ = pump.tick(settle_timeout_ms, &.{}) catch {};
    }

    fn moved(self: *Runner, arena: std.mem.Allocator, before: Table) Error!bool {
        // The usual answer is "no", and a monotonic counter settles that
        // without walking the DOM again.
        const frame = self.session.currentFrame() orelse return true;
        if (frame.page.style_version == before.style_version) return false;
        if (!before.live(self.registry)) return true;
        const now = try table.observe(arena, self.session, self.registry, .{ .text_bytes = 0 });
        return table.changed(before, now);
    }
};

/// Three consecutive real actions that left the page exactly as it was. WAIT
/// is excluded: waiting is *supposed* to change nothing, so counting it would
/// call a legitimately loading page stuck.
pub fn isStuck(history: []const Step) bool {
    var seen: usize = 0;
    var i = history.len;
    while (i > 0 and seen < stuck_streak) {
        i -= 1;
        const step = history[i];
        if (step.op == .WAIT) continue;
        if (step.page_changed) return false;
        seen += 1;
    }
    return seen == stuck_streak;
}

pub const Invocation = struct {
    tool: []const u8,
    arguments: std.json.Value,
};

/// Map a decision onto a browser tool. Going through `lp.tools.call` rather
/// than `lp.actions` is what buys the navigation drain, the popup follow, the
/// registry reset on a frame swap and the `$LP_*` substitution.
pub fn toolCall(
    arena: std.mem.Allocator,
    op: Operation,
    target: ?table.Target,
    typed: ?[]const u8,
) std.mem.Allocator.Error!Invocation {
    var object: std.json.ObjectMap = .empty;
    switch (op) {
        .CLICK => {
            // A checkbox or radio goes through `click` too: `setChecked`
            // rejects unchecking a radio and short-circuits a no-op, both of
            // which surface as failures the decider cannot act on.
            try object.put(arena, "backendNodeId", .{ .integer = target.?.element.node_id });
            return .{ .tool = "click", .arguments = .{ .object = object } };
        },
        .TYPE_TEXT => {
            try object.put(arena, "backendNodeId", .{ .integer = target.?.element.node_id });
            try object.put(arena, "value", .{ .string = typed.? });
            return .{ .tool = "fill", .arguments = .{ .object = object } };
        },
        .SELECT => {
            try object.put(arena, "backendNodeId", .{ .integer = target.?.element.node_id });
            try object.put(arena, "value", .{ .string = target.?.option.? });
            return .{ .tool = "selectOption", .arguments = .{ .object = object } };
        },
        .WAIT => {
            try object.put(arena, "state", .{ .string = "networkidle" });
            try object.put(arena, "timeout", .{ .integer = wait_timeout_ms });
            return .{ .tool = "waitForState", .arguments = .{ .object = object } };
        },
        .DONE, .BLOCKED => unreachable,
    }
}

/// Shorter than `waitForState`'s own default: a WAIT costs a whole decision
/// cycle, so it should return to the decider quickly.
const wait_timeout_ms = 3000;

/// Ceiling on the post-action drain, upstream's non-autocomplete bound.
const settle_timeout_ms = 50;

const testing = @import("../../testing.zig");

/// Replays a fixed list of decisions.
const ScriptedDecider = struct {
    decisions: []const decider_mod.Decision,
    /// Every state document the loop produced, for assertions about what the
    /// decider would have seen.
    seen: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,
    calls: usize = 0,

    fn decider(self: *ScriptedDecider) Decider {
        return .{ .context = self, .decideFn = decide };
    }

    fn deinit(self: *ScriptedDecider) void {
        for (self.seen.items) |state| self.allocator.free(state);
        self.seen.deinit(self.allocator);
    }

    fn decide(context: *anyopaque, _: std.mem.Allocator, state: []const u8, _: table.Ask) decider_mod.Error!decider_mod.Decision {
        const self: *ScriptedDecider = @ptrCast(@alignCast(context));
        self.seen.append(self.allocator, self.allocator.dupe(u8, state) catch return error.OutOfMemory) catch
            return error.OutOfMemory;
        if (self.calls >= self.decisions.len) return .{ .operation = .BLOCKED };
        defer self.calls += 1;
        return self.decisions[self.calls];
    }
};

const ScriptedGenerator = struct {
    value: ?[]const u8,
    calls: usize = 0,

    fn generator(self: *ScriptedGenerator) text.Generator {
        return .{ .context = self, .generateFn = generate };
    }

    fn generate(context: *anyopaque, arena: std.mem.Allocator, _: []const u8, _: []const u8) text.Error!?[]const u8 {
        const self: *ScriptedGenerator = @ptrCast(@alignCast(context));
        self.calls += 1;
        const value = self.value orelse return null;
        return arena.dupe(u8, value) catch return error.OutOfMemory;
    }
};

test "toolCall: each operation lands on the tool that carries the guards" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const element: table.Element = .{
        .index = @enumFromInt(1),
        .node_id = 42,
        .role = "combobox",
        .label = "Party size",
        .value = "2",
        .checked = null,
        .ops = .{ .click = true, .type_text = true, .select = true },
        .options = &.{"6"},
    };
    const target: table.Target = .{ .element = &element, .option = "6" };

    const click = try toolCall(a, .CLICK, target, null);
    try std.testing.expectEqualStrings("click", click.tool);
    try std.testing.expectEqualStrings(
        \\{"backendNodeId":42}
    , try std.json.Stringify.valueAlloc(a, click.arguments, .{}));

    const fill = try toolCall(a, .TYPE_TEXT, target, "ramen");
    try std.testing.expectEqualStrings("fill", fill.tool);
    try std.testing.expectEqualStrings(
        \\{"backendNodeId":42,"value":"ramen"}
    , try std.json.Stringify.valueAlloc(a, fill.arguments, .{}));

    const select = try toolCall(a, .SELECT, target, null);
    try std.testing.expectEqualStrings("selectOption", select.tool);
    try std.testing.expectEqualStrings(
        \\{"backendNodeId":42,"value":"6"}
    , try std.json.Stringify.valueAlloc(a, select.arguments, .{}));

    const wait = try toolCall(a, .WAIT, null, null);
    try std.testing.expectEqualStrings("waitForState", wait.tool);
    try std.testing.expectEqualStrings(
        \\{"state":"networkidle","timeout":3000}
    , try std.json.Stringify.valueAlloc(a, wait.arguments, .{}));
}

test "isStuck: three real actions that moved nothing, WAIT excluded" {
    const moved: Step = .{ .number = 0, .op = .CLICK, .page_changed = true };
    const still: Step = .{ .number = 0, .op = .CLICK, .page_changed = false };
    const waited: Step = .{ .number = 0, .op = .WAIT, .page_changed = false };

    try std.testing.expect(!isStuck(&.{}));
    try std.testing.expect(!isStuck(&.{ still, still }));
    try std.testing.expect(isStuck(&.{ still, still, still }));
    try std.testing.expect(!isStuck(&.{ still, still, moved }));
    // A run that is merely waiting is not stuck, however long it waits.
    try std.testing.expect(!isStuck(&.{ waited, waited, waited }));
    try std.testing.expect(isStuck(&.{ still, waited, still, waited, still }));
    // The streak is the *recent* one; older stillness does not count.
    try std.testing.expect(!isStuck(&.{ still, still, still, moved }));
}

test "run: types, clicks and stops, against scripted answers" {
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("jev/action_space.html", .{ .wait_until_done = true });
    defer page.close();

    var script: ScriptedDecider = .{
        .allocator = std.testing.allocator,
        .decisions = &.{
            // The search box is index 1, the submit button index 5.
            .{ .operation = .TYPE_TEXT, .target = "1", .probability = 0.9, .confidence = 0.8 },
            .{ .operation = .CLICK, .target = "5", .probability = 0.7, .confidence = 0.6 },
            .{ .operation = .DONE, .probability = 0.95, .confidence = 0.9 },
        },
    };
    defer script.deinit();
    var generator: ScriptedGenerator = .{ .value = "gyoza" };

    var loop: Runner = .init(std.testing.allocator, page.session, &registry, script.decider(), "find gyoza");
    defer loop.deinit();
    loop.generator = generator.generator();

    const result = try loop.run();
    defer std.testing.allocator.free(result.url);

    try std.testing.expectEqual(Outcome.done, result.outcome);
    try std.testing.expectEqual(@as(u32, 2), result.steps);
    try std.testing.expectEqual(@as(usize, 1), generator.calls);

    const frame = page.frame().?;
    const input = (try frame.document.querySelector(.wrap("#q"), frame)).?;
    try std.testing.expectEqualStrings("gyoza", input.is(DomInput).?.getValue());

    // The decider was handed the goal and the indexed table, never a node id.
    try std.testing.expect(std.mem.indexOf(u8, script.seen.items[0], "\"goal\":\"find gyoza\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.seen.items[0], "\"i\":1") != null);
    // The second state carries the first action's outcome.
    try std.testing.expect(std.mem.indexOf(u8, script.seen.items[1], "\"op\":\"TYPE_TEXT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script.seen.items[1], "\"text\":\"gyoza\"") != null);
}

test "run: a decision the table cannot resolve executes nothing" {
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("jev/action_space.html", .{ .wait_until_done = true });
    defer page.close();

    var script: ScriptedDecider = .{
        .allocator = std.testing.allocator,
        // Index 99 was never offered.
        .decisions = &.{.{ .operation = .CLICK, .target = "99" }},
    };
    defer script.deinit();

    var loop: Runner = .init(std.testing.allocator, page.session, &registry, script.decider(), "click something");
    defer loop.deinit();

    try std.testing.expectError(error.InvalidDecision, loop.run());
    try std.testing.expectEqual(@as(usize, 0), loop.history.items.len);
}

test "run: TYPE_TEXT without a text model fails rather than guessing" {
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("jev/action_space.html", .{ .wait_until_done = true });
    defer page.close();

    var script: ScriptedDecider = .{
        .allocator = std.testing.allocator,
        .decisions = &.{.{ .operation = .TYPE_TEXT, .target = "1" }},
    };
    defer script.deinit();

    var loop: Runner = .init(std.testing.allocator, page.session, &registry, script.decider(), "type something");
    defer loop.deinit();

    try std.testing.expectError(error.NoTextGenerator, loop.run());
}

test "run: a helper that declines records a dead end instead of typing" {
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("jev/action_space.html", .{ .wait_until_done = true });
    defer page.close();

    var script: ScriptedDecider = .{
        .allocator = std.testing.allocator,
        .decisions = &.{
            .{ .operation = .TYPE_TEXT, .target = "1" },
            .{ .operation = .BLOCKED },
        },
    };
    defer script.deinit();
    var generator: ScriptedGenerator = .{ .value = null };

    var loop: Runner = .init(std.testing.allocator, page.session, &registry, script.decider(), "type a password");
    defer loop.deinit();
    loop.generator = generator.generator();

    const result = try loop.run();
    defer std.testing.allocator.free(result.url);

    try std.testing.expectEqual(Outcome.blocked, result.outcome);
    try std.testing.expectEqual(@as(usize, 1), loop.history.items.len);
    try std.testing.expect(!loop.history.items[0].ok);

    // The field was left alone.
    const frame = page.frame().?;
    const input = (try frame.document.querySelector(.wrap("#q"), frame)).?;
    try std.testing.expectEqualStrings("ramen", input.is(DomInput).?.getValue());
}

test "run: the action budget stops a decider that never finishes" {
    var registry: lp.NodeRegistry = .init(std.testing.allocator);
    defer registry.deinit();

    var page = try testing.pageTest("jev/action_space.html", .{ .wait_until_done = true });
    defer page.close();

    // WAIT is excluded from the stuck heuristic, so only the budget ends this.
    var script: ScriptedDecider = .{
        .allocator = std.testing.allocator,
        .decisions = &.{
            .{ .operation = .WAIT },
            .{ .operation = .WAIT },
            .{ .operation = .WAIT },
            .{ .operation = .WAIT },
        },
    };
    defer script.deinit();

    var loop: Runner = .init(std.testing.allocator, page.session, &registry, script.decider(), "wait forever");
    defer loop.deinit();
    loop.max_actions = 3;

    const result = try loop.run();
    defer std.testing.allocator.free(result.url);

    try std.testing.expectEqual(Outcome.budget, result.outcome);
    try std.testing.expectEqual(@as(u32, 3), result.steps);
}
