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

const js = @import("../js/js.zig");
const Page = @import("../page.zig").Page;

const Animation = @This();

effect: ?js.Object,
timeline: ?js.Object,
ready_resolver: ?js.PromiseResolver,
finished_resolver: ?js.PromiseResolver,

pub fn constructor(effect: ?js.Object, timeline: ?js.Object) !Animation {
    return .{
        .effect = if (effect) |eo| try eo.persist() else null,
        .timeline = if (timeline) |to| try to.persist() else null,
        .ready_resolver = null,
        .finished_resolver = null,
    };
}

pub fn get_playState(self: *const Animation) []const u8 {
    _ = self;
    return "finished";
}

pub fn get_pending(self: *const Animation) bool {
    _ = self;
    return false;
}

pub fn get_finished(self: *Animation, page: *Page) !js.Promise {
    if (self.finished_resolver == null) {
        const resolver = page.js.createPromiseResolver(.none);
        try resolver.resolve(self);
        self.finished_resolver = resolver;
    }
    return self.finished_resolver.?.promise();
}

pub fn get_ready(self: *Animation, page: *Page) !js.Promise {
    // never resolved, because we're always "finished"
    if (self.ready_resolver == null) {
        const resolver = page.js.createPromiseResolver(.none);
        self.ready_resolver = resolver;
    }
    return self.ready_resolver.?.promise();
}

pub fn get_effect(self: *const Animation) ?js.Object {
    return self.effect;
}

pub fn set_effect(self: *Animation, effect: js.Object) !void {
    self.effect = try effect.persist();
}

pub fn get_timeline(self: *const Animation) ?js.Object {
    return self.timeline;
}

pub fn set_timeline(self: *Animation, timeline: js.Object) !void {
    self.timeline = try timeline.persist();
}

pub fn _play(self: *const Animation) void {
    _ = self;
}

pub fn _pause(self: *const Animation) void {
    _ = self;
}

pub fn _cancel(self: *const Animation) void {
    _ = self;
}

pub fn _finish(self: *const Animation) void {
    _ = self;
}

pub fn _reverse(self: *const Animation) void {
    _ = self;
}

const testing = @import("../../testing.zig");
test "Browser: DOM.Animation" {
    try testing.htmlRunner("dom/animation.html");
}
