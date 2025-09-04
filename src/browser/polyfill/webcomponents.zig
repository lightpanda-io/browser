// webcomponents.js code comes from
// https://github.com/webcomponents/polyfills/tree/master/packages/webcomponentsjs
//
// The original code source is available in a "BSD style license".
//
// This is the `webcomponents-ce.js` bundle
pub const source = @embedFile("webcomponents.js");

// The main webcomponents.js is lazilly loaded when window.customElements is
// called. But, if you look at the test below, you'll notice that we declare
// our custom element (LightPanda) before we call `customElements.define`. We
// _have_ to declare it before we can register it.
// That causes an issue, because the LightPanda class extends HTMLElement, which
// hasn't been monkeypatched by the polyfill yet. If you were to try it as-is
// you'd get an "Illegal Constructor", because that's what the Zig HTMLElement
// constructor does (and that's correct).
// However, once HTMLElement is monkeypatched, it'll work. One simple solution
// is to run the webcomponents.js polyfill proactively on each page, ensuring
// that HTMLElement is monkeypatched before any other JavaScript is run. But
// that adds _a lot_ of overhead.
// So instead of always running the [large and intrusive] webcomponents.js
// polyfill, we'll always run this little snippet. It wraps the HTMLElement
// constructor. When the Lightpanda class is created, it'll extend our little
// wrapper. But, unlike the Zig default constructor which throws, our code
// calls the "real" constructor. That might seem like the same thing, but by the
// time our wrapper is called, the webcomponents.js polyfill will have been
// loaded and the "real" constructor will be the monkeypatched version.
// TL;DR creates a layer of indirection for the constructor, so that, when it's
// actually instantiated, the webcomponents.js polyfill will have been loaded.
pub const pre =
    \\ (() => {
    \\   const HE = window.HTMLElement;
    \\   const b = function() { return HE.prototype.constructor.call(this); }
    \\   b.prototype = HE.prototype;
    \\   window.HTMLElement = b;
    \\ })();
;

const testing = @import("../../testing.zig");
test "Browser: Polyfill.WebComponents" {
    try testing.htmlRunner("polyfill/webcomponents.html");
}
