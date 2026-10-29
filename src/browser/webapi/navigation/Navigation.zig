// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const URL = @import("../URL.zig");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Factory = @import("../../Factory.zig");

const Event = @import("../Event.zig");
const Element = @import("../Element.zig");
const EventTarget = @import("../EventTarget.zig");
const AbortSignal = @import("../AbortSignal.zig");
const DOMException = @import("../DOMException.zig");
const FormData = @import("../net/FormData.zig");
const ErrorEvent = @import("../event/ErrorEvent.zig");
const NavigateEvent = @import("../event/NavigateEvent.zig");

const log = lp.log;

// https://developer.mozilla.org/en-US/docs/Web/API/Navigation
const Navigation = @This();

pub const Proto = EventTarget;

const NavigationType = @import("root.zig").NavigationType;
const NavigationKind = @import("root.zig").NavigationKind;
const NavigationActivation = @import("NavigationActivation.zig");
const NavigationTransition = @import("root.zig").NavigationTransition;
const NavigationState = @import("root.zig").NavigationState;
const OngoingNavigation = @import("root.zig").OngoingNavigation;

const NavigationHistoryEntry = @import("NavigationHistoryEntry.zig");
const NavigationDestination = @import("NavigationDestination.zig");
const NavigationCurrentEntryChangeEvent = @import("../event/NavigationCurrentEntryChangeEvent.zig");

_proto: *EventTarget,

_current_navigation_kind: ?NavigationKind = null,

_index: usize = 0,
// Need to be stable pointers, because Events can reference entries.
_entries: std.ArrayList(*NavigationHistoryEntry) = .empty,
_next_entry_id: usize = 0,
_activation: ?NavigationActivation = null,

// True right after createPage seeds the synthetic initial about:blank
// entry, and never otherwise. Per spec, the first real navigation away
// from that initial entry replaces it.
_initial_entry: bool = false,

pub fn asEventTarget(self: *Navigation) *EventTarget {
    return self._proto;
}

fn getActivation(self: *const Navigation) ?NavigationActivation {
    return self._activation;
}

fn getCanGoBack(self: *const Navigation) bool {
    return self._index > 0;
}

fn getCanGoForward(self: *const Navigation) bool {
    return self._entries.items.len > self._index + 1;
}

fn getCurrentEntryOrNull(self: *Navigation) ?*NavigationHistoryEntry {
    if (self._entries.items.len > self._index) {
        return self._entries.items[self._index];
    } else return null;
}

pub fn getCurrentEntry(self: *Navigation) *NavigationHistoryEntry {
    // This should never fail. An entry should always be created before
    // we run the scripts on the frame we are loading.
    const len = self._entries.items.len;
    lp.assert(len > 0, "Navigation.getCurrentEntry", .{ .len = len });

    return self.getCurrentEntryOrNull().?;
}

fn getTransition(_: *const Navigation) ?NavigationTransition {
    // For now, all transitions are just considered complete.
    return null;
}

const NavigationReturn = struct {
    committed: js.Promise.Global,
    finished: js.Promise.Global,
};

const NavigationOptions = struct {
    info: ?js.Value = null,
};

pub fn back(self: *Navigation, _opts: ?NavigationOptions, frame: *Frame) !NavigationReturn {
    if (!self.getCanGoBack()) {
        return error.InvalidStateError;
    }

    const new_index = self._index - 1;
    const next_entry = self._entries.items[new_index];

    const opts = _opts orelse NavigationOptions{};
    return self.navigateInner(next_entry._url, .{ .traverse = new_index }, .{ .info = opts.info }, frame);
}

pub fn entries(self: *const Navigation) []*NavigationHistoryEntry {
    return self._entries.items;
}

pub fn forward(self: *Navigation, _opts: ?NavigationOptions, frame: *Frame) !NavigationReturn {
    if (!self.getCanGoForward()) {
        return error.InvalidStateError;
    }

    const new_index = self._index + 1;
    const next_entry = self._entries.items[new_index];

    const opts = _opts orelse NavigationOptions{};
    return self.navigateInner(next_entry._url, .{ .traverse = new_index }, .{ .info = opts.info }, frame);
}

pub fn updateEntries(
    self: *Navigation,
    url: [:0]const u8,
    kind: NavigationKind,
    frame: *Frame,
    should_dispatch: bool,
) !void {
    switch (kind) {
        .replace => |state| {
            _ = try self.replaceEntry(
                url,
                .{ .source = .navigation, .value = state },
                frame,
                should_dispatch,
            );
        },
        .push => |state| {
            _ = try self.pushEntry(
                url,
                .{ .source = .navigation, .value = state },
                frame,
                should_dispatch,
            );
        },
        .traverse => |index| {
            self._index = index;
        },
        .reload => {},
    }
}

// This is for after true navigation processing, where we need to ensure that our entries are up to date.
//
// This is only really safe to run in the `frameDoneCallback`
// where we can guarantee that the URL and NavigationKind are correct.
pub fn commitNavigation(self: *Navigation, frame: *Frame) !void {
    const url = frame.url;

    var kind: NavigationKind = self._current_navigation_kind orelse .{ .push = null };
    defer self._current_navigation_kind = null;

    const from_entry = self.getCurrentEntryOrNull();
    const was_initial_entry = self._initial_entry;
    if (from_entry == null) {
        kind = .{ .push = null };
    } else if (was_initial_entry) {
        kind = .{ .replace = null };
    }
    self._initial_entry = false;

    try self.updateEntries(url, kind, frame, false);

    // A traversal or reload recreates the document of the entry it lands on:
    // the new frame takes over that document's id, so the other entries of
    // that document stay same-document with it.
    switch (kind) {
        .traverse, .reload => frame._history_document_id = self.getCurrentEntry()._document_id,
        .push, .replace => {},
    }

    self._activation = NavigationActivation{
        // If we are navigating away from the initial about:blank, we have no from.
        ._from = if (was_initial_entry) null else from_entry,
        ._entry = self.getCurrentEntry(),
        ._type = kind.toNavigationType(),
    };
}

/// Pushes an entry into the Navigation stack WITHOUT actually navigating to it.
/// For that, use `navigate`.
pub fn pushEntry(
    self: *Navigation,
    _url: [:0]const u8,
    state: NavigationState,
    frame: *Frame,
    should_dispatch: bool,
) !*NavigationHistoryEntry {
    const arena = frame._session.arena;
    const url = try arena.dupeSentinel(u8, _url, 0);

    // truncates our history here.
    const retained_index = self._index + 1;
    var disposed: []*NavigationHistoryEntry = &.{};
    if (self._entries.items.len > retained_index) {
        disposed = try frame.call_arena.dupe(
            *NavigationHistoryEntry,
            self._entries.items[retained_index..],
        );
        self._entries.shrinkRetainingCapacity(retained_index);
    }

    // Per spec, dispose fires last: after the entry list is updated and
    // currententrychange has been dispatched. These entries are already out
    // of _entries, so fire even if a later step fails, and don't let one
    // entry's failure skip the others.
    defer for (disposed) |d| {
        d.fireDispose(frame) catch |err| {
            log.debug(.event, "NavigationHistoryEntry.dispose", .{ .err = err });
        };
    };

    const index = self._entries.items.len;

    const id = self._next_entry_id;
    self._next_entry_id += 1;

    const id_str = try arena.allocator().print("{d}", .{id});

    const entry = try Factory.chainedWithAllocator(arena.allocator(), .{
        EventTarget{ ._type = .navigation_history_entry },
        NavigationHistoryEntry{
            ._proto = undefined,
            ._id = id_str,
            ._key = id_str,
            ._url = url,
            ._state = state,
            ._document_id = frame._history_document_id,
        },
    });

    // we don't always have a current entry...
    const previous = if (self._entries.items.len > 0) self.getCurrentEntry() else null;
    try self._entries.append(arena.allocator(), entry);
    self._index = index;

    if (should_dispatch) {
        if (previous) |p| {
            try self.fireCurrentEntryChangeEvent(p, .{ .push = state.value }, frame);
        }
    }

    return entry;
}

pub fn replaceEntry(
    self: *Navigation,
    _url: [:0]const u8,
    state: NavigationState,
    frame: *Frame,
    should_dispatch: bool,
) !*NavigationHistoryEntry {
    const arena = frame._session.arena;
    const url = try arena.dupeSentinel(u8, _url, 0);

    const previous = self.getCurrentEntry();

    const id = self._next_entry_id;
    self._next_entry_id += 1;
    const id_str = try arena.allocator().print("{d}", .{id});

    const entry = try Factory.chainedWithAllocator(arena.allocator(), .{
        EventTarget{ ._type = .navigation_history_entry },
        NavigationHistoryEntry{
            ._proto = undefined,
            ._id = id_str,
            ._key = previous._key,
            ._url = url,
            ._state = state,
            ._document_id = frame._history_document_id,
        },
    });

    const old_entry = self._entries.items[self._index];
    self._entries.items[self._index] = entry;

    // Per spec, dispose fires last, after currententrychange. old_entry is
    // already out of _entries, so fire even if the dispatch below fails.
    defer old_entry.fireDispose(frame) catch |err| {
        log.debug(.event, "NavigationHistoryEntry.dispose", .{ .err = err });
    };

    if (should_dispatch) {
        try self.fireCurrentEntryChangeEvent(previous, .{ .replace = state.value }, frame);
    }

    return entry;
}

pub const NavigateEventParams = struct {
    navigation_type: NavigationType,
    url: [:0]const u8,
    same_document: bool,
    // The entry a traversal goes to.
    entry: ?*NavigationHistoryEntry = null,
    // Serialized state given to navigation.navigate() or reload().
    state: ?[]const u8 = null,
    info: ?js.Value = null,
    source_element: ?*Element = null,
    // The entry list of a POST form submission.
    form_data: ?*FormData = null,
    user_initiated: bool = false,
    // pushState/replaceState: never a hashChange, even for a fragment-only URL.
    classic_history: bool = false,
    // The promises of a Navigation API method.
    committed: ?js.PromiseResolver = null,
    finished: ?js.PromiseResolver = null,
};

pub const NavigateEventResult = union(enum) {
    // Don't navigate: a listener canceled the event, or started a navigation
    // that aborted this one.
    canceled,
    // No event: an iframe, the initial about:blank, or nothing could observe it.
    not_fired,
    // Navigate. A same-document navigation then calls commitSameDocument.
    fired: *AbortSignal,
};

// Fires `navigate` at a navigation about to happen in `frame`, aborting the
// ongoing one first.
// https://html.spec.whatwg.org/multipage/nav-history-apis.html#inner-navigate-event-firing-algorithm
pub fn fireNavigateEvent(self: *Navigation, params: NavigateEventParams, frame: *Frame) !NavigateEventResult {
    // A page has one Navigation, shared by its iframes. An iframe's own
    // navigations must not show up on it.
    if (frame.parent != null) {
        return .not_fired;
    }
    // The initial about:blank has "entries and events disabled".
    if (self._initial_entry) {
        return .not_fired;
    }

    try self.abortOngoing(frame);

    const target = self.asEventTarget();
    if (params.finished == null and
        frame.hasDirectListeners(target, "navigate") == false and
        frame.hasDirectListeners(target, "navigateerror") == false and
        frame.hasDirectListeners(target, "navigatesuccess") == false)
    {
        return .not_fired;
    }

    const destination = try frame.page_arena.create(NavigationDestination);
    destination.* = .{
        ._url = try frame.page_arena.dupe(u8, params.url),
        ._same_document = params.same_document,
        ._state = params.state,
    };
    if (params.entry) |entry| {
        destination._entry = entry;
        destination._state = entry.navigationState();
    }

    // A fragment change: the URLs differ only by their fragment.
    const hash_change = params.same_document and
        params.classic_history == false and
        URL.eqlDocument(frame.url, params.url) and
        std.mem.eql(u8, frame.url, params.url) == false;

    const signal = try AbortSignal.init(&frame.js.execution);
    const event = try NavigateEvent.initTrusted(.{
        // A traversal to another document can't be canceled.
        .cancelable = params.navigation_type != .traverse or params.same_document,
        .navigationType = @tagName(params.navigation_type),
        .destination = destination,
        .userInitiated = params.user_initiated,
        .hashChange = hash_change,
        .signal = signal,
        .formData = params.form_data,
        .info = if (params.info) |info| try info.persist() else null,
        .sourceElement = params.source_element,
    }, frame);
    event.asEvent().acquireRef();
    defer event.asEvent().releaseRef(frame.page);

    frame._ongoing_navigate = .{
        .signal = signal,
        .event = event,
        .committed = if (params.committed) |c| try c.persist() else null,
        .finished = if (params.finished) |f| try f.persist() else null,
    };

    {
        errdefer if (ongoingFor(signal, frame)) |ongoing| {
            ongoing.event = null;
        };
        try self.dispatch(event.asEvent(), frame);
    }

    // Gone when a listener started a navigation, which aborted this one.
    const ongoing = ongoingFor(signal, frame) orelse return .canceled;
    ongoing.event = null;

    if (event.asEvent().getDefaultPrevented()) {
        try self.abortOngoing(frame);
        return .canceled;
    }

    if (params.same_document == false) {
        // The promises of a navigation to another document never settle: this
        // document goes away. It stays ongoing until then, so that a newer
        // navigation or window.stop() still aborts it.
        ongoing.releasePromises();
    }
    return .{ .fired = signal };
}

fn ongoingFor(signal: *AbortSignal, frame: *Frame) ?*OngoingNavigation {
    if (frame._ongoing_navigate) |*ongoing| {
        if (ongoing.signal == signal) {
            return ongoing;
        }
    }
    return null;
}

// https://html.spec.whatwg.org/multipage/nav-history-apis.html#abort-the-ongoing-navigation
pub fn abortOngoing(self: *Navigation, frame: *Frame) !void {
    var ongoing = frame._ongoing_navigate orelse return;
    frame._ongoing_navigate = null;
    defer ongoing.releasePromises();

    if (ongoing.event) |event| {
        // Aborted by one of its own listeners: the event is now canceled.
        event.asEvent()._prevent_default = true;
    }

    // One instance, so the signal's reason, navigateerror's error and the
    // rejections are the same object. The message matches Chrome's.
    const dom = try frame.page_arena.create(DOMException);
    dom.* = .init("Navigation was aborted", "AbortError");
    try ongoing.signal.abort(.{ .dom = dom }, &frame.js.execution);

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const local = &ls.local;

    const err = try local.zigValueToJs(dom, .{});
    try self.fireNavigateError(err, frame);

    if (ongoing.committed) |c| {
        c.local(local).rejectValue(err) catch |e| {
            log.debug(.event, "Navigation.abort committed", .{ .err = e });
        };
    }
    if (ongoing.finished) |f| {
        f.local(local).rejectValue(err) catch |e| {
            log.debug(.event, "Navigation.abort finished", .{ .err = e });
        };
    }
}

// A same-document navigation updated the URL and entries: the committed
// promise resolves now, navigatesuccess and the finished promise follow in a
// microtask.
pub fn commitSameDocument(_: *Navigation, signal: *AbortSignal, frame: *Frame) !void {
    // Gone when the commit steps (currententrychange, popstate) started a
    // navigation that aborted this one.
    resolveCommitted(signal, frame);
    const ongoing = ongoingFor(signal, frame) orelse return;
    ongoing.committed_same_document = true;
    try frame.js.queueNavigateSuccess();
}

// Before the entry update: its currententrychange listeners can start a
// navigation that aborts this one, which mustn't reject the committed promise.
fn resolveCommitted(signal: *AbortSignal, frame: *Frame) void {
    const ongoing = ongoingFor(signal, frame) orelse return;
    const committed = ongoing.committed orelse return;
    ongoing.committed = null;
    defer committed.release();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    committed.local(&ls.local).resolve("navigation committed", {});
}

// The microtask queued by commitSameDocument.
pub fn finishSameDocument(self: *Navigation, frame: *Frame) void {
    var ongoing = frame._ongoing_navigate orelse return;
    if (ongoing.committed_same_document == false) {
        // A newer navigation replaced it
        return;
    }

    frame._ongoing_navigate = null;
    defer ongoing.releasePromises();

    self.fireNavigateSuccess(frame) catch |err| {
        log.debug(.event, "Navigation.navigatesuccess", .{ .err = err });
    };

    if (ongoing.finished) |f| {
        var ls: js.Local.Scope = undefined;
        frame.js.localScope(&ls);
        defer ls.deinit();
        f.local(&ls.local).resolve("navigation finished", {});
    }
}

fn fireNavigateSuccess(self: *Navigation, frame: *Frame) !void {
    if (!frame.hasDirectListeners(self.asEventTarget(), "navigatesuccess")) {
        return;
    }

    const event = Event.initTrusted(
        .wrap("navigatesuccess"),
        null,
        frame.page,
    ) catch |err| {
        log.debug(.event, "Navigation.navigatesuccess", .{ .err = err });
        return;
    };

    try self.dispatch(event, frame);
}

fn fireNavigateError(self: *Navigation, err: js.Value, frame: *Frame) !void {
    if (!frame.hasDirectListeners(self.asEventTarget(), "navigateerror")) {
        return;
    }

    const event = try ErrorEvent.initTrusted(.wrap("navigateerror"), .{
        .@"error" = try err.persist(),
        .message = "AbortError: Navigation was aborted",
        .filename = frame.url,
    }, frame.page);

    try self.dispatch(event.asEvent(), frame);
}

fn fireCurrentEntryChangeEvent(
    self: *Navigation,
    previous: *NavigationHistoryEntry,
    kind: ?NavigationKind,
    frame: *Frame,
) !void {
    if (!frame.hasDirectListeners(self.asEventTarget(), "currententrychange")) {
        return;
    }

    const event =
        NavigationCurrentEntryChangeEvent.initTrusted(
            .wrap("currententrychange"),
            .{
                .from = previous,
                .navigationType = if (kind) |k| @tagName(k) else null,
            },
            frame,
        ) catch |err| {
            log.debug(.event, "Navigation.currententrychange", .{ .err = err });
            return;
        };

    try self.dispatch(event.asEvent(), frame);
}

const NavigateOptions = struct {
    history: ?[]const u8 = null,
    info: ?js.Value = null,
    state: ?js.Value = null,
};

// The options of a Navigation API method, for its navigate event.
const ApiOptions = struct {
    info: ?js.Value = null,
    // Serialized, reload()'s. navigate()'s is in its NavigationKind.
    state: ?[]const u8 = null,
    // false for history.back()/forward()/go(), which return no promises.
    api_method: bool = true,
};

pub fn navigateInner(
    self: *Navigation,
    _url: ?[:0]const u8,
    kind: NavigationKind,
    api: ApiOptions,
    frame: *Frame,
) !NavigationReturn {
    const arena = frame._session.arena;
    const url = _url orelse return error.MissingURL;

    // https://github.com/WICG/navigation-api/issues/95
    //
    // These will only settle on same-origin navigation (mostly intended for SPAs).
    // It is fine (and expected) for these to not settle on cross-origin requests :)
    const local = frame.js.local.?;
    const committed = local.createPromiseResolver();
    const finished = local.createPromiseResolver();
    // Per spec, a rejection is reported through the committed promise only.
    finished.promise().markAsHandled();

    var new_url = try URL.resolve(arena.allocator(), frame.url, url, .{});
    const is_same_url = URL.eqlDocument(new_url, frame.url);
    // navigate() stays in the document only for a fragment change, but a
    // traversal stays in it whenever the entry belongs to it, whatever URL
    // pushState gave the entry. A reload never does.
    const is_same_document = switch (kind) {
        .traverse => |index| self._entries.items[index].sameDocument(frame),
        .reload => false,
        else => is_same_url,
    };

    // In case of navigation to the same document, we force an url duplication.
    // Keeping the same url generates a crash during WPT test navigate-history-push-same-url.html.
    // When building a script's src, script's base and frame url overlap.
    if (is_same_document) {
        new_url = try arena.dupeSentinel(u8, new_url, 0);
    }

    const result = try self.fireNavigateEvent(.{
        .navigation_type = kind.toNavigationType(),
        .url = new_url,
        .same_document = is_same_document,
        .entry = switch (kind) {
            .traverse => |index| self._entries.items[index],
            else => null,
        },
        .state = switch (kind) {
            .push, .replace => |state| state,
            // reload() without a state keeps the current entry's
            .reload => api.state orelse self.getCurrentEntry().navigationState(),
            .traverse => null,
        },
        .info = api.info,
        .committed = if (api.api_method) committed else null,
        .finished = if (api.api_method) finished else null,
    }, frame);

    const signal: ?*AbortSignal = switch (result) {
        // aborting the navigation rejected the promises
        .canceled => return returnPromises(committed, finished),
        .not_fired => null,
        .fired => |signal| signal,
    };

    // Captured before a same-document navigation overwrites frame.url; used
    // to queue the hashchange once below.
    const old_url = frame.url;

    const previous = self.getCurrentEntry();

    if (is_same_document) {
        frame.url = new_url;
        try frame.window._location._url.setHref(new_url, &frame.js.execution);
        // `:target` matches off the fragment, which might have just changed.
        frame.styleChanged();

        frame._session.notification.dispatch(.frame_navigated_within_document, &.{
            .url = new_url,
            .frame_id = frame._frame_id,
            .navigation_type = .fragment,
        });

        if (signal) |s| {
            resolveCommitted(s, frame);
        } else {
            committed.resolve("navigation committed", {});
        }
    }

    switch (kind) {
        .push => |state| {
            if (is_same_document) {
                _ = try self.pushEntry(new_url, .{ .source = .navigation, .value = state }, frame, true);
                try self.settleSameDocument(finished, signal, frame);
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .replace => |state| {
            if (is_same_document) {
                _ = try self.replaceEntry(new_url, .{ .source = .navigation, .value = state }, frame, true);
                try self.settleSameDocument(finished, signal, frame);
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .traverse => |index| {
            self._index = index;

            if (is_same_document) {
                try self.fireCurrentEntryChangeEvent(previous, kind, frame);
                try self.settleSameDocument(finished, signal, frame);
            } else {
                try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
            }
        },
        .reload => {
            if (api.state) |state| {
                previous._state = .{ .source = .navigation, .value = state };
                try self.fireCurrentEntryChangeEvent(previous, .reload, frame);
            }
            try frame.scheduleNavigation(url, .{ .reason = .navigation, .kind = kind }, .{ .script = frame });
        },
    }

    if (is_same_document and is_same_url and !std.mem.eql(u8, old_url, new_url)) {
        try frame.queueHashChange(old_url, new_url);
    }

    return returnPromises(committed, finished);
}

fn settleSameDocument(
    self: *Navigation,
    finished: js.PromiseResolver,
    signal: ?*AbortSignal,
    frame: *Frame,
) !void {
    if (signal) |s| {
        return self.commitSameDocument(s, frame);
    }
    // No navigate event fired, nothing can abort it.
    finished.resolve("navigation finished", {});
    try self.fireNavigateSuccess(frame);
}

fn returnPromises(committed: js.PromiseResolver, finished: js.PromiseResolver) !NavigationReturn {
    return .{
        .committed = try committed.promise().persist(),
        .finished = try finished.promise().persist(),
    };
}

pub fn navigate(self: *Navigation, _url: [:0]const u8, _opts: ?NavigateOptions, frame: *Frame) !NavigationReturn {
    const arena = frame._session.arena;
    const opts = _opts orelse NavigateOptions{};
    const json = if (opts.state) |state| state.toJson(arena.allocator()) catch return error.DataClone else null;

    const kind: NavigationKind = if (opts.history) |history|
        if (std.mem.eql(u8, "replace", history)) .{ .replace = json } else .{ .push = json }
    else
        .{ .push = json };

    return try self.navigateInner(_url, kind, .{ .info = opts.info }, frame);
}

const ReloadOptions = struct {
    info: ?js.Value = null,
    state: ?js.Value = null,
};

pub fn reload(self: *Navigation, _opts: ?ReloadOptions, frame: *Frame) !NavigationReturn {
    const arena = frame._session.arena;

    const opts = _opts orelse ReloadOptions{};
    const state = if (opts.state) |state| state.toJson(arena.allocator()) catch return error.DataClone else null;

    return self.navigateInner(self.getCurrentEntry()._url, .reload, .{ .info = opts.info, .state = state }, frame);
}

pub fn traverseTo(self: *Navigation, key: []const u8, _opts: ?NavigationOptions, frame: *Frame) !NavigationReturn {
    const opts = _opts orelse NavigationOptions{};
    for (self._entries.items, 0..) |entry, i| {
        if (std.mem.eql(u8, key, entry._key)) {
            return try self.navigateInner(entry._url, .{ .traverse = i }, .{ .info = opts.info }, frame);
        }
    }

    return error.InvalidStateError;
}

const UpdateCurrentEntryOptions = struct {
    state: js.Value,
};

fn updateCurrentEntry(self: *Navigation, options: UpdateCurrentEntryOptions, frame: *Frame) !void {
    const arena = frame._session.arena;

    const previous = self.getCurrentEntry();
    self.getCurrentEntry()._state = .{
        .source = .navigation,
        .value = options.state.toJson(arena.allocator()) catch return error.DataClone,
    };

    try self.fireCurrentEntryChangeEvent(previous, null, frame);
}

pub fn dispatch(self: *Navigation, event: *Event, frame: *Frame) !void {
    return frame.dispatch(self.asEventTarget(), event, .{ .context = "Navigation" });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Navigation);

    pub const Meta = struct {
        pub const name = "Navigation";
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const activation = bridge.accessor(Navigation.getActivation, null, .{});
    pub const canGoBack = bridge.accessor(Navigation.getCanGoBack, null, .{});
    pub const canGoForward = bridge.accessor(Navigation.getCanGoForward, null, .{});
    pub const currentEntry = bridge.accessor(Navigation.getCurrentEntry, null, .{});
    pub const transition = bridge.accessor(Navigation.getTransition, null, .{});
    pub const back = bridge.function(Navigation.back, .{});
    pub const entries = bridge.function(Navigation.entries, .{});
    pub const forward = bridge.function(Navigation.forward, .{});
    pub const navigate = bridge.function(Navigation.navigate, .{});
    pub const reload = bridge.function(Navigation.reload, .{});
    pub const traverseTo = bridge.function(Navigation.traverseTo, .{});
    pub const updateCurrentEntry = bridge.function(Navigation.updateCurrentEntry, .{});

    pub const onnavigate = EventTarget.handlerAccessor(Navigation, "navigate");
    pub const oncurrententrychange = EventTarget.handlerAccessor(Navigation, "currententrychange");
    pub const onnavigatesuccess = EventTarget.handlerAccessor(Navigation, "navigatesuccess");
    pub const onnavigateerror = EventTarget.handlerAccessor(Navigation, "navigateerror");
};

const testing = @import("../../../testing.zig");

test "Navigation: about:blank commits entry" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    // Drop the entry createPage seeds so we exercise an empty stack.
    const navigation = testing.test_session.navigationFor(frame);
    navigation._entries.clearRetainingCapacity();
    navigation._index = 0;

    try frame.navigate("about:blank", .{});
    try testing.waitForFrame();

    // about:blank / blob: handling in Frame.navigate bypasses rameDoneCallback,
    // so commitNavigation never runs and _entries stays empty. Reading
    // `navigation.currentEntry` from JS then hits the `lp.assert(len > 0, ...)`
    // in Navigation.getCurrentEntry
    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const result = try ls.local.exec(
        "navigation.currentEntry.url === 'about:blank'",
        "Navigation.test",
    );
    try testing.expect(result.isTrue());
}

test "Navigation: reload on empty stack seeds an entry" {
    const frame = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    const navigation = testing.test_session.navigationFor(frame);
    navigation._entries.clearRetainingCapacity();
    navigation._index = 0;

    // Mirrors CDP Page.reload arriving on a fresh session: doReload reads
    // frame.url (default "about:blank") and routes through the synchronous
    // about:blank commit with kind=.reload. updateEntries is a no-op for
    // .reload, so without the empty-stack guard this would assert
    // `len: 0` in getCurrentEntry.
    try frame.navigate("about:blank", .{ .kind = .reload });
    try testing.waitForFrame();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();

    const result = try ls.local.exec(
        "navigation.currentEntry.url === 'about:blank'",
        "Navigation.test",
    );
    try testing.expect(result.isTrue());
}

test "WebApi: NavigateEvent" {
    try testing.htmlRunner("navigation", .{});
}
