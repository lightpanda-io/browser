// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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

const lp = @import("lightpanda");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");
const RuleStore = @import("../../css/RuleStore.zig");

const CSSRule = @import("CSSRule.zig");

/// An at-rule we keep as written (`@keyframes`, `@font-face`, ...).
const GenericRule = @This();

pub const Proto = CSSRule;

_proto_canary: if (lp.IS_DEBUG) *CSSRule else void = undefined,

pub fn init(store: *RuleStore, id: u32, hint: u32, frame: *Frame) !*GenericRule {
    return frame._factory.chained(.{
        CSSRule{ ._type = .generic, ._store = store, ._id = id, ._hint = hint },
        GenericRule{},
    });
}

pub fn asCSSRule(self: *GenericRule) *CSSRule {
    return Factory.protoOf(self);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GenericRule);

    pub const Meta = struct {
        pub var class_id: bridge.ClassId = undefined;
        // These at-rules have no interface of their own here.
        pub const wrap_as = CSSRule.JsApi;
    };
};
