// Copyright (C) 2023 - 2026 Lightpanda (Selecy SAS)
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

const Frame = @import("../Frame.zig");
const HttpClient = @import("../../network/HttpClient.zig");

// https://html.spec.whatwg.org/multipage/document-lifecycle.html#the-x-frame-options-header
pub fn allowed(frame: *const Frame, transfer: *HttpClient.Transfer) bool {
    var options: XFrameOptions = .{};
    var it = transfer.responseHeaderIterator();
    while (it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "content-security-policy")) {
            if (hasFrameAncestors(hdr.value)) {
                // has priority over any x-frame-options
                return true;
            }
        } else if (std.ascii.eqlIgnoreCase(hdr.name, "x-frame-options")) {
            options.add(hdr.value);
        }
    }

    switch (options.policy()) {
        .allow => return true,
        .deny => return false,
        .same_origin => {
            const origin = frame.origin orelse return false;
            var ancestor = frame.parent;
            while (ancestor) |a| : (ancestor = a.parent) {
                // with a same-origin value, every ancestor has to be
                // the same origin
                const ancestor_origin = a.origin orelse return false;
                if (std.mem.eql(u8, origin, ancestor_origin) == false) {
                    return false;
                }
            }
            return true;
        },
    }
}

fn hasFrameAncestors(csp: []const u8) bool {
    const name = "frame-ancestors";
    var pos: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(csp, pos, name)) |start| {
        pos = start + name.len;

        // A directive name starts a policy (',') or a directive (';'), so
        // `script-src frame-ancestors` (a host source) doesn't count.
        const before = std.mem.trimEnd(u8, csp[0..start], HTTP_WHITESPACE);
        if (before.len != 0) {
            const last = before[before.len - 1];
            if (last != ';' and last != ',') {
                continue;
            }
        }
        if (pos == csp.len or std.mem.indexOfScalar(u8, HTTP_WHITESPACE ++ ";,", csp[pos]) != null) {
            return true;
        }
    }
    return false;
}

const HTTP_WHITESPACE = " \t\r\n";

const XFrameOptions = struct {
    first: ?[]const u8 = null,
    conflict: bool = false,
    has_keyword: bool = false,

    const Policy = enum { allow, deny, same_origin };

    fn add(self: *XFrameOptions, value: []const u8) void {
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |token| {
            const v = std.mem.trim(u8, token, HTTP_WHITESPACE);
            if (keyword(v) != null) {
                self.has_keyword = true;
            }
            if (self.first) |first| {
                // we care about the first value and if any subsequent values are different
                if (std.ascii.eqlIgnoreCase(first, v) == false) {
                    self.conflict = true;
                }
            } else {
                self.first = v;
            }
        }
    }

    fn policy(self: *const XFrameOptions) Policy {
        const first = self.first orelse return .allow;
        if (self.conflict) {
            // conflict is a fail, unless they all had meaningless values
            return if (self.has_keyword) .deny else .allow;
        }
        return switch (keyword(first) orelse return .allow) {
            .deny => .deny,
            .sameorigin => .same_origin,
            .allowall => .allow,
        };
    }

    fn keyword(value: []const u8) ?enum { deny, sameorigin, allowall } {
        if (std.ascii.eqlIgnoreCase(value, "deny")) {
            return .deny;
        }
        if (std.ascii.eqlIgnoreCase(value, "sameorigin")) {
            return .sameorigin;
        }
        if (std.ascii.eqlIgnoreCase(value, "allowall")) {
            return .allowall;
        }
        return null;
    }
};

const testing = @import("../../testing.zig");
test "framing: XFrameOptions" {
    const expectPolicy = struct {
        fn expectPolicy(expected: XFrameOptions.Policy, values: []const []const u8) !void {
            var xfo: XFrameOptions = .{};
            for (values) |v| xfo.add(v);
            try testing.expectEqual(expected, xfo.policy());
        }
    }.expectPolicy;

    try expectPolicy(.allow, &.{});
    try expectPolicy(.allow, &.{""});
    try expectPolicy(.allow, &.{"INVALID"});
    try expectPolicy(.allow, &.{"ALLOWALL"});
    try expectPolicy(.allow, &.{"\x0bDENY"});
    try expectPolicy(.allow, &.{ "INVALID", "" });
    try expectPolicy(.deny, &.{"  denY "});
    try expectPolicy(.deny, &.{ "DENY", "deny" });
    try expectPolicy(.deny, &.{",SAMEORIGIN,,DENY,"});
    try expectPolicy(.deny, &.{ "SAMEORIGIN", "DENY" });
    try expectPolicy(.deny, &.{"ALLOWALL,"});
    try expectPolicy(.deny, &.{ "INVALID", "allowAll" });
    try expectPolicy(.same_origin, &.{ "SAMEORIGIN", "sameOrigin" });

    try testing.expect(hasFrameAncestors("default-src 'self'; frame-ancestors 'self'"));
    try testing.expect(hasFrameAncestors("default-src 'self', FRAME-ANCESTORS"));
    try testing.expect(hasFrameAncestors("default-src 'self'") == false);
    try testing.expect(hasFrameAncestors("frame-ancestors-x 'self'") == false);
    try testing.expect(hasFrameAncestors("frame-ancestors"));
    try testing.expect(hasFrameAncestors("frame-ancestors;"));
    try testing.expect(hasFrameAncestors("script-src frame-ancestors") == false);
    try testing.expect(hasFrameAncestors("x-frame-ancestors 'self'") == false);
    try testing.expect(hasFrameAncestors("script-src frame-ancestors; frame-ancestors 'none'"));
}
