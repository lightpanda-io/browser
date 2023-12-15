const std = @import("std");

const parser = @import("../netsurf.zig");

// https://dom.spec.whatwg.org/#interface-window-extensions
// https://html.spec.whatwg.org/multipage/nav-history-apis.html#window
pub const Window = struct {
    pub const mem_guarantied = true;

    document: *parser.Document,
    target: []const u8,

    pub fn create(doc: *parser.Document, target: ?[]const u8) Window {
        return Window{
            .document = doc,
            .target = target orelse "",
        };
    }

    pub fn get_window(self: *Window) *parser.Document {
        return self;
    }

    pub fn get_self(self: *Window) *parser.Document {
        return self;
    }

    pub fn get_parent(self: *Window) *parser.Document {
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
