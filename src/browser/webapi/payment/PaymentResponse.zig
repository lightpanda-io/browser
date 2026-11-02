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

const js = @import("../../js/js.zig");

const EventTarget = @import("../EventTarget.zig");

// https://w3c.github.io/payment-request/#paymentresponse-interface
// Never created: show() never succeeds.
const PaymentResponse = @This();

pub const Proto = EventTarget;

_proto: *EventTarget,

pub const JsApi = struct {
    pub const bridge = js.Bridge(PaymentResponse);

    pub const Meta = struct {
        pub const name = "PaymentResponse";
        pub var class_id: bridge.ClassId = undefined;
    };
};
