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
const Frame = @import("../../Frame.zig");
const Session = @import("../../Session.zig");
const Notification = @import("../../../Notification.zig");

const Cookie = @import("Cookie.zig");
const EventTarget = @import("../EventTarget.zig");
const CookieChangeEvent = @import("../event/CookieChangeEvent.zig");

const Allocator = std.mem.Allocator;
const Execution = js.Execution;
const String = lp.String;

pub fn registerTypes() []const type {
    return &.{ CookieStore, CookieListItem };
}

// https://developer.mozilla.org/en-US/docs/Web/API/CookieStore
const CookieStore = @This();

_proto: *EventTarget,
_on_change: ?js.Function.Global = null,
_exec: ?*Execution = null,

pub fn asEventTarget(self: *CookieStore) *EventTarget {
    return self._proto;
}

/// Registers this CookieStore as a listener for jar-change notifications on
/// the given execution's session. Must be called once after construction by
/// the owning global (Window today; WorkerGlobalScope once wired up).
/// Idempotent on re-call.
pub fn attach(self: *CookieStore, exec: *Execution) !void {
    if (self._exec != null) return;
    self._exec = exec;
    try exec.session.notification.register(.cookie_changed, self, onCookieChanged);
}

/// Removes this CookieStore from the notification list.
pub fn detach(self: *CookieStore) void {
    const exec = self._exec orelse return;
    exec.session.notification.unregisterAll(self);
    self._exec = null;
}

fn onCookieChanged(ctx: *anyopaque, data: *const Notification.CookieChanged) !void {
    const self: *CookieStore = @ptrCast(@alignCast(ctx));
    const exec = self._exec orelse return;

    // CookieStore exposes only cookies that script would see for the
    // current document — same filter as `match` (HttpOnly hidden,
    // same-site treated as first-party against the document URL).
    const doc_url = exec.url.*;
    const target = Cookie.PreparedUri{
        .host = URL.getHostname(doc_url),
        .path = URL.getPathname(doc_url),
        .secure = URL.isHTTPS(doc_url),
    };
    if (target.host.len == 0) return;

    const probe = Cookie{
        .arena = undefined,
        .name = data.name,
        .value = data.value,
        .domain = data.domain,
        .path = data.path,
        .expires = null,
        .secure = data.secure,
        .http_only = data.http_only,
        .same_site = data.same_site,
    };
    if (!probe.appliesTo(&target, true, true, false)) return;

    // Per spec, `change` is dispatched as a queued task — never synchronously
    // from the mutation site. We snapshot the notification fields onto a
    // small page arena that the scheduled callback releases after dispatch.
    const arena = try exec.getArena(.tiny, "CookieStore.change");
    errdefer exec.releaseArena(arena);

    const cb = try arena.create(ChangeCallback);
    cb.* = .{
        .cookie_store = self,
        .exec = exec,
        .arena = arena,
        .kind = data.kind,
        .name = try arena.dupe(u8, data.name),
        .value = try arena.dupe(u8, data.value),
        .domain = try arena.dupe(u8, data.domain),
        .path = try arena.dupe(u8, data.path),
        .secure = data.secure,
        .same_site = data.same_site,
    };

    try exec.js.scheduler.add(cb, ChangeCallback.run, 0, .{
        .name = "CookieStore.change",
        .low_priority = false,
        .finalizer = ChangeCallback.cancelled,
    });
}

const ChangeCallback = struct {
    cookie_store: *CookieStore,
    // Execution is stored only to ensure we can release the arena.
    // The CookieStore could have been detached in the meantime, and so its
    // _exec pointer could have been reset.
    exec: *Execution,
    arena: Allocator,
    kind: Notification.CookieChanged.Kind,
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    secure: bool,
    same_site: Cookie.SameSite,

    fn cancelled(ctx: *anyopaque) void {
        const self: *ChangeCallback = @ptrCast(@alignCast(ctx));
        self.releaseArena();
    }

    fn releaseArena(self: *ChangeCallback) void {
        self.exec.releaseArena(self.arena);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *ChangeCallback = @ptrCast(@alignCast(ctx));
        defer self.releaseArena();

        const cs = self.cookie_store;
        // We use the CookieStore's exec here instead of self.exec to detect if
        // the store has been detached. In this case, we don't dispatch the
        // event.
        const exec = cs._exec orelse return null;
        const target = cs.asEventTarget();

        // Skip event construction when nobody is listening.
        if (!exec.hasDirectListeners(target, "change", cs._on_change)) {
            return null;
        }

        const event = try CookieChangeEvent.initSingle(self.kind, .{
            .kind = self.kind,
            .name = self.name,
            .value = self.value,
            .domain = self.domain,
            .path = self.path,
            .secure = self.secure,
            .http_only = false,
            .same_site = self.same_site,
        }, exec);

        try exec.dispatch(target, event.asEvent(), cs._on_change, .{
            .context = "CookieStore.change",
        });

        return null;
    }
};

pub fn getOnChange(self: *const CookieStore) ?js.Function.Global {
    return self._on_change;
}

pub fn setOnChange(self: *CookieStore, setter: ?FunctionSetter) void {
    const s = setter orelse {
        self._on_change = null;
        return;
    };
    self._on_change = switch (s) {
        .func => |f| f,
        .anything => null,
    };
}

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

// https://developer.mozilla.org/en-US/docs/Web/API/CookieStore/get
const GetOptions = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

const GetInput = union(enum) {
    name: []const u8,
    options: GetOptions,
};

// https://developer.mozilla.org/en-US/docs/Web/API/CookieStore/set
const CookieInit = struct {
    name: []const u8,
    value: []const u8,
    expires: ?f64 = null,
    domain: ?[]const u8 = null,
    path: []const u8 = "/",
    sameSite: SameSite = .strict,
    partitioned: bool = false,
};

const SetInput = union(enum) {
    name: []const u8,
    options: CookieInit,
};

// https://developer.mozilla.org/en-US/docs/Web/API/CookieStore/delete
const DeleteOptions = struct {
    name: []const u8,
    domain: ?[]const u8 = null,
    path: []const u8 = "/",
    partitioned: bool = false,
};

const DeleteInput = union(enum) {
    name: []const u8,
    options: DeleteOptions,
};

const SameSite = enum {
    strict,
    lax,
    none,
    pub const js_enum_from_string = true;
};

pub fn get(_: *CookieStore, input: GetInput, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const name: ?[]const u8, const url: ?[]const u8 = switch (input) {
        .name => |n| .{ n, null },
        .options => |o| .{ o.name, o.url },
    };

    const items = matchCookies(exec, name, url, true) catch |err| {
        return local.rejectPromise(.{ .type_error = @errorName(err) });
    };

    if (items.len == 0) {
        return local.resolvePromise(@as(?*CookieListItem, null));
    }
    return local.resolvePromise(items[0]);
}

pub fn getAll(_: *CookieStore, input: ?GetInput, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const name: ?[]const u8, const url: ?[]const u8 = if (input) |inp| switch (inp) {
        .name => |n| .{ n, null },
        .options => |o| .{ o.name, o.url },
    } else .{ null, null };

    const items = matchCookies(exec, name, url, false) catch |err| {
        return local.rejectPromise(.{ .type_error = @errorName(err) });
    };
    return local.resolvePromise(items);
}

pub fn set(_: *CookieStore, input: SetInput, value: ?[]const u8, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const init: CookieInit = switch (input) {
        .options => |o| o,
        .name => |n| .{
            .name = n,
            .value = value orelse return local.rejectPromise(.{ .type_error = "value is required" }),
        },
    };

    storeCookie(exec, init) catch |err| {
        return local.rejectPromise(.{ .type_error = @errorName(err) });
    };

    return local.resolvePromise({});
}

pub fn delete(_: *CookieStore, input: DeleteInput, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const opts: DeleteOptions = switch (input) {
        .options => |o| o,
        .name => |n| .{ .name = n },
    };

    // Deletion per spec is an expired set: write a cookie with the same
    // name/path/domain but with Expires in the past, and the Jar will drop
    // any existing match (or no-op if none).
    storeCookie(exec, .{
        .name = opts.name,
        .value = "",
        .expires = 0,
        .domain = opts.domain,
        .path = opts.path,
        .sameSite = .strict,
        .partitioned = opts.partitioned,
    }) catch |err| {
        return local.rejectPromise(.{ .type_error = @errorName(err) });
    };

    return local.resolvePromise({});
}

// Resolve the optional `url` per CookieStore.get/getAll spec. In a Window
// context, only the document's own URL is allowed (matches the cookie scope
// script already sees). In a Worker context, any same-origin URL is allowed.
fn resolveQueryUrl(exec: *const Execution, _override: ?[]const u8) ![:0]const u8 {
    const current = exec.url.*;
    const override = _override orelse return current;

    const resolved = try URL.resolve(exec.call_arena, exec.base(), override, .{ .always_dupe = true });
    if (!exec.isSameOrigin(resolved)) return error.SecurityError;

    switch (exec.js.global) {
        .frame => {
            if (!std.mem.eql(u8, resolved, current)) return error.InvalidUrl;
        },
        .worker => {},
    }
    return resolved;
}

fn matchCookies(
    exec: *const Execution,
    name: ?[]const u8,
    url: ?[]const u8,
    first_only: bool,
) ![]*CookieListItem {
    const session = exec.session;
    const url_resolved = try resolveQueryUrl(exec, url);

    const target = Cookie.PreparedUri{
        .host = URL.getHostname(url_resolved),
        .path = URL.getPathname(url_resolved),
        .secure = URL.isHTTPS(url_resolved),
    };
    if (target.host.len == 0) return error.SecurityError;

    session.cookie_jar.removeExpired(null);

    var items: std.ArrayList(*CookieListItem) = .empty;
    for (session.cookie_jar.cookies.items) |*cookie| {
        // CookieStore exposes only cookies that script would see for the
        // current document. HttpOnly cookies stay hidden.
        if (!cookie.appliesTo(&target, true, true, false)) continue;
        if (name) |n| {
            if (!std.mem.eql(u8, cookie.name, n)) continue;
        }

        const item = try exec.arena.create(CookieListItem);
        item.* = .{
            .name = String.wrap(cookie.name),
            .value = String.wrap(cookie.value),
            .domain = if (cookie.domain.len > 0 and cookie.domain[0] == '.')
                String.wrap(cookie.domain[1..])
            else
                null,
            .path = String.wrap(cookie.path),
            .expires = if (cookie.expires) |e| e * 1000.0 else null,
            .secure = cookie.secure,
            .sameSite = switch (cookie.same_site) {
                .strict => .strict,
                .lax => .lax,
                .none => .none,
            },
            .partitioned = false,
        };
        try items.append(exec.call_arena, item);
        if (first_only) break;
    }

    return items.items;
}

fn storeCookie(exec: *const Execution, init: CookieInit) !void {
    const session = exec.session;
    const url = exec.url.*;

    // Reject inputs the cookie model can't represent. `=` is allowed in
    // values but not in names; `;`/CR/LF/NUL break the cookie wire format
    // everywhere and so are forbidden in every field.
    if (init.name.len == 0) return error.InvalidCookieName;
    if (std.mem.indexOfAny(u8, init.name, "=;\r\n\x00") != null) return error.InvalidCookieName;
    if (std.mem.indexOfAny(u8, init.value, ";\r\n\x00") != null) return error.InvalidCookieValue;
    if (std.mem.indexOfAny(u8, init.path, ";\r\n\x00") != null) return error.InvalidCookiePath;
    if (init.domain) |d| {
        if (std.mem.indexOfAny(u8, d, ";\r\n\x00") != null) return error.InvalidCookieDomain;
    }

    const is_https = URL.isHTTPS(url);
    // Per spec, SameSite=None requires Secure. CookieStore additionally
    // marks any cookie written from an HTTPS document as Secure.
    const secure = is_https or init.sameSite == .none;

    // Cookie-name-prefix rules — match Cookie.parse, case-insensitive to
    // catch impersonation attempts (e.g. "__HoSt-").
    // https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-cookie-name-prefixes
    if (std.ascii.startsWithIgnoreCase(init.name, "__Host-")) {
        if (!is_https) return error.InvalidPrefixedCookie;
        if (init.domain) |d| {
            if (d.len > 0) return error.InvalidPrefixedCookie;
        }
        const effective_path = if (init.path.len > 0) init.path else "/";
        if (!std.mem.eql(u8, effective_path, "/")) return error.InvalidPrefixedCookie;
    } else if (std.ascii.startsWithIgnoreCase(init.name, "__Secure-")) {
        if (!is_https) return error.InvalidPrefixedCookie;
    }

    var arena = std.heap.ArenaAllocator.init(session.cookie_jar.allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const owned_name = try aa.dupe(u8, init.name);
    const owned_value = try aa.dupe(u8, init.value);
    const owned_path = try Cookie.parsePath(aa, url, init.path);
    const owned_domain = try Cookie.parseDomain(aa, url, init.domain);

    const cookie: Cookie = .{
        .arena = arena,
        .name = owned_name,
        .value = owned_value,
        .path = owned_path,
        .domain = owned_domain,

        // CookieStore.expires is a unix timestamp in milliseconds; Cookie tracks
        // expiry in seconds. A timestamp at or before "now" deletes the cookie via
        // the Jar's expiry path.
        .expires = if (init.expires) |ms| ms / 1000.0 else null,

        .secure = secure,
        .http_only = false,
        .same_site = switch (init.sameSite) {
            .strict => .strict,
            .lax => .lax,
            .none => .none,
        },
    };

    // CookieStore is a script API, so is_http = false.
    try session.cookie_jar.add(cookie, std.time.timestamp(), false);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CookieStore);

    pub const Meta = struct {
        pub const name = "CookieStore";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const get = bridge.function(CookieStore.get, .{ .dom_exception = true });
    pub const getAll = bridge.function(CookieStore.getAll, .{ .dom_exception = true });
    pub const set = bridge.function(CookieStore.set, .{ .dom_exception = true });
    pub const delete = bridge.function(CookieStore.delete, .{ .dom_exception = true });
    pub const onchange = bridge.accessor(CookieStore.getOnChange, CookieStore.setOnChange, .{});
};

// CookieListItem: per CookieStore.get / getAll return shape, documented inline on
// https://developer.mozilla.org/en-US/docs/Web/API/CookieStore
pub const CookieListItem = struct {
    name: String,
    value: String,
    domain: ?String,
    path: String,
    expires: ?f64,
    secure: bool,
    sameSite: SameSite,
    partitioned: bool,

    fn getName(self: *const CookieListItem) String {
        return self.name;
    }
    fn getValue(self: *const CookieListItem) String {
        return self.value;
    }
    fn getDomain(self: *const CookieListItem) ?String {
        return self.domain;
    }
    fn getPath(self: *const CookieListItem) String {
        return self.path;
    }
    fn getExpires(self: *const CookieListItem) ?f64 {
        return self.expires;
    }
    fn getSecure(self: *const CookieListItem) bool {
        return self.secure;
    }
    fn getSameSite(self: *const CookieListItem) []const u8 {
        return @tagName(self.sameSite);
    }
    fn getPartitioned(self: *const CookieListItem) bool {
        return self.partitioned;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CookieListItem);
        pub const Meta = struct {
            pub const name = "CookieListItem";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(CookieListItem.getName, null, .{});
        pub const value = bridge.accessor(CookieListItem.getValue, null, .{});
        pub const domain = bridge.accessor(CookieListItem.getDomain, null, .{});
        pub const path = bridge.accessor(CookieListItem.getPath, null, .{});
        pub const expires = bridge.accessor(CookieListItem.getExpires, null, .{});
        pub const secure = bridge.accessor(CookieListItem.getSecure, null, .{});
        pub const sameSite = bridge.accessor(CookieListItem.getSameSite, null, .{});
        pub const partitioned = bridge.accessor(CookieListItem.getPartitioned, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: CookieStore" {
    try testing.htmlRunner("cookie_store.html", .{});
}
