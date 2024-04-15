const std = @import("std");

const public = @import("jsruntime");

const Window = @import("html/window.zig").Window;

const cdp = @import("cdp/cdp.zig");
pub var socket_fd: std.os.socket_t = undefined;

// I/O input command context
pub const CmdContext = struct {
    js_env: *public.Env,
    socket: std.os.socket_t,
    completion: *public.IO.Completion,

    read_buf: []u8,
    write_buf: []const u8 = undefined,

    close: bool = false,

    try_catch: public.TryCatch,

    // shortcuts
    fn alloc(self: *CmdContext) std.mem.Allocator {
        return self.js_env.nat_ctx.alloc;
    }

    fn loop(self: *CmdContext) *public.Loop {
        return self.js_env.nat_ctx.loop;
    }
};

fn respCallback(
    ctx: *CmdContext,
    _: *public.IO.Completion,
    result: public.IO.SendError!usize,
) void {
    _ = result catch |err| {
        ctx.close = true;
        std.debug.print("send error: {s}\n", .{@errorName(err)});
        return;
    };
    std.log.debug("send ok", .{});
}

const SendLaterContext = struct {
    cmd_ctx: *CmdContext,
    completion: *public.IO.Completion,
    buf: []const u8,
};

fn sendLaterCallback(
    ctx: *SendLaterContext,
    completion: *public.IO.Completion,
    result: public.IO.TimeoutError!void,
) void {
    std.log.debug("sending after", .{});
    _ = result catch |err| {
        ctx.cmd_ctx.close = true;
        std.debug.print("timeout error: {s}\n", .{@errorName(err)});
        return;
    };

    ctx.cmd_ctx.alloc().destroy(completion);
    defer ctx.cmd_ctx.alloc().destroy(ctx);
    send(ctx.cmd_ctx, ctx.buf) catch unreachable;
}

pub fn sendLater(ctx: *CmdContext, msg: []const u8) !void {
    // NOTE: it seems we can't use the same completion for concurrent
    // recv and timeout operations, that's why we create a new completion here
    const completion = try ctx.alloc().create(public.IO.Completion);
    // NOTE: to handle concurrent calls to sendLater we create each time a new context
    // If no concurrent calls are required we could just use the main CmdContext
    const sendLaterCtx = try ctx.alloc().create(SendLaterContext);
    sendLaterCtx.* = .{
        .cmd_ctx = ctx,
        .completion = completion,
        .buf = msg,
    };
    ctx.loop().io.timeout(*SendLaterContext, sendLaterCtx, sendLaterCallback, completion, 1000);
}

fn send(ctx: *CmdContext, msg: []const u8) !void {
    defer ctx.alloc().free(msg);
    const s = try std.os.write(ctx.socket, msg);
    std.log.debug("send ok {d}", .{s});
}

fn loopSend(ctx: *CmdContext, msg: []const u8) !void {
    ctx.write_buf = msg;
    ctx.loop().io.send(
        *CmdContext,
        ctx,
        respCallback,
        ctx.completion,
        ctx.socket,
        ctx.write_buf,
    );
}

// I/O input command callback
fn cmdCallback(
    ctx: *CmdContext,
    completion: *public.IO.Completion,
    result: public.IO.RecvError!usize,
) void {
    // ctx.completion = completion;
    const size = result catch |err| {
        ctx.close = true;
        std.debug.print("recv error: {s}\n", .{@errorName(err)});
        return;
    };

    const input = ctx.read_buf[0..size];

    // close on exit command
    if (std.mem.eql(u8, input, "exit")) {
        ctx.close = true;
        return;
    }

    std.debug.print("\ninput {s}\n", .{input});
    const res = cdp.do(ctx.alloc(), input, ctx) catch |err| {
        std.log.debug("error: {any}\n", .{err});
        send(ctx, "{}") catch unreachable;
        // TODO: return proper error
        return;
    };
    std.log.debug("res {s}", .{res});

    sendLater(ctx, res) catch unreachable;
    std.log.debug("finish", .{});

    // continue receving messages asynchronously
    ctx.loop().io.recv(
        *CmdContext,
        ctx,
        cmdCallback,
        completion,
        ctx.socket,
        ctx.read_buf,
    );
}

// I/O connection context
const ConnContext = struct {
    socket: std.os.socket_t,

    cmdContext: *CmdContext,
};

// I/O connection callback
fn connCallback(
    ctx: *ConnContext,
    completion: *public.IO.Completion,
    result: public.IO.AcceptError!std.os.socket_t,
) void {
    ctx.cmdContext.socket = result catch |err| @panic(@errorName(err));

    // launch receving messages asynchronously
    ctx.cmdContext.loop().io.recv(
        *CmdContext,
        ctx.cmdContext,
        cmdCallback,
        completion,
        ctx.cmdContext.socket,
        ctx.cmdContext.read_buf,
    );
}

pub fn execJS(
    alloc: std.mem.Allocator,
    js_env: *public.Env,
) anyerror!void {

    // start JS env
    try js_env.start(alloc);
    defer js_env.stop();

    // alias global as self
    try js_env.attachObject(try js_env.getGlobal(), "self", null);

    // alias global as self and window
    const window = Window.create(null);
    // window.replaceDocument(doc); TODO
    try js_env.bindGlobal(window);

    // add console object
    const console = public.Console{};
    try js_env.addObject(console, "console");

    // JS try cache
    var try_catch = public.TryCatch.init(js_env.*);
    defer try_catch.deinit();

    // create I/O contexts and callbacks
    // for accepting connections and receving messages
    var completion: public.IO.Completion = undefined;
    var input: [1024]u8 = undefined;
    var cmd_ctx = CmdContext{
        .js_env = js_env,
        .socket = undefined,
        .read_buf = &input,
        .try_catch = try_catch,
        .completion = &completion,
    };
    var conn_ctx = ConnContext{
        .socket = socket_fd,
        .cmdContext = &cmd_ctx,
    };

    // launch accepting connection asynchronously on internal server
    const loop = js_env.nat_ctx.loop;
    loop.io.accept(
        *ConnContext,
        &conn_ctx,
        connCallback,
        &completion,
        socket_fd,
    );

    // infinite loop on I/O events, either:
    // - cmd from incoming connection on server socket
    // - JS callbacks events from scripts
    while (true) {
        try loop.io.tick();
        if (loop.cbk_error) {
            if (try try_catch.exception(alloc, js_env.*)) |msg| {
                std.debug.print("\n\rUncaught {s}\n\r", .{msg});
                alloc.free(msg);
            }
            loop.cbk_error = false;
        }
        if (cmd_ctx.close) {
            break;
        }
    }
}
