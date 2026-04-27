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
const log = lp.log;

const URL = @import("../../browser/URL.zig");
const WebBotAuth = @import("../WebBotAuth.zig");
const Client = @import("../../browser/HttpClient.zig").Client;
const Request = @import("../../browser/HttpClient.zig").Request;
const Layer = @import("../../browser/HttpClient.zig").Layer;

const WebBotAuthLayer = @This();

next: Layer = undefined,

pub fn layer(self: *WebBotAuthLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

fn request(ptr: *anyopaque, client: *Client, req: Request) anyerror!void {
    const self: *WebBotAuthLayer = @ptrCast(@alignCast(ptr));
    var our_req = req;

    const wba = client.network.web_bot_auth orelse @panic("WebBotAuthLayer shouldn't be active without WebBotAuth");

    const arena = req.params.arena;
    const authority = URL.getHost(req.params.url);
    try wba.signRequest(arena, &our_req.params.headers, authority);

    return self.next.request(client, our_req);
}
