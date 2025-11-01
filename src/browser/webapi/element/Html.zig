const js = @import("../../js/js.zig");
const reflect = @import("../../reflect.zig");

const Node = @import("../Node.zig");
const Element = @import("../Element.zig");

pub const BR = @import("html/BR.zig");
pub const HR = @import("html/HR.zig");
pub const LI = @import("html/LI.zig");
pub const OL = @import("html/OL.zig");
pub const UL = @import("html/UL.zig");
pub const Div = @import("html/Div.zig");
pub const Html = @import("html/Html.zig");
pub const Head = @import("html/Head.zig");
pub const Meta = @import("html/Meta.zig");
pub const Body = @import("html/Body.zig");
pub const Link = @import("html/Link.zig");
pub const Image = @import("html/Image.zig");
pub const Input = @import("html/Input.zig");
pub const Title = @import("html/Title.zig");
pub const Style = @import("html/Style.zig");
pub const Custom = @import("html/Custom.zig");
pub const Script = @import("html/Script.zig");
pub const Anchor = @import("html/Anchor.zig");
pub const Button = @import("html/Button.zig");
pub const Form = @import("html/Form.zig");
pub const Heading = @import("html/Heading.zig");
pub const Unknown = @import("html/Unknown.zig");
pub const Generic = @import("html/Generic.zig");
pub const TextArea = @import("html/TextArea.zig");
pub const Paragraph = @import("html/Paragraph.zig");
pub const Select = @import("html/Select.zig");
pub const Option = @import("html/Option.zig");

const HtmlElement = @This();

_type: Type,
_proto: *Element,

pub const Type = union(enum) {
    anchor: Anchor,
    body: Body,
    br: BR,
    button: Button,
    custom: *Custom,
    div: Div,
    form: Form,
    generic: *Generic,
    heading: *Heading,
    head: Head,
    html: Html,
    hr: HR,
    img: Image,
    input: *Input,
    li: LI,
    link: Link,
    meta: Meta,
    ol: OL,
    option: *Option,
    p: Paragraph,
    script: *Script,
    select: Select,
    style: Style,
    text_area: *TextArea,
    title: Title,
    ul: UL,
    unknown: *Unknown,
};

pub fn is(self: *HtmlElement, comptime T: type) ?*T {
    inline for (@typeInfo(Type).@"union".fields) |f| {
        if (@field(Type, f.name) == self._type) {
            if (f.type == T) {
                return &@field(self._type, f.name);
            }
            if (f.type == *T) {
                return @field(self._type, f.name);
            }
        }
    }
    return null;
}

pub fn className(self: *const HtmlElement) []const u8 {
    return switch (self._type) {
        .anchor => "[object HtmlAnchorElement]",
        .div => "[object HtmlDivElement]",
        .form => "[object HTMLFormElement]",
        .p => "[object HtmlParagraphElement]",
        .custom => "[object CUSTOM-TODO]",
        .img => "[object HTMLImageElement]",
        .br => "[object HTMLBRElement]",
        .button => "[object HTMLButtonElement]",
        .heading => "[object HTMLHeadingElement]",
        .li => "[object HTMLLIElement]",
        .ul => "[object HTMLULElement]",
        .ol => "[object HTMLOLElement]",
        .generic => "[object HTMLElement]",
        .script => "[object HtmlScriptElement]",
        .select => "[object HTMLSelectElement]",
        .option => "[object HTMLOptionElement]",
        .text_area => "[object HtmlTextAreaElement]",
        .input => "[object HtmlInputElement]",
        .link => "[object HtmlLinkElement]",
        .meta => "[object HtmlMetaElement]",
        .hr => "[object HtmlHRElement]",
        .style => "[object HtmlSyleElement]",
        .title => "[object HtmlTitleElement]",
        .body => "[object HtmlBodyElement]",
        .html => "[object HtmlHtmlElement]",
        .head => "[object HtmlHeadElement]",
        .unknown => "[object HtmlUnknownElement]",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HtmlElement);

    pub const Meta = struct {
        pub const name = "HTMLElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the HtmlElement itself.
    pub fn call(self: *const HtmlElement, comptime func_name: []const u8, args: anytype) !bool {
        inline for (@typeInfo(HtmlElement.Type).@"union".fields) |f| {
            if (@field(HtmlElement.Type, f.name) == self._type) {
                // The inner type implements this function. Call it and we're done.
                const S = reflect.Struct(f.type);
                if (@hasDecl(S, "Build")) {
                    if (@hasDecl(S.Build, func_name)) {
                        try @call(.auto, @field(S.Build, func_name), args);
                        return true;
                    }
                }
            }
        }

        if (@hasDecl(HtmlElement.Build, func_name)) {
            // Our last resort - the node implements this function.
            try @call(.auto, @field(HtmlElement.Build, func_name), args);
            return true;
        }

        // inform our caller (the Element) that we didn't find anything that implemented
        // func_name and it should keep searching for a match.
        return false;
    }
};
