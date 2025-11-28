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

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");
const MessagePort = @import("MessagePort.zig");

const MessageChannel = @This();

_port1: *MessagePort,
_port2: *MessagePort,

pub fn init(page: *Page) !*MessageChannel {
    const port1 = try MessagePort.init(page);
    const port2 = try MessagePort.init(page);

    MessagePort.entangle(port1, port2);

    return page._factory.create(MessageChannel{
        ._port1 = port1,
        ._port2 = port2,
    });
}


pub fn getPort1(self: *const MessageChannel) *MessagePort {
    return self._port1;
}

pub fn getPort2(self: *const MessageChannel) *MessagePort {
    return self._port2;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MessageChannel);

    pub const Meta = struct {
        pub const name = "MessageChannel";
        pub var class_id: bridge.ClassId = undefined;
        pub const prototype_chain = bridge.prototypeChain();
    };

    pub const constructor = bridge.constructor(MessageChannel.init, .{});
    pub const port1 = bridge.accessor(MessageChannel.getPort1, null, .{});
    pub const port2 = bridge.accessor(MessageChannel.getPort2, null, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: MessageChannel" {
    try testing.htmlRunner("message_channel.html", .{});
}
