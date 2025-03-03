const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenAallocator = std.heap.ArenaAllocator;

const Loop = @import("jsruntime").Loop;
const Client = @import("asyncio").Client;

const log = std.log.scoped(.telemetry);

const URL = "https://stats.lightpanda.io";

pub const LightPanda = struct {
    uri: std.Uri,
    io: Client.IO,
    client: Client,
    allocator: Allocator,
    sending_pool: std.heap.MemoryPool(Sending),
    client_context_pool: std.heap.MemoryPool(Client.Ctx),

    pub fn init(allocator: Allocator, loop: *Loop) !LightPanda {
        return .{
            .allocator = allocator,
            .io = Client.IO.init(loop),
            .client = .{ .allocator = allocator },
            .uri = std.Uri.parse(URL) catch unreachable,
            .sending_pool = std.heap.MemoryPool(Sending).init(allocator),
            .client_context_pool = std.heap.MemoryPool(Client.Ctx).init(allocator),
        };
    }

    pub fn deinit(self: *LightPanda) void {
        self.client.deinit();
        self.sending_pool.deinit();
        self.client_context_pool.deinit();
    }

    pub fn send(self: *LightPanda, iid: ?[]const u8, eid: []const u8, event: anytype) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const resp_header_buffer = try arena.allocator().alloc(u8, 4096);
        const body = try std.json.stringifyAlloc(arena.allocator(), .{
            .iid = iid,
            .eid = eid,
            .event = event,
        }, .{});

        const sending = try self.sending_pool.create();
        errdefer self.sending_pool.destroy(sending);

        sending.* = .{
            .body = body,
            .arena = arena,
            .lightpanda = self,
            .request = try self.client.create(.POST, self.uri, .{
                .server_header_buffer = resp_header_buffer,
            }),
        };
        errdefer sending.request.deinit();

        const ctx = try self.client_context_pool.create();
        errdefer self.client_context_pool.destroy(ctx);

        ctx.* = try Client.Ctx.init(&self.io, &sending.request);
        ctx.userData = sending;

        try self.client.async_open(
            .POST,
            self.uri,
            .{ .server_header_buffer = resp_header_buffer },
            ctx,
            onRequestConnect,
        );
    }

    fn handleError(self: *LightPanda, ctx: *Client.Ctx, err: anyerror) anyerror!void {
        ctx.deinit();
        self.client_context_pool.destroy(ctx);

        var sending: *Sending = @ptrCast(@alignCast(ctx.userData));
        sending.deinit();
        self.sending_pool.destroy(sending);
        log.info("request failure: {}", .{err});
    }

    fn onRequestConnect(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        var sending: *Sending = @ptrCast(@alignCast(ctx.userData));
        res catch |err| return sending.lightpanda.handleError(ctx, err);

        ctx.req.transfer_encoding = .{ .content_length = sending.body.len };
        return ctx.req.async_send(ctx, onRequestSend) catch |err| {
            return sending.lightpanda.handleError(ctx, err);
        };
    }

    fn onRequestSend(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        var sending: *Sending = @ptrCast(@alignCast(ctx.userData));
        res catch |err| return sending.lightpanda.handleError(ctx, err);

        return ctx.req.async_writeAll(sending.body, ctx, onRequestWrite) catch |err| {
            return sending.lightpanda.handleError(ctx, err);
        };
    }

    fn onRequestWrite(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        var sending: *Sending = @ptrCast(@alignCast(ctx.userData));
        res catch |err| return sending.lightpanda.handleError(ctx, err);
        return ctx.req.async_finish(ctx, onRequestFinish) catch |err| {
            return sending.lightpanda.handleError(ctx, err);
        };
    }

    fn onRequestFinish(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        var sending: *Sending = @ptrCast(@alignCast(ctx.userData));
        res catch |err| return sending.lightpanda.handleError(ctx, err);
        return ctx.req.async_wait(ctx, onRequestWait) catch |err| {
            return sending.lightpanda.handleError(ctx, err);
        };
    }

    fn onRequestWait(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        var sending: *Sending = @ptrCast(@alignCast(ctx.userData));
        res catch |err| return sending.lightpanda.handleError(ctx, err);

        const lightpanda = sending.lightpanda;

        defer {
            ctx.deinit();
            lightpanda.client_context_pool.destroy(ctx);

            sending.deinit();
            lightpanda.sending_pool.destroy(sending);
        }

        var buffer: [2048]u8 = undefined;
        const reader = ctx.req.reader();
        while (true) {
            const n = reader.read(&buffer) catch 0;
            if (n == 0) {
                break;
            }
        }
        if (ctx.req.response.status != .ok) {
            log.info("invalid response: {d}", .{@intFromEnum(ctx.req.response.status)});
        }
    }
};

const Sending = struct {
    body: []const u8,
    request: Client.Request,
    lightpanda: *LightPanda,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Sending) void {
        self.arena.deinit();
        self.request.deinit();
    }
};

// // wraps a telemetry event so that we can serialize it to plausible's event endpoint
// const EventWrap = struct {
//     iid: ?[]const u8,
//     eid: []const u8,
//     event: *const Event,

//     pub fn jsonStringify(self: *const EventWrap, jws: anytype) !void {
//         try jws.beginObject();
//         try jws.objectField("iid");
//         try jws.write(self.iid);
//         try jws.objectField("eid");
//         try jws.write(self.eid);
//         try jws.objectField("event");
//         try jws.write(@tagName(self.event.*));
//         try jws.objectField("props");
//         switch (self.event) {
//             inline else => |props| try jws.write(props),
//         }
//         try jws.endObject();
//     }
// };

// const testing = std.testing;
// test "telemetry: lightpanda json event" {
//     const json = try std.json.stringifyAlloc(testing.allocator, EventWrap{
//         .iid = "1234",
//         .eid = "abc!",
//         .event = .{ .run = .{ .mode = .serve, .version = "over 9000!" } }
//     }, .{});
//     defer testing.allocator.free(json);

//     try testing.expectEqualStrings(
//         \\{"event":"run","iid""1234","eid":"abc!","props":{"version":"over 9000!","mode":"serve"}}
//     , json);
// }
