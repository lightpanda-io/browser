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
const lp = @import("lightpanda");

const HTTP_PORT = 9582;
const WS_PORT = 9584;

pub fn main() !void {
    var http_server: lp.TestHTTPServer = .init(lp.test_routes.handle, HTTP_PORT);
    var ws_server: lp.TestWSServer = .init(WS_PORT);

    var wg: lp.WaitGroup = .{};
    wg.startMany(2);
    const http_thread = try std.Thread.spawn(.{}, lp.TestHTTPServer.run, .{ &http_server, &wg });
    const ws_thread = try std.Thread.spawn(.{}, lp.TestWSServer.run, .{ &ws_server, &wg });
    wg.wait();

    std.debug.print("serving http://127.0.0.1:{d}/src/browser/tests/ (WebSocket on {d})\n", .{ HTTP_PORT, WS_PORT });

    http_thread.join();
    ws_thread.join();
}
