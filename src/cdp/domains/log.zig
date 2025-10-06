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
const log = @import("../../log.zig");

const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: anytype) !void {
    const action = std.meta.stringToEnum(enum {
        enable,
        disable,
    }, cmd.input.action) orelse return error.UnknownMethod;

    switch (action) {
        .enable => return enable(cmd),
        .disable => return disable(cmd),
    }
}
fn enable(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.logEnable();
    return cmd.sendResult(null, .{});
}

fn disable(cmd: anytype) !void {
    const bc = cmd.browser_context orelse return error.BrowserContextNotLoaded;
    bc.logDisable();
    return cmd.sendResult(null, .{});
}

pub fn LogInterceptor(comptime BC: type) type {
    return struct {
        bc: *BC,
        allocating: std.Io.Writer.Allocating,

        const Self = @This();

        pub fn init(allocator: Allocator, bc: *BC) Self {
            return .{
                .bc = bc,
                .allocating = .init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            return self.allocating.deinit();
        }

        pub fn writer(ctx: *anyopaque, scope: log.Scope, level: log.Level) ?*std.Io.Writer {
            if (scope == .unknown_prop or scope == .telemetry) {
                return null;
            }

            // DO NOT REMOVE this. This prevents a log message caused from a failure
            // to intercept to trigger another intercept, which could result in an
            // endless cycle.
            if (scope == .interceptor) {
                return null;
            }

            if (level == .debug) {
                return null;
            }
            const self: *Self = @ptrCast(@alignCast(ctx));
            return &self.allocating.writer;
        }

        pub fn done(ctx: *anyopaque, scope: log.Scope, level: log.Level) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.allocating.clearRetainingCapacity();

            self.bc.cdp.sendEvent("Log.entryAdded", .{
                .entry = .{
                    .source = switch (scope) {
                        .js, .user_script, .console, .web_api, .script_event => "javascript",
                        .http, .fetch, .xhr => "network",
                        .telemetry, .unknown_prop, .interceptor => unreachable, // filtered out in writer above
                        else => "other",
                    },
                    .level = switch (level) {
                        .debug => "verbose",
                        .info => "info",
                        .warn => "warning",
                        .err => "error",
                        .fatal => "error",
                    },
                    .text = self.allocating.written(),
                    .timestamp = @import("../../datetime.zig").milliTimestamp(),
                },
            }, .{
                .session_id = self.bc.session_id,
            }) catch |err| {
                log.err(.interceptor, "failed to send", .{.err = err});
            };
        }
    };
}
