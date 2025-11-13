const std = @import("std");

pub fn parseDimension(value: []const u8) ?f64 {
    if (value.len == 0) {
        return null;
    }

    var num_str = value;
    if (std.mem.endsWith(u8, value, "px")) {
        num_str = value[0 .. value.len - 2];
    }

    return std.fmt.parseFloat(f64, num_str) catch null;
}
