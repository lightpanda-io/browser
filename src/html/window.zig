const std = @import("std");

const parser = @import("../netsurf.zig");

// https://dom.spec.whatwg.org/#interface-window-extensions
// https://html.spec.whatwg.org/multipage/nav-history-apis.html#window
pub const Window = struct {
    pub const mem_guarantied = true;

    document: *parser.Document = undefined,
    target: []const u8,

    pub fn create(target: ?[]const u8) Window {
        return Window{
            .target = target orelse "",
        };
    }

    pub fn replaceDocument(self: *Window, doc: *parser.Document) void {
        self.document = doc;
    }

    pub fn get_window(self: *Window) *Window {
        return self;
    }

    pub fn get_self(self: *Window) *Window {
        return self;
    }

    pub fn get_parent(self: *Window) *Window {
        return self;
    }

    pub fn get_document(self: *Window) *parser.Document {
        return self.document;
    }

    pub fn get_name(self: *Window) []const u8 {
        return self.target;
    }

    // TODO we need to re-implement EventTarget interface.
};
