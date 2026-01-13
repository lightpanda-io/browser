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

pub const Config = @This();

pub const RunMode = enum {
    help,
    fetch,
    serve,
    version,
};

run_mode: RunMode,

user_agent: [:0]const u8,

http_proxy: ?[:0]const u8 = null,
proxy_bearer_token: ?[:0]const u8 = null,

tls_verify_host: bool = true,
http_timeout_ms: u31 = 5000,
http_connect_timeout_ms: u31 = 0,
http_max_redirects: u16 = 10,
http_max_host_open: u8 = 4,
http_max_concurrent: u8 = 10,
