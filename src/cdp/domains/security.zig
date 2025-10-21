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

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        setIgnoreCertificateErrors,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return cmd.sendResult(null, .{}),
        .setIgnoreCertificateErrors => return setIgnoreCertificateErrors(cmd),
    }
}

fn setIgnoreCertificateErrors(cmd: anytype) !void {
    const params = (try cmd.params(struct {
        ignore: bool,
    })) orelse return error.InvalidParams;

    if (params.ignore) {
        try cmd.cdp.browser.http_client.disableTlsVerify();
    } else {
        try cmd.cdp.browser.http_client.enableTlsVerify();
    }

    return cmd.sendResult(null, .{});
}

const testing = @import("../testing.zig");

test "cdp.Security: setIgnoreCertificateErrors" {
    var ctx = testing.context();
    defer ctx.deinit();

    _ = try ctx.loadBrowserContext(.{ .id = "BID-9" });

    try ctx.processMessage(.{
        .id = 8,
        .method = "Security.setIgnoreCertificateErrors",
        .params = .{ .ignore = true },
    });
    try ctx.expectSentResult(null, .{ .id = 8 });

    try ctx.processMessage(.{
        .id = 9,
        .method = "Security.setIgnoreCertificateErrors",
        .params = .{ .ignore = false },
    });
    try ctx.expectSentResult(null, .{ .id = 9 });
}
