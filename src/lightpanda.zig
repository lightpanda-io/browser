const std = @import("std");
pub const App = @import("App.zig");
pub const log = @import("log.zig");
pub const dump = @import("browser/dump.zig");
pub const build_config = @import("build_config");

const Allocator = std.mem.Allocator;

pub const FetchOpts = struct {
    wait_ms: u32 = 5000,
    dump_opts: dump.Opts,
    dump_file: ?std.fs.File = null,
};
pub fn fetch(app: *App, url: [:0]const u8, opts: FetchOpts) !void {
    const Browser = @import("browser/Browser.zig");
    var browser = try Browser.init(app);
    defer browser.deinit();

    var session = try browser.newSession();
    const page = try session.createPage();

    // // Comment this out to get a profile of the JS code in v8/profile.json.
    // // You can open this in Chrome's profiler.
    // // I've seen it generate invalid JSON, but I'm not sure why. It only
    // // happens rarely, and I manually fix the file.
    // page.js.startCpuProfiler();
    // defer {
    //     if (page.js.stopCpuProfiler()) |profile| {
    //         std.fs.cwd().writeFile(.{
    //             .sub_path = "v8/profile.json",
    //             .data = profile,
    //         }) catch |err| {
    //             log.err(.app, "profile write error", .{ .err = err });
    //         };
    //     } else |err| {
    //         log.err(.app, "profile error", .{ .err = err });
    //     }
    // }

    _ = try page.navigate(url, .{});
    _ = session.fetchWait(opts.wait_ms);

    const file = opts.dump_file orelse return;

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    try dump.deep(page.document.asNode(), opts.dump_opts, &writer.interface);
    try writer.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
}
