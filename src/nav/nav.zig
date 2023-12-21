const generate = @import("../generate.zig");

const Window = @import("window.zig").Window;

pub const Interfaces = generate.Tuple(.{
    Window,
});
