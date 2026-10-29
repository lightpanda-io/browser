// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const js = @import("../../../js/js.zig");
const URL = @import("../../../URL.zig");
const Frame = @import("../../../Frame.zig");
const Factory = @import("../../../Factory.zig");
const HttpClient = @import("../../../../network/HttpClient.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const TextTrack = @import("../../media/TextTrack.zig");
const webvtt = @import("../../media/webvtt.zig");

const HtmlElement = @import("../Html.zig");
const Media = @import("Media.zig");

const String = lp.String;
const log = lp.log;

const Track = @This();

pub const Proto = HtmlElement;

_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_ready_state: ReadyState = .none,
_track: ?*TextTrack = null,
_generation: u32 = 0, // bumped when src changes. Drop inflight loads for old URLs

const ReadyState = enum(u8) { none, loading, loaded, @"error" };

pub fn asElement(self: *Track) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Track) *const Element {
    return Factory.protoOf(@constCast(self)).asElement();
}
pub fn asNode(self: *Track) *Node {
    return self.asElement().asNode();
}

pub fn getTrack(self: *Track, frame: *Frame) !*TextTrack {
    if (self._track == null) {
        self._track = try TextTrack.initForElement(self, frame);
    }
    return self._track.?;
}

// The kind attribute, as reflected: missing is subtitles, invalid is metadata.
pub fn getKind(self: *const Track) TextTrack.Kind {
    const value = self.asConstElement().getAttributeSafe(comptime .wrap("kind")) orelse return .subtitles;
    const info = @typeInfo(TextTrack.Kind).@"enum";
    inline for (info.field_names, info.field_values) |field_name, field_value| {
        if (std.ascii.eqlIgnoreCase(value, field_name)) {
            return @fromBackingInt(@intCast(field_value));
        }
    }
    return .metadata;
}

pub fn parentMedia(self: *Track) ?*Media {
    const parent = self.asNode()._parent orelse return null;
    return parent.is(Media);
}

fn getReadyState(self: *const Track) u16 {
    return @backingInt(self._ready_state);
}

// The track was inserted into `parent`
pub fn insertedInto(self: *Track, parent: *Node, frame: *Frame) !void {
    const media = parent.is(Media) orelse return;
    try media.queueAutomaticTrackSelection(frame);
    try self.startTrackProcessing(frame);
}

pub fn startTrackProcessing(self: *Track, frame: *Frame) !void {
    const track = self._track orelse return;
    if (track.getMode() == .disabled) {
        return;
    }
    if (self._ready_state != .none) {
        // already loading, or done until src changes
        return;
    }
    if (self.parentMedia() == null) {
        return;
    }
    if (frame.isGoingAway()) {
        return;
    }
    // A document without a browsing context (DOMParser et al.) loads nothing.
    if (self.asElement().getDocument(frame)._frame == null) {
        return;
    }

    self._ready_state = .loading;
    try TrackLoad.schedule(self, frame);
}

// A changed (or removed) src empties the track's cues and, if the track was
// being processed, restarts it with the new URL.
fn srcChanged(self: *Track, frame: *Frame) !void {
    self._generation +%= 1;
    const track = self._track orelse return;
    track.clearCues();
    if (self._ready_state == .none) {
        return;
    }
    self._ready_state = .none;
    try self.startTrackProcessing(frame);
}

// One fetch of the track's src.
const TrackLoad = struct {
    frame: *Frame,
    track: *Track,
    generation: u32,
    arena: *lp.Arena,
    status: u16 = 0,
    body: std.ArrayList(u8) = .empty,

    fn schedule(track: *Track, frame: *Frame) !void {
        const arena = try frame._session.getArena(.medium, "Track.load");
        errdefer arena.release();

        const self = try arena.allocator().create(TrackLoad);
        self.* = .{
            .frame = frame,
            .track = track,
            .arena = arena,
            .generation = track._generation,
        };

        try frame.js.scheduler.add(self, TrackLoad.start, 0, .{
            .name = "Track.load",
            .finalizer = TrackLoad.finalizer,
        });
        frame._pending_loads += 1;
    }

    fn finalizer(ctx: *anyopaque) void {
        shutdownCallback(ctx);
    }

    fn start(ctx: *anyopaque) !?u32 {
        const self: *TrackLoad = @ptrCast(@alignCast(ctx));
        self.fetch() catch |err| {
            log.info(.http, "track fetch", .{ .err = err });
            self.settle(false);
        };
        return null;
    }

    fn fetch(self: *TrackLoad) !void {
        const frame = self.frame;
        const track = self.track;
        if (self.generation != track._generation or frame.isGoingAway()) {
            return self.settle(false);
        }

        const src = track.asElement().getAttributeInterned("src") orelse "";
        if (src.len == 0) {
            return self.settle(false);
        }
        const url = try URL.resolve(self.arena.allocator(), frame.base(), src, .{ .encoding = frame.charset });

        // A potential-CORS request with the same-origin fallback flag: without
        // a crossorigin attribute on the media element, only same-origin
        // tracks load.
        const media = track.parentMedia() orelse return self.settle(false);
        const cross_origin = media.asElement().getAttributeInterned("crossorigin");
        const request_mode: HttpClient.Request.RequestMode = if (cross_origin == null) .same_origin else .cors;
        const credentials_mode: HttpClient.Request.CredentialsMode = blk: {
            const value = cross_origin orelse break :blk .include;
            break :blk if (std.ascii.eqlIgnoreCase(value, "use-credentials")) .include else .same_origin;
        };

        const transfer = try frame._session.browser.http_client.newRequest(.{
            .ctx = self,
            .url = url,
            .method = .GET,
            .origin = frame.origin,
            .request_mode = request_mode,
            .credentials_mode = credentials_mode,
            .resource_type = .text_track,
            .header_callback = TrackLoad.headerCallback,
            .data_callback = TrackLoad.dataCallback,
            .done_callback = TrackLoad.doneCallback,
            .error_callback = TrackLoad.errorCallback,
            .shutdown_callback = TrackLoad.shutdownCallback,
        }, &frame._http_owner);
        {
            // `deinit` fires no callbacks: our caller settles on this path.
            errdefer transfer.deinit();
            try frame.headersForRequest(transfer, .{});
        }

        // From here the transfer owns us; a failed submit has already gone
        // through errorCallback.
        transfer.submit() catch |err| {
            log.debug(.http, "track fetch", .{ .err = err, .url = url });
        };
    }

    fn headerCallback(transfer: *HttpClient.Transfer) !HttpClient.Transfer.HeaderResult {
        const self: *TrackLoad = @ptrCast(@alignCast(transfer.req.ctx));
        self.status = transfer.responseStatus() orelse 0;
        return .proceed;
    }

    fn dataCallback(transfer: *HttpClient.Transfer, data: []const u8) !void {
        const self: *TrackLoad = @ptrCast(@alignCast(transfer.req.ctx));
        try self.body.appendSlice(self.arena.allocator(), data);
    }

    fn doneCallback(ctx: *anyopaque) !void {
        const self: *TrackLoad = @ptrCast(@alignCast(ctx));
        self.settle(self.status >= 200 and self.status < 300);
    }

    fn errorCallback(ctx: *anyopaque, err: anyerror) void {
        const self: *TrackLoad = @ptrCast(@alignCast(ctx));
        log.info(.http, "track fetch", .{ .err = err, .status = self.status });
        self.settle(false);
    }

    // Teardown or a superseding navigation: give the slot back without
    // running anything (see ImageLoad.shutdownCallback).
    fn shutdownCallback(ctx: *anyopaque) void {
        const self: *TrackLoad = @ptrCast(@alignCast(ctx));
        const frame = self.frame;
        self.arena.release();
        frame._pending_loads -|= 1;
    }

    fn settle(self: *TrackLoad, fetched: bool) void {
        const frame = self.frame;
        const track = self.track;
        const arena = self.arena;
        defer arena.release();

        if (frame.isGoingAway()) {
            frame._pending_loads -|= 1;
            return;
        }

        if (self.generation == track._generation) {
            const loaded = fetched and track.addParsedCues(arena.allocator(), self.body.items, frame);
            track._ready_state = if (loaded) .loaded else .@"error";
            frame.queueElementEvent(Factory.protoOf(track), if (loaded) .load else .@"error") catch |err| {
                log.warn(.frame, "track queue event", .{ .err = err });
            };
        }

        frame.pendingLoadCompleted();
    }
};

// False when the body isn't a WebVTT file.
fn addParsedCues(self: *Track, arena: std.mem.Allocator, body: []const u8, frame: *Frame) bool {
    const cues = webvtt.parse(arena, body, frame) catch |err| {
        log.warn(.frame, "track parse", .{ .err = err });
        return false;
    } orelse return false;

    const track = self.getTrack(frame) catch return false;
    for (cues) |cue| {
        track.addCue(cue.asCue(), frame) catch |err| {
            log.warn(.frame, "track add cue", .{ .err = err });
            return false;
        };
    }
    return true;
}

pub const Build = struct {
    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (name.eql(comptime .wrap("src"))) {
            return element.as(Track).srcChanged(frame);
        }
    }

    pub fn attributeRemove(element: *Element, name: String, frame: *Frame) !void {
        if (name.eql(comptime .wrap("src"))) {
            return element.as(Track).srcChanged(frame);
        }
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Track);

    pub const Meta = struct {
        pub const name = "HTMLTrackElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Track);
    pub const src = reflect.url("src");
    pub const default = reflect.boolean("default");
    pub const srclang = reflect.string("srclang");
    pub const label = reflect.string("label");

    pub const kind = reflect.enumerated("kind", &.{ "subtitles", "captions", "descriptions", "chapters", "metadata" }, .{ .missing = "subtitles", .invalid = "metadata" });

    pub const NONE = bridge.property(@as(u16, @backingInt(ReadyState.none)), .{ .template = true });
    pub const LOADING = bridge.property(@as(u16, @backingInt(ReadyState.loading)), .{ .template = true });
    pub const LOADED = bridge.property(@as(u16, @backingInt(ReadyState.loaded)), .{ .template = true });
    pub const ERROR = bridge.property(@as(u16, @backingInt(ReadyState.@"error")), .{ .template = true });

    pub const readyState = bridge.accessor(Track.getReadyState, null, .{});
    pub const track = bridge.accessor(Track.getTrack, null, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: HTML.Track" {
    try testing.htmlRunner("element/html/track.html", .{});
}
