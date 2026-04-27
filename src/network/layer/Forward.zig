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

pub fn fromRequest(req: Request) Forward {
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

pub const Overrides = struct {
    start: ?Request.StartCallback = null,
    header: ?Request.HeaderCallback = null,
    data: ?Request.DataCallback = null,
    done: ?Request.DoneCallback = null,
    err: ?Request.ErrorCallback = null,
    shutdown: ?Request.ShutdownCallback = null,
};

pub fn wrapRequest(
    self: *Forward,
    req: Request,
    new_ctx: anytype,
    overrides: Overrides,
) Request {
    const T = @TypeOf(new_ctx.*);
    const PassthroughT = makePassthrough(T, "forward");
    var wrapped = req;
    wrapped.ctx = new_ctx;
    wrapped.start_callback = overrides.start orelse if (self.start != null) PassthroughT.start else null;
    wrapped.header_callback = overrides.header orelse PassthroughT.header;
    wrapped.data_callback = overrides.data orelse PassthroughT.data;
    wrapped.done_callback = overrides.done orelse PassthroughT.done;
    wrapped.error_callback = overrides.err orelse PassthroughT.err;
    wrapped.shutdown_callback = overrides.shutdown orelse if (self.shutdown != null) PassthroughT.shutdown else null;
    return wrapped;
}

fn makePassthrough(comptime T: type, comptime field: []const u8) type {
    return struct {
        pub fn start(response: Response) anyerror!void {
            const self: *T = @ptrCast(@alignCast(response.ctx));
            return @field(self, field).forwardStart(response);
        }

        pub fn header(response: Response) anyerror!bool {
            const self: *T = @ptrCast(@alignCast(response.ctx));
            return @field(self, field).forwardHeader(response);
        }

        pub fn data(response: Response, chunk: []const u8) anyerror!void {
            const self: *T = @ptrCast(@alignCast(response.ctx));
            return @field(self, field).forwardData(response, chunk);
        }

        pub fn done(ctx_ptr: *anyopaque) anyerror!void {
            const self: *T = @ptrCast(@alignCast(ctx_ptr));
            return @field(self, field).forwardDone();
        }

        pub fn err(ctx_ptr: *anyopaque, e: anyerror) void {
            const self: *T = @ptrCast(@alignCast(ctx_ptr));
            @field(self, field).forwardErr(e);
        }

        pub fn shutdown(ctx_ptr: *anyopaque) void {
            const self: *T = @ptrCast(@alignCast(ctx_ptr));
            @field(self, field).forwardShutdown();
        }
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
