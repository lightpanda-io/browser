const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenAallocator = std.heap.ArenaAllocator;

const Loop = @import("jsruntime").Loop;
const Client = @import("asyncio").Client;
const Event = @import("telemetry.zig").Event;
const RunMode = @import("../app.zig").RunMode;
const builtin = @import("builtin");
const build_info = @import("build_info");

const log = std.log.scoped(.telemetry);
const URL = "https://telemetry.lightpanda.io";

pub const LightPanda = struct {
    loop: *Loop,
    uri: std.Uri,
    allocator: Allocator,
    sending_pool: std.heap.MemoryPool(Sending),

    pub fn init(allocator: Allocator, loop: *Loop) !LightPanda {
        std.debug.print("{s}\n", .{@typeName(Client.IO)});
        return .{
            .loop = loop,
            .allocator = allocator,
            .uri = std.Uri.parse(URL) catch unreachable,
            .sending_pool = std.heap.MemoryPool(Sending).init(allocator),
        };
    }

    pub fn deinit(self: *LightPanda) void {
        self.sending_pool.deinit();
    }

    pub fn send(self: *LightPanda, iid: ?[]const u8, run_mode: RunMode, event: Event) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const resp_header_buffer = try arena.allocator().alloc(u8, 4096);
        const body = try std.json.stringifyAlloc(arena.allocator(), .{
            .iid = iid,
            .driver = if (std.meta.activeTag(event) == .navigate) "cdp" else null,
            .mode = run_mode,
            .os = builtin.os.tag,
            .arch = builtin.cpu.arch,
            .version = build_info.git_commit,
            .event = std.meta.activeTag(event),
        }, .{ .emit_null_optional_fields = false });

        const sending = try self.sending_pool.create();
        errdefer self.sending_pool.destroy(sending);

        sending.* = .{
            .body = body,
            .arena = arena,
            .ctx = undefined,
            .lightpanda = self,
            .request = undefined,
            .io = Client.IO.init(self.loop),
            .client = .{ .allocator = self.allocator },
        };
        sending.request = try sending.client.create(.POST, self.uri, .{
            .server_header_buffer = resp_header_buffer,
        });
        errdefer sending.request.deinit();

        sending.ctx = try Client.Ctx.init(&sending.io, &sending.request);
        errdefer sending.ctx.deinit();

        try sending.client.async_open(
            .POST,
            self.uri,
            .{ .server_header_buffer = resp_header_buffer },
            &sending.ctx,
            onRequestConnect,
        );
    }

    fn handleError(ctx: *Client.Ctx, err: anyerror) anyerror!void {
        const sending: *Sending = @fieldParentPtr("ctx", ctx);
        const lightpanda = sending.lightpanda;

        sending.deinit();
        lightpanda.sending_pool.destroy(sending);
        log.info("request failure: {}", .{err});
    }

    fn onRequestConnect(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        const sending: *Sending = @fieldParentPtr("ctx", ctx);
        res catch |err| return handleError(ctx, err);

        ctx.req.transfer_encoding = .{ .content_length = sending.body.len };
        return ctx.req.async_send(ctx, onRequestSend) catch |err| {
            return handleError(ctx, err);
        };
    }

    fn onRequestSend(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        const sending: *Sending = @fieldParentPtr("ctx", ctx);
        res catch |err| return handleError(ctx, err);

        return ctx.req.async_writeAll(sending.body, ctx, onRequestWrite) catch |err| {
            return handleError(ctx, err);
        };
    }

    fn onRequestWrite(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        res catch |err| return handleError(ctx, err);
        return ctx.req.async_finish(ctx, onRequestFinish) catch |err| {
            return handleError(ctx, err);
        };
    }

    fn onRequestFinish(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        res catch |err| return handleError(ctx, err);
        return ctx.req.async_wait(ctx, onRequestWait) catch |err| {
            return handleError(ctx, err);
        };
    }

    fn onRequestWait(ctx: *Client.Ctx, res: anyerror!void) anyerror!void {
        const sending: *Sending = @fieldParentPtr("ctx", ctx);
        res catch |err| return handleError(ctx, err);

        const lightpanda = sending.lightpanda;

        defer {
            sending.deinit();
            lightpanda.sending_pool.destroy(sending);
        }

        if (ctx.req.response.status != .ok) {
            log.info("invalid response: {d}", .{@intFromEnum(ctx.req.response.status)});
        }
    }
};

const Sending = struct {
    io: Client.IO,
    ctx: Client.Ctx,
    client: Client,
    body: []const u8,
    request: Client.Request,
    lightpanda: *LightPanda,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Sending) void {
        self.ctx.deinit();
        self.arena.deinit();
        self.request.deinit();
        self.client.deinit();
    }
};
