// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const Frame = @import("../../../Frame.zig");
const Mime = @import("../../../Mime.zig");
const Factory = @import("../../../Factory.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Event = @import("../../Event.zig");
const reflection = @import("../reflection.zig");

const HtmlElement = @import("../Html.zig");
const MediaError = @import("../../media/MediaError.zig");
const TextTrack = @import("../../media/TextTrack.zig");
const TextTrackList = @import("../../media/TextTrackList.zig");

pub const Audio = @import("Audio.zig");
pub const Video = @import("Video.zig");

const Media = @This();

pub const Proto = HtmlElement;

const ReadyState = enum(u16) {
    HAVE_NOTHING = 0,
    HAVE_METADATA = 1,
    HAVE_CURRENT_DATA = 2,
    HAVE_FUTURE_DATA = 3,
    HAVE_ENOUGH_DATA = 4,
};

const NetworkState = enum(u16) {
    NETWORK_EMPTY = 0,
    NETWORK_IDLE = 1,
    NETWORK_LOADING = 2,
    NETWORK_NO_SOURCE = 3,
};

pub const Type = enum(u8) {
    generic,
    audio,
    video,
};

// `.generic` maps to Media itself: a bare <media> chain ends at Media, so the
// tag has no chain member of its own.
pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .generic => Media,
        .audio => Audio,
        .video => Video,
    };
}

pub fn subtype(self: *const Media, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, Media);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

_type: Type,
_proto_canary: if (lp.IS_DEBUG) *HtmlElement else void = undefined,
_paused: bool = true,
_current_time: f64 = 0,
_volume: f64 = 1.0,
_muted: bool = false,
_playback_rate: f64 = 1.0,
_ready_state: ReadyState = .HAVE_NOTHING,
_network_state: NetworkState = .NETWORK_EMPTY,
_error: ?*MediaError = null,
_text_track_list: ?*TextTrackList = null,
// added via addTextTrack. <track> children are found by a normal tree walk
_added_text_tracks: std.ArrayList(*TextTrack) = .empty,
_track_selection: enum { none, pending, done } = .none,

pub fn asElement(self: *Media) *Element {
    return Factory.protoOf(self).asElement();
}
pub fn asConstElement(self: *const Media) *const Element {
    return Factory.protoOf(@constCast(self)).asElement();
}
pub fn asNode(self: *Media) *Node {
    return self.asElement().asNode();
}

pub fn is(self: *Media, comptime T: type) ?*T {
    switch (self._type) {
        inline .audio, .video => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *Media, comptime T: type) *T {
    return self.is(T).?;
}

// Answers follow Chrome's tables: single-codec types are "probably" on their
// own, containers are "maybe" until every listed codec is one they can hold.
fn canPlayType(_: *const Media, mime_type: []const u8) []const u8 {
    var it = Mime.ContentTypeIterator.init(mime_type);
    var buf: [32]u8 = undefined;
    if (it.essence.len > buf.len) {
        return "";
    }
    const container = containers.get(std.ascii.lowerString(&buf, it.essence)) orelse return "";

    const codecs = while (it.next()) |param| {
        if (std.ascii.eqlIgnoreCase(param.key, "codecs")) break param.value;
    } else "";
    if (codecs.len == 0) {
        return if (container.implied) "probably" else "maybe";
    }

    var result: []const u8 = "probably";
    var ids = std.mem.splitScalar(u8, codecs, ',');
    while (ids.next()) |raw| {
        const codec = parseCodec(std.mem.trim(u8, raw, " \t")) orelse return "";
        if (container.codecs.contains(codec.kind) == false) {
            return "";
        }
        if (codec.ambiguous) {
            result = "maybe";
        }
    }
    return result;
}

const Codec = enum { mp3, pcm, vorbis, opus, flac, vp8, vp9, vp09, av1, avc, aac };
const Codecs = std.EnumSet(Codec);

const Container = struct {
    // A single-codec type: "probably" without a codecs parameter.
    implied: bool = false,
    codecs: Codecs,
};

const audio_codecs: []const Codec = &.{ .mp3, .pcm, .vorbis, .opus, .flac, .aac };

const containers: std.StaticStringMap(Container) = .initComptime(.{
    .{ "audio/mpeg", Container{ .implied = true, .codecs = .initOne(.mp3) } },
    .{ "audio/mp3", Container{ .implied = true, .codecs = .empty } },
    .{ "audio/aac", Container{ .implied = true, .codecs = .empty } },
    .{ "audio/flac", Container{ .implied = true, .codecs = .empty } },
    .{ "audio/wav", Container{ .codecs = .initOne(.pcm) } },
    .{ "audio/x-wav", Container{ .codecs = .initOne(.pcm) } },
    .{ "audio/ogg", Container{ .codecs = .initMany(&.{ .vorbis, .opus, .flac }) } },
    .{ "video/ogg", Container{ .codecs = .initMany(&.{ .vorbis, .opus, .flac, .vp8 }) } },
    .{ "application/ogg", Container{ .codecs = .initMany(&.{ .vorbis, .opus, .flac, .vp8 }) } },
    .{ "audio/webm", Container{ .codecs = .initMany(&.{ .vorbis, .opus }) } },
    .{ "video/webm", Container{ .codecs = .initMany(&.{ .vorbis, .opus, .vp8, .vp9, .vp09, .av1 }) } },
    .{ "audio/mp4", Container{ .codecs = .initMany(&.{ .mp3, .opus, .flac, .aac }) } },
    .{ "video/mp4", Container{ .codecs = .initMany(&.{ .mp3, .opus, .flac, .aac, .vp09, .av1, .avc }) } },
    .{ "audio/x-m4a", Container{ .codecs = .initOne(.aac) } },
    .{ "video/x-m4v", Container{ .codecs = .initMany(&.{ .aac, .avc }) } },
    .{ "audio/x-matroska", Container{ .codecs = .initMany(audio_codecs) } },
    .{ "video/x-matroska", Container{ .codecs = .initMany(audio_codecs ++ &[_]Codec{ .vp8, .vp09, .av1, .avc }) } },
});

const ParsedCodec = struct {
    kind: Codec,
    // No profile given (`avc1`, `mp4a.40`): Chrome answers "maybe".
    ambiguous: bool = false,
};

// Codec ids are case-sensitive. Profile suffixes aren't validated.
fn parseCodec(id: []const u8) ?ParsedCodec {
    const exact: std.StaticStringMap(ParsedCodec) = comptime .initComptime(.{
        .{ "mp3", ParsedCodec{ .kind = .mp3 } },
        .{ "mp4a.69", ParsedCodec{ .kind = .mp3 } },
        .{ "mp4a.6B", ParsedCodec{ .kind = .mp3 } },
        .{ "1", ParsedCodec{ .kind = .pcm } },
        .{ "vorbis", ParsedCodec{ .kind = .vorbis } },
        .{ "opus", ParsedCodec{ .kind = .opus } },
        .{ "flac", ParsedCodec{ .kind = .flac } },
        .{ "vp8", ParsedCodec{ .kind = .vp8 } },
        .{ "vp8.0", ParsedCodec{ .kind = .vp8 } },
        .{ "vp9", ParsedCodec{ .kind = .vp9 } },
        .{ "mp4a.67", ParsedCodec{ .kind = .aac } },
        .{ "mp4a.40", ParsedCodec{ .kind = .aac, .ambiguous = true } },
        .{ "avc1", ParsedCodec{ .kind = .avc, .ambiguous = true } },
        .{ "avc3", ParsedCodec{ .kind = .avc, .ambiguous = true } },
    });
    if (exact.get(id)) |codec| {
        return codec;
    }

    const prefixes = [_]struct { []const u8, Codec }{
        .{ "mp4a.40.", .aac },
        .{ "avc1.", .avc },
        .{ "avc3.", .avc },
        .{ "vp09.", .vp09 },
        .{ "av01.", .av1 },
    };
    for (prefixes) |prefix| {
        if (id.len > prefix[0].len and std.mem.startsWith(u8, id, prefix[0])) {
            return .{ .kind = prefix[1] };
        }
    }
    return null;
}

pub fn play(self: *Media, frame: *Frame) !js.Promise {
    const was_paused = self._paused;
    self._paused = false;
    self._ready_state = .HAVE_ENOUGH_DATA;
    self._network_state = .NETWORK_IDLE;
    if (was_paused) {
        try self.dispatchEvent("play", frame);
        try self.dispatchEvent("playing", frame);
    }
    return frame.js.local.?.resolvePromise(js.Undefined{});
}

pub fn pause(self: *Media, frame: *Frame) !void {
    if (!self._paused) {
        self._paused = true;
        try self.dispatchEvent("pause", frame);
    }
}

pub fn load(self: *Media, frame: *Frame) !void {
    self._paused = true;
    self._current_time = 0;
    self._ready_state = .HAVE_NOTHING;
    self._network_state = .NETWORK_LOADING;
    self._error = null;
    try self.dispatchEvent("emptied", frame);
}

fn dispatchEvent(self: *Media, name: []const u8, frame: *Frame) !void {
    const event = try Event.init(name, .{ .bubbles = false, .cancelable = false }, frame.page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

fn getPaused(self: *const Media) bool {
    return self._paused;
}

fn getCurrentTime(self: *const Media) f64 {
    return self._current_time;
}

pub fn getDuration(_: *const Media) f64 {
    return std.math.nan(f64);
}

fn getReadyState(self: *const Media) u16 {
    return @backingInt(self._ready_state);
}

fn getNetworkState(self: *const Media) u16 {
    return @backingInt(self._network_state);
}

fn getEnded(_: *const Media) bool {
    return false;
}

fn getSeeking(_: *const Media) bool {
    return false;
}

fn getError(self: *const Media) ?*MediaError {
    return self._error;
}

fn getVolume(self: *const Media) f64 {
    return self._volume;
}

fn setVolume(self: *Media, value: f64) !void {
    if ((value >= 0.0 and value <= 1.0) == false) {
        return error.IndexSizeError;
    }
    self._volume = value;
}

fn getMuted(self: *const Media) bool {
    return self._muted;
}

fn setMuted(self: *Media, value: bool) void {
    self._muted = value;
}

fn getPlaybackRate(self: *const Media) f64 {
    return self._playback_rate;
}

fn setPlaybackRate(self: *Media, value: f64) void {
    self._playback_rate = value;
}

fn setCurrentTime(self: *Media, value: f64) void {
    self._current_time = value;
}

fn getTextTracks(self: *Media, frame: *Frame) !*TextTrackList {
    if (self._text_track_list == null) {
        self._text_track_list = try TextTrackList.init(self, frame);
    }
    return self._text_track_list.?;
}

fn addTextTrack(self: *Media, kind_: []const u8, label_: ?[]const u8, language_: ?[]const u8, frame: *Frame) !*TextTrack {
    const kind = std.meta.stringToEnum(TextTrack.Kind, kind_) orelse return error.TypeError;
    const track = try TextTrack.initForScript(kind, label_ orelse "", language_ orelse "", frame);
    try self._added_text_tracks.append(frame.page_arena, track);
    return track;
}

pub fn queueAutomaticTrackSelection(self: *Media, frame: *Frame) !void {
    if (self._track_selection != .none) {
        return;
    }
    const task = try frame._factory.create(TrackSelectionTask{ .media = self, .frame = frame });
    errdefer frame._factory.destroy(task);
    try frame.js.scheduler.add(task, TrackSelectionTask.run, 0, .{
        .name = "Media.automaticTrackSelection",
        .finalizer = TrackSelectionTask.finalizer,
    });
    self._track_selection = .pending;
}

const TrackSelectionTask = struct {
    media: *Media,
    frame: *Frame,

    fn run(ctx: *anyopaque) !?u32 {
        const self: *TrackSelectionTask = @ptrCast(@alignCast(ctx));
        const media = self.media;
        const frame = self.frame;
        frame._factory.destroy(self);
        try media.performAutomaticTrackSelection(frame);
        return null;
    }

    fn finalizer(ctx: *anyopaque) void {
        const self: *TrackSelectionTask = @ptrCast(@alignCast(ctx));
        self.frame._factory.destroy(self);
    }
};

fn performAutomaticTrackSelection(self: *Media, frame: *Frame) !void {
    self._track_selection = .done;

    var shown_subtitles = false;
    var shown_chapters = false;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        const track_element = child.is(Element.Html.Track) orelse continue;
        if (track_element.asElement().hasAttributeSafe(comptime .wrap("default")) == false) {
            continue;
        }
        const track = try track_element.getTrack(frame);
        if (track.getMode() != .disabled) {
            continue;
        }
        switch (track.getKind()) {
            .subtitles, .captions => {
                if (shown_subtitles) continue;
                shown_subtitles = true;
                try track.setMode(.showing, frame);
            },
            .chapters => {
                if (shown_chapters) continue;
                shown_chapters = true;
                try track.setMode(.showing, frame);
            },
            .metadata => try track.setMode(.hidden, frame),
            .descriptions => {},
        }
    }
}

// Missing and invalid values are metadata (Chrome), the empty string is auto.
fn getPreload(self: *const Media) []const u8 {
    const value = self.asConstElement().getAttributeSafe(comptime .wrap("preload")) orelse return "metadata";
    if (value.len == 0) {
        return "auto";
    }
    return reflection.enumeratedValue(value, &.{ "none", "metadata", "auto" }, null, "metadata").?;
}

fn setPreload(self: *Media, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("preload"), .wrap(value), frame);
}

pub fn getSrc(self: *const Media, frame: *Frame) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeInterned("src") orelse return "";
    if (src.len == 0) {
        return "";
    }
    return element.asConstNode().resolveURLReflect(src, frame, .{});
}

fn setSrc(self: *Media, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), frame);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Media);

    pub const Meta = struct {
        pub const name = "HTMLMediaElement";
        pub var class_id: bridge.ClassId = undefined;
    };

    const reflect = Element.Reflect(Media);
    pub const crossOrigin = reflect.enumerated("crossorigin", &.{ "anonymous", "use-credentials" }, .{ .missing = null, .nullable = true, .invalid = "anonymous" });
    pub const defaultMuted = reflect.boolean("muted");

    pub const NETWORK_EMPTY = bridge.property(@backingInt(NetworkState.NETWORK_EMPTY), .{ .template = true });
    pub const NETWORK_IDLE = bridge.property(@backingInt(NetworkState.NETWORK_IDLE), .{ .template = true });
    pub const NETWORK_LOADING = bridge.property(@backingInt(NetworkState.NETWORK_LOADING), .{ .template = true });
    pub const NETWORK_NO_SOURCE = bridge.property(@backingInt(NetworkState.NETWORK_NO_SOURCE), .{ .template = true });

    pub const HAVE_NOTHING = bridge.property(@backingInt(ReadyState.HAVE_NOTHING), .{ .template = true });
    pub const HAVE_METADATA = bridge.property(@backingInt(ReadyState.HAVE_METADATA), .{ .template = true });
    pub const HAVE_CURRENT_DATA = bridge.property(@backingInt(ReadyState.HAVE_CURRENT_DATA), .{ .template = true });
    pub const HAVE_FUTURE_DATA = bridge.property(@backingInt(ReadyState.HAVE_FUTURE_DATA), .{ .template = true });
    pub const HAVE_ENOUGH_DATA = bridge.property(@backingInt(ReadyState.HAVE_ENOUGH_DATA), .{ .template = true });

    pub const src = bridge.accessor(Media.getSrc, Media.setSrc, .{ .ce_reactions = true });
    pub const currentSrc = bridge.accessor(Media.getSrc, null, .{});
    pub const autoplay = reflect.boolean("autoplay");
    pub const controls = reflect.boolean("controls");
    pub const loop = reflect.boolean("loop");
    pub const muted = bridge.accessor(Media.getMuted, Media.setMuted, .{});
    pub const preload = bridge.accessor(Media.getPreload, Media.setPreload, .{ .ce_reactions = true });
    pub const volume = bridge.accessor(Media.getVolume, Media.setVolume, .{});
    pub const playbackRate = bridge.accessor(Media.getPlaybackRate, Media.setPlaybackRate, .{});
    pub const currentTime = bridge.accessor(Media.getCurrentTime, Media.setCurrentTime, .{});
    pub const duration = bridge.accessor(Media.getDuration, null, .{});
    pub const paused = bridge.accessor(Media.getPaused, null, .{});
    pub const ended = bridge.accessor(Media.getEnded, null, .{});
    pub const seeking = bridge.accessor(Media.getSeeking, null, .{});
    pub const readyState = bridge.accessor(Media.getReadyState, null, .{});
    pub const networkState = bridge.accessor(Media.getNetworkState, null, .{});
    pub const @"error" = bridge.accessor(Media.getError, null, .{});

    pub const textTracks = bridge.accessor(Media.getTextTracks, null, .{});
    pub const addTextTrack = bridge.function(Media.addTextTrack, .{});

    pub const canPlayType = bridge.function(Media.canPlayType, .{});
    pub const play = bridge.function(Media.play, .{});
    pub const pause = bridge.function(Media.pause, .{});
    pub const load = bridge.function(Media.load, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: Media" {
    try testing.htmlRunner("element/html/media.html", .{});
}
