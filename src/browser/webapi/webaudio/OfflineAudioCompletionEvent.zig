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

// https://webaudio.github.io/web-audio-api/#OfflineAudioCompletionEvent

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");
const AudioBuffer = @import("AudioBuffer.zig");

const String = lp.String;

const OfflineAudioCompletionEvent = @This();

pub const Proto = Event;

_proto: *Event,
// holds a ref
_rendered_buffer: *AudioBuffer,

const Options = Event.inheritOptions(OfflineAudioCompletionEvent, struct {
    renderedBuffer: *AudioBuffer,
});

fn constructor(typ: []const u8, options: Options, page: *Page) !*OfflineAudioCompletionEvent {
    const arena = try page.getArena(.tiny, "OfflineAudioCompletionEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, type_string, options, false, page);
}

pub fn initTrusted(rendered_buffer: *AudioBuffer, page: *Page) !*OfflineAudioCompletionEvent {
    const arena = try page.getArena(.tiny, "OfflineAudioCompletionEvent.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, comptime .wrap("complete"), .{ .renderedBuffer = rendered_buffer }, true, page);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, options: Options, trusted: bool, page: *Page) !*OfflineAudioCompletionEvent {
    const event = try page.factory.event(arena, typ, OfflineAudioCompletionEvent{
        ._proto = undefined,
        ._rendered_buffer = options.renderedBuffer,
    });
    options.renderedBuffer.acquireRef();
    Event.populatePrototypes(event, options, trusted);
    return event;
}

pub fn deinit(self: *OfflineAudioCompletionEvent, page: *Page) void {
    self._rendered_buffer.releaseRef(page);
}

pub fn asEvent(self: *OfflineAudioCompletionEvent) *Event {
    return self._proto;
}

fn getRenderedBuffer(self: *const OfflineAudioCompletionEvent) *AudioBuffer {
    return self._rendered_buffer;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(OfflineAudioCompletionEvent);

    pub const Meta = struct {
        pub const name = "OfflineAudioCompletionEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(OfflineAudioCompletionEvent.constructor, .{});
    pub const renderedBuffer = bridge.accessor(OfflineAudioCompletionEvent.getRenderedBuffer, null, .{});
};
