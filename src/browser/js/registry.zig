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

// The engine-agnostic part of the bridge: the master list of WebAPI types
// and the comptime machinery to look them up and walk their prototype
// chains. Both the v8 and qjs backends build their bindings from this.
const std = @import("std");
const lp = @import("lightpanda");

pub const PrototypeChainEntry = struct {
    index: JsApiLookup.BackingInt,
    offset: u16, // offset to the _proto field
};

// Builds the prototype chain for a WebAPI type. entries[0] is T itself,
// followed by each _proto ancestor.
pub fn prototypeChain(comptime T: type) [prototypeChainLength(T)]PrototypeChainEntry {
    var entries: [prototypeChainLength(T)]PrototypeChainEntry = undefined;

    entries[0] = .{ .offset = 0, .index = JsApiLookup.getId(T.JsApi) };

    if (entries.len == 1) {
        return entries;
    }

    var Prototype = T;
    inline for (entries[1..]) |*entry| {
        const Next = PrototypeType(Prototype).?;
        entry.* = .{
            .index = JsApiLookup.getId(Next.JsApi),
            .offset = @offsetOf(Prototype, "_proto"),
        };
        Prototype = Next;
    }
    return entries;
}

// Given a Type, returns the length of the prototype chain, including self
pub fn prototypeChainLength(comptime T: type) usize {
    var l: usize = 1;
    var Next = T;
    while (PrototypeType(Next)) |N| {
        Next = N;
        l += 1;
    }
    return l;
}

// Given a Type, gets its prototype Type (if any)
fn PrototypeType(comptime T: type) ?type {
    if (!@hasField(T, "_proto")) {
        return null;
    }
    return Struct(std.meta.fieldInfo(T, ._proto).type);
}

fn flattenTypes(comptime Types: []const type) [countFlattenedTypes(Types)]type {
    var index: usize = 0;
    var flat: [countFlattenedTypes(Types)]type = undefined;
    for (Types) |T| {
        if (@hasDecl(T, "registerTypes")) {
            for (T.registerTypes()) |TT| {
                flat[index] = TT.JsApi;
                index += 1;
            }
        } else {
            flat[index] = T.JsApi;
            index += 1;
        }
    }
    return flat;
}

fn countFlattenedTypes(comptime Types: []const type) usize {
    var c: usize = 0;
    for (Types) |T| {
        c += if (@hasDecl(T, "registerTypes")) T.registerTypes().len else 1;
    }
    return c;
}

//  T => T
// *T => T
pub fn Struct(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => T,
        .pointer => |ptr| ptr.child,
        else => @compileError("Expecting Struct or *Struct, got: " ++ @typeName(T)),
    };
}

pub const JsApiLookup = struct {
    /// Integer type we use for `JsApiLookup` enum. Can be u8 at min.
    pub const BackingInt = std.math.IntFittingRange(0, @max(std.math.maxInt(u8), JsApis.len));

    /// Imagine we have a type `Cat` which has a getter:
    ///
    ///    fn get_owner(self: *Cat) *Owner {
    ///        return self.owner;
    ///    }
    ///
    /// When we execute `caller.getter`, we'll end up doing something like:
    ///
    ///    const res = @call(.auto, Cat.get_owner, .{cat_instance});
    ///
    /// How do we turn `res`, which is an *Owner, into something we can return
    /// to v8? We need the ObjectTemplate associated with Owner. How do we
    /// get that? Well, we store all the ObjectTemplates in an array that's
    /// tied to env. So we do something like:
    ///
    ///    env.templates[index_of_owner].initInstance(...);
    ///
    /// But how do we get that `index_of_owner`? `Index` is an enum
    /// that looks like:
    ///
    ///    pub const Enum = enum(BackingInt) {
    ///        cat = 0,
    ///        owner = 1,
    ///        ...
    ///    }
    ///
    /// (`BackingInt` is calculated at comptime regarding to interfaces we have)
    /// So to get the template index of `owner`, simply do:
    ///
    ///    const index_id = types.getId(@TypeOf(res));
    ///
    pub const Enum = blk: {
        var fields: [JsApis.len]std.builtin.Type.EnumField = undefined;
        for (JsApis, 0..) |JsApi, i| {
            fields[i] = .{ .name = @typeName(JsApi), .value = i };
        }

        break :blk @Type(.{
            .@"enum" = .{
                .fields = &fields,
                .tag_type = BackingInt,
                .is_exhaustive = true,
                .decls = &.{},
            },
        });
    };

    /// Returns a boolean indicating if a type exist in the lookup.
    pub inline fn has(t: type) bool {
        return @hasField(Enum, @typeName(t));
    }

    /// Returns the `Enum` for the given type.
    pub inline fn getIndex(t: type) Enum {
        return @field(Enum, @typeName(t));
    }

    /// Returns the ID for the given type.
    pub inline fn getId(t: type) BackingInt {
        return @intFromEnum(getIndex(t));
    }
};

pub const SubType = enum {
    @"error",
    array,
    arraybuffer,
    dataview,
    date,
    generator,
    iterator,
    map,
    node,
    promise,
    proxy,
    regexp,
    set,
    typedarray,
    wasmvalue,
    weakmap,
    weakset,
    webassemblymemory,
};

// APIs for Page/Window contexts. Used by Snapshot.zig for Page snapshot creation.
pub const PageJsApis = flattenTypes(&.{
    @import("../webapi/AbortController.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/CData.zig"),
    @import("../webapi/cdata/Comment.zig"),
    @import("../webapi/cdata/Text.zig"),
    @import("../webapi/cdata/CDATASection.zig"),
    @import("../webapi/cdata/ProcessingInstruction.zig"),
    @import("../webapi/collections.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/Permissions.zig"),
    @import("../webapi/StorageManager.zig"),
    @import("../webapi/CSS.zig"),
    @import("../webapi/css/CSSRule.zig"),
    @import("../webapi/css/CSSRuleList.zig"),
    @import("../webapi/css/CSSStyleDeclaration.zig"),
    @import("../webapi/css/CSSStyleRule.zig"),
    @import("../webapi/css/CSSStyleSheet.zig"),
    @import("../webapi/css/CSSStyleProperties.zig"),
    @import("../webapi/css/FontFace.zig"),
    @import("../webapi/css/FontFaceSet.zig"),
    @import("../webapi/css/MediaQueryList.zig"),
    @import("../webapi/css/StyleSheetList.zig"),
    @import("../webapi/Document.zig"),
    @import("../webapi/HTMLDocument.zig"),
    @import("../webapi/XMLDocument.zig"),
    @import("../webapi/History.zig"),
    @import("../webapi/KeyValueList.zig"),
    @import("../webapi/DocumentFragment.zig"),
    @import("../webapi/DocumentType.zig"),
    @import("../webapi/ShadowRoot.zig"),
    @import("../webapi/DOMException.zig"),
    @import("../webapi/DOMImplementation.zig"),
    @import("../webapi/DOMTreeWalker.zig"),
    @import("../webapi/DOMNodeIterator.zig"),
    @import("../webapi/DOMRect.zig"),
    @import("../webapi/DOMMatrixReadOnly.zig"),
    @import("../webapi/DOMMatrix.zig"),
    @import("../webapi/DOMParser.zig"),
    @import("../webapi/XMLSerializer.zig"),
    @import("../webapi/AbstractRange.zig"),
    @import("../webapi/Range.zig"),
    @import("../webapi/StaticRange.zig"),
    @import("../webapi/NodeFilter.zig"),
    @import("../webapi/Element.zig"),
    @import("../webapi/element/DOMStringMap.zig"),
    @import("../webapi/element/Attribute.zig"),
    @import("../webapi/element/Html.zig"),
    @import("../webapi/element/html/IFrame.zig"),
    @import("../webapi/element/html/Anchor.zig"),
    @import("../webapi/element/html/Area.zig"),
    @import("../webapi/element/html/Audio.zig"),
    @import("../webapi/element/html/Base.zig"),
    @import("../webapi/element/html/Body.zig"),
    @import("../webapi/element/html/BR.zig"),
    @import("../webapi/element/html/Button.zig"),
    @import("../webapi/element/html/Canvas.zig"),
    @import("../webapi/element/html/Custom.zig"),
    @import("../webapi/element/html/Data.zig"),
    @import("../webapi/element/html/DataList.zig"),
    @import("../webapi/element/html/Details.zig"),
    @import("../webapi/element/html/Dialog.zig"),
    @import("../webapi/element/html/Directory.zig"),
    @import("../webapi/element/html/DList.zig"),
    @import("../webapi/element/html/Div.zig"),
    @import("../webapi/element/html/Embed.zig"),
    @import("../webapi/element/html/FieldSet.zig"),
    @import("../webapi/element/html/Font.zig"),
    @import("../webapi/element/html/FrameSet.zig"),
    @import("../webapi/element/html/Form.zig"),
    @import("../webapi/element/html/Generic.zig"),
    @import("../webapi/element/html/Head.zig"),
    @import("../webapi/element/html/Heading.zig"),
    @import("../webapi/element/html/HR.zig"),
    @import("../webapi/element/html/Html.zig"),
    @import("../webapi/element/html/Image.zig"),
    @import("../webapi/element/html/Input.zig"),
    @import("../webapi/element/html/Label.zig"),
    @import("../webapi/element/html/Legend.zig"),
    @import("../webapi/element/html/LI.zig"),
    @import("../webapi/element/html/Link.zig"),
    @import("../webapi/element/html/Map.zig"),
    @import("../webapi/element/html/Marquee.zig"),
    @import("../webapi/element/html/Media.zig"),
    @import("../webapi/element/html/Meta.zig"),
    @import("../webapi/element/html/Meter.zig"),
    @import("../webapi/element/html/Mod.zig"),
    @import("../webapi/element/html/Object.zig"),
    @import("../webapi/element/html/OL.zig"),
    @import("../webapi/element/html/OptGroup.zig"),
    @import("../webapi/element/html/Option.zig"),
    @import("../webapi/element/html/Output.zig"),
    @import("../webapi/element/html/Paragraph.zig"),
    @import("../webapi/element/html/Picture.zig"),
    @import("../webapi/element/html/Param.zig"),
    @import("../webapi/element/html/Pre.zig"),
    @import("../webapi/element/html/Progress.zig"),
    @import("../webapi/element/html/Quote.zig"),
    @import("../webapi/element/html/Script.zig"),
    @import("../webapi/element/html/Select.zig"),
    @import("../webapi/element/html/Slot.zig"),
    @import("../webapi/element/html/Source.zig"),
    @import("../webapi/element/html/Span.zig"),
    @import("../webapi/element/html/Style.zig"),
    @import("../webapi/element/html/Table.zig"),
    @import("../webapi/element/html/TableCaption.zig"),
    @import("../webapi/element/html/TableCell.zig"),
    @import("../webapi/element/html/TableCol.zig"),
    @import("../webapi/element/html/TableRow.zig"),
    @import("../webapi/element/html/TableSection.zig"),
    @import("../webapi/element/html/Template.zig"),
    @import("../webapi/element/html/TextArea.zig"),
    @import("../webapi/element/html/Time.zig"),
    @import("../webapi/element/html/Title.zig"),
    @import("../webapi/element/html/Track.zig"),
    @import("../webapi/element/html/Video.zig"),
    @import("../webapi/element/html/UL.zig"),
    @import("../webapi/element/html/Unknown.zig"),
    @import("../webapi/element/html/ValidityState.zig"),
    @import("../webapi/element/Svg.zig"),
    @import("../webapi/element/svg/Generic.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/encoding/TextEncoderStream.zig"),
    @import("../webapi/encoding/TextDecoderStream.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/CompositionEvent.zig"),
    @import("../webapi/event/CustomEvent.zig"),
    @import("../webapi/event/ErrorEvent.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ProgressEvent.zig"),
    @import("../webapi/event/NavigationCurrentEntryChangeEvent.zig"),
    @import("../webapi/event/PageTransitionEvent.zig"),
    @import("../webapi/event/PopStateEvent.zig"),
    @import("../webapi/event/UIEvent.zig"),
    @import("../webapi/event/MouseEvent.zig"),
    @import("../webapi/event/PointerEvent.zig"),
    @import("../webapi/event/KeyboardEvent.zig"),
    @import("../webapi/event/FocusEvent.zig"),
    @import("../webapi/event/WheelEvent.zig"),
    @import("../webapi/event/DragEvent.zig"),
    @import("../webapi/event/TextEvent.zig"),
    @import("../webapi/event/InputEvent.zig"),
    @import("../webapi/event/PromiseRejectionEvent.zig"),
    @import("../webapi/event/SubmitEvent.zig"),
    @import("../webapi/event/FormDataEvent.zig"),
    @import("../webapi/event/ToggleEvent.zig"),
    @import("../webapi/MessageChannel.zig"),
    @import("../webapi/MessagePort.zig"),
    @import("../webapi/Worker.zig"),
    @import("../webapi/media/MediaError.zig"),
    @import("../webapi/media/TextTrackCue.zig"),
    @import("../webapi/media/VTTCue.zig"),
    @import("../webapi/animation/Animation.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Location.zig"),
    @import("../webapi/ModelContext.zig"),
    @import("../webapi/Navigator.zig"),
    @import("../webapi/NavigatorUAData.zig"),
    @import("../webapi/Notification.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/net/XMLHttpRequestUpload.zig"),
    @import("../webapi/net/WebSocket.zig"),
    @import("../webapi/event/CloseEvent.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/streams/WritableStream.zig"),
    @import("../webapi/streams/WritableStreamDefaultWriter.zig"),
    @import("../webapi/streams/WritableStreamDefaultController.zig"),
    @import("../webapi/streams/TransformStream.zig"),
    @import("../webapi/Node.zig"),
    @import("../webapi/storage/storage.zig"),
    @import("../webapi/storage/CookieStore.zig"),
    @import("../webapi/event/CookieChangeEvent.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/Window.zig"),
    @import("../webapi/Performance.zig"),
    @import("../webapi/EventCounts.zig"),
    @import("../webapi/PluginArray.zig"),
    @import("../webapi/MutationObserver.zig"),
    @import("../webapi/IntersectionObserver.zig"),
    @import("../webapi/CustomElementRegistry.zig"),
    @import("../webapi/ResizeObserver.zig"),
    @import("../webapi/IdleDeadline.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/FileList.zig"),
    @import("../webapi/FileReader.zig"),
    @import("../webapi/DataTransfer.zig"),
    @import("../webapi/Screen.zig"),
    @import("../webapi/VisualViewport.zig"),
    @import("../webapi/PerformanceObserver.zig"),
    @import("../webapi/navigation/Navigation.zig"),
    @import("../webapi/navigation/NavigationHistoryEntry.zig"),
    @import("../webapi/navigation/NavigationActivation.zig"),
    @import("../webapi/canvas/CanvasRenderingContext2D.zig"),
    @import("../webapi/canvas/WebGLRenderingContext.zig"),
    @import("../webapi/canvas/OffscreenCanvas.zig"),
    @import("../webapi/canvas/OffscreenCanvasRenderingContext2D.zig"),
    @import("../webapi/SubtleCrypto.zig"),
    @import("../webapi/CryptoKey.zig"),
    @import("../webapi/Selection.zig"),
    @import("../webapi/ImageData.zig"),
    @import("../webapi/XPathResult.zig"),
    @import("../webapi/XPathExpression.zig"),
    @import("../webapi/XPathEvaluator.zig"),
    @import("../webapi/BroadcastChannel.zig"),
});

// APIs available on Worker context globals (constructors like URL, Headers, etc.)
// This is a subset of PageJsApis plus WorkerGlobalScope.
// TODO: Expand this list to include all worker-appropriate APIs.
pub const WorkerJsApis = flattenTypes(&.{
    @import("../webapi/WorkerGlobalScope.zig"),
    @import("../webapi/WorkerLocation.zig"),
    @import("../webapi/EventTarget.zig"),
    @import("../webapi/Event.zig"),
    @import("../webapi/event/MessageEvent.zig"),
    @import("../webapi/event/ErrorEvent.zig"),
    @import("../webapi/event/PromiseRejectionEvent.zig"),
    @import("../webapi/event/CloseEvent.zig"),
    @import("../webapi/DOMException.zig"),
    @import("../webapi/DOMMatrixReadOnly.zig"),
    @import("../webapi/DOMMatrix.zig"),
    @import("../webapi/net/URLSearchParams.zig"),
    @import("../webapi/encoding/TextEncoder.zig"),
    @import("../webapi/encoding/TextDecoder.zig"),
    @import("../webapi/Blob.zig"),
    @import("../webapi/File.zig"),
    @import("../webapi/Console.zig"),
    @import("../webapi/Crypto.zig"),
    @import("../webapi/SubtleCrypto.zig"),
    @import("../webapi/CryptoKey.zig"),
    @import("../webapi/net/FormData.zig"),
    @import("../webapi/net/Headers.zig"),
    @import("../webapi/net/Request.zig"),
    @import("../webapi/net/Response.zig"),
    @import("../webapi/streams/TransformStream.zig"),
    @import("../webapi/streams/ReadableStream.zig"),
    @import("../webapi/streams/ReadableStreamDefaultReader.zig"),
    @import("../webapi/streams/ReadableStreamDefaultController.zig"),
    @import("../webapi/streams/WritableStream.zig"),
    @import("../webapi/streams/WritableStreamDefaultWriter.zig"),
    @import("../webapi/streams/WritableStreamDefaultController.zig"),
    @import("../webapi/encoding/TextEncoderStream.zig"),
    @import("../webapi/encoding/TextDecoderStream.zig"),
    @import("../webapi/AbortSignal.zig"),
    @import("../webapi/AbortController.zig"),
    @import("../webapi/URL.zig"),
    @import("../webapi/canvas/OffscreenCanvas.zig"),
    @import("../webapi/canvas/OffscreenCanvasRenderingContext2D.zig"),
    @import("../webapi/net/XMLHttpRequest.zig"),
    @import("../webapi/net/XMLHttpRequestEventTarget.zig"),
    @import("../webapi/net/XMLHttpRequestUpload.zig"),
    @import("../webapi/net/WebSocket.zig"),
    @import("../webapi/FileReader.zig"),
    @import("../webapi/ImageData.zig"),
    @import("../webapi/Performance.zig"),
    @import("../webapi/PerformanceObserver.zig"),
    @import("../webapi/storage/CookieStore.zig"),
    @import("../webapi/event/CookieChangeEvent.zig"),
    @import("../webapi/Navigator.zig"),
    @import("../webapi/NavigatorUAData.zig"),
    @import("../webapi/Permissions.zig"),
    @import("../webapi/StorageManager.zig"),
    @import("../webapi/BroadcastChannel.zig"),
});

// Master list of ALL JS APIs across all contexts.
// Used by Env (class IDs, templates), JsApiLookup, and anywhere that needs
// to know about all possible types. Individual snapshots use their own
// subsets (PageJsApis, WorkerSnapshot.JsApis).
pub const JsApis = blk: {
    const base = PageJsApis ++ [_]type{
        @import("../webapi/WorkerGlobalScope.zig").JsApi,
        @import("../webapi/WorkerLocation.zig").JsApi,
    };
    if (lp.build_config.wpt_extensions == false) {
        break :blk base;
    }
    break :blk base ++ [_]type{@import("../webapi/WebDriver.zig").JsApi};
};
