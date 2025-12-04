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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Animation = @This();

pub fn init() !Animation {
    return .{};
}

pub fn play(_: *Animation) void {}
pub fn pause(_: *Animation) void {}
pub fn cancel(_: *Animation) void {}
pub fn finish(_: *Animation) void {}
pub fn reverse(_: *Animation) void {}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Animation);

    pub const Meta = struct {
        pub const name = "Animation";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const play = bridge.function(Animation.play, .{});
    pub const pause = bridge.function(Animation.pause, .{});
    pub const cancel = bridge.function(Animation.cancel, .{});
    pub const finish = bridge.function(Animation.finish, .{});
    pub const reverse = bridge.function(Animation.reverse, .{});
};
