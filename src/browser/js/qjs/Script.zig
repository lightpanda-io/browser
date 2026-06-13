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

// A compiled-but-not-run script (JS_EVAL_FLAG_COMPILE_ONLY result).
const js = @import("js.zig");

const q = js.q;

const Script = @This();

local: *const js.Local,
handle: q.JSValue,

pub fn getUnboundScript(self: Script) Unbound {
    return .{
        .qctx = self.local.ctx.ctx,
        .handle = self.handle,
    };
}

// quickjs bytecode isn't bound to a context until evaluated, so "unbound"
// is just the compiled function value plus the context needed to manage
// its refcount.
pub const Unbound = struct {
    qctx: ?*q.JSContext,
    handle: q.JSValue,

    pub fn bindToCurrentContext(self: Unbound, local: *const js.Local) Script {
        return .{
            .local = local,
            .handle = self.handle,
        };
    }

    pub fn createCodeCache(self: Unbound, allocator: anytype) ![]u8 {
        _ = self;
        _ = allocator;
        return error.NotSupported;
    }

    pub fn persist(self: Unbound, isolate: anytype) Global {
        _ = isolate;
        const qctx = self.qctx.?;
        const Context = @import("Context.zig");
        const ctx = Context.fromQ(qctx);
        // NOTE: the slot lives on the page arena; a persisted unbound
        // script does not survive a page navigation (the v8 backend's
        // isolate-level Global does). Runner only crosses navigations in
        // unusual wait_script flows; revisit if that ever matters.
        return .{ .handle = ctx.persist(q.JS_DupValue(qctx, self.handle)) };
    }

    pub const Global = struct {
        handle: js.PersistentHandle,

        pub fn deinit(self: *Global) void {
            js.resetPersistentHandle(&self.handle);
        }

        pub fn get(self: *const Global, isolate: anytype) Unbound {
            _ = isolate;
            return .{ .qctx = null, .handle = self.handle.value };
        }
    };
};

pub fn run(self: Script) !js.Value {
    const ctx = self.local.ctx.ctx;
    // JS_EvalFunction consumes a reference; dup so the Script stays valid.
    const value = q.JS_EvalFunction(ctx, q.JS_DupValue(ctx, self.handle));
    if (q.JS_IsException(value)) {
        return error.JsException;
    }
    self.local.track(value);
    return .{ .local = self.local, .handle = value };
}
