const std = @import("std");
const builtin = @import("builtin");

const jsruntime = @import("jsruntime");
const Env = jsruntime.Env;

const fetch = @import("fetch.zig").fetch_polyfill;

const log = std.log.scoped(.polyfill);

const modules = [_]struct {
    name: []const u8,
    source: []const u8,
}{
    .{ .name = "polyfill-fetch", .source = @import("fetch.zig").source },
};

pub fn load(alloc: std.mem.Allocator, env: Env) !void {
    var try_catch: jsruntime.TryCatch = undefined;
    try_catch.init(env);
    defer try_catch.deinit();

    for (modules) |m| {
        const res = env.exec(m.source, m.name) catch {
            if (try try_catch.err(alloc, env)) |msg| {
                defer alloc.free(msg);
                log.err("load {s}: {s}", .{ m.name, msg });
            }
            return;
        };

        if (builtin.mode == .Debug) {
            const msg = try res.toString(alloc, env);
            defer alloc.free(msg);
            log.debug("load {s}: {s}", .{ m.name, msg });
        }
    }
}
