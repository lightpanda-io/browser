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

const js = @import("../js/js.zig");

// @ZIGDOM (haha, bet you wish you hadn't opened this file)
// puppeteer's startup script creates a MutationObserver, even if it doesn't use
// it in simple scripts. This not-even-a-skeleton is required for puppeteer/cdp.js
// to run
const MutationObserver = @This();

pub fn init() MutationObserver {
    return .{};
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(MutationObserver);

    pub const Meta = struct {
        pub const name = "MutationObserver";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(MutationObserver.init, .{});
};
