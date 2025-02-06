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

const generate = @import("generate.zig");

const Console = @import("jsruntime").Console;

const DOM = @import("dom/dom.zig");
const HTML = @import("html/html.zig");
const Events = @import("events/event.zig");
const XHR = @import("xhr/xhr.zig");
const Storage = @import("storage/storage.zig");
const URL = @import("url/url.zig");
const Iterators = @import("iterator/iterator.zig");
const XMLSerializer = @import("xmlserializer/xmlserializer.zig");

pub const HTMLDocument = @import("html/document.zig").HTMLDocument;

// Interfaces
pub const Interfaces = generate.Tuple(.{
    Console,
    DOM.Interfaces,
    Events.Interfaces,
    HTML.Interfaces,
    XHR.Interfaces,
    Storage.Interfaces,
    URL.Interfaces,
    Iterators.Interfaces,
    XMLSerializer.Interfaces,
}){};

pub const UserContext = @import("user_context.zig").UserContext;
