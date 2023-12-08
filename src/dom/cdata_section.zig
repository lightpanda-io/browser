const std = @import("std");

const parser = @import("../netsurf.zig");

const Text = @import("text.zig").Text;

// https://dom.spec.whatwg.org/#cdatasection
pub const CDATASection = struct {
    pub const Self = parser.CDATASection;
    pub const prototype = *Text;
    pub const mem_guarantied = true;
};
