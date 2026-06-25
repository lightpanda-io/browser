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
const builtin = @import("builtin");

const js = @import("js/js.zig");
const v8 = js.v8;

const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const Factory = @import("Factory.zig");
const Viewport = @import("Viewport.zig");

const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

// A Page is the container for a root Frame and all of its descendants
// (nested iframes). It owns the resources that share the lifetime of the root
// document: the DOM factory, the per-page arena, the JS identity map, shared
// origins, v8 global handles, and queued navigation buffers.
//
// In the future, a Session may hold multiple Pages at once (e.g. during a
// navigation, while the old Page is retiring and the new one is provisional).
// For now, Session still holds a single Page.
const Page = @This();

session: *Session,

// DOM version used to invalidate cached state of "live" collections. Ideally
// this would be on the Frame (and that's where it used to be). But getting the
// frame from a DOM mutation call is [relatively] expensive. You can't use
// the bridge-injected *Frame, because that's the frame where the JS is being
// executed, which might not be the *Frame that owns the node. We don't store
// *Frame in node (think of the memory!), so we have to iterate through its
// parents, find the Document, which has the frame.
// So the choice is between making every DOM mutation (which has to increase
// the dom_version) + every read (which has to check the version) slow, or
// putting this on the Page, and having an DOM mutation in Frame 1 invalidate
// a cached lookup on Frame 2. We picked the latter.
dom_version: usize = 0,

// Monotonic creation counter for BroadcastChannels in this Page. A postMessage
// captures the current value so delivery targets only channels that existed
// when it was called
broadcast_sequence: u64 = 0,

// DOM object factory scoped to this Page's documents.
factory: Factory,

// The arena for this Page's lifetime. Document / Frame / Factory / DOM
// objects allocate out of this.
frame_arena: Allocator,

// Origin map for same-origin context sharing. Entries live for the Page's
// lifetime.
origins: std.StringHashMapUnmanaged(*js.Origin) = .empty,

// Identity tracking for the main world. All main-world contexts in this Page
// share this, ensuring object identity works across same-origin frames.
identity: js.Identity = .{},

// Finalizer callbacks for Zig instances exposed to v8 in this Page. Keyed by
// Zig instance ptr. The backing FinalizerCallback.Identity structs come from
// Browser.fc_identity_pool so they outlive the Page (and the Session) for v8
// weak-callback safety.
finalizer_callbacks: std.AutoHashMapUnmanaged(usize, *js.FinalizerCallback) = .empty,

// Tracked global v8 objects that need to be released when the Page tears down.
globals: std.ArrayList(v8.Global) = .empty,

// Temporary v8 globals that can be released early. Key is global.data_ptr.
temps: std.AutoHashMapUnmanaged(usize, v8.Global) = .empty,

// Double buffered so that, as we process one list of queued navigations, new
// entries are added to the separate buffer. Prevents endless navigation loops
// and invalidation of the list during iteration.
queued_navigation_1: std.ArrayList(*Frame) = .empty,
queued_navigation_2: std.ArrayList(*Frame) = .empty,
// pointer to either queued_navigation_1 or queued_navigation_2
queued_navigation: *std.ArrayList(*Frame) = undefined,

// Temporary buffer for about:blank navigations during processing.
// We process async navigations first (safe from re-entrance), then sync
// about:blank navigations (which may add to queued_navigation).
queued_queued_navigation: std.ArrayList(*Frame) = .empty,

// The root Frame of this Page. Non-optional — a Page always has a root frame.
frame: Frame,

// Popup Frames opened by window.open. They are top-level browsing contexts
// (parent == null, no iframe element) but share this Page's factory, arena,
// and identity map.
// Their lifetime is bound to the Page: on Page.deinit they
// are torn down. TODO: this is far from correct. An new window shouldn't be tied
// to the original page like this.
popups: std.ArrayList(*Frame) = .empty,

// Popup Frames that have been closed. The window can still be referenced / used
// from JS, so we defer shutting them down until page tear down (which isn't
// ideal from a memory point of view).
closed_frames: std.ArrayList(*Frame) = .empty,

// In-flight navigation for a root page. When not null, this page will "replace"
// the referenced page once the response header arrives. This is necessary
// because, during navigation, both the "old" and "new" pages remain addressable
// in CDP
replaces: ?*Page = null,

// Inverse of `replaces`. While we don't strictly need both, it does streamline
// code. The two are kept in sync.
replacement: ?*Page = null,

// The viewport every consumer should read. The runtime override (set via
// Emulation.setDeviceMetricsOverride) is stored on the Browser so it persists
// across page navigations; delegate to it here, keeping a single read path for
// every viewport consumer.
pub fn getViewport(self: *const Page) Viewport {
    return self.session.browser.getViewport();
}

// Initialize a Page and its root Frame.
pub fn init(self: *Page, session: *Session, frame_id: u32) !void {
    const frame_arena = try session.arena_pool.acquire(.large, "Page.frame_arena");
    errdefer session.arena_pool.release(frame_arena);

    self.* = .{
        .session = session,
        .frame = undefined,
        .frame_arena = frame_arena,
        .factory = Factory.init(frame_arena),
    };
    self.queued_navigation = &self.queued_navigation_1;

    try Frame.init(&self.frame, frame_id, self, .{});
}

// Tear down the Page and its root Frame. Equivalent to the old
// Session.removePage + Session.resetFrameResources.
pub fn deinit(self: *Page) void {
    for (self.popups.items) |popup| {
        popup.deinit();
    }
    self.popups = .empty;

    for (self.closed_frames.items) |frame| {
        frame.deinit();
    }
    self.closed_frames = .empty;

    self.frame.deinit();

    const session = self.session;
    defer session.browser.env.memoryPressureNotification(.moderate);

    self.identity.deinit();
    self.identity = .{};

    // Force cleanup all remaining finalized objects.
    {
        var it = self.finalizer_callbacks.valueIterator();
        while (it.next()) |fc| {
            fc.*.deinit(self);
        }
        self.finalizer_callbacks = .empty;
    }

    {
        for (self.globals.items) |*global| {
            v8.v8__Global__Reset(global);
        }
        self.globals = .empty;
    }

    {
        var it = self.temps.valueIterator();
        while (it.next()) |global| {
            v8.v8__Global__Reset(global);
        }
        self.temps = .empty;
    }

    if (comptime IS_DEBUG) {
        std.debug.assert(self.origins.count() == 0);
    }
    // Defensive cleanup in case origins leaked.
    {
        const app = session.browser.app;
        var it = self.origins.valueIterator();
        while (it.next()) |value| {
            value.*.deinit(app);
        }
        self.origins = .empty;
    }

    session.arena_pool.release(self.frame_arena);
}

pub fn getArena(self: *Page, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.session.getArena(size_or_bucket, debug);
}

pub fn releaseArena(self: *Page, allocator: Allocator) void {
    return self.session.releaseArena(allocator);
}

pub fn getOrCreateOrigin(self: *Page, key_: ?[]const u8) !*js.Origin {
    const session = self.session;
    const key = key_ orelse {
        var opaque_origin: [36]u8 = undefined;
        @import("../id.zig").uuidv4(&opaque_origin);
        // Origin.init will dupe opaque_origin. It's fine that this doesn't
        // get added to self.origins. In fact, it further isolates it. When the
        // context is freed, it'll call Page.releaseOrigin which will free it.
        return js.Origin.init(session.browser.app, session.browser.env.isolate, &opaque_origin);
    };

    const gop = try self.origins.getOrPut(session.arena, key);
    if (gop.found_existing) {
        const origin = gop.value_ptr.*;
        origin.rc += 1;
        return origin;
    }

    errdefer _ = self.origins.remove(key);

    const origin = try js.Origin.init(session.browser.app, session.browser.env.isolate, key);
    gop.key_ptr.* = origin.key;
    gop.value_ptr.* = origin;
    return origin;
}

pub fn releaseOrigin(self: *Page, origin: *js.Origin) void {
    const rc = origin.rc;
    if (rc == 1) {
        _ = self.origins.remove(origin.key);
        origin.deinit(self.session.browser.app);
    } else {
        origin.rc = rc - 1;
    }
}

pub fn scheduleNavigation(self: *Page, frame: *Frame) !void {
    const list = self.queued_navigation;

    // Check if frame is already queued
    for (list.items) |existing| {
        if (existing == frame) {
            // Already queued
            return;
        }
    }

    return list.append(self.session.arena, frame);
}

pub fn findFrameByFrameId(self: *Page, frame_id: u32) ?*Frame {
    if (findFrameBy(&self.frame, "_frame_id", frame_id)) |found| {
        return found;
    }
    return self.findPopupBy("_frame_id", frame_id);
}

// Returns the popup Frame registered under `name`, or null.
pub fn findPopupByName(self: *Page, name: []const u8) ?*Frame {
    for (self.popups.items) |popup| {
        if (std.mem.eql(u8, popup.window._name, name)) {
            return popup;
        }
    }
    return null;
}

pub fn findFrameByLoaderId(self: *Page, loader_id: u32) ?*Frame {
    if (findFrameBy(&self.frame, "_loader_id", loader_id)) |found| {
        return found;
    }
    return self.findPopupBy("_loader_id", loader_id);
}

fn findFrameBy(frame: *Frame, comptime field: []const u8, id: u32) ?*Frame {
    if (@field(frame, field) == id) {
        return frame;
    }
    for (frame.child_frames.items) |f| {
        if (findFrameBy(f, field, id)) |found| {
            return found;
        }
    }
    return null;
}

fn findPopupBy(self: *Page, comptime field: []const u8, id: u32) ?*Frame {
    for (self.popups.items) |frame| {
        if (findFrameBy(frame, field, id)) |found| {
            return found;
        }
    }
    return null;
}

// Snapshots the Execution of every same-origin global in this Page — the root
// frame, descendant iframes, popups (and their descendants), and each frame's
// worker scopes — into `arena`.
//
// The returned set is fixed, so a caller may run user JS (which can create or
// tear down frames/workers) while walking it without invalidating the slice.
pub fn executionsForOrigin(self: *Page, arena: Allocator, origin: []const u8) ![]*js.Execution {
    var list: std.ArrayList(*js.Execution) = .empty;
    try appendFrameExecutions(&self.frame, origin, arena, &list);
    for (self.popups.items) |popup| {
        try appendFrameExecutions(popup, origin, arena, &list);
    }
    return list.items;
}

fn appendFrameExecutions(frame: *Frame, origin: []const u8, arena: Allocator, list: *std.ArrayList(*js.Execution)) !void {
    if (frame.origin) |fo| {
        if (std.mem.eql(u8, fo, origin)) {
            try list.append(arena, &frame.js.execution);
        }
    }
    for (frame.workers.items) |worker| {
        const wgs = worker._worker_scope;
        if (wgs.origin) |wo| {
            if (std.mem.eql(u8, wo, origin)) {
                try list.append(arena, &wgs.js.execution);
            }
        }
    }
    for (frame.child_frames.items) |child| {
        try appendFrameExecutions(child, origin, arena, list);
    }
}
