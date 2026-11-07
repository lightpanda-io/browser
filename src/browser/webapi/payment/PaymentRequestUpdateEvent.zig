// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");

const Event = @import("../Event.zig");

const String = lp.String;

// https://w3c.github.io/payment-request/#paymentrequestupdateevent-interface
const PaymentRequestUpdateEvent = @This();

pub const Proto = Event;

_type: Type,
_proto: *Event,

pub const Type = union(enum) {
    generic,
    payment_method_change_event: *@import("PaymentMethodChangeEvent.zig"),
};

pub const Options = Event.inheritOptions(PaymentRequestUpdateEvent, struct {});

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*PaymentRequestUpdateEvent {
    const arena = try page.getArena(.tiny, "PaymentRequestUpdateEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const event = try page.factory.event(
        arena,
        type_string,
        PaymentRequestUpdateEvent{
            ._type = .generic,
            ._proto = undefined,
        },
    );

    Event.populatePrototypes(event, opts_ orelse Options{}, false);
    return event;
}

pub fn is(self: *PaymentRequestUpdateEvent, comptime T: type) ?*T {
    switch (self._type) {
        .generic => return if (T == PaymentRequestUpdateEvent) self else null,
        .payment_method_change_event => |e| return if (T == @import("PaymentMethodChangeEvent.zig")) e else null,
    }
}

pub fn asEvent(self: *PaymentRequestUpdateEvent) *Event {
    return self._proto;
}

// Only a trusted event can; there's no payment UI to dispatch one.
fn updateWith(_: *PaymentRequestUpdateEvent, _: js.Value) !void {
    return error.InvalidStateError;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PaymentRequestUpdateEvent);

    pub const Meta = struct {
        pub const name = "PaymentRequestUpdateEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PaymentRequestUpdateEvent.init, .{});
    pub const updateWith = bridge.function(PaymentRequestUpdateEvent.updateWith, .{});
};
