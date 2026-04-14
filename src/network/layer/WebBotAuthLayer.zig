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
const log = @import("../../log.zig");

const URL = @import("../../browser/URL.zig");
const WebBotAuth = @import("../WebBotAuth.zig");
const Context = @import("../../browser/HttpClient.zig").Context;
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

pub fn deinit(_: *WebBotAuthLayer, _: std.mem.Allocator) void {}

fn request(ptr: *anyopaque, ctx: Context, req: Request) anyerror!void {
    const self: *WebBotAuthLayer = @ptrCast(@alignCast(ptr));
    var our_req = req;

    if (ctx.network.web_bot_auth) |*wba| {
        const arena = try ctx.network.app.arena_pool.acquire(.small, "WebBotAuthLayer");
        defer ctx.network.app.arena_pool.release(arena);

        const authority = URL.getHost(req.params.url);
        try wba.signRequest(arena, &our_req.params.headers, authority);
    }

    return self.next.request(ctx, our_req);
}
