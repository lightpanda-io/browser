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
    buf: []u8,
    close: bool = false,

    try_catch: public.TryCatch,

    // shortcuts
    fn alloc(self: *CmdContext) std.mem.Allocator {
        return self.js_env.nat_ctx.alloc;
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

pub fn send(ctx: *CmdContext, msg: []const u8) !void {
    defer ctx.alloc().free(msg);
    return osSend(ctx, msg);
}

pub const SendFn = (fn (*CmdContext, []const u8) anyerror!void);

fn osSend(ctx: *CmdContext, msg: []const u8) !void {
    const s = try std.os.write(ctx.socket, msg);
    std.log.debug("send ok {d}", .{s});
}

fn loopSend(ctx: *CmdContext, msg: []const u8) !void {
    ctx.js_env.nat_ctx.loop.io.send(
        *CmdContext,
        ctx,
        respCallback,
        ctx.completion,
        ctx.socket,
        msg,
    );
}

// I/O input command callback
fn cmdCallback(
    ctx: *CmdContext,
    completion: *public.IO.Completion,
    result: public.IO.RecvError!usize,
) void {
    const size = result catch |err| {
        ctx.close = true;
        std.debug.print("recv error: {s}\n", .{@errorName(err)});
        return;
    };

    const input = ctx.buf[0..size];

    // close on exit command
    if (std.mem.eql(u8, input, "exit")) {
        ctx.close = true;
        return;
    }

    // continue receving messages asynchronously
    defer {
        ctx.js_env.nat_ctx.loop.io.recv(
            *CmdContext,
            ctx,
            cmdCallback,
            completion,
            ctx.socket,
            ctx.buf,
        );
    }

    std.debug.print("input {s}\n", .{input});
    const res = cdp.do(ctx.alloc(), input, ctx, osSend) catch |err| {
        std.log.debug("error: {any}\n", .{err});
        loopSend(ctx, "{}") catch unreachable;
        // TODO: return proper error
        return;
    };
    std.log.debug("res {s}", .{res});

    osSend(ctx, res) catch unreachable;

    // ctx.js_env.nat_ctx.loop.io.send(
    //     *CmdContext,
    //     ctx,
    //     respCallback,
    //     completion,
    //     ctx.socket,
    //     res,
    // );

    // JS execute
    // const res = ctx.js_env.exec(
    //     ctx.alloc,
    //     input,
    //     "shell.js",
    //     ctx.try_catch,
    // ) catch |err| {
    //     ctx.close = true;
    //     std.debug.print("JS exec error: {s}\n", .{@errorName(err)});
    //     return;
    // };
    // defer res.deinit(ctx.alloc);

    // // JS print result
    // if (res.success) {
    //     if (std.mem.eql(u8, res.result, "undefined")) {
    //         std.debug.print("<- \x1b[38;5;242m{s}\x1b[0m\n", .{res.result});
    //     } else {
    //         std.debug.print("<- \x1b[33m{s}\x1b[0m\n", .{res.result});
    //     }
    // } else {
    //     std.debug.print("{s}\n", .{res.result});
    // }

    // acknowledge to repl result has been printed
    // _ = std.os.write(ctx.socket, "ok") catch unreachable;
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
    ctx.cmdContext.js_env.nat_ctx.loop.io.recv(
        *CmdContext,
        ctx.cmdContext,
        cmdCallback,
        completion,
        ctx.cmdContext.socket,
        ctx.cmdContext.buf,
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
        .buf = &input,
        .try_catch = try_catch,
        .completion = &completion,
        // .cmds = .{},
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
