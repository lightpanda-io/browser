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
const builtin = @import("builtin");
const log = @import("../../log.zig");

const IS_DEBUG = builtin.mode == .Debug;

const URL = @import("../../browser/URL.zig");
const Client = @import("../../browser/HttpClient.zig").Client;
const Request = @import("../../browser/HttpClient.zig").Request;
const Layer = @import("../../browser/HttpClient.zig").Layer;

const InterceptionLayer = @This();

// Count of intercepted requests. This is to help deal with intercepted requests.
// The client doesn't track intercepted transfers. If a request is intercepted,
// the client forgets about it and requires the interceptor to continue or abort
// it. That works well, except if we only rely on active, we might think there's
// no more network activity when, with interecepted requests, there might be more
// in the future. (We really only need this to properly emit a 'networkIdle' and
// 'networkAlmostIdle' Page.lifecycleEvent in CDP).
intercepted: usize = 0,

next: Layer = undefined,

pub fn layer(self: *InterceptionLayer) Layer {
    return .{
        .ptr = self,
        .vtable = &.{ .request = request },
    };
}

fn request(ptr: *anyopaque, client: *Client, in_req: Request) anyerror!void {
    const self: *InterceptionLayer = @ptrCast(@alignCast(ptr));
    var req = in_req;

    req.params.notification.dispatch(.http_request_start, &.{ .request = &req });

    const wait_for_interception = false;
    // req.params.notification.dispatch(.http_request_intercept, &.{
    //     .transfer = transfer,
    //     .wait_for_interception = &wait_for_interception,
    // });

    if (wait_for_interception == false) {
        // request not intercepted, process it normally
        return self.next.request(client, req);
    }

    @panic("not implemented yet");
}
