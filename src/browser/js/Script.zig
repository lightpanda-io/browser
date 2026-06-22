// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const js = @import("js.zig");
const Isolate = @import("Isolate.zig");

const v8 = js.v8;
const Allocator = std.mem.Allocator;

const Script = @This();

local: *const js.Local,
handle: *const v8.Script,

pub fn run(self: Script) !js.Value {
    const result = v8.v8__Script__Run(self.handle, self.local.handle) orelse return error.JsException;
    return .{ .local = self.local, .handle = result };
}

// The context-independent script. Binding it back to a context returns a Script
// which can be run.
pub fn getUnboundScript(self: Script) Unbound {
    return .{ .handle = v8.v8__Script__GetUnboundScript(self.handle).? };
}

pub const Unbound = struct {
    handle: *const v8.UnboundScript,

    pub fn bindToCurrentContext(self: Unbound, local: *const js.Local) Script {
        return .{
            .local = local,
            .handle = v8.v8__UnboundScript__BindToCurrentContext(self.handle).?,
        };
    }

    // Serialize the script. The returned bytes can be persisted and passed back
    // into local.compileWithCache
    pub fn createCodeCache(self: Unbound, allocator: Allocator) ![]u8 {
        const cached = v8.v8__ScriptCompiler__CreateCodeCache(self.handle) orelse return error.CodeCacheFailed;
        defer v8.v8__ScriptCompiler__CachedData__DELETE(cached);
        const len: usize = @intCast(cached.*.length);
        return allocator.dupe(u8, cached.*.data[0..len]);
    }

    pub fn persist(self: Unbound, isolate: Isolate) Global {
        var global: v8.Global = undefined;
        v8.v8__Global__New(isolate.handle, self.handle, &global);
        return .{ .handle = global };
    }

    pub const Global = struct {
        handle: v8.Global,

        pub fn deinit(self: *Global) void {
            v8.v8__Global__Reset(&self.handle);
        }

        pub fn get(self: *const Global, isolate: Isolate) Unbound {
            return .{ .handle = @ptrCast(v8.v8__Global__Get(&self.handle, isolate.handle)) };
        }
    };
};

const testing = @import("../../testing.zig");
test "Script: persisted unbound script re-binds and re-runs" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const script = try ls.local.compile("1 + 2", "rebind_test");
    try testing.expectEqual(3, try (try script.run()).toI32());

    var unbound = script.getUnboundScript().persist(ls.local.isolate);
    defer unbound.deinit();

    const rebound = unbound.get(ls.local.isolate).bindToCurrentContext(&ls.local);
    try testing.expectEqual(3, try (try rebound.run()).toI32());
}

test "Script: code cache round-trips and rejects a source mismatch" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const src = "function add(a, b) { return a + b; } add(40, 2);";

    const produced = try ls.local.compile(src, "cache_test");
    const bytes = try produced.getUnboundScript().createCodeCache(testing.allocator);
    defer testing.allocator.free(bytes);
    try testing.expect(bytes.len > 0);

    const hit = try ls.local.compileWithCache(src, "cache_test", bytes);
    try testing.expectEqual(false, hit.cache_rejected);
    try testing.expectEqual(42, try (try hit.script.run()).toI32());

    const miss = try ls.local.compileWithCache("1 + 1;", "cache_test", bytes);
    try testing.expectEqual(true, miss.cache_rejected);
    try testing.expectEqual(2, try (try miss.script.run()).toI32());
}
