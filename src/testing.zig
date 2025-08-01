// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const std = @import("std");
const Allocator = std.mem.Allocator;

const Platform = @import("runtime/js.zig").Platform;

pub const allocator = std.testing.allocator;
pub const expectError = std.testing.expectError;
pub const expect = std.testing.expect;
pub const expectString = std.testing.expectEqualStrings;
pub const expectEqualSlices = std.testing.expectEqualSlices;

// sometimes it's super useful to have an arena you don't really care about
// in a test. Like, you need a mutable string, so you just want to dupe a
// string literal. It has nothing to do with the code under test, it's just
// infrastructure for the test itself.
pub var arena_instance = std.heap.ArenaAllocator.init(std.heap.c_allocator);
pub const arena_allocator = arena_instance.allocator();

pub fn reset() void {
    _ = arena_instance.reset(.{ .retain_capacity = {} });
}

const App = @import("app.zig").App;
const parser = @import("browser/netsurf.zig");

// Merged std.testing.expectEqual and std.testing.expectString
// can be useful when testing fields of an anytype an you don't know
// exactly how to assert equality
pub fn expectEqual(expected: anytype, actual: anytype) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .array => |arr| if (arr.child == u8) {
            return std.testing.expectEqualStrings(expected, &actual);
        },
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (comptime isStringArray(ptr.child)) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (ptr.child == []u8 or ptr.child == []const u8) {
                return expectString(expected, actual);
            }
        },
        .@"struct" => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
            return;
        },
        .optional => {
            if (@typeInfo(@TypeOf(expected)) == .null) {
                return std.testing.expectEqual(null, actual);
            }
            if (actual) |_actual| {
                return expectEqual(expected, _actual);
            }
            return std.testing.expectEqual(expected, null);
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }
            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);
            try expectEqual(expectedTag, actualTag);

            inline for (std.meta.fields(@TypeOf(actual))) |fld| {
                if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
                    return;
                }
            }
            unreachable;
        },
        else => {},
    }
    return std.testing.expectEqual(expected, actual);
}

pub fn expectDelta(expected: anytype, actual: anytype, delta: anytype) !void {
    if (@typeInfo(@TypeOf(expected)) == .null) {
        return std.testing.expectEqual(null, actual);
    }

    switch (@typeInfo(@TypeOf(actual))) {
        .optional => {
            if (actual) |value| {
                return expectDelta(expected, value, delta);
            }
            return std.testing.expectEqual(null, expected);
        },
        else => {},
    }

    switch (@typeInfo(@TypeOf(expected))) {
        .optional => {
            if (expected) |value| {
                return expectDelta(value, actual, delta);
            }
            return std.testing.expectEqual(null, actual);
        },
        else => {},
    }

    var diff = expected - actual;
    if (diff < 0) {
        diff = -diff;
    }
    if (diff <= delta) {
        return;
    }

    print("Expected {} to be within {} of {}. Actual diff: {}", .{ expected, delta, actual, diff });
    return error.NotWithinDelta;
}

fn isStringArray(comptime T: type) bool {
    if (!is(.array)(T) and !isPtrTo(.array)(T)) {
        return false;
    }
    return std.meta.Elem(T) == u8;
}

pub const TraitFn = fn (type) bool;
pub fn is(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            return id == @typeInfo(T);
        }
    };
    return Closure.trait;
}

pub fn isPtrTo(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            if (!comptime isSingleItemPtr(T)) return false;
            return id == @typeInfo(std.meta.Child(T));
        }
    };
    return Closure.trait;
}

pub fn isSingleItemPtr(comptime T: type) bool {
    if (comptime is(.pointer)(T)) {
        return @typeInfo(T).pointer.size == .one;
    }
    return false;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else {
        std.debug.print(fmt, args);
    }
}

// dummy opts incase we want to add something, and not have to break all the callers
pub fn createApp(_: anytype) *App {
    return App.init(allocator, .{ .run_mode = .serve }) catch unreachable;
}

pub const Random = struct {
    var instance: ?std.Random.DefaultPrng = null;

    pub fn fill(buf: []u8) void {
        var r = random();
        r.bytes(buf);
    }

    pub fn fillAtLeast(buf: []u8, min: usize) []u8 {
        var r = random();
        const l = r.intRangeAtMost(usize, min, buf.len);
        r.bytes(buf[0..l]);
        return buf;
    }

    pub fn intRange(comptime T: type, min: T, max: T) T {
        var r = random();
        return r.intRangeAtMost(T, min, max);
    }

    pub fn random() std.Random {
        if (instance == null) {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
            instance = std.Random.DefaultPrng.init(seed);
            // instance = std.Random.DefaultPrng.init(0);
        }
        return instance.?.random();
    }
};

pub const Document = struct {
    doc: *parser.DocumentHTML,
    arena: std.heap.ArenaAllocator,

    pub fn init(html: []const u8) !Document {
        parser.deinit();
        try parser.init();

        var fbs = std.io.fixedBufferStream(html);
        const html_doc = try parser.documentHTMLParse(fbs.reader(), "utf-8");

        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .doc = html_doc,
        };
    }

    pub fn deinit(self: *Document) void {
        parser.deinit();
        self.arena.deinit();
    }

    pub fn querySelectorAll(self: *Document, selector: []const u8) ![]const *parser.Node {
        const css = @import("browser/dom/css.zig");
        const node_list = try css.querySelectorAll(self.arena.allocator(), self.asNode(), selector);
        return node_list.nodes.items;
    }

    pub fn querySelector(self: *Document, selector: []const u8) !?*parser.Node {
        const css = @import("browser/dom/css.zig");
        return css.querySelector(self.arena.allocator(), self.asNode(), selector);
    }

    pub fn asNode(self: *const Document) *parser.Node {
        return parser.documentHTMLToNode(self.doc);
    }
};

pub fn expectJson(a: anytype, b: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();

    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);

    errdefer {
        const a_json = std.json.stringifyAlloc(aa, a_value, .{ .whitespace = .indent_2 }) catch unreachable;
        const b_json = std.json.stringifyAlloc(aa, b_value, .{ .whitespace = .indent_2 }) catch unreachable;
        std.debug.print("== Expected ==\n{s}\n\n== Actual ==\n{s}", .{ a_json, b_json });
    }

    try expectJsonValue(a_value, b_value);
}

pub fn isEqualJson(a: anytype, b: anytype) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();
    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);
    return isJsonValue(a_value, b_value);
}

fn convertToJson(arena: Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);
    if (T == std.json.Value) {
        return value;
    }

    var str: []const u8 = undefined;
    if (T == []u8 or T == []const u8 or comptime isStringArray(T)) {
        str = value;
    } else {
        str = try std.json.stringifyAlloc(arena, value, .{});
    }
    return std.json.parseFromSliceLeaky(std.json.Value, arena, str, .{});
}

fn expectJsonValue(a: std.json.Value, b: std.json.Value) !void {
    try expectEqual(@tagName(a), @tagName(b));

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return,
        .bool => try expectEqual(a.bool, b.bool),
        .integer => try expectEqual(a.integer, b.integer),
        .float => try expectEqual(a.float, b.float),
        .number_string => try expectEqual(a.number_string, b.number_string),
        .string => try expectEqual(a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            try expectEqual(a_len, b_len);
            for (a.array.items, b.array.items) |a_item, b_item| {
                try expectJsonValue(a_item, b_item);
            }
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    try expectJsonValue(entry.value_ptr.*, b_item);
                } else {
                    return error.MissingKey;
                }
            }
        },
    }
}

fn isJsonValue(a: std.json.Value, b: std.json.Value) bool {
    if (std.mem.eql(u8, @tagName(a), @tagName(b)) == false) {
        return false;
    }

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return true,
        .bool => return a.bool == b.bool,
        .integer => return a.integer == b.integer,
        .float => return a.float == b.float,
        .number_string => return std.mem.eql(u8, a.number_string, b.number_string),
        .string => return std.mem.eql(u8, a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            if (a_len != b_len) {
                return false;
            }
            for (a.array.items, b.array.items) |a_item, b_item| {
                if (isJsonValue(a_item, b_item) == false) {
                    return false;
                }
            }
            return true;
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    if (isJsonValue(entry.value_ptr.*, b_item) == false) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        },
    }
}

pub const tracking_allocator = @import("root").tracking_allocator.allocator();
pub const JsRunner = struct {
    const URL = @import("url.zig").URL;
    const Env = @import("browser/env.zig").Env;
    const Page = @import("browser/page.zig").Page;
    const Browser = @import("browser/browser.zig").Browser;

    app: *App,
    page: *Page,
    browser: *Browser,

    fn init(alloc: Allocator, opts: RunnerOpts) !JsRunner {
        parser.deinit();

        var app = try App.init(alloc, .{
            .run_mode = .serve,
            .tls_verify_host = false,
            .platform = opts.platform,
        });
        errdefer app.deinit();

        const browser = try alloc.create(Browser);
        errdefer alloc.destroy(browser);

        browser.* = try Browser.init(app);
        errdefer browser.deinit();

        var session = try browser.newSession();

        var page = try session.createPage();

        // a bit hacky, but since we aren't going through page.navigate, there's
        // some minimum setup we need to do
        page.url = try URL.parse(opts.url, null);
        try page.window.replaceLocation(.{
            .url = try page.url.toWebApi(page.arena),
        });

        var html = std.io.fixedBufferStream(opts.html);
        try page.loadHTMLDoc(html.reader(), "UTF-8");

        return .{
            .app = app,
            .page = page,
            .browser = browser,
        };
    }

    pub fn deinit(self: *JsRunner) void {
        self.browser.deinit();
        self.app.allocator.destroy(self.browser);
        self.app.deinit();
    }

    const RunOpts = struct {};
    pub const Case = std.meta.Tuple(&.{ []const u8, ?[]const u8 });
    pub fn testCases(self: *JsRunner, cases: []const Case, _: RunOpts) !void {
        const js_context = self.page.main_context;
        const arena = self.page.arena;

        const start = try std.time.Instant.now();

        for (cases, 0..) |case, i| {
            var try_catch: Env.TryCatch = undefined;
            try_catch.init(js_context);
            defer try_catch.deinit();

            const value = js_context.exec(case.@"0", null) catch |err| {
                if (try try_catch.err(arena)) |msg| {
                    std.debug.print("{s}\n\nCase: {d}\n{s}\n", .{ msg, i + 1, case.@"0" });
                }
                return err;
            };
            try self.page.loop.run(std.time.ns_per_ms * 200);
            @import("root").js_runner_duration += std.time.Instant.since(try std.time.Instant.now(), start);

            if (case.@"1") |expected| {
                const actual = try value.toString(arena);
                if (std.mem.eql(u8, expected, actual) == false) {
                    std.debug.print("Expected:\n{s}\n\nGot:\n{s}\n\nCase: {d}\n{s}\n", .{ expected, actual, i + 1, case.@"0" });
                    return error.UnexpectedResult;
                }
            }
        }
    }

    pub fn exec(self: *JsRunner, src: []const u8, name: ?[]const u8, err_msg: *?[]const u8) !void {
        _ = try self.eval(src, name, err_msg);
    }

    pub fn eval(self: *JsRunner, src: []const u8, name: ?[]const u8, err_msg: *?[]const u8) !Env.Value {
        const js_context = self.page.main_context;
        const arena = self.page.arena;

        var try_catch: Env.TryCatch = undefined;
        try_catch.init(js_context);
        defer try_catch.deinit();

        return js_context.exec(src, name) catch |err| {
            if (try try_catch.err(arena)) |msg| {
                err_msg.* = msg;
                std.debug.print("Error running script: {s}\n", .{msg});
            }
            return err;
        };
    }

    pub fn dispatchDOMContentLoaded(self: *JsRunner) !void {
        const HTMLDocument = @import("browser/html/document.zig").HTMLDocument;
        const html_doc = self.page.window.document;
        try HTMLDocument.documentIsLoaded(html_doc, self.page);
    }
};

const RunnerOpts = struct {
    platform: ?*const Platform = null,
    url: []const u8 = "https://lightpanda.io/opensource-browser/",
    html: []const u8 =
        \\ <div id="content">
        \\   <a id="link" href="foo" class="ok">OK</a>
        \\   <p id="para-empty" class="ok empty">
        \\     <span id="para-empty-child"></span>
        \\   </p>
        \\   <p id="para"> And</p>
        \\   <!--comment-->
        \\ </div>
        \\
    ,
};

pub fn jsRunner(alloc: Allocator, opts: RunnerOpts) !JsRunner {
    return JsRunner.init(alloc, opts);
}
