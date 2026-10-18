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

// An AudioParam's automation events.
// https://webaudio.github.io/web-audio-api/#computation-of-value

const std = @import("std");

const Allocator = std.mem.Allocator;

const Timeline = @This();

events: std.ArrayList(Event) = .empty,
// The param's value when the first event was scheduled: what it holds until
// that event, and where a set_target with nothing before it decays from.
base: f32 = 0,

pub const Kind = enum {
    set_value,
    linear_ramp,
    exponential_ramp,
    set_target,
    set_value_curve,
};

pub const Event = struct {
    kind: Kind,
    // A ramp's end time; every other kind's start time.
    time: f64,
    value: f32 = 0,
    time_constant: f64 = 0,
    // set_value_curve: the duration the curve's values are spread over, and
    // when the event stops holding the timeline (earlier after a
    // cancelAndHoldAtTime).
    duration: f64 = 0,
    end_time: f64 = 0,
    curve: []const f32 = &.{},
    // A ramp with no event before it starts from where the param was when the
    // ramp was scheduled.
    start_time: f64 = 0,
    start_value: f32 = 0,

    fn isRamp(self: *const Event) bool {
        return self.kind == .linear_ramp or self.kind == .exponential_ramp;
    }

    // When the next event takes over. Curves hold their last value from
    // end_time on, like the implicit setValueAtTime the spec inserts there.
    fn endTime(self: *const Event) f64 {
        return if (self.kind == .set_value_curve) self.end_time else self.time;
    }
};

pub const InsertError = error{NotSupported} || Allocator.Error;

pub fn isEmpty(self: *const Timeline) bool {
    return self.events.items.len == 0;
}

// `current` is the param's value now.
pub fn insert(self: *Timeline, allocator: Allocator, event: Event, current: f32) InsertError!void {
    const events = self.events.items;
    for (events) |*e| {
        // nothing goes in a curve's [start, end), and a curve can't span an
        // event (one at its start time is fine)
        if (e.kind == .set_value_curve and event.time >= e.time and event.time < e.end_time) {
            return error.NotSupported;
        }
        if (event.kind == .set_value_curve and e.time > event.time and e.time < event.end_time) {
            return error.NotSupported;
        }
    }

    if (events.len == 0) {
        self.base = current;
    }
    // after every event at the same time
    var index: usize = events.len;
    for (events, 0..) |*e, i| {
        if (e.time > event.time) {
            index = i;
            break;
        }
    }
    // A set_value right after another at the same time overrides it, so
    // repeatedly assigning `value` doesn't grow the list.
    if (event.kind == .set_value and index > 0) {
        const previous = &events[index - 1];
        if (previous.kind == .set_value and previous.time == event.time) {
            previous.* = event;
            return;
        }
    }
    try self.events.insert(allocator, index, event);
}

// Drops the events that only matter before `now`, so a long render doesn't
// walk its whole history for every frame. What they left behind becomes
// `base`: where the first remaining event starts from.
pub fn prune(self: *Timeline, now: f64) void {
    const events = self.events.items;
    var first: usize = 0;
    for (events, 0..) |*e, i| {
        if (e.time <= now) first = i;
    }
    if (first == 0) {
        return;
    }
    self.base = valueIn(events[0..first], events[first].time, self.base);
    self.events.replaceRangeAssumeCapacity(0, first, &.{});
}

pub fn cancelScheduledValues(self: *Timeline, cancel_time: f64) void {
    var keep: usize = 0;
    for (self.events.items) |e| {
        const active_curve = e.kind == .set_value_curve and e.time < cancel_time and cancel_time < e.end_time;
        if (e.time >= cancel_time or active_curve) {
            continue;
        }
        self.events.items[keep] = e;
        keep += 1;
    }
    self.events.shrinkRetainingCapacity(keep);
}

pub fn cancelAndHoldAtTime(self: *Timeline, allocator: Allocator, cancel_time: f64) Allocator.Error!void {
    const events = self.events.items;

    // The first event to cancel: anything starting at or after the cancel
    // time, or a ramp still running then.
    var first: usize = events.len;
    for (events, 0..) |*e, i| {
        const started = if (e.isRamp()) e.time <= cancel_time else e.time < cancel_time;
        if (started == false) {
            first = i;
            break;
        }
    }

    if (first < events.len and events[first].isRamp()) {
        // the running ramp now ends at the cancel time, where it was
        const hold = self.valueAt(cancel_time, self.base);
        events[first].time = cancel_time;
        events[first].value = hold;
        self.events.shrinkRetainingCapacity(first + 1);
        return;
    }

    self.events.shrinkRetainingCapacity(first);
    const last = if (first > 0) &self.events.items[first - 1] else return;
    const hold = self.valueAt(cancel_time, self.base);
    switch (last.kind) {
        .set_target => {},
        .set_value_curve => {
            if (cancel_time >= last.end_time) return;
            last.end_time = cancel_time;
        },
        else => return,
    }
    try self.events.append(allocator, .{ .kind = .set_value, .time = cancel_time, .value = hold });
}

// The automation value at time t; `current` (the param's value) when nothing
// is scheduled.
pub fn valueAt(self: *const Timeline, t: f64, current: f32) f32 {
    if (self.events.items.len == 0) {
        return current;
    }
    return valueIn(self.events.items, t, self.base);
}

// One pass over the events, tracking the automation in effect.
fn valueIn(events: []const Event, t: f64, base: f32) f32 {
    var active: Active = .{ .constant = base };
    var previous_end: ?f64 = null;
    for (events) |*e| {
        if (e.isRamp()) {
            // from the previous event's end (or where the param was when
            // the ramp was scheduled) to this event's time
            const t0, const v0 = if (previous_end) |end| .{ end, active.at(end) } else .{ e.start_time, e.start_value };
            if (t < t0) {
                // still in the previous event (a curve), or before the first
                return if (previous_end == null) base else active.at(t);
            }
            if (t < e.time) {
                return rampValue(e, t0, v0, t);
            }
            active = .{ .constant = e.value };
        } else {
            if (e.time > t) break;
            const start = active.at(e.time);
            active = switch (e.kind) {
                .set_value => .{ .constant = e.value },
                .set_target => .{ .target = .{ .event = e, .start = start } },
                .set_value_curve => .{ .curve = e },
                .linear_ramp, .exponential_ramp => unreachable,
            };
        }
        previous_end = e.endTime();
    }
    return active.at(t);
}

const Active = union(enum) {
    constant: f32,
    target: struct { event: *const Event, start: f32 },
    curve: *const Event,

    fn at(self: Active, t: f64) f32 {
        return switch (self) {
            .constant => |v| v,
            .target => |target| blk: {
                const e = target.event;
                if (e.time_constant == 0) break :blk e.value;
                const decay = std.math.exp(-(t - e.time) / e.time_constant);
                break :blk @floatCast(e.value + (target.start - e.value) * decay);
            },
            .curve => |e| curveValue(e, t),
        };
    }
};

fn rampValue(ramp: *const Event, t0: f64, v0: f32, t: f64) f32 {
    const t1 = ramp.time;
    const v1 = ramp.value;
    if (t1 <= t0) return v1;
    const fraction = (t - t0) / (t1 - t0);
    if (ramp.kind == .linear_ramp) {
        return @floatCast(v0 + (v1 - v0) * fraction);
    }
    // An exponential ramp from 0, or across 0, holds its start value.
    if (v0 == 0 or (v0 < 0) != (v1 < 0)) {
        return v0;
    }
    const ratio: f64 = v1 / v0;
    return @floatCast(v0 * std.math.pow(f64, ratio, fraction));
}

fn curveValue(e: *const Event, t: f64) f32 {
    const curve = e.curve;
    const n = curve.len;
    if (t >= e.time + e.duration) {
        return curve[n - 1];
    }
    const position = @as(f64, @floatFromInt(n - 1)) / e.duration * (t - e.time);
    const k: usize = @intFromFloat(@floor(position));
    if (k + 1 >= n) {
        return curve[n - 1];
    }
    const fraction: f32 = @floatCast(position - @as(f64, @floatFromInt(k)));
    return curve[k] + (curve[k + 1] - curve[k]) * fraction;
}

// Whether the value can change at or after `t`, i.e. a per-frame computation
// is needed. Mirrors Chrome's AudioParamHandler::HasSampleAccurateValues,
// which the oscillator's bit-exact output depends on.
pub fn hasSampleAccurateValues(self: *const Timeline, quantum_start: f64, quantum_end: f64) bool {
    const events = self.events.items;
    if (events.len == 0) return false;

    const first = &events[0];
    if (first.time > quantum_end) {
        switch (first.kind) {
            .set_target, .set_value, .set_value_curve => return false,
            else => {},
        }
    }
    if (events.len >= 2) return true;

    return switch (first.kind) {
        .set_target => first.time <= quantum_end,
        .set_value, .linear_ramp, .exponential_ramp => (first.time < quantum_start) == false,
        .set_value_curve => first.time <= quantum_start and quantum_start < first.time + first.duration,
    };
}

const testing = std.testing;
fn testInsert(tl: *Timeline, event: Event) !void {
    return tl.insert(testing.allocator, event, 1);
}

fn expectValue(timeline: *const Timeline, t: f64, expected: f32) !void {
    try testing.expectApproxEqAbs(expected, timeline.valueAt(t, 1), 1e-6);
}

test "Timeline: set value and ramps" {
    var tl: Timeline = .{};
    defer tl.events.deinit(testing.allocator);
    try testInsert(&tl, .{ .kind = .set_value, .time = 1, .value = 0 });
    try testInsert(&tl, .{ .kind = .linear_ramp, .time = 2, .value = 10 });
    try testInsert(&tl, .{ .kind = .exponential_ramp, .time = 3, .value = 1000 });

    try expectValue(&tl, 0.5, 1);
    try expectValue(&tl, 1, 0);
    try expectValue(&tl, 1.5, 5);
    try expectValue(&tl, 2, 10);
    try expectValue(&tl, 2.5, 100);
    try expectValue(&tl, 4, 1000);
}

test "Timeline: ramp with nothing before it" {
    var tl: Timeline = .{};
    defer tl.events.deinit(testing.allocator);
    try testInsert(&tl, .{ .kind = .linear_ramp, .time = 2, .value = 3, .start_time = 1, .start_value = 1 });
    try expectValue(&tl, 0.5, 1);
    try expectValue(&tl, 1.5, 2);
    try expectValue(&tl, 3, 3);
}

test "Timeline: set target and curve" {
    var tl: Timeline = .{};
    defer tl.events.deinit(testing.allocator);
    try testInsert(&tl, .{ .kind = .set_value, .time = 0, .value = 1 });
    try testInsert(&tl, .{ .kind = .set_target, .time = 1, .value = 0, .time_constant = 1 });
    try expectValue(&tl, 2, @floatCast(std.math.exp(-1.0)));

    const curve = [_]f32{ 0, 2, 4 };
    try testInsert(&tl, .{ .kind = .set_value_curve, .time = 3, .duration = 2, .end_time = 5, .curve = &curve });
    try expectValue(&tl, 3.5, 1);
    try expectValue(&tl, 4.5, 3);
    try expectValue(&tl, 6, 4);

    try testing.expectError(error.NotSupported, testInsert(&tl, .{ .kind = .set_value, .time = 4, .value = 1 }));
}

test "Timeline: ramp after a curve" {
    var tl: Timeline = .{};
    defer tl.events.deinit(testing.allocator);
    const curve = [_]f32{ 0, 2, 4 };
    try testInsert(&tl, .{ .kind = .set_value_curve, .time = 1, .duration = 1, .end_time = 2, .curve = &curve });
    try testInsert(&tl, .{ .kind = .linear_ramp, .time = 3, .value = 10 });
    try expectValue(&tl, 1.5, 2);
    try expectValue(&tl, 2.5, 7);

    // a ramp at the curve's end
    try testInsert(&tl, .{ .kind = .linear_ramp, .time = 2, .value = 10 });
    try expectValue(&tl, 1.5, 2);
    try expectValue(&tl, 2, 10);
}

test "Timeline: prune" {
    var tl: Timeline = .{};
    defer tl.events.deinit(testing.allocator);
    try testInsert(&tl, .{ .kind = .set_value, .time = 0, .value = 0 });
    try testInsert(&tl, .{ .kind = .linear_ramp, .time = 2, .value = 2 });
    try testInsert(&tl, .{ .kind = .set_target, .time = 3, .value = 0, .time_constant = 1 });
    const decayed: f32 = @floatCast(2 * std.math.exp(-1.0));

    tl.prune(1);
    try testing.expectEqual(3, tl.events.items.len);
    tl.prune(2.5);
    try testing.expectEqual(2, tl.events.items.len);
    try expectValue(&tl, 2.5, 2);
    try expectValue(&tl, 4, decayed);
    // the set_target keeps decaying from where the ramp left the param
    tl.prune(3.5);
    try testing.expectEqual(1, tl.events.items.len);
    try expectValue(&tl, 4, decayed);
}

test "Timeline: cancel and hold" {
    var tl: Timeline = .{};
    defer tl.events.deinit(testing.allocator);
    try testInsert(&tl, .{ .kind = .set_value, .time = 0, .value = 0 });
    try testInsert(&tl, .{ .kind = .linear_ramp, .time = 2, .value = 2 });
    try tl.cancelAndHoldAtTime(testing.allocator, 1);
    try expectValue(&tl, 0.5, 0.5);
    try expectValue(&tl, 1, 1);
    try expectValue(&tl, 3, 1);

    tl.cancelScheduledValues(0.5);
    try expectValue(&tl, 3, 0);
}
