// fetch.js code comes from
// https://github.com/JakeChampion/fetch/blob/main/fetch.js
//
// The original code source is available in MIT license.
//
// The script comes from the built version from npm.
// You can get the package with the command:
//
// wget $(npm view whatwg-fetch dist.tarball)
//
// The source is the content of `package/dist/fetch.umd.js` file.
pub const source = @embedFile("fetch.js");

const testing = @import("../../testing.zig");
test "Browser.fetch" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try @import("polyfill.zig").load(testing.allocator, runner.page.scope);

    try runner.testCases(&.{
        .{
            \\  var ok = false;
            \\  const request = new Request("http://127.0.0.1:9582/loader");
            \\  fetch(request).then((response) => { ok = response.ok; });
            \\  false;
            ,
            "false",
        },
        // all events have been resolved.
        .{ "ok", "true" },
    }, .{});

    try runner.testCases(&.{
        .{
            \\  var ok2 = false;
            \\  const request2 = new Request("http://127.0.0.1:9582/loader");
            \\  (async function () { resp = await fetch(request2); ok2 = resp.ok; }());
            \\  false;
            ,
            "false",
        },
        // all events have been resolved.
        .{ "ok2", "true" },
    }, .{});
}
