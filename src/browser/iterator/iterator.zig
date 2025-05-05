pub const Interfaces = .{
    U32Iterator,
};

pub const U32Iterator = struct {
    length: u32,
    index: u32 = 0,

    pub const Return = struct {
        value: u32,
        done: bool,
    };

    pub fn _next(self: *U32Iterator) Return {
        const i = self.index;
        if (i >= self.length) {
            return .{
                .value = 0,
                .done = true,
            };
        }

        self.index = i + 1;
        return .{
            .value = i,
            .done = false,
        };
    }

    // Iterators should be iterable. There's a [JS] example on MDN that
    // suggests this is the correct approach:
    // https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Iteration_protocols#the_iterator_protocol
    pub fn _symbol_iterator(self: *U32Iterator) *U32Iterator {
        return self;
    }
};

// A wrapper around an iterator that emits an Iterable result
// An iterable has a next() which emits a {done: bool, value: T} result
pub fn Iterable(comptime T: type, comptime JsName: []const u8) type {
    // The inner iterator's return type.
    // Maybe an error union.
    // Definitely an optional
    const RawValue = @typeInfo(@TypeOf(T._next)).@"fn".return_type.?;
    const CanError = @typeInfo(RawValue) == .error_union;

    const Value = blk: {
        // Unwrap the RawValue
        var V = RawValue;
        if (CanError) {
            V = @typeInfo(V).error_union.payload;
        }
        break :blk @typeInfo(V).optional.child;
    };

    const Result = struct {
        done: bool,
        // todo, technically, we should return undefined when done = true
        // or even omit the value;
        value: ?Value,
    };

    const ReturnType = if (CanError) T.Error!Result else Result;

    return struct {
        // the inner value iterator
        inner: T,

        // Generics don't generate clean names. Can't just take the resulting
        // type name and use that as a the JS class name. So we always ask for
        // an explicit JS class name
        pub const js_name = JsName;

        const Self = @This();

        pub fn init(inner: T) Self {
            return .{ .inner = inner };
        }

        pub fn _next(self: *Self) ReturnType {
            const value = if (comptime CanError) try self.inner._next() else self.inner._next();
            return .{ .done = value == null, .value = value };
        }

        pub fn _symbol_iterator(self: *Self) *Self {
            return self;
        }
    };
}

// A wrapper around an iterator that emits integer/index keyed entries.
pub fn NumericEntries(comptime T: type, comptime JsName: []const u8) type {
    // The inner iterator's return type.
    // Maybe an error union.
    // Definitely an optional
    const RawValue = @typeInfo(@TypeOf(T._next)).@"fn".return_type.?;
    const CanError = @typeInfo(RawValue) == .error_union;

    const Value = blk: {
        // Unwrap the RawValue
        var V = RawValue;
        if (CanError) {
            V = @typeInfo(V).error_union.payload;
        }
        break :blk @typeInfo(V).optional.child;
    };

    const ReturnType = if (CanError) T.Error!?struct { u32, Value } else ?struct { u32, Value };

    // Avoid ambiguity. We want to expose a NumericEntries(T).Iterable, so we
    // need a declartion inside here for an "Iterable", but that will conflict
    // with the above Iterable generic function we have.
    const BaseIterable = Iterable;

    return struct {
        // the inner value iterator
        inner: T,
        index: u32,

        const Self = @This();

        // Generics don't generate clean names. Can't just take the resulting
        // type name and use that as a the JS class name. So we always ask for
        // an explicit JS class name
        pub const js_name = JsName;

        // re-exposed for when/if we compose this type into an Iterable
        pub const Error = T.Error;

        // This iterator as an iterable
        pub const Iterable = BaseIterable(Self, JsName ++ "Iterable");

        pub fn init(inner: T) Self {
            return .{ .inner = inner, .index = 0 };
        }

        pub fn _next(self: *Self) ReturnType {
            const value_ = if (comptime CanError) try self.inner._next() else self.inner._next();
            const value = value_ orelse return null;

            const index = self.index;
            self.index = index + 1;
            return .{ index, value };
        }

        // make the iterator, iterable
        pub fn _symbol_iterator(self: *Self) Self.Iterable {
            return Self.Iterable.init(self.*);
        }
    };
}

const testing = @import("../../testing.zig");
test "U32Iterator" {
    {
        var it = U32Iterator{ .length = 0 };
        try testing.expectEqual(.{ .value = 0, .done = true }, it._next());
        try testing.expectEqual(.{ .value = 0, .done = true }, it._next());
    }

    {
        var it = U32Iterator{ .length = 3 };
        try testing.expectEqual(.{ .value = 0, .done = false }, it._next());
        try testing.expectEqual(.{ .value = 1, .done = false }, it._next());
        try testing.expectEqual(.{ .value = 2, .done = false }, it._next());
        try testing.expectEqual(.{ .value = 0, .done = true }, it._next());
        try testing.expectEqual(.{ .value = 0, .done = true }, it._next());
    }
}

test "NumericEntries" {
    const it = DummyIterator{};
    var entries = NumericEntries(DummyIterator, "DummyIterator").init(it);

    const v1 = entries._next().?;
    try testing.expectEqual(0, v1.@"0");
    try testing.expectEqual("it's", v1.@"1");

    const v2 = entries._next().?;
    try testing.expectEqual(1, v2.@"0");
    try testing.expectEqual("over", v2.@"1");

    const v3 = entries._next().?;
    try testing.expectEqual(2, v3.@"0");
    try testing.expectEqual("9000!!", v3.@"1");

    try testing.expectEqual(null, entries._next());
    try testing.expectEqual(null, entries._next());
    try testing.expectEqual(null, entries._next());
}

test "Iterable" {
    const it = DummyIterator{};
    var entries = Iterable(DummyIterator, "DummyIterator").init(it);

    const v1 = entries._next();
    try testing.expectEqual(false, v1.done);
    try testing.expectEqual("it's", v1.value.?);

    const v2 = entries._next();
    try testing.expectEqual(false, v2.done);
    try testing.expectEqual("over", v2.value.?);

    const v3 = entries._next();
    try testing.expectEqual(false, v3.done);
    try testing.expectEqual("9000!!", v3.value.?);

    try testing.expectEqual(true, entries._next().done);
    try testing.expectEqual(true, entries._next().done);
    try testing.expectEqual(true, entries._next().done);
}

const DummyIterator = struct {
    index: u32 = 0,

    pub fn _next(self: *DummyIterator) ?[]const u8 {
        const index = self.index;
        self.index = index + 1;
        return switch (index) {
            0 => "it's",
            1 => "over",
            2 => "9000!!",
            else => null,
        };
    }
};
