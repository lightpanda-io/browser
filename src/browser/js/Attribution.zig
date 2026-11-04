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
const std = @import("std");
const lp = @import("lightpanda");
const js = @import("js.zig");

const log = lp.log;
const Isolate = js.Isolate;
const IS_DEBUG = lp.IS_DEBUG;

const Attribution = @This();

isolate: Isolate,
last_id: u29 = 0,

pub const Kind = enum {
    script,
    timeout,
    interval,
    animation_frame,
    idle,
    request,
    message,
    observer,
    event,
    callback,
};

// Lives in V8's continuation-preserved embedder data as a Smi, hence u30.
// The `id` is just for logging. `tracked` is what actually matters. It lets
// "begin" inherit `tracked` from its caller.
pub const Tag = packed struct(u30) {
    tracked: bool,
    id: u29,

    pub fn format(self: Tag, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return writer.print("{d}", .{self.id});
    }
};

const max_id = std.math.maxInt(u29);

// A timeout that's at least his long stops the chain. Number is a guess, but
// presumably there isn't a great reason to wait 100ms for essential content.
pub const short_timeout_ms = 100;

pub fn isTracked(tag: ?Tag) bool {
    const t = tag orelse return false;
    return t.tracked;
}

pub const BeginOpts = struct {
    label: []const u8 = "", // A url, timer name, ...
    detail: []const u8 = "", // A request's resource type, ...
    delay_ms: ?u32 = null,
    cut: bool = false, // An untracked chain, e.g. a WebSocket message.
    root: bool = false, // A tracked chain whatever the parent
    parent: ??Tag = null, // can be explicitly nulled
};

// Hands out the next task id and logs it.
pub fn begin(self: *Attribution, kind: Kind, opts: BeginOpts) Tag {
    const id = if (self.last_id >= max_id) 1 else self.last_id + 1;
    self.last_id = id;

    const parent = opts.parent orelse self.current();
    const tracked = opts.root or (isTracked(parent) and !opts.cut and !isACut(kind, opts.delay_ms));
    const tag: Tag = .{ .id = id, .tracked = tracked };
    if (comptime IS_DEBUG) {
        log.debug(.attribution, "task", .{
            .id = tag,
            .parent = parent,
            .kind = kind,
            .label = opts.label,
            .detail = opts.detail,
            .delay_ms = opts.delay_ms,
            .tracked = tracked,
        });
    }
    return tag;
}

fn isACut(kind: Kind, delay_ms: ?u32) bool {
    return switch (kind) {
        .interval, .idle => true,
        .timeout => (delay_ms orelse 0) >= short_timeout_ms,
        else => false,
    };
}

// Per Page, tracks work that hasn't finished yet
pub const Settle = struct {
    pending: u32 = 0,

    // Takes one count when `task` is tracked; the Hold gives it back.
    pub fn hold(self: *Settle, task: ?Tag) Hold {
        if (!isTracked(task)) {
            return .{};
        }
        self.pending += 1;
        return .{ .settle = self };
    }
};

// Taken when an action wants to hold the settle, released when it's done
pub const Hold = struct {
    // Nullable for two reasons:
    // 1 - double-release is safe and
    // 2 - Cases which conditionally can hold a null settle and release it so
    // that every case is just a hold + defer release.
    settle: ?*Settle = null,

    pub fn release(self: *Hold) void {
        const settle = self.settle orelse return;
        self.settle = null;
        if (comptime lp.IS_DEBUG) {
            lp.assert(settle.pending > 0, "Settle.release underflow", .{});
        }
        settle.pending -|= 1;
    }
};

pub fn current(self: *const Attribution) ?Tag {
    var hs: js.HandleScope = undefined;
    hs.init(self.isolate);
    defer hs.deinit();
    const raw = self.isolate.getContinuationTag() orelse return null;
    return @bitCast(raw);
}

pub const Scope = struct {
    prev: ?Tag,
    attribution: *Attribution,
    tag: if (IS_DEBUG) ?Tag else void, // only for debug log

    pub fn exit(self: Scope) void {
        if (comptime IS_DEBUG) {
            log.debug(.attribution, "exit", .{ .id = self.tag, .restore = self.prev });
        }
        self.attribution.set(self.prev);
    }
};

// Makes `tag` current until exit().
pub fn enter(self: *Attribution, tag: ?Tag) Scope {
    const prev = self.current();
    if (comptime IS_DEBUG) {
        log.debug(.attribution, "enter", .{ .id = tag, .prev = prev });
    }
    self.set(tag);
    return .{ .attribution = self, .prev = prev, .tag = if (comptime IS_DEBUG) tag else {} };
}

// Restores the current tag on exit(), for the microtask checkpoint: V8 clears
// the tag after each microtask rather than restoring it.
pub fn preserve(self: *Attribution) Scope {
    const prev = self.current();
    if (comptime IS_DEBUG) {
        log.debug(.attribution, "preserve", .{ .id = prev });
    }
    return .{ .attribution = self, .prev = prev, .tag = if (comptime IS_DEBUG) prev else {} };
}

// begin + enter.
pub fn enterNew(self: *Attribution, kind: Kind, opts: BeginOpts) Scope {
    return self.enter(self.begin(kind, opts));
}

// For work entered from native code when no task is running. If a running tasks
// is running, the work will run under the existing tag
pub fn enterIfUntagged(self: *Attribution, kind: Kind, label: []const u8) ?Scope {
    if (self.current() != null) {
        return null;
    }
    return self.enterNew(kind, .{ .label = label });
}

fn set(self: *const Attribution, tag: ?Tag) void {
    var hs: js.HandleScope = undefined;
    hs.init(self.isolate);
    defer hs.deinit();
    self.isolate.setContinuationTag(if (tag) |t| @bitCast(t) else null);
}
