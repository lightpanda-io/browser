const std = @import("std");
const Browser = @import("browser/browser.zig").Browser;

const jsruntime = @import("jsruntime");
const apiweb = @import("apiweb.zig");

pub const Types = jsruntime.reflect(apiweb.Interfaces);

pub const std_options = struct {
    pub const log_level = .debug;
};

const usage =
    \\usage: {s} [options] <url>
    \\  request the url with the browser
    \\
    \\  -h, --help      Print this help message and exit.
    \\  --dump          Dump document in stdout
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.log.warn("leaks detected\n", .{});
        }
    }
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const execname = args.next().?;
    var url: []const u8 = "";
    var dump: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try std.io.getStdErr().writer().print(usage, .{execname});
            std.os.exit(0);
        }
        if (std.mem.eql(u8, "--dump", arg)) {
            dump = true;
            continue;
        }
        // allow only one url
        if (url.len != 0) {
            try std.io.getStdErr().writer().print(usage, .{execname});
            std.os.exit(1);
        }
        url = arg;
    }

    if (url.len == 0) {
        try std.io.getStdErr().writer().print(usage, .{execname});
        std.os.exit(1);
    }

    const vm = jsruntime.VM.init();
    defer vm.deinit();

    var browser = try Browser.init(allocator, vm);
    defer browser.deinit();

    var page = try browser.currentSession().createPage();
    defer page.deinit();

    try page.navigate(url);
    defer page.end();

    if (dump) {
        try page.dump(std.io.getStdOut());
    }
}
