const std = @import("std");
const js = @import("../../../js/js.zig");
const Page = @import("../../../Page.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const TreeWalker = @import("../../TreeWalker.zig");

const Input = @import("Input.zig");
const Button = @import("Button.zig");
const Select = @import("Select.zig");
const TextArea = @import("TextArea.zig");

const Form = @This();
_proto: *HtmlElement,

pub fn asElement(self: *Form) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Form) *Node {
    return self.asElement().asNode();
}

// Untested / unused right now. Iterates over all the controls of a form,
// including those outside the <form>...</form> but with a form=$FORM_ID attribute
pub const Iterator = struct {
    _form_id: ?[]const u8,
    _walkers: union(enum) {
        nested: TreeWalker.FullExcludeSelf,
        names: TreeWalker.FullExcludeSelf,
    },

    pub fn init(form: *Form) Iterator {
        const form_element = form.asElement();
        const form_id = form_element.getAttributeSafe("id");

        return .{
            ._form_id = form_id,
            ._walkers = .{
                .nested = TreeWalker.FullExcludeSelf.init(form.asNode(), .{}),
            },
        };
    }

    pub fn next(self: *Iterator) ?FormControl {
        switch (self._walkers) {
            .nested => |*tw| {
                // find controls nested directly in the form
                while (tw.next()) |node| {
                    const element = node.is(Element) orelse continue;
                    const control = asFormControl(element) orelse continue;
                    // Skip if it has a form attribute (will be handled in phase 2)
                    if (element.getAttributeSafe("form") == null) {
                        return control;
                    }
                }
                if (self._form_id == null) {
                    return null;
                }

                const doc = tw._root.getRootNode();
                self._walkers = .{
                    .names = TreeWalker.FullExcludeSelf(doc, .{}),
                };
                return self.next();
            },
            .names => |*tw| {
                // find controls with a name matching the form id
                while (tw.next()) |node| {
                    const input = node.is(Input) orelse continue;
                    if (input._type != .radio) {
                        continue;
                    }
                    const input_form = input.asElement().getAttributeSafe("form") orelse continue;
                    // must have a self._form_id, else we never would have transitioned
                    // from a nested walker to a namew walker
                    if (!std.mem.eql(u8, input_form, self._form_id.?)) {
                        continue;
                    }
                    return .{ .input = input };
                }

                return null;
            },
        }
    }
};

pub const FormControl = union(enum) {
    input: *Input,
    button: *Button,
    select: *Select,
    textarea: *TextArea,
};

fn asFormControl(element: *Element) ?FormControl {
    if (element._type != .html) {
        return null;
    }
    const html = element._type.html;
    switch (html._type) {
        .input => |cntrl| return .{ .input = cntrl },
        .button => |cntrl| return .{ .button = cntrl },
        .select => |cntrl| return .{ .select = cntrl },
        .textarea => |cntrl| return .{ .textarea = cntrl },
        else => return null,
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Form);
    pub const Meta = struct {
        pub const name = "HTMLFormElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_index: u16 = 0;
    };
};
