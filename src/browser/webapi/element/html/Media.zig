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
const URL = @import("../../../URL.zig");
const Frame = @import("../../../Frame.zig");
const Mime = @import("../../../Mime.zig");
const Factory = @import("../../../Factory.zig");
const data_url = @import("../../../data_url.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const Event = @import("../../Event.zig");
const reflection = @import("../reflection.zig");

const HtmlElement = @import("../Html.zig");
const Source = @import("Source.zig");
const wav = @import("../../webaudio/dsp/wav.zig");
const MediaError = @import("../../media/MediaError.zig");
const TextTrack = @import("../../media/TextTrack.zig");
const TextTrackList = @import("../../media/TextTrackList.zig");

pub const Audio = @import("Audio.zig");
pub const Video = @import("Video.zig");

const log = lp.log;
const String = lp.String;
const Allocator = std.mem.Allocator;

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
// The playback position, as of `_clock_started` while the clock runs.
_current_time: f64 = 0,
// NaN until a source's metadata is read. Nothing is decoded and nothing plays:
// a known duration is what gives the element a timeline.
_duration: f64 = std.math.nan(f64),
_seeking: bool = false,
// When the position started advancing, on the scheduler's clock.
_clock_started: ?u64 = null,
_clock: ?*Clock = null,
// bumped by each load. Drops the pending tasks of the previous one
_generation: u32 = 0,
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
    if (self.getEnded()) {
        try self.seek(0, frame);
    }
    const was_paused = self._paused;
    self._paused = false;
    self._ready_state = .HAVE_ENOUGH_DATA;
    self._network_state = .NETWORK_IDLE;
    if (was_paused) {
        try self.dispatchEvent("play", frame);
        try self.dispatchEvent("playing", frame);
        try self.startClock(frame);
    }
    return frame.js.local.?.resolvePromise(js.Undefined{});
}

pub fn pause(self: *Media, frame: *Frame) !void {
    if (!self._paused) {
        self.stopClock();
        self._paused = true;
        try self.dispatchEvent("pause", frame);
    }
}

pub fn load(self: *Media, frame: *Frame) !void {
    self.resetForLoad();
    try self.dispatchEvent("emptied", frame);
    try self.selectResource(frame);
}

fn resetForLoad(self: *Media) void {
    self._generation +%= 1;
    self._paused = true;
    self._seeking = false;
    self._clock_started = null;
    self._current_time = 0;
    self._duration = std.math.nan(f64);
    self._ready_state = .HAVE_NOTHING;
    self._network_state = .NETWORK_LOADING;
    self._error = null;
}

// The frame whose scheduler runs the element's tasks: its document's, not the
// caller's, and only while that frame is still running.
fn taskFrame(self: *Media, frame: *Frame) ?*Frame {
    const owner = self.asNode().ownerFrame(frame) orelse return null;
    return if (owner.isGoingAway()) null else owner;
}

fn dispatchEvent(self: *Media, name: []const u8, frame: *Frame) !void {
    const event = try Event.init(name, .{ .bubbles = false, .cancelable = false }, frame.page);
    try frame._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

// Resource selection, which runs in a task. The element's state only changes
// once a source could be read.
// https://html.spec.whatwg.org/multipage/media.html#concept-media-load-algorithm
fn selectResource(self: *Media, frame: *Frame) !void {
    // A document without a browsing context (DOMParser et al.) loads nothing.
    const owner = self.taskFrame(frame) orelse return;
    if (self.asElement().getAttributeInterned("src") == null and self.firstSource(null) == null) {
        return;
    }
    try Task.schedule(self, owner, .load);
}

fn firstSource(self: *Media, after: ?*Node) ?*Source {
    var next = if (after) |node| node.nextSibling() else self.asNode().firstChild();
    while (next) |node| : (next = node.nextSibling()) {
        if (node.is(Source)) |source| {
            return source;
        }
    }
    return null;
}

// A <source> was inserted into `parent`. A media element that has nothing to
// play yet tries again with it.
pub fn sourceInserted(parent: *Node, frame: *Frame) !void {
    const self = parent.is(Media) orelse return;
    if (self.asElement().getAttributeInterned("src") != null or std.math.isNan(self._duration) == false) {
        return;
    }
    self._generation +%= 1;
    try self.selectResource(frame);
}

// Only a source whose duration can be read is loaded. Any other leaves the
// element as it was: play() fakes playback, with no duration and no clock.
fn loadResource(self: *Media, frame: *Frame) !void {
    const arena = try frame._session.getArena(.medium, "Media.loadResource");
    defer arena.release();

    self._duration = self.readDuration(arena.allocator(), frame) orelse return;
    self._current_time = std.math.clamp(self._current_time, 0, self._duration);
    self._ready_state = .HAVE_ENOUGH_DATA;
    self._network_state = .NETWORK_IDLE;

    const generation = self._generation;
    inline for (.{ "loadstart", "durationchange", "loadedmetadata", "loadeddata", "canplay", "canplaythrough" }) |name| {
        try self.dispatchEvent(name, frame);
        if (self._generation != generation) {
            // a listener loaded another source
            return;
        }
    }
    // play() might not have waited for us.
    try self.startClock(frame);
}

// The src attribute, or else the first <source> child that can be read.
fn readDuration(self: *Media, arena: Allocator, frame: *Frame) ?f64 {
    if (self.asElement().getAttributeInterned("src")) |src| {
        return sourceDuration(arena, src, frame);
    }
    var source = self.firstSource(null);
    while (source) |s| : (source = self.firstSource(s.asNode())) {
        const src = s.asElement().getAttributeInterned("src") orelse continue;
        if (sourceDuration(arena, src, frame)) |duration| {
            return duration;
        }
    }
    return null;
}

// In seconds. Only for a WAV file in a data: URL: nothing is fetched.
fn sourceDuration(arena: Allocator, src: []const u8, frame: *Frame) ?f64 {
    const url = URL.resolve(arena, frame.base(), src, .{ .encoding = frame.charset }) catch return null;
    if (isWavDataUrl(url) == false) {
        return null;
    }
    const parsed = data_url.parse(arena, url) catch return null;
    const file = wav.parse(parsed.body) catch return null;
    return @as(f64, @floatFromInt(file.frames)) / file.sample_rate;
}

// Told by its type, so that no other data: URL is decoded for nothing.
fn isWavDataUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "data:") == false) {
        return false;
    }
    const meta = url["data:".len .. std.mem.findScalar(u8, url, ',') orelse return false];
    const essence = std.mem.trim(u8, meta[0 .. std.mem.findScalar(u8, meta, ';') orelse meta.len], " ");
    inline for (.{ "audio/wav", "audio/wave", "audio/x-wav", "audio/vnd.wave" }) |mime| {
        if (std.ascii.eqlIgnoreCase(essence, mime)) {
            return true;
        }
    }
    return false;
}

// The current playback position.
fn position(self: *const Media) f64 {
    const started = self._clock_started orelse return self._current_time;
    const elapsed: f64 = @floatFromInt(lp.datetime.milliTimestamp(.boot) - started);
    return @min(self._current_time + elapsed / 1000 * self._playback_rate, self._duration);
}

fn stopClock(self: *Media) void {
    self._current_time = self.position();
    self._clock_started = null;
}

// (Re)starts the clock from the current position, if the element is playing
// a source with a timeline.
fn startClock(self: *Media, frame: *Frame) !void {
    self.stopClock();
    if (self._paused or std.math.isNan(self._duration) or (self._playback_rate > 0) == false) {
        return;
    }
    // Time stops with the element's frame.
    const owner = self.taskFrame(frame) orelse return;
    self._clock_started = lp.datetime.milliTimestamp(.boot);
    try Clock.schedule(self, owner);
}

// "timeupdate [...] at least every 250ms"
// https://html.spec.whatwg.org/multipage/media.html#time-marches-on
const TIMEUPDATE_MS = 250;

// The delay to the next timeupdate, or to the end if that comes first.
fn msToNextTick(self: *const Media) u32 {
    const to_end = (self._duration - self.position()) * 1000 / self._playback_rate;
    return @intFromFloat(std.math.clamp(@ceil(to_end), 1, TIMEUPDATE_MS));
}

fn tick(self: *Media, frame: *Frame) !void {
    if (self._clock_started == null) {
        return;
    }
    if (self.position() < self._duration) {
        return self.dispatchEvent("timeupdate", frame);
    }

    // https://html.spec.whatwg.org/multipage/media.html#reaches-the-end
    if (self.asConstElement().hasAttributeSafe(comptime .wrap("loop"))) {
        return self.seek(0, frame);
    }
    self.stopClock();
    try self.dispatchEvent("timeupdate", frame);
    if (self._paused == false and self.getEnded()) {
        self._paused = true;
        try self.dispatchEvent("pause", frame);
    }
    try self.dispatchEvent("ended", frame);
}

// The task that moves a playing element along its timeline. `currentTime` is
// computed when read, so the task is only here for the events.
const Clock = struct {
    // null once another clock took over
    media: ?*Media,
    frame: *Frame,

    fn schedule(media: *Media, frame: *Frame) !void {
        const self = try frame._factory.create(Clock{ .media = media, .frame = frame });
        errdefer frame._factory.destroy(self);
        // A page isn't done only once its media has played out.
        try frame.js.scheduler.add(self, Clock.run, media.msToNextTick(), .{
            .name = "Media.clock",
            .blocks_done = false,
            .finalizer = Clock.finalizer,
        });
        if (media._clock) |previous| {
            previous.media = null;
        }
        media._clock = self;
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        const frame = self.frame;
        if (self.media) |media| {
            media.tick(frame) catch |err| {
                log.warn(.frame, "media clock", .{ .err = err });
            };
        }

        // The listeners can have paused the element, or restarted its clock.
        if (self.media) |media| {
            if (media._clock_started != null) {
                return media.msToNextTick();
            }
            media._clock = null;
        }
        frame._factory.destroy(self);
        return null;
    }

    // The frame is going away. The element can outlive it: a script of
    // another frame may still hold it.
    fn finalizer(ctx: *anyopaque) void {
        const self: *Clock = @ptrCast(@alignCast(ctx));
        if (self.media) |media| {
            media.stopClock();
            media._clock = null;
        }
        self.frame._factory.destroy(self);
    }
};

// https://html.spec.whatwg.org/multipage/media.html#dom-media-seek
// There's no data to wait for: the new position is current at once, and the
// events follow in a task.
fn seek(self: *Media, to: f64, frame: *Frame) !void {
    self._clock_started = null;
    self._current_time = std.math.clamp(to, 0, self._duration);
    try self.startClock(frame);
    if (self._seeking) {
        // the task of an earlier seek is still to run
        return;
    }
    const owner = self.taskFrame(frame) orelse return;
    try Task.schedule(self, owner, .seek);
    self._seeking = true;
}

fn finishSeek(self: *Media, frame: *Frame) !void {
    const generation = self._generation;
    try self.dispatchEvent("seeking", frame);
    if (self._generation != generation) {
        return;
    }
    self._seeking = false;
    try self.dispatchEvent("timeupdate", frame);
    if (self._generation != generation) {
        return;
    }
    try self.dispatchEvent("seeked", frame);
}

// A task for the element's current source, dropped if the element has loaded
// another by the time it runs.
const Task = struct {
    media: *Media,
    frame: *Frame,
    generation: u32,
    step: Step,

    const Step = enum { load, seek, removed };

    fn schedule(media: *Media, frame: *Frame, step: Step) !void {
        const self = try frame._factory.create(Task{
            .media = media,
            .frame = frame,
            .generation = media._generation,
            .step = step,
        });
        errdefer frame._factory.destroy(self);
        try frame.js.scheduler.add(self, Task.run, 0, .{
            .name = "Media.task",
            .finalizer = Task.finalizer,
        });
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *Task = @ptrCast(@alignCast(ctx));
        const task = self.*;
        task.frame._factory.destroy(self);

        const media = task.media;
        if (task.generation != media._generation or task.frame.isGoingAway()) {
            return null;
        }
        switch (task.step) {
            .load => try media.loadResource(task.frame),
            .seek => try media.finishSeek(task.frame),
            // "When a media element is removed from a document [...] if the
            // media element is in a document, return", else pause.
            .removed => if (media.asNode().isConnected() == false) try media.pause(task.frame),
        }
        return null;
    }

    fn finalizer(ctx: *anyopaque) void {
        const self: *Task = @ptrCast(@alignCast(ctx));
        if (self.step == .seek and self.generation == self.media._generation) {
            self.media._seeking = false;
        }
        self.frame._factory.destroy(self);
    }
};

fn getPaused(self: *const Media) bool {
    return self._paused;
}

fn getCurrentTime(self: *const Media) f64 {
    return self.position();
}

pub fn getDuration(self: *const Media) f64 {
    return self._duration;
}

fn getReadyState(self: *const Media) u16 {
    return @backingInt(self._ready_state);
}

fn getNetworkState(self: *const Media) u16 {
    return @backingInt(self._network_state);
}

// Never without a duration: NaN compares false.
fn getEnded(self: *const Media) bool {
    return self.position() >= self._duration and self.asConstElement().hasAttributeSafe(comptime .wrap("loop")) == false;
}

fn getSeeking(self: *const Media) bool {
    return self._seeking;
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

fn setPlaybackRate(self: *Media, value: f64, frame: *Frame) !void {
    if (std.math.isFinite(value) == false) {
        return error.TypeError;
    }
    // the time played so far went at the previous rate
    self.stopClock();
    self._playback_rate = value;
    try self.startClock(frame);
}

fn setCurrentTime(self: *Media, value: f64, frame: *Frame) !void {
    if (std.math.isFinite(value) == false) {
        return error.TypeError;
    }
    if (std.math.isNan(self._duration)) {
        // no timeline to seek in
        self._current_time = value;
        return;
    }
    try self.seek(value, frame);
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

pub const Build = struct {
    pub fn created(node: *Node, frame: *Frame) !void {
        const self = node.as(Media);
        if (self.asElement().getAttributeInterned("src") != null) {
            try self.selectResource(frame);
        }
    }

    // Removing the src doesn't load anything, nor drop what's loaded.
    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (name.eql(comptime .wrap("src")) == false) {
            return;
        }
        const self = element.as(Media);
        if (std.math.isNan(self._duration)) {
            // nothing loaded to reset, only a pending load to drop
            self._generation +%= 1;
        } else {
            self.resetForLoad();
        }
        try self.selectResource(frame);
    }

    // An element playing out its timeline pauses once it has left its
    // document, unless it is back in one by the time the task runs.
    pub fn disconnected(element: *Element, frame: *Frame) !void {
        const self = element.as(Media);
        if (self._clock_started == null) {
            return;
        }
        const owner = self.taskFrame(frame) orelse return;
        try Task.schedule(self, owner, .removed);
    }
};

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

test "WebApi: Media clock" {
    try testing.htmlRunner("element/html/media_clock.html", .{});
}
