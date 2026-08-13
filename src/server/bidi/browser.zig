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

const BiDi = @import("BiDi.zig");

pub fn processMessage(cmd: *const BiDi.Command) !void {
    const command = std.meta.stringToEnum(enum {
        getUserContexts,
    }, cmd.action) orelse return error.UnknownCommand;

    switch (command) {
        .getUserContexts => return getUserContexts(cmd),
    }
}

fn getUserContexts(cmd: *const BiDi.Command) !void {
    return cmd.sendResult(.{
        .userContexts = &[_]struct { userContext: []const u8 }{
            .{ .userContext = "default" },
        },
    });
}
