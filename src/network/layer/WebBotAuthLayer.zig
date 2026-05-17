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

const WebBotAuth = @import("../WebBotAuth.zig");

const URL = @import("../../browser/URL.zig");
const Layer = @import("../../browser/HttpClient.zig").Layer;
const Client = @import("../../browser/HttpClient.zig").Client;
const Transfer = @import("../../browser/HttpClient.zig").Transfer;

const log = lp.log;

const WebBotAuthLayer = @This();

next: Layer = undefined,

pub fn layer(self: *WebBotAuthLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

fn request(ptr: *anyopaque, transfer: *Transfer) anyerror!void {
    const self: *WebBotAuthLayer = @ptrCast(@alignCast(ptr));

    const wba = transfer.client.network.web_bot_auth orelse @panic("WebBotAuthLayer shouldn't be active without WebBotAuth");

    const authority = URL.getHost(transfer.req.url);
    try wba.signRequest(transfer.arena, &transfer.req.headers, authority);

    return self.next.request(transfer);
}
