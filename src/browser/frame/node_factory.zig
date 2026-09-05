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

// Node creation for a frame: the createElementNS comptime tag dispatch and its
// element-building helpers, plus the Text/Comment/CDATASection/ProcessingInstruction
// factories and XML Name validation. All allocate through the frame's Factory and
// arenas; these functions operate on a *Frame.

const std = @import("std");
const lp = @import("lightpanda");

const JS = @import("../js/js.zig");
const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const Parser = @import("../parser/Parser.zig");

const Node = @import("../webapi/Node.zig");
const CData = @import("../webapi/CData.zig");
const Element = @import("../webapi/Element.zig");
const CustomElementDefinition = @import("../webapi/CustomElementDefinition.zig");

const log = lp.log;
const String = lp.String;
const IFrame = Element.Html.IFrame;

pub fn createElementNS(frame: *Frame, namespace: Element.Namespace, name: []const u8, attribute_iterator: anytype) !*Node {
    const from_parser = @TypeOf(attribute_iterator) == Parser.AttributeIterator;

    switch (namespace) {
        .html => {
            switch (name.len) {
                1 => switch (name[0]) {
                    'p' => return createHtmlElementT(
                        frame,
                        Element.Html.Paragraph,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    'a' => return createHtmlElementT(
                        frame,
                        Element.Html.Anchor,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    'b' => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("b"), ._tag = .b },
                    ),
                    'i' => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("i"), ._tag = .i },
                    ),
                    'q' => return createHtmlElementT(
                        frame,
                        Element.Html.Quote,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("q"), ._tag = .quote },
                    ),
                    's' => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("s"), ._tag = .s },
                    ),
                    else => {},
                },
                2 => switch (@as(u16, @bitCast(name[0..2].*))) {
                    asUint("br") => return createHtmlElementT(
                        frame,
                        Element.Html.BR,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("ol") => return createHtmlElementT(
                        frame,
                        Element.Html.OL,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("ul") => return createHtmlElementT(
                        frame,
                        Element.Html.UL,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("li") => return createHtmlElementT(
                        frame,
                        Element.Html.LI,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("h1") => return createHtmlElementT(
                        frame,
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("h1"), ._tag = .h1 },
                    ),
                    asUint("h2") => return createHtmlElementT(
                        frame,
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("h2"), ._tag = .h2 },
                    ),
                    asUint("h3") => return createHtmlElementT(
                        frame,
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("h3"), ._tag = .h3 },
                    ),
                    asUint("h4") => return createHtmlElementT(
                        frame,
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("h4"), ._tag = .h4 },
                    ),
                    asUint("h5") => return createHtmlElementT(
                        frame,
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("h5"), ._tag = .h5 },
                    ),
                    asUint("h6") => return createHtmlElementT(
                        frame,
                        Element.Html.Heading,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("h6"), ._tag = .h6 },
                    ),
                    asUint("hr") => return createHtmlElementT(
                        frame,
                        Element.Html.HR,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("em") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("em"), ._tag = .em },
                    ),
                    asUint("dd") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("dd"), ._tag = .dd },
                    ),
                    asUint("dl") => return createHtmlElementT(
                        frame,
                        Element.Html.DList,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("dt") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("dt"), ._tag = .dt },
                    ),
                    asUint("td") => return createHtmlElementT(
                        frame,
                        Element.Html.TableCell,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("td"), ._tag = .td },
                    ),
                    asUint("th") => return createHtmlElementT(
                        frame,
                        Element.Html.TableCell,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("th"), ._tag = .th },
                    ),
                    asUint("tr") => return createHtmlElementT(
                        frame,
                        Element.Html.TableRow,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    else => {},
                },
                3 => switch (@as(u24, @bitCast(name[0..3].*))) {
                    asUint("div") => return createHtmlElementT(
                        frame,
                        Element.Html.Div,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("img") => return createHtmlElementT(
                        frame,
                        Element.Html.Image,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("nav") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("nav"), ._tag = .nav },
                    ),
                    asUint("del") => return createHtmlElementT(
                        frame,
                        Element.Html.Mod,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("del"), ._tag = .del },
                    ),
                    asUint("ins") => return createHtmlElementT(
                        frame,
                        Element.Html.Mod,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("ins"), ._tag = .ins },
                    ),
                    asUint("col") => return createHtmlElementT(
                        frame,
                        Element.Html.TableCol,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("col"), ._tag = .col },
                    ),
                    asUint("dir") => return createHtmlElementT(
                        frame,
                        Element.Html.Directory,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("map") => return createHtmlElementT(
                        frame,
                        Element.Html.Map,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("pre") => return createHtmlElementT(
                        frame,
                        Element.Html.Pre,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("sub") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("sub"), ._tag = .sub },
                    ),
                    asUint("sup") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("sup"), ._tag = .sup },
                    ),
                    asUint("dfn") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("dfn"), ._tag = .dfn },
                    ),
                    else => {},
                },
                4 => switch (@as(u32, @bitCast(name[0..4].*))) {
                    asUint("span") => return createHtmlElementT(
                        frame,
                        Element.Html.Span,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("meta") => return createHtmlElementT(
                        frame,
                        Element.Html.Meta,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("link") => return createHtmlElementT(
                        frame,
                        Element.Html.Link,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("slot") => return createHtmlElementT(
                        frame,
                        Element.Html.Slot,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("html") => return createHtmlElementT(
                        frame,
                        Element.Html.Html,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("head") => {
                        // Inject user-provided scripts.
                        const inject_scripts = frame._session.inject_scripts;
                        const should_inject_scripts = from_parser and frame._parse_mode == .document and inject_scripts.len > 0;

                        if (should_inject_scripts) {
                            var ls: JS.Local.Scope = undefined;
                            frame.js.localScope(&ls);
                            defer ls.deinit();

                            for (inject_scripts) |inject_script| {
                                var try_catch: JS.TryCatch = undefined;
                                try_catch.init(&ls.local);
                                defer try_catch.deinit();

                                ls.local.eval(inject_script, "inject_script") catch |err| {
                                    const caught = try_catch.caughtOrError(frame.local_arena, err);
                                    log.err(.app, "inject script error", .{ .err = caught });
                                };
                            }
                        }

                        return createHtmlElementT(
                            frame,
                            Element.Html.Head,
                            namespace,
                            attribute_iterator,
                            .{},
                        );
                    },
                    asUint("body") => return createHtmlElementT(
                        frame,
                        Element.Html.Body,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("form") => return createHtmlElementT(
                        frame,
                        Element.Html.Form,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("main") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("main"), ._tag = .main },
                    ),
                    asUint("data") => return createHtmlElementT(
                        frame,
                        Element.Html.Data,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("base") => {
                        const n = try createHtmlElementT(
                            frame,
                            Element.Html.Base,
                            namespace,
                            attribute_iterator,
                            .{},
                        );

                        // If frames's base url is not already set, fill it with
                        // the base tag.
                        if (frame.base_url == null) {
                            if (n.as(Element).getAttributeSafe(comptime .wrap("href"))) |href| {
                                frame.base_url = try URL.resolve(frame.arena, frame.url, href, .{});
                            }
                        }

                        return n;
                    },
                    asUint("menu") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("menu"), ._tag = .menu },
                    ),
                    asUint("area") => return createHtmlElementT(
                        frame,
                        Element.Html.Area,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("font") => return createHtmlElementT(
                        frame,
                        Element.Html.Font,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("code") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("code"), ._tag = .code },
                    ),
                    asUint("time") => return createHtmlElementT(
                        frame,
                        Element.Html.Time,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    else => {},
                },
                5 => switch (@as(u40, @bitCast(name[0..5].*))) {
                    asUint("input") => return createHtmlElementT(
                        frame,
                        Element.Html.Input,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("style") => return createHtmlElementT(
                        frame,
                        Element.Html.Style,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("title") => return createHtmlElementT(
                        frame,
                        Element.Html.Title,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("embed") => return createHtmlElementT(
                        frame,
                        Element.Html.Embed,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("audio") => return createHtmlMediaElementT(
                        frame,
                        Element.Html.Media.Audio,
                        namespace,
                        attribute_iterator,
                    ),
                    asUint("video") => return createHtmlMediaElementT(
                        frame,
                        Element.Html.Media.Video,
                        namespace,
                        attribute_iterator,
                    ),
                    asUint("aside") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("aside"), ._tag = .aside },
                    ),
                    asUint("label") => return createHtmlElementT(
                        frame,
                        Element.Html.Label,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("meter") => return createHtmlElementT(
                        frame,
                        Element.Html.Meter,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("param") => return createHtmlElementT(
                        frame,
                        Element.Html.Param,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("table") => return createHtmlElementT(
                        frame,
                        Element.Html.Table,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("thead") => return createHtmlElementT(
                        frame,
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("thead"), ._tag = .thead },
                    ),
                    asUint("tbody") => return createHtmlElementT(
                        frame,
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("tbody"), ._tag = .tbody },
                    ),
                    asUint("tfoot") => return createHtmlElementT(
                        frame,
                        Element.Html.TableSection,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("tfoot"), ._tag = .tfoot },
                    ),
                    asUint("track") => return createHtmlElementT(
                        frame,
                        Element.Html.Track,
                        namespace,
                        attribute_iterator,
                        .{ ._kind = comptime .wrap("subtitles"), ._ready_state = .none },
                    ),
                    else => {},
                },
                6 => switch (@as(u48, @bitCast(name[0..6].*))) {
                    asUint("script") => return createHtmlElementT(
                        frame,
                        Element.Html.Script,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("button") => return createHtmlElementT(
                        frame,
                        Element.Html.Button,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("canvas") => return createHtmlElementT(
                        frame,
                        Element.Html.Canvas,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("dialog") => return createHtmlElementT(
                        frame,
                        Element.Html.Dialog,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("legend") => return createHtmlElementT(
                        frame,
                        Element.Html.Legend,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("object") => return createHtmlElementT(
                        frame,
                        Element.Html.Object,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("output") => return createHtmlElementT(
                        frame,
                        Element.Html.Output,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("source") => return createHtmlElementT(
                        frame,
                        Element.Html.Source,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("strong") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("strong"), ._tag = .strong },
                    ),
                    asUint("header") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("header"), ._tag = .header },
                    ),
                    asUint("footer") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("footer"), ._tag = .footer },
                    ),
                    asUint("select") => return createHtmlElementT(
                        frame,
                        Element.Html.Select,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("option") => return createHtmlElementT(
                        frame,
                        Element.Html.Option,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("iframe") => return createHtmlElementT(
                        frame,
                        IFrame,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("figure") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("figure"), ._tag = .figure },
                    ),
                    asUint("hgroup") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("hgroup"), ._tag = .hgroup },
                    ),
                    else => {},
                },
                7 => switch (@as(u56, @bitCast(name[0..7].*))) {
                    asUint("section") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("section"), ._tag = .section },
                    ),
                    asUint("article") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("article"), ._tag = .article },
                    ),
                    asUint("details") => return createHtmlElementT(
                        frame,
                        Element.Html.Details,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("summary") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("summary"), ._tag = .summary },
                    ),
                    asUint("caption") => return createHtmlElementT(
                        frame,
                        Element.Html.TableCaption,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("marquee") => return createHtmlElementT(
                        frame,
                        Element.Html.Marquee,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("address") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("address"), ._tag = .address },
                    ),
                    asUint("picture") => return createHtmlElementT(
                        frame,
                        Element.Html.Picture,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    else => {},
                },
                8 => switch (@as(u64, @bitCast(name[0..8].*))) {
                    asUint("textarea") => return createHtmlElementT(
                        frame,
                        Element.Html.TextArea,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("template") => return createHtmlElementT(
                        frame,
                        Element.Html.Template,
                        namespace,
                        attribute_iterator,
                        .{ ._content = undefined },
                    ),
                    asUint("colgroup") => return createHtmlElementT(
                        frame,
                        Element.Html.TableCol,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("colgroup"), ._tag = .colgroup },
                    ),
                    asUint("fieldset") => return createHtmlElementT(
                        frame,
                        Element.Html.FieldSet,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("frameset") => {
                        if (comptime from_parser) {
                            log.warn(.not_implemented, "framset", .{ .note = "<framset>...</frameset> in html is not handled properly" });
                        }
                        return createHtmlElementT(
                            frame,
                            Element.Html.FrameSet,
                            namespace,
                            attribute_iterator,
                            .{},
                        );
                    },
                    asUint("optgroup") => return createHtmlElementT(
                        frame,
                        Element.Html.OptGroup,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("progress") => return createHtmlElementT(
                        frame,
                        Element.Html.Progress,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("datalist") => return createHtmlElementT(
                        frame,
                        Element.Html.DataList,
                        namespace,
                        attribute_iterator,
                        .{},
                    ),
                    asUint("noscript") => return createHtmlElementT(
                        frame,
                        Element.Html.Generic,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("noscript"), ._tag = .noscript },
                    ),
                    else => {},
                },
                10 => switch (@as(u80, @bitCast(name[0..10].*))) {
                    asUint("blockquote") => return createHtmlElementT(
                        frame,
                        Element.Html.Quote,
                        namespace,
                        attribute_iterator,
                        .{ ._tag_name = comptime .wrap("blockquote"), ._tag = .blockquote },
                    ),
                    else => {},
                },
                else => {},
            }
            const tag_name = try String.init(frame.arena, name, .{});

            // Check if this is a custom element (must have hyphen for HTML namespace)
            const has_hyphen = std.mem.indexOfScalar(u8, name, '-') != null;
            if (has_hyphen and namespace == .html) {
                const creation = frame._custom_element_creation;
                const definition = switch (creation) {
                    .construct, .bare_context => frame.window._custom_elements._definitions.get(name),
                    // A windowless document has no registry.
                    .undefined => null,
                };

                // Fragment-parse context element. It will not be inserted and
                // we should not run the custom element's constructor.
                //
                // Undefined elements are created in the "undefined" state and
                // upgraded later, when a matching definition is registered.
                // Only elements created for this frame's document are
                // candidates: a windowless document's element is upgraded on
                // insertion into this frame's document instead.
                if (creation != .construct or definition == null) {
                    const node = try createHtmlElementT(frame, Element.Html.Custom, namespace, attribute_iterator, .{
                        ._tag_name = tag_name,
                        ._definition = definition,
                    });
                    if (creation == .construct) {
                        try frame._undefined_custom_elements.append(frame.arena, node.as(Element).is(Element.Html.Custom).?);
                    }
                    return node;
                }

                // https://dom.spec.whatwg.org/#concept-create-element, the
                // synchronous branch. super() has to create its own element
                const constructed = constructForToken(frame, definition.?, tag_name, from_parser) catch {
                    // Construction failed, we fallback to  HTMLUnknownElement
                    return createHtmlElementT(frame, Element.Html.Unknown, namespace, attribute_iterator, .{
                        ._tag_name = tag_name,
                    });
                };

                // Attributes are applied after construction, so the constructor
                // observes none of them and each one enqueues its reaction.
                try populateElementAttributes(frame, constructed, attribute_iterator);
                for (constructed.attributeEntries()) |*attr| {
                    Element.Html.Custom.enqueueAttributeChangedCallbackOnElement(
                        constructed,
                        .wrap(attr.name()),
                        null, // old_value is null for initial attributes
                        .wrap(attr.value()),
                        null,
                        frame,
                    );
                }

                return constructed.asNode();
            }

            return createHtmlElementT(frame, Element.Html.Unknown, namespace, attribute_iterator, .{ ._tag_name = tag_name });
        },
        .svg => {
            const Graphics = Element.Svg.Graphics;
            const Geometry = Graphics.Geometry;
            // SVG tag names are case-sensitive; no lowering before matching.
            switch (name.len) {
                1 => switch (name[0]) {
                    'g' => return createSvgElementT(frame, Graphics.G, name, attribute_iterator, .{}),
                    'a' => return createSvgElementT(frame, Graphics.A, name, attribute_iterator, .{}),
                    else => {},
                },
                3 => switch (@as(u24, @bitCast(name[0..3].*))) {
                    asUint("svg") => return createSvgElementT(frame, Graphics.Svg, name, attribute_iterator, .{}),
                    asUint("use") => return createSvgElementT(frame, Graphics.Use, name, attribute_iterator, .{}),
                    else => {},
                },
                4 => switch (@as(u32, @bitCast(name[0..4].*))) {
                    asUint("defs") => return createSvgElementT(frame, Graphics.Defs, name, attribute_iterator, .{}),
                    asUint("desc") => return createSvgElementT(frame, Element.Svg.Desc, name, attribute_iterator, .{}),
                    asUint("mask") => return createSvgElementT(frame, Element.Svg.Mask, name, attribute_iterator, .{}),
                    asUint("rect") => return createSvgElementT(frame, Geometry.Rect, name, attribute_iterator, .{}),
                    asUint("stop") => return createSvgElementT(frame, Element.Svg.Stop, name, attribute_iterator, .{}),
                    asUint("text") => return createSvgElementT(frame, Graphics.TextContent.TextPositioning.Text, name, attribute_iterator, .{}),
                    asUint("line") => return createSvgElementT(frame, Geometry.Line, name, attribute_iterator, .{}),
                    asUint("path") => return createSvgElementT(frame, Geometry.Path, name, attribute_iterator, .{}),
                    asUint("view") => return createSvgElementT(frame, Element.Svg.View, name, attribute_iterator, .{}),
                    else => {},
                },
                5 => switch (@as(u40, @bitCast(name[0..5].*))) {
                    asUint("image") => return createSvgElementT(frame, Graphics.Image, name, attribute_iterator, .{}),
                    asUint("title") => return createSvgElementT(frame, Element.Svg.Title, name, attribute_iterator, .{}),
                    asUint("tspan") => return createSvgElementT(frame, Graphics.TextContent.TextPositioning.TSpan, name, attribute_iterator, .{}),
                    else => {},
                },
                6 => switch (@as(u48, @bitCast(name[0..6].*))) {
                    asUint("circle") => return createSvgElementT(frame, Geometry.Circle, name, attribute_iterator, .{}),
                    asUint("marker") => return createSvgElementT(frame, Element.Svg.Marker, name, attribute_iterator, .{}),
                    asUint("switch") => return createSvgElementT(frame, Graphics.Switch, name, attribute_iterator, .{}),
                    asUint("symbol") => return createSvgElementT(frame, Graphics.Symbol, name, attribute_iterator, .{}),
                    else => {},
                },
                7 => switch (@as(u56, @bitCast(name[0..7].*))) {
                    asUint("ellipse") => return createSvgElementT(frame, Geometry.Ellipse, name, attribute_iterator, .{}),
                    asUint("pattern") => return createSvgElementT(frame, Element.Svg.Pattern, name, attribute_iterator, .{}),
                    asUint("polygon") => return createSvgElementT(frame, Geometry.Polygon, name, attribute_iterator, .{}),
                    else => {},
                },
                8 => switch (@as(u64, @bitCast(name[0..8].*))) {
                    asUint("clipPath") => return createSvgElementT(frame, Element.Svg.ClipPath, name, attribute_iterator, .{}),
                    asUint("metadata") => return createSvgElementT(frame, Element.Svg.Metadata, name, attribute_iterator, .{}),
                    asUint("polyline") => return createSvgElementT(frame, Geometry.Polyline, name, attribute_iterator, .{}),
                    asUint("textPath") => return createSvgElementT(frame, Graphics.TextContent.TextPath, name, attribute_iterator, .{}),
                    else => {},
                },
                13 => switch (@as(u104, @bitCast(name[0..13].*))) {
                    asUint("foreignObject") => return createSvgElementT(frame, Graphics.ForeignObject, name, attribute_iterator, .{}),
                    else => {},
                },
                14 => switch (@as(u112, @bitCast(name[0..14].*))) {
                    asUint("linearGradient") => return createSvgElementT(frame, Element.Svg.GradientElement.LinearGradient, name, attribute_iterator, .{}),
                    asUint("radialGradient") => return createSvgElementT(frame, Element.Svg.GradientElement.RadialGradient, name, attribute_iterator, .{}),
                    else => {},
                },
                else => {},
            }

            const lower = std.ascii.lowerString(&frame.buf, name);
            const tag = std.meta.stringToEnum(Element.Tag, lower) orelse .unknown;
            return createSvgElementT(frame, Element.Svg.Generic, name, attribute_iterator, .{ ._tag = tag });
        },
        else => {
            const tag_name = try String.init(frame.arena, name, .{});
            return createHtmlElementT(frame, Element.Html.Unknown, namespace, attribute_iterator, .{ ._tag_name = tag_name });
        },
    }
}

// Runs a custom element constructor for a token being created (parser or
// createElement), and validates the result against the post-conditions.
fn constructForToken(frame: *Frame, definition: *CustomElementDefinition, tag_name: String, comptime from_parser: bool) !*Element {
    // This is a creation, not an upgrade. super() ha to build a new element
    const prev_upgrading = frame._upgrading_element;
    const prev_consumed = frame._upgrading_consumed;
    frame._upgrading_element = null;
    frame._upgrading_consumed = false;
    defer {
        frame._upgrading_element = prev_upgrading;
        frame._upgrading_consumed = prev_consumed;
    }

    var ls: JS.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    if (from_parser) {
        // There are some things custom elements aren't allowed to do
        // when we're parsing.
        frame.document._throw_on_dynamic_markup_insertion_counter += 1;
    }
    defer if (from_parser) {
        frame.document._throw_on_dynamic_markup_insertion_counter -= 1;
    };

    const name = tag_name.str();
    const local = &ls.local;

    var try_catch: JS.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    const object = ls.toLocal(definition.constructor).newInstanceThrow() catch |err| {
        if (err != error.ExecutionTerminated) {
            log.warn(.js, "custom element constructor", .{ .name = name, .err = err, .type = frame._type, .url = frame.url });
            if (try_catch.exceptionValue()) |exc| {
                // Spec: report the exception
                frame.window.reportError(exc, frame) catch {};
            }
        }
        return err;
    };

    const reason: []const u8, const exc: JS.Value = blk: {
        // Validate the result. A result that isn't an HTMLElement is a
        // TypeError; any other violation is a NotSupportedError.
        const node = object.toZig(*Node) catch break :blk .{ "not a node", typeError(local) };
        const element = node.is(Element) orelse break :blk .{ "not an element", typeError(local) };
        if (element._namespace != .html) {
            break :blk .{ "wrong namespace", typeError(local) };
        }
        if (node._parent != null) {
            break :blk .{ "has a parent", notSupportedError(local) };
        }
        if (node.firstChild() != null) {
            break :blk .{ "has children", notSupportedError(local) };
        }
        if (element._attributes.isEmpty() == false) {
            break :blk .{ "has attributes", notSupportedError(local) };
        }
        if (node.ownerDocument(frame) != frame.document) {
            break :blk .{ "wrong document", notSupportedError(local) };
        }
        if (std.mem.eql(u8, element.getTagNameLower(), name) == false) {
            break :blk .{ "wrong local name", notSupportedError(local) };
        }
        return element;
    };

    log.warn(.js, "custom element not usable", .{ .name = name, .reason = reason, .type = frame._type, .url = frame.url });
    frame.window.reportError(exc, frame) catch {};
    return error.CustomElementConstructionFailed;
}

fn typeError(local: *const JS.Local) JS.Value {
    return .{ .local = local, .handle = local.isolate.createTypeError("Invalid custom element constructor return value") };
}

fn notSupportedError(local: *const JS.Local) JS.Value {
    const DOMException = @import("../webapi/DOMException.zig");
    const ex = DOMException.fromError(error.NotSupported).?;
    return local.zigValueToJs(ex, .{}) catch .{ .local = local, .handle = local.isolate.createError("not supported") };
}

fn createHtmlElementT(frame: *Frame, comptime E: type, namespace: Element.Namespace, attribute_iterator: anytype, html_element: E) !*Node {
    const html_element_ptr = try frame._factory.htmlElement(html_element);
    const element = html_element_ptr.asElement();
    element._namespace = namespace;
    element._attributes.normalize = namespace == .html;
    try populateElementAttributes(frame, element, attribute_iterator);

    // Check for customized built-in element via "is" attribute
    try Element.Html.Custom.checkAndAttachBuiltIn(element, frame);

    const node = element.asNode();
    if (@hasDecl(E, "Build") and @hasDecl(E.Build, "created")) {
        @call(.auto, @field(E.Build, "created"), .{ node, frame }) catch |err| {
            log.err(.frame, "build.created", .{ .tag = node.getNodeName(&frame.buf), .err = err, .type = frame._type, .url = frame.url });
            return err;
        };
    }
    return node;
}

fn createHtmlMediaElementT(frame: *Frame, comptime E: type, namespace: Element.Namespace, attribute_iterator: anytype) !*Node {
    const media_element = try frame._factory.htmlMediaElement(E{});
    const element = media_element.asElement();
    element._namespace = namespace;
    try populateElementAttributes(frame, element, attribute_iterator);
    return element.asNode();
}

fn createSvgElementT(frame: *Frame, comptime E: type, tag_name: []const u8, attribute_iterator: anytype, svg_element: E) !*Node {
    const svg_element_ptr = try frame._factory.svgElement(tag_name, svg_element);
    return initSvgElement(frame, svg_element_ptr.asElement(), attribute_iterator);
}

fn initSvgElement(frame: *Frame, element: *Element, attribute_iterator: anytype) !*Node {
    element._namespace = .svg;
    element._attributes.normalize = false;
    try populateElementAttributes(frame, element, attribute_iterator);
    return element.asNode();
}

fn populateElementAttributes(frame: *Frame, element: *Element, list: anytype) !void {
    if (@TypeOf(list) == *Element.Attribute.List or @TypeOf(list) == *const Element.Attribute.List) {
        // from cloneNode
        try element._attributes.cloneFrom(list, frame);
        element.noteStyleAttribute();
        return;
    }

    // from the parser
    if (@TypeOf(list) == @TypeOf(null)) {
        return;
    }
    const count = list.count();
    if (count == 0) {
        return;
    }
    var attributes = &element._attributes;
    try attributes.ensureTotalCapacity(count, frame);
    while (list.next()) |attr| {
        const name = try parserAttributeName(frame, attr.name);
        try attributes.putNew(name, attr.value.slice(), frame);
    }
    element.noteStyleAttribute();
}

// Attributes are keyed by qualified name (no namespace model), so a prefixed
// attribute (`xlink:href` in foreign content, `xml:id` in XML) must keep its
// prefix — that is what `getAttribute("xlink:href")` and `Attr.name` see in
// browsers. The joined name only has to outlive putNew, which canonicalizes
// it into the frame arena. (Not frame.buf: name normalization writes there.)
fn parserAttributeName(frame: *Frame, qname: Parser.QualName) ![]const u8 {
    const local = qname.local.slice();
    const prefix = (qname.prefix.unwrap() orelse return local).slice();
    if (prefix.len == 0) {
        return local;
    }
    return std.fmt.allocPrint(frame.local_arena, "{s}:{s}", .{ prefix, local });
}

// Called when `new MyElement()` is invoked directly in JS (not via the
// customElements.define/upgrade path). `new_target` is the constructor
// function that was used with `new`. We find the matching definition in the
// registry by function identity and allocate a detached Custom element with
// the registered tag name.
pub fn constructCustomElement(frame: *Frame, new_target: JS.Function) !*Element {
    var it = frame.window._custom_elements._definitions.iterator();
    const definition = while (it.next()) |entry| {
        if (entry.value_ptr.*.constructor.isEqual(new_target)) {
            break entry.value_ptr.*;
        }
    } else return error.IllegalConstructor;

    // Customized built-ins (`class Foo extends HTMLDivElement`, etc.) would
    // need to allocate the extended HTML type rather than Custom. Not yet
    // supported via direct `new` — upgrade path still works for those.
    if (definition.isCustomizedBuiltIn()) {
        return error.IllegalConstructor;
    }

    const tag_name = try String.init(frame.arena, definition.name, .{});
    const node = try createHtmlElementT(frame, Element.Html.Custom, .html, null, .{
        ._tag_name = tag_name,
        ._definition = definition,
    });
    return node.as(Element);
}

pub fn createTextNode(frame: *Frame, text: []const u8) !*Node {
    const cd = try frame._factory.cdataNode(.{
        ._type = .text,
        ._data = try frame.dupeSSO(text),
    }, CData.Text{});
    return cd.asNode();
}

pub fn createComment(frame: *Frame, text: []const u8) !*Node {
    const cd = try frame._factory.cdataNode(.{
        ._type = .comment,
        ._data = try frame.dupeSSO(text),
    }, CData.Comment{});
    return cd.asNode();
}

pub fn createCDATASection(frame: *Frame, data: []const u8) !*Node {
    // Validate that the data doesn't contain "]]>"
    if (std.mem.indexOf(u8, data, "]]>") != null) {
        return error.InvalidCharacterError;
    }

    const cd = try frame._factory.cdataNode(.{
        ._type = .cdata_section,
        ._data = try frame.dupeSSO(data),
    }, CData.CDATASection{});
    return cd.asNode();
}

pub fn createProcessingInstruction(frame: *Frame, target: []const u8, data: []const u8) !*Node {
    // Validate neither target nor data contain "?>"
    if (std.mem.indexOf(u8, target, "?>") != null) {
        return error.InvalidCharacterError;
    }
    if (std.mem.indexOf(u8, data, "?>") != null) {
        return error.InvalidCharacterError;
    }

    // Validate target follows XML Name production
    try validateXmlName(target);

    const owned_target = try frame.dupeString(target);

    const cd = try frame._factory.cdataNode(.{
        ._type = .processing_instruction,
        ._data = try frame.dupeSSO(data),
    }, CData.ProcessingInstruction{
        ._target = owned_target,
    });
    return cd.asNode();
}

/// Validate a string against the XML Name production.
/// https://www.w3.org/TR/xml/#NT-Name
fn validateXmlName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidCharacterError;

    var i: usize = 0;

    // First character must be a NameStartChar.
    const first_len = std.unicode.utf8ByteSequenceLength(name[0]) catch
        return error.InvalidCharacterError;
    if (first_len > name.len) return error.InvalidCharacterError;
    const first_cp = std.unicode.utf8Decode(name[0..][0..first_len]) catch
        return error.InvalidCharacterError;
    if (!isXmlNameStartChar(first_cp)) return error.InvalidCharacterError;
    i = first_len;

    // Subsequent characters must be NameChars.
    while (i < name.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(name[i]) catch
            return error.InvalidCharacterError;
        if (i + cp_len > name.len) return error.InvalidCharacterError;
        const cp = std.unicode.utf8Decode(name[i..][0..cp_len]) catch
            return error.InvalidCharacterError;
        if (!isXmlNameChar(cp)) return error.InvalidCharacterError;
        i += cp_len;
    }
}

fn isXmlNameStartChar(c: u21) bool {
    return c == ':' or
        (c >= 'A' and c <= 'Z') or
        c == '_' or
        (c >= 'a' and c <= 'z') or
        (c >= 0xC0 and c <= 0xD6) or
        (c >= 0xD8 and c <= 0xF6) or
        (c >= 0xF8 and c <= 0x2FF) or
        (c >= 0x370 and c <= 0x37D) or
        (c >= 0x37F and c <= 0x1FFF) or
        (c >= 0x200C and c <= 0x200D) or
        (c >= 0x2070 and c <= 0x218F) or
        (c >= 0x2C00 and c <= 0x2FEF) or
        (c >= 0x3001 and c <= 0xD7FF) or
        (c >= 0xF900 and c <= 0xFDCF) or
        (c >= 0xFDF0 and c <= 0xFFFD) or
        (c >= 0x10000 and c <= 0xEFFFF);
}

fn isXmlNameChar(c: u21) bool {
    return isXmlNameStartChar(c) or
        c == '-' or
        c == '.' or
        (c >= '0' and c <= '9') or
        c == 0xB7 or
        (c >= 0x300 and c <= 0x36F) or
        (c >= 0x203F and c <= 0x2040);
}

fn asUint(comptime string: anytype) std.meta.Int(
    .unsigned,
    @bitSizeOf(@TypeOf(string.*)) - 8, // (- 8) to exclude sentinel 0
) {
    const byteLength = @sizeOf(@TypeOf(string.*)) - 1;
    const expectedType = *const [byteLength:0]u8;
    if (@TypeOf(string) != expectedType) {
        @compileError("expected : " ++ @typeName(expectedType) ++ ", got: " ++ @typeName(@TypeOf(string)));
    }

    return @bitCast(@as(*const [byteLength]u8, string).*);
}
