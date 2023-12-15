const generate = @import("../generate.zig");

const Window = @import("window.zig");

pub const Interfaces = generate.Tuple(.{
    Window,
});
