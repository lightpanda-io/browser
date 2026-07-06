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
const Notification = @import("../../../Notification.zig");

const Cookie = @import("Cookie.zig");
const EventTarget = @import("../EventTarget.zig");
const CookieChangeEvent = @import("../event/CookieChangeEvent.zig");

const Allocator = std.mem.Allocator;
const Execution = js.Execution;
const String = lp.String;

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
    const target = Cookie.PreparedUri.init(doc_url);
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
        return local.resolvePromise(@as(?CookieListItem, null));
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

    storeCookie(exec, init, false) catch |err| {
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
    }, true) catch |err| {
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

    const resolved = try URL.resolve(exec.call_arena, exec.base(), override, .{});
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
) ![]CookieListItem {
    const session = exec.session;
    const url_resolved = try resolveQueryUrl(exec, url);

    const target = Cookie.PreparedUri{
        .host = URL.getHostname(url_resolved),
        .path = URL.getPathname(url_resolved),
        .secure = URL.isSecure(url_resolved),
    };
    if (target.host.len == 0) return error.SecurityError;

    session.cookie_jar.removeExpired(null);

    var items: std.ArrayList(CookieListItem) = .empty;
    for (session.cookie_jar.cookies.items) |*cookie| {
        // CookieStore exposes only cookies that script would see for the
        // current document. HttpOnly cookies stay hidden.
        if (!cookie.appliesTo(&target, true, true, false)) continue;
        if (name) |n| {
            if (!std.mem.eql(u8, cookie.name, n)) continue;
        }

        try items.append(exec.call_arena, .{
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
                .strict => "strict",
                .lax => "lax",
                .none => "none",
            },
            .partitioned = false,
        });
        if (first_only) break;
    }

    return items.items;
}

fn storeCookie(exec: *const Execution, init_: CookieInit, is_delete: bool) !void {
    const session = exec.session;
    const url = exec.url.*;

    var init = init_;

    init.name = std.mem.trim(u8, init.name, " \t");
    init.value = std.mem.trim(u8, init.value, " \t");

    // delete() may legitimately target a nameless cookie — its value is always empty.
    if (!is_delete and init.name.len == 0) {
        if (init.value.len == 0) {
            return error.InvalidCookieName;
        }
        if (std.mem.indexOfScalar(u8, init.value, '=') != null) {
            return error.InvalidCookieName;
        }
    }

    // Reject inputs the cookie model can't represent. `=` is allowed in
    // values but not in names; `;` and the control characters (U+0000–U+001F,
    // U+007F) break the cookie wire format and so are forbidden in both.
    if (std.mem.indexOfScalar(u8, init.name, '=') != null) {
        return error.InvalidCookieName;
    }
    if (hasForbiddenChar(init.name)) {
        return error.InvalidCookieName;
    }
    if (hasForbiddenChar(init.value)) {
        return error.InvalidCookieValue;
    }

    // A path attribute, when given, must be absolute. The Cookie path/domain
    // attribute values are also capped at 1024 bytes per spec.
    // https://cookiestore.spec.whatwg.org/#cookie-maximum-attribute-value-size
    if (init.path.len > 0 and init.path[0] != '/') {
        return error.InvalidCookiePath;
    }
    if (init.path.len > 1024) {
        return error.InvalidCookiePath;
    }
    if (std.mem.indexOfAny(u8, init.path, ";\r\n\x00") != null) {
        return error.InvalidCookiePath;
    }
    if (init.domain) |d| {
        // CookieStore (unlike the HTTP cookie syntax) rejects a leading dot.
        if (d.len > 0 and d[0] == '.') {
            return error.InvalidCookieDomain;
        }
        if (d.len > 1024) {
            return error.InvalidCookieDomain;
        }
        if (std.mem.indexOfAny(u8, d, ";\r\n\x00") != null) {
            return error.InvalidCookieDomain;
        }
    }

    const is_https = URL.isSecure(url);
    // Per spec, SameSite=None requires Secure. CookieStore additionally
    // marks any cookie written from an HTTPS document as Secure.
    const secure = is_https or init.sameSite == .none;

    // The `__Http-` and `__Host-Http-` prefixes are reserved for HTTP-state
    // cookies; the (script) CookieStore API can never set them, on any origin.
    if (std.ascii.startsWithIgnoreCase(init.name, "__Http-") or std.ascii.startsWithIgnoreCase(init.name, "__Host-Http-")) {
        return error.InvalidPrefixedCookie;
    }

    // Cookie-name-prefix rules — match Cookie.parse, case-insensitive to
    // catch impersonation attempts (e.g. "__HoSt-").
    // https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis#name-cookie-name-prefixes
    if (std.ascii.startsWithIgnoreCase(init.name, "__Host-")) {
        if (!is_https) {
            return error.InvalidPrefixedCookie;
        }
        if (init.domain) |d| {
            if (d.len > 0) {
                return error.InvalidPrefixedCookie;
            }
        }
        const effective_path = if (init.path.len > 0) init.path else "/";
        if (!std.mem.eql(u8, effective_path, "/")) {
            return error.InvalidPrefixedCookie;
        }
    } else if (std.ascii.startsWithIgnoreCase(init.name, "__Secure-")) {
        if (!is_https) {
            return error.InvalidPrefixedCookie;
        }
    }

    // The errdefer only protects construction failures. Once we `break :blk`
    // with the Cookie value, `Jar.add` owns its lifetime.
    const cookie: Cookie = blk: {
        var arena = std.heap.ArenaAllocator.init(session.cookie_jar.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const owned_name = try aa.dupe(u8, init.name);
        const owned_value = try aa.dupe(u8, init.value);
        const owned_path = try Cookie.parsePath(aa, url, init.path);
        const owned_domain = try Cookie.parseDomain(aa, url, init.domain);

        break :blk .{
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
    };

    // CookieStore is a script API, so is_http = false.
    try session.cookie_jar.add(cookie, std.time.timestamp(), false);
}

// Control characters (U+0000–U+001F and U+007F DEL) and `;` cannot appear in
// a cookie name or value. The whitespace chars TAB and SPACE are trimmed
// before this check, so the surviving controls are all genuinely invalid.
fn hasForbiddenChar(s: []const u8) bool {
    for (s) |c| {
        if (c <= 0x1F or c == 0x7F or c == ';') {
            return true;
        }
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CookieStore);

    pub const Meta = struct {
        pub const name = "CookieStore";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const get = bridge.function(CookieStore.get, .{});
    pub const getAll = bridge.function(CookieStore.getAll, .{});
    pub const set = bridge.function(CookieStore.set, .{});
    pub const delete = bridge.function(CookieStore.delete, .{});
    pub const onchange = bridge.accessor(CookieStore.getOnChange, CookieStore.setOnChange, .{});
};

// CookieListItem is an plain JavaScript object, not an interface. The bridge
// automatically translate a Zig struct -> JS Object This should _not_ have a
// JsApi.
pub const CookieListItem = struct {
    name: String,
    // Optional because a deletion change-event reports the removed cookie with
    // `value` omitted (serialized as undefined via the `deleted` accessor's
    // null_as_undefined). For get/getAll and `changed` items it is always set.
    value: ?String,
    domain: ?String,
    path: String,
    expires: ?f64,
    secure: bool,
    sameSite: []const u8,
    partitioned: bool,
};

const testing = @import("../../../testing.zig");
test "WebApi: CookieStore" {
    try testing.htmlRunner("cookie_store.html", .{});
}
