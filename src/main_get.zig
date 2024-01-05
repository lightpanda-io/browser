const std = @import("std");
const Browser = @import("browser/browser.zig").Browser;

pub const std_options = struct {
    pub const log_level = .debug;
};

const usage =
    \\usage: {s} [options] <url>
    \\  request the url with the browser
    \\
    \\  -h, --help       Print this help message and exit.
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

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try std.io.getStdErr().writer().print(usage, .{execname});
            std.os.exit(0);
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

    Browser.initVM();
    defer Browser.deinitVM();

    var browser = try Browser.init(allocator);
    defer browser.deinit();

    var page = try browser.currentSession().createPage();
    defer page.end();
    try page.navigate(url);
    try page.dump(std.io.getStdOut());
}
