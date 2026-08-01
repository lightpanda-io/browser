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

const js = @import("../js/js.zig");

const DOMException = @import("DOMException.zig");

const Execution = js.Execution;

const QuotaExceededError = @This();

pub const Proto = DOMException;

_proto: *DOMException,
_quota: ?f64 = null,
_requested: ?f64 = null,

const Options = struct {
    quota: ?f64 = null,
    requested: ?f64 = null,
};

pub fn init(message_: ?[]const u8, options_: ?Options, exec: *const Execution) !*QuotaExceededError {
    const opts = options_ orelse Options{};
    if (opts.quota) |quota| {
        if (quota < 0) {
            return error.RangeError;
        }
    }
    if (opts.requested) |requested| {
        if (requested < 0) {
            return error.RangeError;
        }
    }
    if (opts.quota != null and opts.requested != null and opts.requested.? < opts.quota.?) {
        return error.RangeError;
    }

    const message = if (message_) |m| try exec.dupeString(m) else null;
    return exec._factory.chained(.{
        DOMException.init(message, "QuotaExceededError"),
        QuotaExceededError{ ._proto = undefined, ._quota = opts.quota, ._requested = opts.requested },
    });
}

pub fn throw(local: *const js.Local, exec: *const Execution) error{ TryCatchRethrow, OutOfMemory } {
    const self = init(null, null, exec) catch return error.OutOfMemory;
    const js_val = local.zigValueToJs(self, .{}) catch return error.OutOfMemory;
    _ = local.isolate.throwException(js_val.handle);
    return error.TryCatchRethrow;
}

pub fn getQuota(self: *const QuotaExceededError) ?f64 {
    return self._quota;
}

pub fn getRequested(self: *const QuotaExceededError) ?f64 {
    return self._requested;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(QuotaExceededError);

    pub const Meta = struct {
        pub const name = "QuotaExceededError";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(QuotaExceededError.init, .{});
    pub const quota = bridge.accessor(QuotaExceededError.getQuota, null, .{});
    pub const requested = bridge.accessor(QuotaExceededError.getRequested, null, .{});
};
