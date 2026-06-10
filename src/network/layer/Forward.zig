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

// A snapshot of the original ctx + callbacks from a Request, taken before a
// layer overwrites them with its own wrappers. The layer's wrapper callbacks
// call forwardX(...) to invoke the captured originals with the original ctx.
const Request = @import("../../browser/HttpClient.zig").Request;
const Response = @import("../../browser/HttpClient.zig").Response;

const Forward = @This();

ctx: *anyopaque,
start: ?Request.StartCallback,
header: Request.HeaderCallback,
data: Request.DataCallback,
done: Request.DoneCallback,
err: Request.ErrorCallback,
shutdown: ?Request.ShutdownCallback,

pub fn capture(req: *const Request) Forward {
    return .{
        .ctx = req.ctx,
        .start = req.start_callback,
        .header = req.header_callback,
        .data = req.data_callback,
        .done = req.done_callback,
        .err = req.error_callback,
        .shutdown = req.shutdown_callback,
    };
}

pub fn forwardStart(self: Forward, response: Response) anyerror!void {
    var fwd = response;
    fwd.ctx = self.ctx;
    if (self.start) |cb| try cb(fwd);
}

pub fn forwardHeader(self: Forward, response: Response) anyerror!bool {
    var fwd = response;
    fwd.ctx = self.ctx;
    return self.header(fwd);
}

pub fn forwardData(self: Forward, response: Response, chunk: []const u8) anyerror!void {
    var fwd = response;
    fwd.ctx = self.ctx;
    return self.data(fwd, chunk);
}

pub fn forwardDone(self: Forward) anyerror!void {
    return self.done(self.ctx);
}

pub fn forwardErr(self: Forward, e: anyerror) void {
    self.err(self.ctx, e);
}

pub fn forwardShutdown(self: Forward) void {
    if (self.shutdown) |cb| cb(self.ctx);
}
