pub const PopupSource = enum(u8) {
    none,
    anchor,
    form,
    script,

    pub fn label(self: PopupSource) []const u8 {
        return switch (self) {
            .none => "",
            .anchor => "anchor",
            .form => "form",
            .script => "script",
        };
    }
};
