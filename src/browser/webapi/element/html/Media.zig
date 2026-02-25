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
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");

const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const Event = @import("../../Event.zig");
pub const Audio = @import("Audio.zig");
pub const Video = @import("Video.zig");
const MediaError = @import("../../media/MediaError.zig");

const Media = @This();

pub const ReadyState = enum(u16) {
    HAVE_NOTHING = 0,
    HAVE_METADATA = 1,
    HAVE_CURRENT_DATA = 2,
    HAVE_FUTURE_DATA = 3,
    HAVE_ENOUGH_DATA = 4,
};

pub const NetworkState = enum(u16) {
    NETWORK_EMPTY = 0,
    NETWORK_IDLE = 1,
    NETWORK_LOADING = 2,
    NETWORK_NO_SOURCE = 3,
};

pub const Type = union(enum) {
    generic,
    audio: *Audio,
    video: *Video,
};

_type: Type,
_proto: *HtmlElement,
_paused: bool = true,
_current_time: f64 = 0,
_volume: f64 = 1.0,
_muted: bool = false,
_playback_rate: f64 = 1.0,
_ready_state: ReadyState = .HAVE_NOTHING,
_network_state: NetworkState = .NETWORK_EMPTY,
_error: ?*MediaError = null,

pub fn asElement(self: *Media) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const Media) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *Media) *Node {
    return self.asElement().asNode();
}

pub fn is(self: *Media, comptime T: type) ?*T {
    const type_name = @typeName(T);
    switch (self._type) {
        .audio => |a| {
            if (T == *Audio) return a;
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.Audio")) {
                return a;
            }
        },
        .video => |v| {
            if (T == *Video) return v;
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.Video")) {
                return v;
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *Media, comptime T: type) *T {
    return self.is(T).?;
}

pub fn canPlayType(_: *const Media, mime_type: []const u8, page: *Page) []const u8 {
    const pos = std.mem.indexOfScalar(u8, mime_type, ';') orelse mime_type.len;
    const base_type = std.mem.trim(u8, mime_type[0..pos], &std.ascii.whitespace);

    if (base_type.len > page.buf.len) {
        return "";
    }
    const lower = std.ascii.lowerString(&page.buf, base_type);

    if (isProbablySupported(lower)) {
        return "probably";
    }
    if (isMaybeSupported(lower)) {
        return "maybe";
    }
    return "";
}

fn isProbablySupported(mime_type: []const u8) bool {
    if (std.mem.eql(u8, mime_type, "video/mp4")) return true;
    if (std.mem.eql(u8, mime_type, "video/webm")) return true;
    if (std.mem.eql(u8, mime_type, "audio/mp4")) return true;
    if (std.mem.eql(u8, mime_type, "audio/webm")) return true;
    if (std.mem.eql(u8, mime_type, "audio/mpeg")) return true;
    if (std.mem.eql(u8, mime_type, "audio/mp3")) return true;
    if (std.mem.eql(u8, mime_type, "audio/ogg")) return true;
    if (std.mem.eql(u8, mime_type, "video/ogg")) return true;
    if (std.mem.eql(u8, mime_type, "audio/wav")) return true;
    if (std.mem.eql(u8, mime_type, "audio/wave")) return true;
    if (std.mem.eql(u8, mime_type, "audio/x-wav")) return true;
    return false;
}

fn isMaybeSupported(mime_type: []const u8) bool {
    if (std.mem.eql(u8, mime_type, "audio/aac")) return true;
    if (std.mem.eql(u8, mime_type, "audio/x-m4a")) return true;
    if (std.mem.eql(u8, mime_type, "video/x-m4v")) return true;
    if (std.mem.eql(u8, mime_type, "audio/flac")) return true;
    return false;
}

pub fn play(self: *Media, page: *Page) !void {
    const was_paused = self._paused;
    self._paused = false;
    self._ready_state = .HAVE_ENOUGH_DATA;
    self._network_state = .NETWORK_IDLE;
    if (was_paused) {
        try self.dispatchEvent("play", page);
        try self.dispatchEvent("playing", page);
    }
}

pub fn pause(self: *Media, page: *Page) !void {
    if (!self._paused) {
        self._paused = true;
        try self.dispatchEvent("pause", page);
    }
}

pub fn load(self: *Media, page: *Page) !void {
    self._paused = true;
    self._current_time = 0;
    self._ready_state = .HAVE_NOTHING;
    self._network_state = .NETWORK_LOADING;
    self._error = null;
    try self.dispatchEvent("emptied", page);
}

fn dispatchEvent(self: *Media, name: []const u8, page: *Page) !void {
    const event = try Event.init(name, .{ .bubbles = false, .cancelable = false }, page);
    try page._event_manager.dispatch(self.asElement().asEventTarget(), event);
}

pub fn getPaused(self: *const Media) bool {
    return self._paused;
}

pub fn getCurrentTime(self: *const Media) f64 {
    return self._current_time;
}

pub fn getDuration(_: *const Media) f64 {
    return std.math.nan(f64);
}

pub fn getReadyState(self: *const Media) u16 {
    return @intFromEnum(self._ready_state);
}

pub fn getNetworkState(self: *const Media) u16 {
    return @intFromEnum(self._network_state);
}

pub fn getEnded(_: *const Media) bool {
    return false;
}

pub fn getSeeking(_: *const Media) bool {
    return false;
}

pub fn getError(self: *const Media) ?*MediaError {
    return self._error;
}

pub fn getVolume(self: *const Media) f64 {
    return self._volume;
}

pub fn setVolume(self: *Media, value: f64) void {
    self._volume = @max(0.0, @min(1.0, value));
}

pub fn getMuted(self: *const Media) bool {
    return self._muted;
}

pub fn setMuted(self: *Media, value: bool) void {
    self._muted = value;
}

pub fn getPlaybackRate(self: *const Media) f64 {
    return self._playback_rate;
}

pub fn setPlaybackRate(self: *Media, value: f64) void {
    self._playback_rate = value;
}

pub fn setCurrentTime(self: *Media, value: f64) void {
    self._current_time = value;
}

pub fn getSrc(self: *const Media, page: *Page) ![]const u8 {
    const element = self.asConstElement();
    const src = element.getAttributeSafe(comptime .wrap("src")) orelse return "";
    if (src.len == 0) {
        return "";
    }
    const URL = @import("../../URL.zig");
    return URL.resolve(page.call_arena, page.base(), src, .{ .encode = true });
}

pub fn setSrc(self: *Media, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("src"), .wrap(value), page);
}

pub fn getAutoplay(self: *const Media) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("autoplay")) != null;
}

pub fn setAutoplay(self: *Media, value: bool, page: *Page) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("autoplay"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("autoplay"), page);
    }
}

pub fn getControls(self: *const Media) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("controls")) != null;
}

pub fn setControls(self: *Media, value: bool, page: *Page) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("controls"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("controls"), page);
    }
}

pub fn getLoop(self: *const Media) bool {
    return self.asConstElement().getAttributeSafe(comptime .wrap("loop")) != null;
}

pub fn setLoop(self: *Media, value: bool, page: *Page) !void {
    if (value) {
        try self.asElement().setAttributeSafe(comptime .wrap("loop"), .wrap(""), page);
    } else {
        try self.asElement().removeAttribute(comptime .wrap("loop"), page);
    }
}

pub fn getPreload(self: *const Media) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("preload")) orelse "auto";
}

pub fn setPreload(self: *Media, value: []const u8, page: *Page) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("preload"), .wrap(value), page);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Media);

    pub const Meta = struct {
        pub const name = "HTMLMediaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const NETWORK_EMPTY = bridge.property(@intFromEnum(NetworkState.NETWORK_EMPTY), .{ .template = true });
    pub const NETWORK_IDLE = bridge.property(@intFromEnum(NetworkState.NETWORK_IDLE), .{ .template = true });
    pub const NETWORK_LOADING = bridge.property(@intFromEnum(NetworkState.NETWORK_LOADING), .{ .template = true });
    pub const NETWORK_NO_SOURCE = bridge.property(@intFromEnum(NetworkState.NETWORK_NO_SOURCE), .{ .template = true });

    pub const HAVE_NOTHING = bridge.property(@intFromEnum(ReadyState.HAVE_NOTHING), .{ .template = true });
    pub const HAVE_METADATA = bridge.property(@intFromEnum(ReadyState.HAVE_METADATA), .{ .template = true });
    pub const HAVE_CURRENT_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_CURRENT_DATA), .{ .template = true });
    pub const HAVE_FUTURE_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_FUTURE_DATA), .{ .template = true });
    pub const HAVE_ENOUGH_DATA = bridge.property(@intFromEnum(ReadyState.HAVE_ENOUGH_DATA), .{ .template = true });

    pub const src = bridge.accessor(Media.getSrc, Media.setSrc, .{});
    pub const autoplay = bridge.accessor(Media.getAutoplay, Media.setAutoplay, .{});
    pub const controls = bridge.accessor(Media.getControls, Media.setControls, .{});
    pub const loop = bridge.accessor(Media.getLoop, Media.setLoop, .{});
    pub const muted = bridge.accessor(Media.getMuted, Media.setMuted, .{});
    pub const preload = bridge.accessor(Media.getPreload, Media.setPreload, .{});
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

    pub const canPlayType = bridge.function(Media.canPlayType, .{});
    pub const play = bridge.function(Media.play, .{});
    pub const pause = bridge.function(Media.pause, .{});
    pub const load = bridge.function(Media.load, .{});
};

const testing = @import("../../../../testing.zig");
test "WebApi: Media" {
    try testing.htmlRunner("element/html/media.html", .{});
}
