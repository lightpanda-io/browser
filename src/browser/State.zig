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

// Sometimes we need to extend libdom. For example, its HTMLDocument doesn't
// have a readyState. We have a couple different options, such as making the
// correction in libdom directly. Another option stems from the fact that every
// libdom node has an opaque embedder_data field. This is the struct that we
// lazily load into that field.
//
// It didn't originally start off as a collection of every single extension, but
// this quickly proved necessary, since different fields are needed on the same
// data at different levels of the prototype chain. This isn't memory efficient.

const js = @import("js/js.zig");
const parser = @import("netsurf.zig");
const DataSet = @import("html/DataSet.zig");
const ShadowRoot = @import("dom/shadow_root.zig").ShadowRoot;
const StyleSheet = @import("cssom/StyleSheet.zig");
const CSSStyleDeclaration = @import("cssom/CSSStyleDeclaration.zig");

// for HTMLScript (but probably needs to be added to more)
onload: ?js.Function = null,
onerror: ?js.Function = null,

// for HTMLElement
style: CSSStyleDeclaration = .empty,
dataset: ?DataSet = null,
template_content: ?*parser.DocumentFragment = null,

// For dom/element
shadow_root: ?*ShadowRoot = null,

// for html/document
ready_state: ReadyState = .loading,

// for html/HTMLStyleElement
style_sheet: ?*StyleSheet = null,

// for dom/document
active_element: ?*parser.Element = null,
adopted_style_sheets: ?js.Object = null,

// for HTMLSelectElement
// By default, if no option is explicitly selected, the first option should
// be selected. However, libdom doesn't do this, and it sets the
// selectedIndex to -1, which is a valid value for "nothing selected".
// Therefore, when libdom says the selectedIndex == -1, we don't know if
// it means that nothing is selected, or if the first option is selected by
// default.
// There are cases where this won't work, but when selectedIndex is
// explicitly set, we set this boolean flag. Then, when we're getting then
// selectedIndex, if this flag is == false, which is to say that if
// selectedIndex hasn't been explicitly set AND if we have at least 1 option
// AND if it isn't a multi select, we can make the 1st item selected by
// default (by returning selectedIndex == 0).
explicit_index_set: bool = false,

const ReadyState = enum {
    loading,
    interactive,
    complete,
};
