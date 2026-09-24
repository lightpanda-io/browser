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

//! Who decides the next operation. One request carries the operation head and
//! every target head; only the head the chosen operation names is read, so the
//! speculative ones cost a few tokens and no extra round trip.

const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const table = @import("table.zig");
const Operation = table.Operation;

const types = zenai.typesafe.types;

pub const Decision = struct {
    operation: Operation,
    /// The raw target id, still to be resolved against the table.
    target: ?[]const u8 = null,
    /// Probability of the chosen target, or of the operation when it takes none.
    probability: f64 = 0,
    confidence: f64 = 0,
    latency_ms: u64 = 0,
    usage: types.Usage = .{},
};

pub const Error = error{
    /// An answer outside the offered option set. Not retried: a calibrated
    /// decoder returns the same answer for the same state.
    InvalidDecision,
    DeciderFailed,
    OutOfMemory,
};

/// Indirection so the loop can run against a scripted decider in tests and
/// against System One in production.
pub const Decider = struct {
    context: *anyopaque,
    decideFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, table.Ask) Error!Decision,

    pub fn decide(self: Decider, arena: std.mem.Allocator, state: []const u8, ask: table.Ask) Error!Decision {
        return self.decideFn(self.context, arena, state, ask);
    }
};

/// The production decider: `zenai.typesafe` plus the validation that makes a
/// choice safe to act on.
pub const SystemOne = struct {
    client: *zenai.typesafe.Client,
    model: []const u8,
    /// Last transport failure, for the caller's error message.
    last_error: ?[]const u8 = null,
    /// The versioned model the service says answered. An alias moves without
    /// notice, and the gateway exposes nothing but aliases, so this is the
    /// only record of what actually decided a run.
    resolved: ?[]const u8 = null,
    resolved_buf: [64]u8 = undefined,

    pub fn decider(self: *SystemOne) Decider {
        return .{ .context = self, .decideFn = decide };
    }

    fn decide(context: *anyopaque, arena: std.mem.Allocator, state: []const u8, ask: table.Ask) Error!Decision {
        const self: *SystemOne = @ptrCast(@alignCast(context));

        const started: std.Io.Timestamp = .now(lp.io, .boot);
        var response = self.client.ask(.{ .text = state }, ask.entries(), .{ .model = self.model }) catch |err| {
            self.last_error = self.client.last_error.message;
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.DeciderFailed,
            };
        };
        defer response.deinit();
        if (self.resolved == null and response.value.model.len > 0) {
            const n = @min(response.value.model.len, self.resolved_buf.len);
            @memcpy(self.resolved_buf[0..n], response.value.model[0..n]);
            self.resolved = self.resolved_buf[0..n];
        }
        const latency_ms: u64 = @intCast(started.untilNow(lp.io, .boot).toMilliseconds());

        const operation_name = response.value.choice("operation", ask.questions) catch return error.InvalidDecision;
        const operation = std.meta.stringToEnum(Operation, operation_name) orelse return error.InvalidDecision;
        const operation_answer = response.value.answer("operation").?;

        if (!operation.needsTarget()) {
            return .{
                .operation = operation,
                .probability = operation_answer.probability(operation_name) orelse 0,
                .confidence = operation_answer.confidence() orelse 0,
                .latency_ms = latency_ms,
                .usage = response.value.usage,
            };
        }

        // The speculative heads cannot reach the browser, so they are not
        // validated.
        const question = operation.targetQuestion().?;
        const target = response.value.choice(question, ask.questions) catch return error.InvalidDecision;
        const target_answer = response.value.answer(question).?;

        return .{
            .operation = operation,
            // The answers borrow the response, which dies with this scope.
            .target = try arena.dupe(u8, target),
            .probability = target_answer.probability(target) orelse 0,
            .confidence = target_answer.confidence() orelse 0,
            .latency_ms = latency_ms,
            .usage = response.value.usage,
        };
    }
};
