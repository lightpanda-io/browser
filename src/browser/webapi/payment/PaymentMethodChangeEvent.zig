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
const PaymentRequestUpdateEvent = @import("PaymentRequestUpdateEvent.zig");

const String = lp.String;

// https://w3c.github.io/payment-request/#paymentmethodchangeevent-interface
const PaymentMethodChangeEvent = @This();

pub const Proto = PaymentRequestUpdateEvent;

_proto: *PaymentRequestUpdateEvent,
_method_name: []const u8,
_method_details: ?js.Object.Global,

const PaymentMethodChangeEventOptions = struct {
    methodDetails: ?js.Object.Global = null,
    methodName: []const u8 = "",
};

const Options = Event.inheritOptions(PaymentMethodChangeEvent, PaymentMethodChangeEventOptions);

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*PaymentMethodChangeEvent {
    const arena = try page.getArena(.tiny, "PaymentMethodChangeEvent");
    errdefer arena.release();
    const type_string = try String.init(arena.allocator(), typ, .{});

    const opts = opts_ orelse Options{};
    const event = try page.factory.eventWithParent(
        PaymentRequestUpdateEvent,
        arena,
        type_string,
        PaymentMethodChangeEvent{
            ._proto = undefined,
            ._method_name = try arena.dupe(u8, opts.methodName),
            ._method_details = opts.methodDetails,
        },
    );

    Event.populatePrototypes(event, opts, false);
    return event;
}

pub fn deinit(self: *PaymentMethodChangeEvent, _: *Page) void {
    if (self._method_details) |d| {
        d.release();
    }
}

pub fn asEvent(self: *PaymentMethodChangeEvent) *Event {
    return self._proto.asEvent();
}

fn getMethodName(self: *const PaymentMethodChangeEvent) []const u8 {
    return self._method_name;
}

fn getMethodDetails(self: *const PaymentMethodChangeEvent) ?js.Object.Global {
    return self._method_details;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PaymentMethodChangeEvent);

    pub const Meta = struct {
        pub const name = "PaymentMethodChangeEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PaymentMethodChangeEvent.init, .{});
    pub const methodName = bridge.accessor(getMethodName, null, .{});
    pub const methodDetails = bridge.accessor(getMethodDetails, null, .{});
};
