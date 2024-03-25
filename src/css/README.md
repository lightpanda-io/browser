# css

Lightpanda css implements CSS selectors parsing and matching in Zig.
This package is a port of the Go lib [andybalholm/cascadia](https://github.com/andybalholm/cascadia).

## Usage

### Query parser

```zig
const css = @import("css.zig");

const selector = try css.parse(alloc, "h1", .{});
defer selector.deinit(alloc);
```

### DOM tree match

The lib expects a `Node` interface implementation to match your DOM tree.

```zig
pub const Node = struct {
    pub fn firstChild(_: Node) !?Node {
        return error.TODO;
    }

    pub fn lastChild(_: Node) !?Node {
        return error.TODO;
    }

    pub fn nextSibling(_: Node) !?Node {
        return error.TODO;
    }

    pub fn prevSibling(_: Node) !?Node {
        return error.TODO;
    }

    pub fn parent(_: Node) !?Node {
        return error.TODO;
    }

    pub fn isElement(_: Node) bool {
        return false;
    }

    pub fn isDocument(_: Node) bool {
        return false;
    }

    pub fn isComment(_: Node) bool {
        return false;
    }

    pub fn isText(_: Node) bool {
        return false;
    }

    pub fn isEmptyText(_: Node) !bool {
        return error.TODO;
    }

    pub fn tag(_: Node) ![]const u8 {
        return error.TODO;
    }

    pub fn attr(_: Node, _: []const u8) !?[]const u8 {
        return error.TODO;
    }

    pub fn eql(_: Node, _: Node) bool {
        return false;
    }
};
```

You also need do define a `Matcher` implementing a `match` function to
accumulate the results.

```zig
const Matcher = struct {
    const Nodes = std.ArrayList(Node);

    nodes: Nodes,

    fn init(alloc: std.mem.Allocator) Matcher {
        return .{ .nodes = Nodes.init(alloc) };
    }

    fn deinit(m: *Matcher) void {
        m.nodes.deinit();
    }

    pub fn match(m: *Matcher, n: Node) !void {
        try m.nodes.append(n);
    }
};
```

Then you can use the lib itself.

```zig
var matcher = Matcher.init(alloc);
defer matcher.deinit();

try css.matchAll(selector, node, &matcher);
_ = try css.matchFirst(selector, node, &matcher); // returns true if a node matched.
```

## Features

* [x] parse query selector
* [x] `matchAll`
* [x] `matchFirst`
* [ ] specificity

### Selectors implemented

#### Selectors

* [x] Class selectors
* [x] Id selectors
* [x] Type selectors
* [x] Universal selectors
* [ ] Nesting selectors

#### Combinators

* [x] Child combinator
* [ ] Column combinator
* [x] Descendant combinator
* [ ] Namespace combinator
* [x] Next-sibling combinator
* [x] Selector list combinator
* [x] Subsequent-sibling combinator

#### Attribute

* [x] `[attr]`
* [x] `[attr=value]`
* [x] `[attr|=value]`
* [x] `[attr^=value]`
* [x] `[attr$=value]`
* [ ] `[attr*=value]`
* [x] `[attr operator value i]`
* [ ] `[attr operator value s]`

#### Pseudo classes

* [ ] `:active`
* [ ] `:any-link`
* [ ] `:autofill`
* [ ] `:blank Experimental`
* [x] `:checked`
* [ ] `:current Experimental`
* [ ] `:default`
* [ ] `:defined`
* [ ] `:dir() Experimental`
* [x] `:disabled`
* [x] `:empty`
* [x] `:enabled`
* [ ] `:first`
* [x] `:first-child`
* [x] `:first-of-type`
* [ ] `:focus`
* [ ] `:focus-visible`
* [ ] `:focus-within`
* [ ] `:fullscreen`
* [ ] `:future Experimental`
* [x] `:has() Experimental`
* [ ] `:host`
* [ ] `:host()`
* [ ] `:host-context() Experimental`
* [ ] `:hover`
* [ ] `:indeterminate`
* [ ] `:in-range`
* [ ] `:invalid`
* [ ] `:is()`
* [x] `:lang()`
* [x] `:last-child`
* [x] `:last-of-type`
* [ ] `:left`
* [x] `:link`
* [ ] `:local-link Experimental`
* [ ] `:modal`
* [x] `:not()`
* [x] `:nth-child()`
* [x] `:nth-last-child()`
* [x] `:nth-last-of-type()`
* [x] `:nth-of-type()`
* [x] `:only-child`
* [x] `:only-of-type`
* [ ] `:optional`
* [ ] `:out-of-range`
* [ ] `:past Experimental`
* [ ] `:paused`
* [ ] `:picture-in-picture`
* [ ] `:placeholder-shown`
* [ ] `:playing`
* [ ] `:read-only`
* [ ] `:read-write`
* [ ] `:required`
* [ ] `:right`
* [x] `:root`
* [ ] `:scope`
* [ ] `:state() Experimental`
* [ ] `:target`
* [ ] `:target-within Experimental`
* [ ] `:user-invalid Experimental`
* [ ] `:valid`
* [ ] `:visited`
* [ ] `:where()`
* [ ] `:contains()`
* [ ] `:containsown()`
* [ ] `:matched()`
* [ ] `:matchesown()`
* [x] `:root`

