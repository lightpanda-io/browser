// webcomponents.js code comes from
// https://github.com/webcomponents/polyfills/tree/master/packages/webcomponentsjs
//
// The original code source is available in a "BSD style license".
//
// This is the `webcomponents-ce.js` bundle
pub const source = @embedFile("webcomponents.js");

const testing = @import("../../testing.zig");
test "Browser.webcomponents" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{ .html = "<div id=main></div>" });
    defer runner.deinit();

    try runner.testCases(&.{
        .{
            \\ window.customElements; // temporarily needed, lazy loading doesn't work!
            \\
            \\ class LightPanda extends HTMLElement {
            \\   constructor() {
            \\     super();
            \\   }
            \\   connectedCallback() {
            \\     this.append('connected')
            \\   }
            \\ }
            \\ window.customElements.define("lightpanda-test", LightPanda);
            \\ const main = document.getElementById('main');
            \\ main.appendChild(document.createElement('lightpanda-test'));
            ,
            null,
        },

        .{ "main.innerHTML", "<lightpanda-test>connected</lightpanda-test>" },
    }, .{});
}
