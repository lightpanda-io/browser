const std = @import("std");
const jsruntime = @import("jsruntime");
const Case = jsruntime.test_utils.Case;
const checkCases = jsruntime.test_utils.checkCases;

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

pub fn testExecFn(
    alloc: std.mem.Allocator,
    js_env: *jsruntime.Env,
) anyerror!void {
    try @import("polyfill.zig").load(alloc, js_env.*);

    var fetch = [_]Case{
        .{
            .src =
            \\var ok = false;
            \\const request = new Request("https://httpbin.io/json");
            \\fetch(request)
            \\ .then((response) => { ok = response.ok; });
            \\false;
            ,
            .ex = "false",
        },
        // all events have been resolved.
        .{ .src = "ok", .ex = "true" },
    };
    try checkCases(js_env, &fetch);

    var fetch2 = [_]Case{
        .{
            .src =
            \\var ok2 = false;
            \\const request2 = new Request("https://httpbin.io/json");
            \\(async function () { resp = await fetch(request2); ok2 = resp.ok; }());
            \\false;
            ,
            .ex = "false",
        },
        // all events have been resolved.
        .{ .src = "ok2", .ex = "true" },
    };
    try checkCases(js_env, &fetch2);
}
