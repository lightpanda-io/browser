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

const CSSRule = @import("CSSRule.zig");

/// An at-rule we keep as written (`@keyframes`, `@font-face`, ...).
const GenericRule = @This();

pub const Proto = CSSRule;

_text: []const u8,
_kind: Kind,
_proto_canary: if (lp.IS_DEBUG) *CSSRule else void = undefined,

/// In the order of the CSSOM rule-type constants, starting at CHARSET_RULE.
pub const Kind = enum(u8) {
    charset,
    import,
    media,
    font_face,
    page,
    keyframes,
    keyframe,
    margin,
    namespace,
    counter_style,
    supports,
    document,
    font_feature_values,
    viewport,
    region_style,
    layer,
    unknown,
};

pub fn init(kind: Kind, text: []const u8, frame: *Frame) !*GenericRule {
    return frame._factory.chained(.{
        CSSRule{ ._type = .generic },
        GenericRule{ ._kind = kind, ._text = try frame.dupeString(text) },
    });
}

pub fn asCSSRule(self: *GenericRule) *CSSRule {
    return Factory.protoOf(self);
}

pub fn getType(self: *const GenericRule) u16 {
    return switch (self._kind) {
        // `@layer` rules postdate the legacy numeric type constants, so
        // their `type` is 0 (CSSOM §6.4.1) — same as unknown at-rules.
        .layer, .unknown => 0,
        else => @as(u16, @backingInt(self._kind)) + 2,
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(GenericRule);

    pub const Meta = struct {
        pub var class_id: bridge.ClassId = undefined;
        // These at-rules have no interface of their own here.
        pub const wrap_as = CSSRule.JsApi;
    };
};
