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

const std = @import("std");
const Allocator = std.mem.Allocator;

const Env = @import("../env.zig").Env;
const SessionState = @import("../env.zig").SessionState;

const log = std.log.scoped(.trusted_types);

pub const Interfaces = .{
    TrustedTypePolicyFactory,
    TrustedTypePolicy,
    TrustedTypePolicyOptions,
    TrustedHTML,
    TrustedScript,
    TrustedScriptURL,
};

const TrustedHTML = struct {
    value: []const u8,

    // TODO _toJSON
    pub fn _toString(self: *const TrustedHTML) []const u8 {
        return self.value;
    }
};
const TrustedScript = struct {
    value: []const u8,

    pub fn _toString(self: *const TrustedScript) []const u8 {
        return self.value;
    }
};
const TrustedScriptURL = struct {
    value: []const u8,

    pub fn _toString(self: *const TrustedScriptURL) []const u8 {
        return self.value;
    }
};

// https://developer.mozilla.org/en-US/docs/Web/API/TrustedTypePolicyFactory
pub const TrustedTypePolicyFactory = struct {
    // TBD innerHTML if set the default createHTML should be used when `element.innerHTML = userInput;` does v8 do that for us? Prob not.
    default_policy: ?TrustedTypePolicy = null, // The default policy, set by creating a policy with the name "default".
    created_policy_names: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn _defaultPolicy(self: *TrustedTypePolicyFactory) ?TrustedTypePolicy {
        return self.default_policy;
    }

    // https://w3c.github.io/trusted-types/dist/spec/#dom-trustedtypepolicyfactory-createpolicy
    // https://w3c.github.io/trusted-types/dist/spec/#abstract-opdef-create-a-trusted-type-policy
    pub fn _createPolicy(self: *TrustedTypePolicyFactory, name: []const u8, options: ?TrustedTypePolicyOptions, state: *SessionState) !TrustedTypePolicy {
        // TODO Throw TypeError if policy names are restricted by the Content Security Policy trusted-types directive and this name is not on the allowlist.
        // TODO Throw TypeError if the name is a duplicate and the Content Security Policy trusted-types directive is not using allow-duplicates

        const policy = TrustedTypePolicy{
            .name = name,
            .options = options orelse TrustedTypePolicyOptions{},
        };

        if (std.mem.eql(u8, name, "default")) {
            // TBD what if default_policy is already set?
            self.default_policy = policy;
        }
        try self.created_policy_names.append(state.arena, try state.arena.dupe(u8, name));

        return policy;
    }
};

pub const TrustedTypePolicyOptions = struct {
    createHTML: ?Env.Function = null, // (str, ..args) -> str
    createScript: ?Env.Function = null, // (str, ..args) -> str
    createScriptURL: ?Env.Function = null, // (str, ..args) -> str
};

// https://developer.mozilla.org/en-US/docs/Web/API/TrustedTypePolicy
pub const TrustedTypePolicy = struct {
    name: []const u8,
    options: TrustedTypePolicyOptions,

    pub fn get_name(self: *TrustedTypePolicy) []const u8 {
        return self.name;
    }

    pub fn _createHTML(self: *TrustedTypePolicy, html: []const u8) !TrustedHTML {
        // TODO handle throwIfMissing
        const create = self.options.createHTML orelse return error.TypeError;

        var result: Env.Function.Result = undefined;
        const out = try create.tryCall([]const u8, .{html}, &result); // TODO varargs
        return .{
            .value = out,
        };
    }

    pub fn _createScript(self: *TrustedTypePolicy, script: []const u8) !TrustedScript {
        // TODO handle throwIfMissing
        const create = self.options.createScript orelse return error.TypeError;

        var result: Env.Function.Result = undefined;
        return try create.tryCall(TrustedScript, .{script}, &result); // TODO varargs
    }

    pub fn _createScriptURL(self: *TrustedTypePolicy, url: []const u8) !TrustedScriptURL {
        // TODO handle throwIfMissing
        const create = self.options.createScriptURL orelse return error.TypeError;

        var result: Env.Function.Result = undefined;
        return try create.tryCall(TrustedScriptURL, .{url}, &result); // TODO varargs
    }
};

const testing = @import("../../testing.zig");
test "Browser.TrustedTypes" {
    var runner = try testing.jsRunner(testing.tracking_allocator, .{});
    defer runner.deinit();

    try runner.testCases(&.{
        .{ "trustedTypes", "[object TrustedTypePolicyFactory]" },
        .{
            \\ let escapeHTMLPolicy = trustedTypes.createPolicy('myEscapePolicy', {
            \\      createHTML: (string) => string.replace(/</g, "&lt;"),
            \\ });
            ,
            null,
        },
        .{ "escapeHTMLPolicy.createHTML('<img src=x onerror=alert(1)>');", "&lt;img src=x onerror=alert(1)>" },
    }, .{});
}
