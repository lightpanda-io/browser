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

const generate = @import("../generate.zig");

const HTMLDocument = @import("document.zig").HTMLDocument;
const HTMLElem = @import("elements.zig");
const Window = @import("window.zig").Window;
const Navigator = @import("navigator.zig").Navigator;
const History = @import("history.zig").History;
const Location = @import("location.zig").Location;

pub const Interfaces = generate.Tuple(.{
    HTMLDocument,
    HTMLElem.HTMLElement,
    HTMLElem.HTMLMediaElement,
    HTMLElem.Interfaces,
    Window,
    Navigator,
    History,
    Location,
});
