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

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const URL = @import("../../URL.zig");
const Page = @import("../../Page.zig");

const EventTarget = @import("../EventTarget.zig");

const Execution = js.Execution;

// https://w3c.github.io/payment-request/#paymentrequest-interface
//
// Behaves like Chrome with no payment app installed, which sends checkout
// pages to their card-form fallback.
const PaymentRequest = @This();

pub const Proto = EventTarget;

_rc: lp.RC = .{},
_arena: *lp.Arena,
_proto: *EventTarget,
_id: []const u8,
// The spec's "interactive" state is never entered: show() closes at once.
_closed: bool = false,
_shipping_option: ?[]const u8 = null,
_shipping_type: ?ShippingType = null,

const ShippingType = enum {
    shipping,
    delivery,
    pickup,
    pub const js_enum_from_string = true;
};

const PaymentCurrencyAmount = struct {
    currency: []const u8,
    value: []const u8,
};

const PaymentItem = struct {
    amount: PaymentCurrencyAmount,
    label: []const u8,
};

const PaymentShippingOption = struct {
    amount: PaymentCurrencyAmount,
    id: []const u8,
    label: []const u8,
    selected: bool = false,
};

const PaymentMethodData = struct {
    supportedMethods: []const u8,
};

const PaymentDetailsModifier = struct {
    additionalDisplayItems: ?[]const PaymentItem = null,
    supportedMethods: []const u8,
    total: ?PaymentItem = null,
};

const PaymentDetailsInit = struct {
    displayItems: ?[]const PaymentItem = null,
    id: ?[]const u8 = null,
    modifiers: ?[]const PaymentDetailsModifier = null,
    shippingOptions: ?[]const PaymentShippingOption = null,
    total: PaymentItem,
};

const PaymentOptions = struct {
    requestShipping: bool = false,
    shippingType: ShippingType = .shipping,
};

pub fn init(
    method_data: []const PaymentMethodData,
    details: PaymentDetailsInit,
    options_: ?PaymentOptions,
    exec: *const Execution,
) !*PaymentRequest {
    // Chrome's order decides which error a multiply-invalid request throws.
    if (details.id) |id| {
        try validateLength(id, exec);
    }

    if (method_data.len == 0) {
        return exec.js.typeError("At least one payment method is required");
    }
    try validateListLength(method_data.len, exec);
    for (method_data, 0..) |md, i| {
        try validateMethod(md.supportedMethods, exec);
        for (method_data[0..i]) |prev| {
            if (std.mem.eql(u8, prev.supportedMethods, md.supportedMethods)) {
                return error.RangeError;
            }
        }
    }

    try validateTotal(details.total, exec);
    try validateItems(details.displayItems orelse &.{}, exec);

    const options = options_ orelse PaymentOptions{};
    var selected_shipping: ?[]const u8 = null;
    if (options.requestShipping) {
        const shipping_options = details.shippingOptions orelse &.{};
        try validateListLength(shipping_options.len, exec);
        for (shipping_options, 0..) |opt, i| {
            try validateItem(opt.label, opt.amount, exec);
            try validateLength(opt.id, exec);
            for (shipping_options[0..i]) |prev| {
                if (std.mem.eql(u8, prev.id, opt.id)) {
                    return exec.js.typeError("Cannot have duplicate shipping option identifiers");
                }
            }
            if (opt.selected) {
                selected_shipping = opt.id;
            }
        }
    }

    const modifiers = details.modifiers orelse &.{};
    try validateListLength(modifiers.len, exec);
    for (modifiers) |modifier| {
        if (modifier.total) |total| {
            try validateTotal(total, exec);
        }
        try validateItems(modifier.additionalDisplayItems orelse &.{}, exec);
        try validateMethod(modifier.supportedMethods, exec);
    }

    const arena = try exec.getArena(.tiny, "PaymentRequest");
    errdefer arena.release();

    const id = if (details.id) |id| try arena.dupe(u8, id) else blk: {
        const uuid = try arena.alloc(u8, 36);
        @import("../../../id.zig").uuidv4(uuid);
        break :blk uuid;
    };

    return exec._factory.eventTargetWithAllocator(arena.allocator(), PaymentRequest{
        ._arena = arena,
        ._proto = undefined,
        ._id = id,
        ._shipping_option = if (selected_shipping) |s| try arena.dupe(u8, s) else null,
        ._shipping_type = if (options.requestShipping) options.shippingType else null,
    });
}

pub fn deinit(self: *PaymentRequest, page: *Page) void {
    page.removeTarget(self._proto);
    self._arena.release();
}

pub fn releaseRef(self: *PaymentRequest, page: *Page) void {
    self._rc.release(self, page);
}

pub fn acquireRef(self: *PaymentRequest) void {
    self._rc.acquire();
}

pub fn asEventTarget(self: *PaymentRequest) *EventTarget {
    return self._proto;
}

// Chrome's caps.
const max_string_length = 1024;
const max_list_length = 1024;

fn validateLength(s: []const u8, exec: *const Execution) !void {
    if (s.len > max_string_length) {
        return exec.js.typeError(std.fmt.comptimePrint("Value cannot be longer than {d} characters", .{max_string_length}));
    }
}

fn validateListLength(len: usize, exec: *const Execution) !void {
    if (len > max_list_length) {
        return exec.js.typeError(std.fmt.comptimePrint("At most {d} entries allowed", .{max_list_length}));
    }
}

// Chrome's IsValidMethodFormat, laxer than the spec: plain http is allowed on
// a loopback host.
fn validateMethod(pmi: []const u8, exec: *const Execution) !void {
    if (isStandardizedMethod(pmi)) {
        return;
    }
    const href = URL.resolve(exec.call_arena, "", pmi, .{}) catch return error.RangeError;
    if (URL.getUsername(href).len > 0 or URL.getPassword(href).len > 0) {
        return error.RangeError;
    }
    if (std.mem.startsWith(u8, href, "https:")) {
        return;
    }
    if (std.mem.startsWith(u8, href, "http:") and URL.isLoopbackHost(URL.getHostname(href))) {
        return;
    }
    return error.RangeError;
}

// [a-z]+[0-9a-z]*(-[a-z]+[0-9a-z]*)*
fn isStandardizedMethod(pmi: []const u8) bool {
    var it = std.mem.splitScalar(u8, pmi, '-');
    while (it.next()) |part| {
        if (part.len == 0 or !std.ascii.isLower(part[0])) {
            return false;
        }
        for (part) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c)) {
                return false;
            }
        }
    }
    return true;
}

fn validateTotal(total: PaymentItem, exec: *const Execution) !void {
    try validateItem(total.label, total.amount, exec);
    if (total.amount.value[0] == '-') {
        return exec.js.typeError("Total amount value should be non-negative");
    }
}

fn validateItems(items: []const PaymentItem, exec: *const Execution) !void {
    try validateListLength(items.len, exec);
    for (items) |item| {
        try validateItem(item.label, item.amount, exec);
    }
}

// https://w3c.github.io/payment-request/#validity-checkers
fn validateItem(label: []const u8, amount: PaymentCurrencyAmount, exec: *const Execution) !void {
    try validateLength(label, exec);
    try validateLength(amount.currency, exec);
    try validateLength(amount.value, exec);

    if (amount.currency.len != 3) {
        return error.RangeError;
    }
    for (amount.currency) |c| {
        if (!std.ascii.isAlphabetic(c)) {
            return error.RangeError;
        }
    }
    if (!isValidDecimalMonetaryValue(amount.value)) {
        return exec.js.typeError("Invalid amount value");
    }
}

// -?[0-9]+(\.[0-9]+)?
fn isValidDecimalMonetaryValue(value: []const u8) bool {
    const unsigned = if (value.len > 0 and value[0] == '-') value[1..] else value;
    const dot = std.mem.indexOfScalar(u8, unsigned, '.');
    const integer = unsigned[0 .. dot orelse unsigned.len];
    const fraction: []const u8 = if (dot) |d| unsigned[d + 1 ..] else "0";
    return isDigits(integer) and isDigits(fraction);
}

fn isDigits(s: []const u8) bool {
    if (s.len == 0) {
        return false;
    }
    for (s) |c| {
        if (!std.ascii.isDigit(c)) {
            return false;
        }
    }
    return true;
}

pub fn show(self: *PaymentRequest, _: ?js.Value) !js.Promise {
    if (self._closed) {
        return error.InvalidStateError;
    }
    self._closed = true;
    return error.NotSupported;
}

// Only an interactive request can be aborted, and none ever is.
pub fn abort(_: *PaymentRequest) !js.Promise {
    return error.InvalidStateError;
}

pub fn canMakePayment(self: *PaymentRequest, exec: *const Execution) !js.Promise {
    if (self._closed) {
        return error.InvalidStateError;
    }
    return exec.js.local.?.resolvePromise(false);
}

// Dropped from the spec; Chrome still ships it.
pub fn hasEnrolledInstrument(self: *PaymentRequest, exec: *const Execution) !js.Promise {
    return self.canMakePayment(exec);
}

fn getId(self: *const PaymentRequest) []const u8 {
    return self._id;
}

fn getShippingAddress(_: *const PaymentRequest) ?js.Object {
    return null;
}

fn getShippingOption(self: *const PaymentRequest) ?[]const u8 {
    return self._shipping_option;
}

fn getShippingType(self: *const PaymentRequest) ?[]const u8 {
    const shipping_type = self._shipping_type orelse return null;
    return @tagName(shipping_type);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PaymentRequest);

    pub const Meta = struct {
        pub const name = "PaymentRequest";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(PaymentRequest.init, .{});

    pub const show = bridge.function(PaymentRequest.show, .{});
    pub const abort = bridge.function(PaymentRequest.abort, .{});
    pub const canMakePayment = bridge.function(PaymentRequest.canMakePayment, .{});
    pub const hasEnrolledInstrument = bridge.function(PaymentRequest.hasEnrolledInstrument, .{});

    pub const id = bridge.accessor(getId, null, .{});
    pub const shippingAddress = bridge.accessor(getShippingAddress, null, .{});
    pub const shippingOption = bridge.accessor(getShippingOption, null, .{});
    pub const shippingType = bridge.accessor(getShippingType, null, .{});

    pub const onshippingaddresschange = EventTarget.handlerAccessor(PaymentRequest, "shippingaddresschange");
    pub const onshippingoptionchange = EventTarget.handlerAccessor(PaymentRequest, "shippingoptionchange");
    pub const onpaymentmethodchange = EventTarget.handlerAccessor(PaymentRequest, "paymentmethodchange");
};

const testing = @import("../../../testing.zig");
test "WebApi: PaymentRequest" {
    try testing.htmlRunner("payment_request.html", .{});
}
