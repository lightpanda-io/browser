// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! An extraction rule is an ES module, run in the page's main world, whose
//! default export is `{ runAt, wait, extract, validate }`:
//!
//!   runAt          optional, the page lifecycle point (a --wait-until name)
//!                  before which nothing below runs. Defaults to "load".
//!   wait()         optional, polled until truthy. Synchronous: a page can
//!                  navigate under a wait, and a promise wouldn't survive it.
//!   extract()      the extracted value, JSON-serializable.
//!   validate(out)  optional, truthy when `out` is what the rule expects.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("js/js.zig");
const Frame = @import("Frame.zig");

const log = lp.log;
const WaitUntil = lp.Config.WaitUntil;

// Module cache keys, and what stack traces name the modules.
const rule_url = "lightpanda:ler";
const helpers_url = "lightpanda:extract";
const helpers_src = @embedFile("extract_rule.js");

pub const Failure = struct {
    of: u32,
    count: u32,
    path: []const u8,
    got: []const u8,
    expected: []const u8,
};

pub const Result = struct {
    json: Json = .{ .text = "" }, // extracted values, even when not valid
    failures: []const Failure = &.{},
};

// JSON text which stringifies as the value it holds, not as a string.
pub const Json = struct {
    text: []const u8,

    pub fn jsonStringify(self: Json, jws: *std.json.Stringify) std.Io.Writer.Error!void {
        if (self.text.len == 0) {
            return jws.write(null);
        }
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.text);
        jws.endWriteRaw();
    }
};

const Rule = struct {
    object: js.Object,
    // extract_rule.js' namespace
    lib: js.Object,
    helpers: js.Value,
};

// pull out the runAt value from the module
pub fn runAt(src: []const u8, frame: *Frame) !?WaitUntil {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const rule = try load(&ls.local, src, frame) orelse return null;
    const value = try rule.object.get("runAt");
    if (value.isUndefined()) {
        return .load;
    }
    const name = try value.toStringSliceWithAlloc(frame.call_arena);
    return std.meta.stringToEnum(WaitUntil, name) orelse {
        log.err(.app, "extract rule error", .{ .err = "invalid runAt", .value = name });
        return error.ScriptError;
    };
}

// Poll on the rule's "wait"
pub fn ready(src: []const u8, frame: *Frame) !bool {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const rule = try load(&ls.local, src, frame) orelse return false;
    const wait = try rule.object.getFunction("wait") orelse return true;
    const value = try call(wait, rule.object, .{rule.helpers});
    if (value.isPromise()) {
        log.err(.app, "extract rule error", .{ .err = "wait returned a promise" });
        return error.ScriptError;
    }
    return value.toBool();
}

// Run the extractor + validate
pub fn extract(arena: std.mem.Allocator, src: []const u8, frame: *Frame) !Result {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const rule = try load(&ls.local, src, frame) orelse {
        log.err(.app, "extract rule error", .{ .err = "module is still loading" });
        return error.ScriptError;
    };
    const extract_fn = try rule.object.getFunction("extract") orelse {
        log.err(.app, "extract rule error", .{ .err = "no extract function" });
        return error.ScriptError;
    };
    const value = try call(extract_fn, rule.object, .{rule.helpers});

    const json = value.toJson(arena) catch {
        log.err(.app, "extract rule error", .{ .err = "extract value isn't JSON-serializable" });
        return error.ScriptError;
    };
    // What V8 hands back for a value JSON can't represent (undefined, function).
    if (std.mem.eql(u8, json, "undefined")) {
        log.err(.app, "extract rule error", .{ .err = "extract returned no value" });
        return error.ScriptError;
    }

    const run_validate = (try rule.lib.getFunction("runValidate")).?;
    const invalid = try call(run_validate, rule.lib, .{ rule.object, value });
    if (invalid.isNullOrUndefined()) {
        return .{ .json = .{ .text = json } };
    }

    const failures = std.json.parseFromSliceLeaky([]const Failure, arena, try invalid.toJson(arena), .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.err(.app, "extract rule error", .{ .err = "malformed validation failures" });
            return error.ScriptError;
        },
    };
    for (failures) |f| {
        log.err(.app, "extract validation", .{ .path = f.path, .expected = f.expected, .got = f.got, .count = f.count, .of = f.of });
    }
    return .{ .json = .{ .text = json }, .failures = failures };
}

// null while the rule's top-level await is pending.
fn load(local: *const js.Local, src: []const u8, frame: *Frame) !?Rule {
    const namespace = try loadModule(local, src, rule_url, frame) orelse return null;
    const object = try namespace.get("default");
    if (object.isObject() == false) {
        log.err(.app, "extract rule error", .{ .err = "no default export" });
        return error.ScriptError;
    }

    const lib = (try loadModule(local, helpers_src, helpers_url, frame)).?;
    return .{
        .object = object.toObject(),
        .lib = lib,
        .helpers = try lib.get("helpers"),
    };
}

// Pulls it from the module cache after the first load
fn loadModule(local: *const js.Local, src: []const u8, url: []const u8, frame: *Frame) !?js.Object {
    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const entry = frame.js.module(true, local, src, url, true) catch |err| {
        const caught = try_catch.caughtOrError(frame.call_arena, err);
        log.err(.app, "extract rule error", .{ .err = caught });
        return error.ScriptError;
    };

    const promise = local.toLocal(entry.module_promise.?);
    switch (promise.state()) {
        .pending => return null,
        .rejected => {
            log.err(.app, "extract rule error", .{ .err = promise.result() });
            return error.ScriptError;
        },
        .fulfilled => {},
    }
    return local.toLocal(entry.module.?).getModuleNamespace().toObject();
}

fn call(function: js.Function, this: js.Object, args: anytype) !js.Value {
    var caught: js.TryCatch.Caught = .{};
    return function.tryCallWithThis(js.Value, this, args, &caught) catch |err| {
        if (err == error.ExecutionTerminated) {
            return err;
        }
        log.err(.app, "extract rule error", .{ .err = err, .caught = caught });
        return error.ScriptError;
    };
}

const testing = @import("../testing.zig");
test "extract_rule: wait, extract, validate" {
    var page = try testing.pageTest("cdp/registry1.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const src =
        \\const links = () => Array.from(document.querySelectorAll("a"));
        \\export default {
        \\  wait: () => links().length > window.min,
        \\  extract: () => links().map((a) => ({ id: a.id, text: a.textContent })),
        \\  validate: (out) => out.length < window.max,
        \\};
    ;

    try testing.expectEqual(.load, (try runAt(src, frame)).?);

    {
        testing.expectLog(&.{.app});
        try exec(frame, "window.min = 1; window.max = 1;");
        try testing.expectEqual(false, try ready(src, frame));
        const result = try extract(testing.arena_allocator, src, frame);
        try testing.expectJson(.{.{ .id = "a1", .text = "link1" }}, result.json.text);
        try testing.expectEqual(1, result.failures.len);
        try testing.expectEqual("$", result.failures[0].path);
        try testing.expectEqual("validate to return true", result.failures[0].expected);
        try testing.expectEqual("false", result.failures[0].got);
    }

    try exec(frame, "window.min = 0; window.max = 2;");
    try testing.expectEqual(true, try ready(src, frame));
    const result = try extract(testing.arena_allocator, src, frame);
    try testing.expectJson(.{.{ .id = "a1", .text = "link1" }}, result.json.text);
    try testing.expectEqual(0, result.failures.len);
}

test "extract_rule: only extract is required" {
    var page = try testing.pageTest("cdp/registry1.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const src = "export default { runAt: 'networkidle', extract: () => document.querySelector('a').id };";
    try testing.expectEqual(.networkidle, (try runAt(src, frame)).?);
    try testing.expectEqual(true, try ready(src, frame));
    const result = try extract(testing.arena_allocator, src, frame);
    try testing.expectEqual("\"a1\"", result.json.text);
    try testing.expectEqual(0, result.failures.len);
}

test "extract_rule: helpers" {
    var page = try testing.pageTest("cdp/registry1.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const valid =
        \\export default {
        \\  wait: (t) => typeof t.check === "function",
        \\  extract: (t) => ({
        \\    helpers: Object.keys(t).length,
        \\    posts: [
        \\      { id: 1, href: "https://lightpanda.io/", title: "a", date: "2026-09-21T05:55:22", score: 3, tags: ["x"] },
        \\      { id: 2, href: "https://lightpanda.io/b", title: "b", date: "2026-09-20", score: null, tags: [] },
        \\    ],
        \\  }),
        \\  validate: (out, t) => t.check(out, {
        \\    helpers: t.int,
        \\    posts: t.array({
        \\      id: t.int, href: t.url, title: t.string, date: t.date,
        \\      score: t.optional(t.int), tags: t.array(t.string),
        \\    }, { min: 2, max: 2 }),
        \\  }),
        \\};
    ;
    try testing.expectEqual(true, try ready(valid, frame));
    try testing.expectEqual(0, (try extract(testing.arena_allocator, valid, frame)).failures.len);
}

test "extract_rule: check reports grouped failures" {
    var page = try testing.pageTest("cdp/registry1.html", .{});
    defer page.close();
    const frame = page.frame().?;

    const src =
        \\export default {
        \\  extract: () => [
        \\    { id: 1, href: "/relative", score: NaN, user: { name: "a" } },
        \\    { id: "2", href: "https://lightpanda.io/", score: NaN, user: null },
        \\    { id: 3, href: "https://lightpanda.io/", score: NaN, user: { name: "" } },
        \\  ],
        \\  validate: (posts, t) => t.check(posts, t.array({
        \\    id: t.int, href: t.url, score: t.int, user: { name: t.string },
        \\  }, { min: 5 })),
        \\};
    ;
    testing.expectLog(&.{ .app, .app, .app, .app, .app, .app });
    const result = try extract(testing.arena_allocator, src, frame);
    try testing.expectJson(&[_]Failure{
        .{ .path = "$", .expected = "at least 5 items", .got = "3", .count = 1, .of = 1 },
        .{ .path = "$[*].href", .expected = "absolute url", .got = "\"/relative\"", .count = 1, .of = 3 },
        .{ .path = "$[*].score", .expected = "int", .got = "NaN", .count = 3, .of = 3 },
        .{ .path = "$[*].id", .expected = "int", .got = "\"2\"", .count = 1, .of = 3 },
        .{ .path = "$[*].user", .expected = "object", .got = "null", .count = 1, .of = 3 },
        .{ .path = "$[*].user.name", .expected = "non-empty string", .got = "\"\"", .count = 1, .of = 2 },
    }, result.failures);
}

test "extract_rule: errors" {
    const cases = [_][]const u8{
        "export default {",
        "null.x; export default {};",
        "export const extract = () => 1;",
        "export default { runAt: 'onload', extract: () => 1 };",
        "export default { wait: async () => true, extract: () => 1 };",
        "export default { wait: () => null.x, extract: () => 1 };",
    };
    for (cases) |src| {
        var page = try testing.pageTest("cdp/registry1.html", .{});
        defer page.close();
        testing.silenceLog(&.{ .app, .js });
        const frame = page.frame().?;
        try testing.expectError(error.ScriptError, gate(src, frame));
    }

    const extract_cases = [_][]const u8{
        "export default {};",
        "export default { extract: () => null.x };",
        "export default { extract: () => undefined };",
        "export default { extract: () => 1, validate: () => null.x };",
        "export default { extract: () => 1, validate: async () => true };",
    };
    for (extract_cases) |src| {
        var page = try testing.pageTest("cdp/registry1.html", .{});
        defer page.close();
        testing.silenceLog(&.{ .app, .js });
        try testing.expectError(error.ScriptError, extract(testing.arena_allocator, src, page.frame().?));
    }
}

fn gate(src: []const u8, frame: *Frame) !void {
    _ = try runAt(src, frame);
    _ = try ready(src, frame);
}

fn exec(frame: *Frame, src: []const u8) !void {
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec(src, null);
}
