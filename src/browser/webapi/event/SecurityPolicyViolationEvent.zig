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

// We don't enforce CSP, so this is never dispatched; it exists so scripts
// can construct one (consent managers probe its isTrusted getter).
// https://w3c.github.io/webappsec-csp/#violation-events
const SecurityPolicyViolationEvent = @This();

pub const Proto = Event;

_proto: *Event,
_document_uri: []const u8,
_referrer: []const u8,
_blocked_uri: []const u8,
_violated_directive: []const u8,
_effective_directive: []const u8,
_original_policy: []const u8,
_source_file: []const u8,
_sample: []const u8,
_disposition: Disposition,
_status_code: u16,
_line_number: u32,
_column_number: u32,

const Disposition = enum {
    enforce,
    report,

    pub const js_enum_from_string = true;

    pub fn toString(self: Disposition) []const u8 {
        return @tagName(self);
    }
};

const SecurityPolicyViolationEventOptions = struct {
    blockedURI: []const u8 = "",
    columnNumber: u32 = 0,
    disposition: Disposition = .enforce,
    documentURI: []const u8 = "",
    effectiveDirective: []const u8 = "",
    lineNumber: u32 = 0,
    originalPolicy: []const u8 = "",
    referrer: []const u8 = "",
    sample: []const u8 = "",
    sourceFile: []const u8 = "",
    statusCode: u16 = 0,
    violatedDirective: []const u8 = "",
};

const Options = Event.inheritOptions(SecurityPolicyViolationEvent, SecurityPolicyViolationEventOptions);

fn init(typ: []const u8, opts_: ?Options, page: *Page) !*SecurityPolicyViolationEvent {
    const opts = opts_ orelse Options{};
    const arena = try page.getArena(.tiny, "SecurityPolicyViolationEvent");
    errdefer arena.release();
    const allocator = arena.allocator();

    const event = try page.factory.event(
        arena,
        try String.init(allocator, typ, .{}),
        SecurityPolicyViolationEvent{
            ._proto = undefined,
            ._document_uri = try allocator.dupe(u8, opts.documentURI),
            ._referrer = try allocator.dupe(u8, opts.referrer),
            ._blocked_uri = try allocator.dupe(u8, opts.blockedURI),
            ._violated_directive = try allocator.dupe(u8, opts.violatedDirective),
            ._effective_directive = try allocator.dupe(u8, opts.effectiveDirective),
            ._original_policy = try allocator.dupe(u8, opts.originalPolicy),
            ._source_file = try allocator.dupe(u8, opts.sourceFile),
            ._sample = try allocator.dupe(u8, opts.sample),
            ._disposition = opts.disposition,
            ._status_code = opts.statusCode,
            ._line_number = opts.lineNumber,
            ._column_number = opts.columnNumber,
        },
    );

    // Chrome ignores the init's bubbles/cancelable/composed (Firefox honors them).
    var forced = opts;
    forced.bubbles = true;
    forced.cancelable = false;
    forced.composed = true;
    Event.populatePrototypes(event, forced, false);
    return event;
}

pub fn asEvent(self: *SecurityPolicyViolationEvent) *Event {
    return self._proto;
}

fn getDocumentURI(self: *const SecurityPolicyViolationEvent) []const u8 {
    return self._document_uri;
}

fn getReferrer(self: *const SecurityPolicyViolationEvent) []const u8 {
    return self._referrer;
}

fn getBlockedURI(self: *const SecurityPolicyViolationEvent) []const u8 {
    return self._blocked_uri;
}

fn getViolatedDirective(self: *const SecurityPolicyViolationEvent) []const u8 {
    return self._violated_directive;
}

fn getEffectiveDirective(self: *const SecurityPolicyViolationEvent) []const u8 {
    return self._effective_directive;
}

fn getOriginalPolicy(self: *const SecurityPolicyViolationEvent) []const u8 {
    return self._original_policy;
}

fn getSourceFile(self: *const SecurityPolicyViolationEvent) []const u8 {
    return self._source_file;
}

fn getSample(self: *const SecurityPolicyViolationEvent) []const u8 {
    return self._sample;
}

fn getDisposition(self: *const SecurityPolicyViolationEvent) Disposition {
    return self._disposition;
}

fn getStatusCode(self: *const SecurityPolicyViolationEvent) u16 {
    return self._status_code;
}

fn getLineNumber(self: *const SecurityPolicyViolationEvent) u32 {
    return self._line_number;
}

fn getColumnNumber(self: *const SecurityPolicyViolationEvent) u32 {
    return self._column_number;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(SecurityPolicyViolationEvent);

    pub const Meta = struct {
        pub const name = "SecurityPolicyViolationEvent";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(SecurityPolicyViolationEvent.init, .{});
    pub const documentURI = bridge.accessor(SecurityPolicyViolationEvent.getDocumentURI, null, .{});
    pub const referrer = bridge.accessor(SecurityPolicyViolationEvent.getReferrer, null, .{});
    pub const blockedURI = bridge.accessor(SecurityPolicyViolationEvent.getBlockedURI, null, .{});
    pub const violatedDirective = bridge.accessor(SecurityPolicyViolationEvent.getViolatedDirective, null, .{});
    pub const effectiveDirective = bridge.accessor(SecurityPolicyViolationEvent.getEffectiveDirective, null, .{});
    pub const originalPolicy = bridge.accessor(SecurityPolicyViolationEvent.getOriginalPolicy, null, .{});
    pub const sourceFile = bridge.accessor(SecurityPolicyViolationEvent.getSourceFile, null, .{});
    pub const sample = bridge.accessor(SecurityPolicyViolationEvent.getSample, null, .{});
    pub const disposition = bridge.accessor(SecurityPolicyViolationEvent.getDisposition, null, .{});
    pub const statusCode = bridge.accessor(SecurityPolicyViolationEvent.getStatusCode, null, .{});
    pub const lineNumber = bridge.accessor(SecurityPolicyViolationEvent.getLineNumber, null, .{});
    pub const columnNumber = bridge.accessor(SecurityPolicyViolationEvent.getColumnNumber, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: SecurityPolicyViolationEvent" {
    try testing.htmlRunner("event/security_policy_violation.html", .{});
}
