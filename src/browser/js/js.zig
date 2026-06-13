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

// Engine-selection facade. Callers import this file and use the aliased
// types; the concrete implementation lives in v8/ or qjs/ depending on
// the -Djs_engine build option. Only the selected backend is ever
// analyzed - a name that one backend doesn't provide is a compile error
// only if something in that build actually references it.
const lp = @import("lightpanda");

const backend = if (lp.build_config.v8) @import("v8/js.zig") else @import("qjs/js.zig");

// Raw engine namespace. v8-only; anything outside of js/ referencing this
// must be gated behind `lp.build_config.v8`.
pub const v8 = backend.v8;

pub const Env = backend.Env;
pub const bridge = backend.bridge;
pub const Caller = backend.Caller;
pub const Origin = backend.Origin;
pub const Identity = backend.Identity;
pub const Context = backend.Context;
pub const Execution = backend.Execution;
pub const Local = backend.Local;
pub const Inspector = backend.Inspector;
pub const Snapshot = backend.Snapshot;
pub const Platform = backend.Platform;
pub const Isolate = backend.Isolate;
pub const HandleScope = backend.HandleScope;

pub const Value = backend.Value;
pub const Array = backend.Array;
pub const String = backend.String;
pub const Object = backend.Object;
pub const TryCatch = backend.TryCatch;
pub const Function = backend.Function;
pub const Promise = backend.Promise;
pub const RegExp = backend.RegExp;
pub const Module = backend.Module;
pub const Script = backend.Script;
pub const BigInt = backend.BigInt;
pub const Number = backend.Number;
pub const Integer = backend.Integer;
pub const PromiseResolver = backend.PromiseResolver;
pub const PromiseRejection = backend.PromiseRejection;

pub const PersistentHandle = backend.PersistentHandle;
pub const resetPersistentHandle = backend.resetPersistentHandle;

pub const Bridge = backend.Bridge;
pub const TypedArray = backend.TypedArray;
pub const ArrayBuffer = backend.ArrayBuffer;
pub const ArrayType = backend.ArrayType;
pub const ArrayBufferRef = backend.ArrayBufferRef;
pub const NullableString = backend.NullableString;
pub const Exception = backend.Exception;
pub const Undefined = backend.Undefined;
pub const FinalizerCallback = backend.FinalizerCallback;
pub const simpleZigValueToJs = backend.simpleZigValueToJs;
pub const writeStackTrace = backend.writeStackTrace;

test {
    _ = backend;
}
