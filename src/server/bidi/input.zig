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

const Frame = @import("../../browser/Frame.zig");
const Node = @import("../../browser/webapi/Node.zig");
const KeyboardEvent = @import("../../browser/webapi/event/KeyboardEvent.zig");

const BiDi = @import("BiDi.zig");
const remote_value = @import("remote_value.zig");
const browsing_context = @import("browsing_context.zig");

const log = lp.log;
const user_input = Frame.user_input;
const Allocator = std.mem.Allocator;

pub fn processMessage(cmd: *const BiDi.Command) !void {
    const command = std.meta.stringToEnum(enum {
        performActions,
        releaseActions,
    }, cmd.action) orelse return error.UnknownCommand;

    switch (command) {
        .performActions => return performActions(cmd),
        .releaseActions => return releaseActions(cmd),
    }
}

fn performActions(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        context: []const u8,
        actions: []const std.json.Value,
    });

    if ((try browsing_context.requireContext(cmd, p.context)) == null) {
        return;
    }

    const bidi = cmd.bidi;
    const arena = try bidi.app.arena_pool.acquire(.small, "bidi input.Pending");
    // run takes onwership of arena, so errdefer can lead to a double-free.
    // explicit release on error instead, then transfer to run.

    const ticks = parseTicks(bidi, arena.allocator(), p.actions) catch |err| {
        arena.release();
        if (err == error.OutOfMemory) {
            return err;
        }
        return cmd.sendError("invalid argument", errorMessage(err));
    };

    const pending = arena.allocator().create(Pending) catch |err| {
        arena.release();
        return err;
    };
    pending.* = .{
        .bidi = bidi,
        .arena = arena,
        .ticks = ticks,
        .command_id = cmd.id,
        .generation = bidi.input_state.generation,
    };
    return pending.run();
}

// Undo everything still held: keys and buttons in reverse press order.
fn releaseActions(cmd: *const BiDi.Command) !void {
    const p = try cmd.params(struct {
        context: []const u8,
    });

    if ((try browsing_context.requireContext(cmd, p.context)) == null) {
        return;
    }

    const bidi = cmd.bidi;
    const frame = bidi.user_context.session.currentFrame() orelse {
        return cmd.sendError("no such frame", "no frame");
    };

    // dispatch pops the released key/button off `pressed` itself. The state
    // is reset even if a dispatch fails (e.g. ExecutionTerminated), so nothing
    // stays held into the next performActions, and the client gets a reply.
    const state = &bidi.input_state;
    defer state.reset(bidi.app.allocator);

    for (state.sources.items) |*source| {
        switch (source.kind) {
            .key => while (source.key.pressed.getLastOrNull()) |cp| {
                dispatch(bidi, frame, source, &.{ .key_up = cp }) catch |err| return dispatchFailed(cmd, err);
            },
            .pointer => while (source.pointer.pressed.getLastOrNull()) |button| {
                dispatch(bidi, frame, source, &.{ .pointer_up = button }) catch |err| return dispatchFailed(cmd, err);
            },
            .none, .wheel => {},
        }
    }

    return cmd.sendResult(struct {}{});
}

fn dispatchFailed(cmd: *const BiDi.Command, err: DispatchError) !void {
    if (err == error.OutOfMemory) {
        return err;
    }
    return cmd.sendError(errorCode(err), errorMessage(err));
}

// Spec: the input state map, keyed by top-level browsing context. We have one
// browsing context, so this lives on the BiDi and survives navigations until
// input.releaseActions or the browsing context closes.
pub const State = struct {
    // incremented on reset so that performActions
    // Bumped by reset so a parked performActions can tell its sources are gone.
    generation: u32 = 0,
    sources: std.ArrayList(Source) = .empty,

    pub fn deinit(self: *State, allocator: Allocator) void {
        self.reset(allocator);
        self.sources.deinit(allocator);
    }

    pub fn reset(self: *State, allocator: Allocator) void {
        for (self.sources.items) |*source| {
            source.deinit(allocator);
        }
        self.sources.clearRetainingCapacity();
        self.generation +%= 1;
    }

    fn find(self: *State, id: []const u8) ?usize {
        for (self.sources.items, 0..) |*source, i| {
            if (std.mem.eql(u8, source.id, id)) {
                return i;
            }
        }
        return null;
    }

    fn findOrCreate(self: *State, allocator: Allocator, id: []const u8, kind: Source.Kind) !usize {
        if (self.find(id)) |i| {
            if (self.sources.items[i].kind != kind) {
                return error.SourceKindMismatch;
            }
            return i;
        }
        const owned = try allocator.dupe(u8, id);
        errdefer allocator.free(owned);
        try self.sources.append(allocator, .{ .id = owned, .kind = kind });
        return self.sources.items.len - 1;
    }
};

const Modifiers = struct {
    alt: bool = false,
    ctrl: bool = false,
    meta: bool = false,
    shift: bool = false,
};

const Source = struct {
    id: []const u8,
    kind: Kind,
    key: KeyState = .{},
    pointer: PointerState = .{},

    const Kind = enum { none, key, pointer, wheel };

    const KeyState = struct {
        // in press order, so releaseActions can undo them in reverse
        pressed: std.ArrayList(u21) = .empty,
        modifiers: Modifiers = .{},
    };

    const PointerState = struct {
        x: f64 = 0,
        y: f64 = 0,
        // DOM button numbers, in press order
        pressed: std.ArrayList(u8) = .empty,
        // for the click count
        last_click_ms: u64 = 0,
        last_click_x: f64 = 0,
        last_click_y: f64 = 0,
        click_count: i32 = 0,
    };

    fn deinit(self: *Source, allocator: Allocator) void {
        allocator.free(self.id);
        self.key.pressed.deinit(allocator);
        self.pointer.pressed.deinit(allocator);
    }
};

const Origin = union(enum) {
    viewport,
    pointer,
    // Resolved when the action runs, not when it's parsed: an earlier tick can
    // pause long enough for the page to change under us.
    element: []const u8,
};

const Action = union(enum) {
    pause: u32,
    key_down: u21,
    key_up: u21,
    pointer_down: u8,
    pointer_up: u8,
    pointer_move: struct { x: f64, y: f64, duration: u32, origin: Origin },
    scroll: struct { x: f64, y: f64, delta_x: f64, delta_y: f64, duration: u32, origin: Origin },

    fn duration(self: *const Action) u32 {
        return switch (self.*) {
            .pause => |d| d,
            .pointer_move => |m| m.duration,
            .scroll => |s| s.duration,
            else => 0,
        };
    }
};

const TickAction = struct {
    source: usize,
    action: Action,
};

const Pending = struct {
    bidi: *BiDi,
    arena: *lp.Arena,
    command_id: u64,
    generation: u32,
    ticks: []const []const TickAction,
    next: usize = 0,

    fn deinit(self: *Pending) void {
        self.arena.release();
    }

    fn run(self: *Pending) !void {
        const parked = self.step() catch |err| {
            self.deinit();
            return err;
        };
        if (!parked) {
            self.deinit();
        }
    }

    // Runs ticks until one has a duration. True if parked in the scheduler.
    fn step(self: *Pending) !bool {
        const bidi = self.bidi;
        while (self.next < self.ticks.len) {
            if (bidi.input_state.generation != self.generation) {
                try bidi.sendError(self.command_id, "unknown error", "input state was released while actions were pending");
                return false;
            }
            const frame = bidi.user_context.session.currentFrame() orelse {
                try bidi.sendError(self.command_id, "no such frame", "no frame");
                return false;
            };

            const next = self.next;
            const tick = self.ticks[next];
            self.next = next + 1;

            var wait: u32 = 0;
            for (tick) |ta| {
                wait = @max(wait, ta.action.duration());
                dispatch(bidi, frame, &bidi.input_state.sources.items[ta.source], &ta.action) catch |err| {
                    if (err == error.OutOfMemory) {
                        return err;
                    }
                    try bidi.sendError(self.command_id, errorCode(err), errorMessage(err));
                    return false;
                };
            }

            if (wait > 0) {
                try frame.js.scheduler.add(self, resumeFromScheduler, wait, .{ .name = "bidi.performActions", .finalizer = cancelled });
                return true;
            }
        }

        try bidi.sendResult(self.command_id, struct {}{});
        return false;
    }

    fn resumeFromScheduler(ctx: *anyopaque) !?u32 {
        const self: *Pending = @ptrCast(@alignCast(ctx));

        // need to capture it here, run can free self
        const command_id = self.command_id;

        self.run() catch |err| {
            log.err(.bidi, "performActions", .{ .err = err, .id = command_id });
        };
        return null;
    }

    fn cancelled(ctx: *anyopaque) void {
        const self: *Pending = @ptrCast(@alignCast(ctx));
        self.bidi.sendError(self.command_id, "no such frame", "frame destroyed while actions were pending") catch {};
        self.deinit();
    }
};

const ParseError = error{
    OutOfMemory,
    InvalidActions,
    SourceKindMismatch,
    UnknownActionType,
    ActionNotAllowedForSource,
    MissingField,
    InvalidField,
    InvalidKeyValue,
    InvalidOrigin,
};

const SourceActions = struct {
    id: []const u8,
    type: Source.Kind,
    parameters: ?std.json.Value = null,
    actions: []const std.json.Value,
};

// Given 2 actions:
// {id: "keyboard", actions: [
//    {type: "keyDown", value: "a"},
//    {type: "keyUp", value: "a"}
// ]},
// {id: "mouse", actions: [
//    { type: "pointerDown", button: 0 },
//    { type: "pointerUp", button: 0 },
// ]}
//
// We'll flatten it rotate the actions into:
// [
//   {tick: 1, actions: {
//      keyboard:  { type: "keyDown", value: "a" },
//      mouse:  { type: "pointerDown", button: 0 },
//   }},
//   {tick: 2, actions: {
//      keyboard:  { type: "keyUp", value: "a" },
//      mouse:  { type: "pointerUp", button: 0 },
//   }}
// ]
//
// If the action arrays aren' the same length, a "pause" is inserteds
fn parseTicks(bidi: *BiDi, arena: Allocator, actions: []const std.json.Value) ParseError![]const []const TickAction {
    const state = &bidi.input_state;
    const allocator = bidi.app.allocator;

    var columns: std.ArrayList(struct { source: usize, actions: []const Action }) = try .initCapacity(arena, actions.len);

    var tick_count: usize = 0;
    for (actions) |value| {
        const sa = std.json.parseFromValueLeaky(SourceActions, arena, value, .{ .ignore_unknown_fields = true }) catch {
            return error.InvalidActions;
        };
        const source = try state.findOrCreate(allocator, sa.id, sa.type);

        const parsed = try arena.alloc(Action, sa.actions.len);
        for (sa.actions, parsed) |raw, *action| {
            action.* = try parseAction(sa.type, raw);
        }
        columns.appendAssumeCapacity(.{ .source = source, .actions = parsed });

        // the number of ticks we'll have is the max # of actions the actions have
        tick_count = @max(tick_count, parsed.len);
    }

    const ticks = try arena.alloc([]const TickAction, tick_count);
    for (ticks, 0..) |*tick, i| {
        var row: std.ArrayList(TickAction) = try .initCapacity(arena, columns.items.len);
        for (columns.items) |column| {
            if (i < column.actions.len) {
                row.appendAssumeCapacity(.{ .source = column.source, .action = column.actions[i] });
            }
        }
        tick.* = row.items;
    }
    return ticks;
}

fn parseAction(kind: Source.Kind, raw: std.json.Value) ParseError!Action {
    const obj = switch (raw) {
        .object => |o| o,
        else => return error.InvalidActions,
    };
    const type_name = switch (obj.get("type") orelse return error.MissingField) {
        .string => |s| s,
        else => return error.InvalidField,
    };
    const typ = std.meta.stringToEnum(enum {
        pause,
        keyDown,
        keyUp,
        pointerDown,
        pointerUp,
        pointerMove,
        scroll,
    }, type_name) orelse return error.UnknownActionType;

    const allowed = switch (typ) {
        .pause => true,
        .keyDown, .keyUp => kind == .key,
        .pointerDown, .pointerUp, .pointerMove => kind == .pointer,
        .scroll => kind == .wheel,
    };
    if (!allowed) {
        return error.ActionNotAllowedForSource;
    }

    return switch (typ) {
        .pause => .{ .pause = try uintField(obj, "duration", 0) },
        .keyDown => .{ .key_down = try keyValue(obj) },
        .keyUp => .{ .key_up = try keyValue(obj) },
        .pointerDown => .{ .pointer_down = try buttonField(obj) },
        .pointerUp => .{ .pointer_up = try buttonField(obj) },
        .pointerMove => .{ .pointer_move = .{
            .x = try numberField(obj, "x"),
            .y = try numberField(obj, "y"),
            .duration = try uintField(obj, "duration", 0),
            .origin = try originField(obj, .pointer),
        } },
        .scroll => .{ .scroll = .{
            .x = try numberField(obj, "x"),
            .y = try numberField(obj, "y"),
            .delta_x = try numberField(obj, "deltaX"),
            .delta_y = try numberField(obj, "deltaY"),
            .duration = try uintField(obj, "duration", 0),
            .origin = try originField(obj, .wheel),
        } },
    };
}

fn keyValue(obj: std.json.ObjectMap) ParseError!u21 {
    const str = switch (obj.get("value") orelse return error.MissingField) {
        .string => |s| s,
        else => return error.InvalidField,
    };
    // one code point, no more, no less
    if (str.len == 0) {
        return error.InvalidKeyValue;
    }
    const len = std.unicode.utf8ByteSequenceLength(str[0]) catch return error.InvalidKeyValue;
    if (str.len != len) {
        return error.InvalidKeyValue;
    }
    return std.unicode.utf8Decode(str) catch return error.InvalidKeyValue;
}

fn buttonField(obj: std.json.ObjectMap) ParseError!u8 {
    const button = try uintField(obj, "button", 0);
    if (button > std.math.maxInt(u8)) {
        return error.InvalidField;
    }
    return @intCast(button);
}

fn uintField(obj: std.json.ObjectMap, name: []const u8, default: u32) ParseError!u32 {
    const value = obj.get(name) orelse return default;
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= std.math.maxInt(u32)) @intCast(i) else error.InvalidField,
        .null => default,
        else => error.InvalidField,
    };
}

fn numberField(obj: std.json.ObjectMap, name: []const u8) ParseError!f64 {
    const value = obj.get(name) orelse return error.MissingField;
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => error.InvalidField,
    };
}

fn originField(obj: std.json.ObjectMap, source: Source.Kind) ParseError!Origin {
    const value = obj.get("origin") orelse return .viewport;
    switch (value) {
        .null => return .viewport,
        .string => |s| {
            if (std.mem.eql(u8, s, "viewport")) {
                return .viewport;
            }
            if (std.mem.eql(u8, s, "pointer") and source == .pointer) {
                return .pointer;
            }
            return error.InvalidOrigin;
        },
        .object => |o| {
            const typ = o.get("type") orelse return error.InvalidOrigin;
            if (typ != .string or std.mem.eql(u8, typ.string, "element") == false) {
                return error.InvalidOrigin;
            }
            const element = switch (o.get("element") orelse return error.InvalidOrigin) {
                .object => |e| e,
                else => return error.InvalidOrigin,
            };
            return switch (element.get("sharedId") orelse return error.InvalidOrigin) {
                .string => |s| .{ .element = s },
                else => error.InvalidOrigin,
            };
        },
        else => return error.InvalidOrigin,
    }
}

const DispatchError = error{
    OutOfMemory,
    NoSuchElement,
    NotAnElement,
    StringTooLarge,
    CompilationError,
    JsException,
    ExecutionTerminated,
};

fn dispatch(bidi: *BiDi, frame: *Frame, source: *Source, action: *const Action) DispatchError!void {
    const allocator = bidi.app.allocator;
    switch (action.*) {
        .pause => {},
        .key_down => |cp| {
            const key = &source.key;
            const info = keyInfo(cp, key.modifiers.shift);
            setModifier(&key.modifiers, info.modifier, true);
            if (std.mem.indexOfScalar(u21, key.pressed.items, cp) == null) {
                try key.pressed.append(allocator, cp);
            }
            try dispatchKey(frame, "keydown", &info, &key.modifiers);
        },
        .key_up => |cp| {
            const key = &source.key;
            const info = keyInfo(cp, key.modifiers.shift);
            setModifier(&key.modifiers, info.modifier, false);
            if (std.mem.indexOfScalar(u21, key.pressed.items, cp)) |i| {
                _ = key.pressed.orderedRemove(i);
            }
            try dispatchKey(frame, "keyup", &info, &key.modifiers);
        },
        .pointer_down => |button| {
            const pointer = &source.pointer;
            if (std.mem.indexOfScalar(u8, pointer.pressed.items, button) != null) {
                return; // already down; the spec makes this a no-op
            }
            try pointer.pressed.append(allocator, button);

            // A press near the last click, soon enough after it, counts up
            const now = lp.datetime.milliTimestamp(.boot);
            const near = @abs(pointer.x - pointer.last_click_x) <= 2 and @abs(pointer.y - pointer.last_click_y) <= 2;
            pointer.click_count = if (near and now - pointer.last_click_ms <= 500) pointer.click_count + 1 else 1;
            pointer.last_click_ms = now;
            pointer.last_click_x = pointer.x;
            pointer.last_click_y = pointer.y;

            try user_input.triggerMousePress(frame, pointer.x, pointer.y, button);
        },
        .pointer_up => |button| {
            const pointer = &source.pointer;
            const i = std.mem.indexOfScalar(u8, pointer.pressed.items, button) orelse return;
            _ = pointer.pressed.orderedRemove(i);
            try user_input.triggerMouseRelease(frame, pointer.x, pointer.y, button, pointer.click_count);
        },
        .pointer_move => |move| {
            const pointer = &source.pointer;
            const target = try resolveOrigin(bidi, frame, source, move.origin, move.x, move.y);
            pointer.x = target.x;
            pointer.y = target.y;
            try user_input.triggerMouseMove(frame, target.x, target.y);
        },
        .scroll => |scroll| {
            const target = try resolveOrigin(bidi, frame, source, scroll.origin, scroll.x, scroll.y);
            try user_input.triggerMouseWheel(frame, target.x, target.y, scroll.delta_x, scroll.delta_y);
        },
    }
}

const Point = struct { x: f64, y: f64 };

fn resolveOrigin(bidi: *BiDi, frame: *Frame, source: *const Source, origin: Origin, x: f64, y: f64) !Point {
    switch (origin) {
        .viewport => return .{ .x = x, .y = y },
        .pointer => return .{ .x = source.pointer.x + x, .y = source.pointer.y + y },
        .element => |shared_id| {
            const node = remote_value.nodeFromSharedId(&bidi.node_registry, .{ .string = shared_id }) catch {
                return error.NoSuchElement;
            };
            const element = node.is(Node.Element) orelse return error.NotAnElement;
            // relative to the element's center
            const rect = element.boundingClientRectValues(frame);
            return .{ .x = rect.x + rect.width / 2 + x, .y = rect.y + rect.height / 2 + y };
        },
    }
}

fn dispatchKey(frame: *Frame, comptime typ: []const u8, info: *const KeyInfo, modifiers: *const Modifiers) !void {
    var buf: [4]u8 = undefined;
    const key: []const u8 = switch (info.key) {
        .name => |name| name,
        .char => |cp| buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable],
    };
    const event = try KeyboardEvent.initTrusted(comptime .wrap(typ), .{
        .key = key,
        .code = info.code,
        .location = info.location,
        .altKey = modifiers.alt,
        .ctrlKey = modifiers.ctrl,
        .metaKey = modifiers.meta,
        .shiftKey = modifiers.shift,
    }, frame);
    try user_input.triggerKeyboard(frame, event);
}

fn setModifier(modifiers: *Modifiers, which: ?Modifier, down: bool) void {
    switch (which orelse return) {
        .alt => modifiers.alt = down,
        .ctrl => modifiers.ctrl = down,
        .meta => modifiers.meta = down,
        .shift => modifiers.shift = down,
    }
}

const Modifier = enum { alt, ctrl, meta, shift };

const KeyInfo = struct {
    // a named key, or the character itself
    key: union(enum) { name: []const u8, char: u21 },
    code: []const u8,
    location: u32 = 0,
    modifier: ?Modifier = null,
};

// WebDriver's key table: the Private Use Area - names the
// non-printing keys, anything else is the character itself.
// https://w3c.github.io/webdriver/#keyboard-actions
fn keyInfo(cp: u21, shift: bool) KeyInfo {
    if (cp >= 0xE000 and cp <= 0xE05D) {
        return specialKey(cp);
    }

    const char: u21 = if (shift and cp < 128) shiftedAscii(@intCast(cp)) else cp;
    return .{ .key = .{ .char = char }, .code = asciiCode(cp) };
}

fn specialKey(cp: u21) KeyInfo {
    const k = struct {
        fn k(key: []const u8, code: []const u8) KeyInfo {
            return .{ .key = .{ .name = key }, .code = code };
        }
        fn m(key: []const u8, code: []const u8, location: u32, modifier: Modifier) KeyInfo {
            return .{ .key = .{ .name = key }, .code = code, .location = location, .modifier = modifier };
        }
        fn n(key: []const u8, code: []const u8) KeyInfo {
            return .{ .key = .{ .name = key }, .code = code, .location = 3 };
        }
    };
    return switch (cp) {
        0xE000 => k.k("Unidentified", ""),
        0xE001 => k.k("Cancel", "Abort"),
        0xE002 => k.k("Help", "Help"),
        0xE003 => k.k("Backspace", "Backspace"),
        0xE004 => k.k("Tab", "Tab"),
        0xE005 => k.k("Clear", "NumLock"),
        0xE006 => k.k("Enter", "Enter"),
        0xE007 => k.n("Enter", "NumpadEnter"),
        0xE008 => k.m("Shift", "ShiftLeft", 1, .shift),
        0xE009 => k.m("Control", "ControlLeft", 1, .ctrl),
        0xE00A => k.m("Alt", "AltLeft", 1, .alt),
        0xE00B => k.k("Pause", "Pause"),
        0xE00C => k.k("Escape", "Escape"),
        0xE00D => k.k(" ", "Space"),
        0xE00E => k.k("PageUp", "PageUp"),
        0xE00F => k.k("PageDown", "PageDown"),
        0xE010 => k.k("End", "End"),
        0xE011 => k.k("Home", "Home"),
        0xE012 => k.k("ArrowLeft", "ArrowLeft"),
        0xE013 => k.k("ArrowUp", "ArrowUp"),
        0xE014 => k.k("ArrowRight", "ArrowRight"),
        0xE015 => k.k("ArrowDown", "ArrowDown"),
        0xE016 => k.k("Insert", "Insert"),
        0xE017 => k.k("Delete", "Delete"),
        0xE018 => k.k(";", "Semicolon"),
        0xE019 => k.k("=", "Equal"),
        0xE01A => k.n("0", "Numpad0"),
        0xE01B => k.n("1", "Numpad1"),
        0xE01C => k.n("2", "Numpad2"),
        0xE01D => k.n("3", "Numpad3"),
        0xE01E => k.n("4", "Numpad4"),
        0xE01F => k.n("5", "Numpad5"),
        0xE020 => k.n("6", "Numpad6"),
        0xE021 => k.n("7", "Numpad7"),
        0xE022 => k.n("8", "Numpad8"),
        0xE023 => k.n("9", "Numpad9"),
        0xE024 => k.n("*", "NumpadMultiply"),
        0xE025 => k.n("+", "NumpadAdd"),
        0xE026 => k.n(",", "NumpadComma"),
        0xE027 => k.n("-", "NumpadSubtract"),
        0xE028 => k.n(".", "NumpadDecimal"),
        0xE029 => k.n("/", "NumpadDivide"),
        0xE031 => k.k("F1", "F1"),
        0xE032 => k.k("F2", "F2"),
        0xE033 => k.k("F3", "F3"),
        0xE034 => k.k("F4", "F4"),
        0xE035 => k.k("F5", "F5"),
        0xE036 => k.k("F6", "F6"),
        0xE037 => k.k("F7", "F7"),
        0xE038 => k.k("F8", "F8"),
        0xE039 => k.k("F9", "F9"),
        0xE03A => k.k("F10", "F10"),
        0xE03B => k.k("F11", "F11"),
        0xE03C => k.k("F12", "F12"),
        0xE03D => k.m("Meta", "MetaLeft", 1, .meta),
        0xE040 => k.k("ZenkakuHankaku", ""),
        0xE050 => k.m("Shift", "ShiftRight", 2, .shift),
        0xE051 => k.m("Control", "ControlRight", 2, .ctrl),
        0xE052 => k.m("Alt", "AltRight", 2, .alt),
        0xE053 => k.m("Meta", "MetaRight", 2, .meta),
        0xE054 => k.n("PageUp", "Numpad9"),
        0xE055 => k.n("PageDown", "Numpad3"),
        0xE056 => k.n("End", "Numpad1"),
        0xE057 => k.n("Home", "Numpad7"),
        0xE058 => k.n("ArrowLeft", "Numpad4"),
        0xE059 => k.n("ArrowUp", "Numpad8"),
        0xE05A => k.n("ArrowRight", "Numpad6"),
        0xE05B => k.n("ArrowDown", "Numpad2"),
        0xE05C => k.n("Insert", "Numpad0"),
        0xE05D => k.n("Delete", "NumpadDecimal"),
        else => k.k("Unidentified", ""),
    };
}

// slices into this literal are always valid
const key_codes = "KeyAKeyBKeyCKeyDKeyEKeyFKeyGKeyHKeyIKeyJKeyKKeyLKeyMKeyNKeyOKeyPKeyQKeyRKeySKeyTKeyUKeyVKeyWKeyXKeyYKeyZ";
const digit_codes = "Digit0Digit1Digit2Digit3Digit4Digit5Digit6Digit7Digit8Digit9";

// The `code` of a printable character on a US layout.
fn asciiCode(cp: u21) []const u8 {
    if (cp >= 128) {
        return "";
    }
    const c: u8 = @intCast(cp);
    return switch (c) {
        'a'...'z' => key_codes[(c - 'a') * 4 ..][0..4],
        'A'...'Z' => key_codes[(c - 'A') * 4 ..][0..4],
        '0'...'9' => digit_codes[(c - '0') * 6 ..][0..6],
        ' ' => "Space",
        '\n', '\r' => "Enter",
        '\t' => "Tab",
        '`', '~' => "Backquote",
        '-', '_' => "Minus",
        '=', '+' => "Equal",
        '[', '{' => "BracketLeft",
        ']', '}' => "BracketRight",
        '\\', '|' => "Backslash",
        ';', ':' => "Semicolon",
        '\'', '"' => "Quote",
        ',', '<' => "Comma",
        '.', '>' => "Period",
        '/', '?' => "Slash",
        '!' => "Digit1",
        '@' => "Digit2",
        '#' => "Digit3",
        '$' => "Digit4",
        '%' => "Digit5",
        '^' => "Digit6",
        '&' => "Digit7",
        '*' => "Digit8",
        '(' => "Digit9",
        ')' => "Digit0",
        else => "",
    };
}

// What a held Shift turns a US-layout key into.
fn shiftedAscii(c: u8) u8 {
    return switch (c) {
        'a'...'z' => std.ascii.toUpper(c),
        '`' => '~',
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        else => c,
    };
}

fn errorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.NoSuchElement => "no such element",
        error.NotAnElement => "no such element",
        else => "unknown error",
    };
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidActions => "actions must be a list of source actions",
        error.SourceKindMismatch => "input source id already used with a different type",
        error.UnknownActionType => "unknown action type",
        error.ActionNotAllowedForSource => "action type not allowed for this input source",
        error.MissingField => "missing required action field",
        error.InvalidField => "invalid action field",
        error.InvalidKeyValue => "key value must be a single code point",
        error.InvalidOrigin => "invalid origin",
        error.NoSuchElement => "origin element not found",
        error.NotAnElement => "origin must be an element",
        else => "action failed",
    };
}

const testing = @import("testing.zig");
test "bidi.input: click via element origin" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const context_id = try ctx.createContext(.{ .url = "bidi/input.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "browsingContext.locateNodes",
        .params = .{ .context = context_id, .locator = .{ .type = "css", .value = "#btn" } },
    });
    try ctx.expectSentResult(.{ .nodes = .{.{ .sharedId = "1" }} }, .{ .id = 1 });

    // puppeteer's page.click shape: move, down, up
    try ctx.processMessage(.{
        .id = 2,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "pointer",
            .id = "mouse",
            .actions = .{
                .{ .type = "pointerMove", .x = 0, .y = 0, .origin = .{ .type = "element", .element = .{ .sharedId = "1" } } },
                .{ .type = "pointerDown", .button = 0 },
                .{ .type = "pointerUp", .button = 0 },
            },
        }} },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try evaluate(&ctx, 3, context_id, "window.events.join(' ')");
    try ctx.expectSentResult(.{ .type = "success", .result = .{
        .type = "string",
        .value = "mousemove@btn mousedown@btn mouseup@btn click@btn",
    } }, .{ .id = 3 });

    // The pointer keeps its position across commands; a second click there
    // is a double click.
    try ctx.processMessage(.{
        .id = 4,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "pointer",
            .id = "mouse",
            .actions = .{
                .{ .type = "pointerDown", .button = 0 },
                .{ .type = "pointerUp", .button = 0 },
            },
        }} },
    });
    try ctx.expectSentResult(null, .{ .id = 4 });
    try evaluate(&ctx, 5, context_id, "window.events.slice(4).join(' ')");
    try ctx.expectSentResult(.{ .type = "success", .result = .{
        .type = "string",
        .value = "mousedown@btn mouseup@btn click@btn dblclick@btn",
    } }, .{ .id = 5 });

    // right button
    try ctx.processMessage(.{
        .id = 6,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "pointer",
            .id = "mouse",
            .actions = .{
                .{ .type = "pointerMove", .x = 0, .y = 0, .origin = "pointer" },
                .{ .type = "pointerDown", .button = 2 },
                .{ .type = "pointerUp", .button = 2 },
            },
        }} },
    });
    try ctx.expectSentResult(null, .{ .id = 6 });
    try evaluate(&ctx, 7, context_id, "window.events.slice(8).join(' ')");
    try ctx.expectSentResult(.{ .type = "success", .result = .{
        .type = "string",
        .value = "mousemove@btn mousedown:b2@btn mouseup:b2@btn",
    } }, .{ .id = 7 });
}

test "bidi.input: keys and modifiers" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const context_id = try ctx.createContext(.{ .url = "bidi/input.html" });

    try evaluate(&ctx, 1, context_id, "document.getElementById('inp').focus()");
    try ctx.expectSentResult(.{ .type = "success" }, .{ .id = 1 });

    // a, Shift+b (Shift = ), Enter ()
    try ctx.processMessage(.{
        .id = 2,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "key",
            .id = "kb",
            .actions = .{
                .{ .type = "keyDown", .value = "a" },
                .{ .type = "keyUp", .value = "a" },
                .{ .type = "keyDown", .value = "\u{E008}" },
                .{ .type = "keyDown", .value = "b" },
                .{ .type = "keyUp", .value = "b" },
                .{ .type = "keyUp", .value = "\u{E008}" },
                .{ .type = "keyDown", .value = "\u{E007}" },
                .{ .type = "keyUp", .value = "\u{E007}" },
            },
        }} },
    });
    try ctx.expectSentResult(null, .{ .id = 2 });

    try evaluate(&ctx, 3, context_id, "window.events.join(' ')");
    try ctx.expectSentResult(.{ .type = "success", .result = .{
        .type = "string",
        .value = "keydown:a@inp keyup:a@inp keydown:Shift+shift@inp keydown:B+shift@inp keyup:B+shift@inp keyup:Shift@inp keydown:Enter@inp keyup:Enter@inp",
    } }, .{ .id = 3 });

    try evaluate(&ctx, 4, context_id, "document.getElementById('inp').value");
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "string", .value = "aB" } }, .{ .id = 4 });

    try evaluate(&ctx, 5, context_id, "window.codes.join(' ')");
    try ctx.expectSentResult(.{ .type = "success", .result = .{
        .type = "string",
        .value = "KeyA KeyA ShiftLeft KeyB KeyB ShiftLeft NumpadEnter NumpadEnter",
    } }, .{ .id = 5 });
}

test "bidi.input: pause parks the command, releaseActions undoes held input" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const context_id = try ctx.createContext(.{ .url = "bidi/input.html" });

    try evaluate(&ctx, 1, context_id, "document.getElementById('inp').focus()");
    try ctx.expectSentResult(.{ .type = "success" }, .{ .id = 1 });

    // Two sources in lockstep: the key source holds Control while the "none"
    // source pauses. Only the ticks before the pause run synchronously.
    try ctx.processMessage(.{
        .id = 2,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{
            .{
                .type = "key",
                .id = "kb",
                .actions = .{
                    .{ .type = "keyDown", .value = "\u{E009}" },
                    .{ .type = "pause" },
                    .{ .type = "keyDown", .value = "x" },
                },
            },
            .{
                .type = "none",
                .id = "clock",
                .actions = .{
                    .{ .type = "pause" },
                    .{ .type = "pause", .duration = 20 },
                },
            },
        } },
    });
    try ctx.expectNotAnswered(2);
    try evaluate(&ctx, 3, context_id, "window.events.join(' ')");
    try ctx.expectSentResult(.{ .type = "success", .result = .{ .type = "string", .value = "keydown:Control+ctrl@inp" } }, .{ .id = 3 });

    try ctx.wait();
    try ctx.expectSentResult(null, .{ .id = 2 });
    try evaluate(&ctx, 4, context_id, "window.events.join(' ')");
    try ctx.expectSentResult(.{ .type = "success", .result = .{
        .type = "string",
        .value = "keydown:Control+ctrl@inp keydown:x+ctrl@inp",
    } }, .{ .id = 4 });

    // Control and x are still held; release lets go in reverse order.
    try ctx.processMessage(.{ .id = 5, .method = "input.releaseActions", .params = .{ .context = context_id } });
    try ctx.expectSentResult(null, .{ .id = 5 });
    try evaluate(&ctx, 6, context_id, "window.events.slice(2).join(' ')");
    try ctx.expectSentResult(.{ .type = "success", .result = .{
        .type = "string",
        .value = "keyup:x+ctrl@inp keyup:Control@inp",
    } }, .{ .id = 6 });
}

test "bidi.input: errors" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const context_id = try ctx.createContext(.{ .url = "bidi/input.html" });

    try ctx.processMessage(.{
        .id = 1,
        .method = "input.performActions",
        .params = .{ .context = "nope", .actions = .{} },
    });
    try ctx.expectSentError("no such frame", null, .{ .id = 1 });

    // key action on a pointer source
    try ctx.processMessage(.{
        .id = 2,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "pointer",
            .id = "mouse",
            .actions = .{.{ .type = "keyDown", .value = "a" }},
        }} },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 2 });

    // an id can't change type
    try ctx.processMessage(.{
        .id = 3,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{ .type = "key", .id = "mouse", .actions = .{} }} },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 3 });

    try ctx.processMessage(.{
        .id = 4,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "key",
            .id = "kb",
            .actions = .{.{ .type = "keyDown", .value = "ab" }},
        }} },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 4 });

    try ctx.processMessage(.{
        .id = 5,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "pointer",
            .id = "mouse",
            .actions = .{.{ .type = "pointerMove", .x = 0, .y = 0, .origin = .{ .type = "element", .element = .{ .sharedId = "99" } } }},
        }} },
    });
    try ctx.expectSentError("no such element", null, .{ .id = 5 });

    try ctx.processMessage(.{
        .id = 7,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{ .type = "key", .id = "kb", .actions = .{.{ .type = "keyDown", .value = "" }} }} },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 7 });

    try ctx.processMessage(.{
        .id = 8,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{ .type = "pointer", .id = "mouse", .actions = .{.{ .type = "pointerDown", .button = 300 }} }} },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 8 });

    try ctx.processMessage(.{
        .id = 6,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "wheel",
            .id = "w",
            .actions = .{.{ .type = "scroll", .x = 0, .y = 0, .deltaX = 0, .deltaY = 10, .origin = "pointer" }},
        }} },
    });
    try ctx.expectSentError("invalid argument", null, .{ .id = 6 });
}

test "bidi.input: teardown while actions are parked" {
    var ctx = try testing.context();
    defer ctx.deinit();
    const context_id = try ctx.createContext(.{ .url = "bidi/input.html" });

    // A long pause parks the command on the frame's scheduler; tearing the
    // context down must finalize it (answer + free), which the leak checker
    // verifies.
    try ctx.processMessage(.{
        .id = 1,
        .method = "input.performActions",
        .params = .{ .context = context_id, .actions = .{.{
            .type = "none",
            .id = "clock",
            .actions = .{.{ .type = "pause", .duration = 60_000 }},
        }} },
    });
    try ctx.expectNotAnswered(1);
}

fn evaluate(ctx: *testing.TestContext, id: u64, context_id: []const u8, expression: []const u8) !void {
    return ctx.processMessage(.{
        .id = id,
        .method = "script.evaluate",
        .params = .{ .expression = expression, .target = .{ .context = context_id } },
    });
}
