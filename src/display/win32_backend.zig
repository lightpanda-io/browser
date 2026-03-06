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
const log = @import("../log.zig");
const Page = @import("../browser/Page.zig");
const URL = @import("../browser/URL.zig");
const BrowserCommand = @import("BrowserCommand.zig").BrowserCommand;
const DisplayList = @import("../render/DisplayList.zig").DisplayList;
const DisplayColor = @import("../render/DisplayList.zig").Color;
const ImageCommand = @import("../render/DisplayList.zig").ImageCommand;

const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("imm.h");
    @cInclude("urlmon.h");
});

const GpStatus = c_int;
const GpImage = opaque {};
const GpGraphics = opaque {};

const GdiplusStartupInput = extern struct {
    GdiplusVersion: c.UINT,
    DebugEventCallback: ?*const fn (c_int, [*c]u8) callconv(.winapi) void,
    SuppressBackgroundThread: c.BOOL,
    SuppressExternalCodecs: c.BOOL,
};

extern "gdiplus" fn GdiplusStartup(
    token: *c.ULONG_PTR,
    input: *const GdiplusStartupInput,
    output: ?*anyopaque,
) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdiplusShutdown(token: c.ULONG_PTR) callconv(.winapi) void;
extern "gdiplus" fn GdipDisposeImage(image: *GpImage) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipLoadImageFromFile(filename: [*:0]const u16, image: *?*GpImage) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipGetImageWidth(image: *GpImage, width: *c.UINT) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipGetImageHeight(image: *GpImage, height: *c.UINT) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipCreateFromHDC(hdc: c.HDC, graphics: *?*GpGraphics) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDeleteGraphics(graphics: *GpGraphics) callconv(.winapi) GpStatus;
extern "gdiplus" fn GdipDrawImageRectI(
    graphics: *GpGraphics,
    image: *GpImage,
    x: c.INT,
    y: c.INT,
    width: c.INT,
    height: c.INT,
) callconv(.winapi) GpStatus;
const LoadCursorWUnaligned = @extern(
    *const fn (c.HINSTANCE, ?*align(1) const anyopaque) callconv(.winapi) c.HCURSOR,
    .{ .name = "LoadCursorW" },
);

const GDIP_STATUS_OK: GpStatus = 0;

const CachedImage = struct {
    state: enum {
        unloaded,
        loaded,
        failed,
    } = .unloaded,
    cache_path: []u8 = &.{},
    gp_image: ?*GpImage = null,
    width: u32 = 0,
    height: u32 = 0,
    owns_cache_file: bool = false,

    fn deinit(self: *CachedImage, allocator: std.mem.Allocator) void {
        if (self.gp_image) |image| {
            _ = GdipDisposeImage(image);
        }
        if (self.owns_cache_file and self.cache_path.len > 0) {
            if (std.fs.path.isAbsolute(self.cache_path)) {
                std.fs.deleteFileAbsolute(self.cache_path) catch {};
            } else {
                std.fs.cwd().deleteFile(self.cache_path) catch {};
            }
        }
        allocator.free(self.cache_path);
        self.* = .{};
    }
};

pub const Win32Backend = struct {
    allocator: std.mem.Allocator,
    page_count: u32 = 0,

    requested_width: std.atomic.Value(u32),
    requested_height: std.atomic.Value(u32),
    resize_seq: std.atomic.Value(u64) = .init(0),
    open_requested: std.atomic.Value(bool) = .init(false),
    shutdown_requested: std.atomic.Value(bool) = .init(false),
    user_closed: std.atomic.Value(bool) = .init(false),
    pending_high_surrogate: ?u16 = null,
    ime_composing: bool = false,
    suppress_wm_char_units: u32 = 0,

    input_lock: std.Thread.Mutex = .{},
    input_events: std.ArrayListUnmanaged(InputEvent) = .{},

    command_lock: std.Thread.Mutex = .{},
    command_queue: std.ArrayListUnmanaged(BrowserCommand) = .{},

    presentation_lock: std.Thread.Mutex = .{},
    presentation_title: []u8 = &.{},
    presentation_url: []u8 = &.{},
    presentation_body: []u8 = &.{},
    presentation_display_list: ?DisplayList = null,
    presentation_seq: std.atomic.Value(u64) = .init(0),
    presentation_scroll_px: i32 = 0,
    presentation_max_scroll_px: i32 = 0,
    presentation_can_go_back: bool = false,
    presentation_can_go_forward: bool = false,
    presentation_is_loading: bool = false,
    address_input: std.ArrayListUnmanaged(u8) = .{},
    address_input_active: bool = false,
    address_input_select_all: bool = false,
    address_pending_high_surrogate: ?u16 = null,
    pending_presentation_command: ?BrowserCommand = null,
    image_cache_lock: std.Thread.Mutex = .{},
    image_cache: std.StringHashMapUnmanaged(CachedImage) = .{},
    gdiplus_token: c.ULONG_PTR = 0,
    gdiplus_started: bool = false,

    thread: ?std.Thread = null,
    thread_start_lock: std.Thread.Mutex = .{},
    thread_start_cond: std.Thread.Condition = .{},
    thread_started: bool = false,

    const InputEvent = union(enum) {
        mouse_down: MouseEvent,
        mouse_up: MouseEvent,
        mouse_move: MouseMoveEvent,
        mouse_wheel: MouseWheelEvent,
        key_down: KeyEvent,
        key_up: KeyEvent,
        text_input: TextInputEvent,
        window_blur,
    };

    const MouseEvent = struct {
        x: f64,
        y: f64,
        button: Page.MouseButton,
        modifiers: Page.MouseModifiers,
    };

    const MouseMoveEvent = struct {
        x: f64,
        y: f64,
        modifiers: Page.MouseModifiers,
    };

    const MouseWheelEvent = struct {
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        modifiers: Page.MouseModifiers,
    };

    const KeyEvent = struct {
        vk: u32,
        modifiers: Page.KeyboardModifiers,
        repeat: bool = false,
    };

    const TextInputEvent = struct {
        bytes: [4]u8,
        len: u8,
    };

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) Win32Backend {
        return .{
            .allocator = allocator,
            .requested_width = .init(width),
            .requested_height = .init(height),
        };
    }

    pub fn onPageCreated(self: *Win32Backend) bool {
        self.page_count += 1;
        if (self.page_count != 1) {
            return false;
        }

        if (!self.ensureThreadStarted()) {
            return false;
        }
        self.user_closed.store(false, .release);
        self.open_requested.store(true, .release);
        return true;
    }

    pub fn onPageRemoved(self: *Win32Backend) bool {
        const had_pages = self.page_count > 0;
        if (self.page_count > 0) {
            self.page_count -= 1;
        }
        const should_close = had_pages and self.page_count == 0;
        if (should_close) {
            self.open_requested.store(false, .release);
            self.user_closed.store(false, .release);
        }
        return should_close;
    }

    pub fn onViewportChanged(self: *Win32Backend, width: u32, height: u32) void {
        self.requested_width.store(width, .release);
        self.requested_height.store(height, .release);
        _ = self.resize_seq.fetchAdd(1, .acq_rel);
    }

    pub fn setNavigationState(self: *Win32Backend, can_go_back: bool, can_go_forward: bool, is_loading: bool) void {
        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        if (self.presentation_can_go_back == can_go_back and
            self.presentation_can_go_forward == can_go_forward and
            self.presentation_is_loading == is_loading)
        {
            return;
        }
        self.presentation_can_go_back = can_go_back;
        self.presentation_can_go_forward = can_go_forward;
        self.presentation_is_loading = is_loading;
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    pub fn deinit(self: *Win32Backend) void {
        self.open_requested.store(false, .release);
        self.shutdown_requested.store(true, .release);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.input_events.deinit(self.allocator);
        self.command_lock.lock();
        for (self.command_queue.items) |command| {
            command.deinit(self.allocator);
        }
        self.command_queue.deinit(self.allocator);
        self.command_lock.unlock();
        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();
        self.allocator.free(self.presentation_title);
        self.allocator.free(self.presentation_url);
        self.allocator.free(self.presentation_body);
        if (self.presentation_display_list) |*display_list| {
            display_list.deinit(self.allocator);
        }
        self.address_input.deinit(self.allocator);
        if (self.pending_presentation_command) |command| {
            command.deinit(self.allocator);
        }

        self.image_cache_lock.lock();
        defer self.image_cache_lock.unlock();
        var image_it = self.image_cache.iterator();
        while (image_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.image_cache.deinit(self.allocator);
        if (self.gdiplus_started) {
            GdiplusShutdown(self.gdiplus_token);
            self.gdiplus_started = false;
            self.gdiplus_token = 0;
        }
    }

    pub fn dispatchInput(self: *Win32Backend, page: *Page) !void {
        var pending: std.ArrayListUnmanaged(InputEvent) = .{};
        self.input_lock.lock();
        std.mem.swap(std.ArrayListUnmanaged(InputEvent), &pending, &self.input_events);
        self.input_lock.unlock();
        defer pending.deinit(self.allocator);

        var key_buf: [2]u8 = undefined;
        for (pending.items) |event| {
            switch (event) {
                .mouse_down => |mouse| try page.triggerMouseDown(mouse.x, mouse.y, mouse.button, mouse.modifiers),
                .mouse_up => |mouse| {
                    try page.triggerMouseUp(mouse.x, mouse.y, mouse.button, mouse.modifiers);
                    if (mouse.button == .main) {
                        try page.triggerMouseClickWithModifiers(mouse.x, mouse.y, .main, mouse.modifiers);
                    }
                },
                .mouse_move => |mouse| try page.triggerMouseMove(mouse.x, mouse.y, mouse.modifiers),
                .mouse_wheel => |wheel| try page.triggerMouseWheel(
                    wheel.x,
                    wheel.y,
                    wheel.delta_x,
                    wheel.delta_y,
                    wheel.modifiers,
                ),
                .key_down => |key_down| {
                    const key = mapVirtualKey(key_down.vk, key_down.modifiers.shift, &key_buf) orelse continue;
                    const default_allowed = try page.triggerKeyboardKeyDownNoTextWithRepeat(
                        key,
                        key_down.modifiers,
                        key_down.repeat,
                    );
                    if (default_allowed) {
                        if (clipboardShortcutAction(key_down.vk, key_down.modifiers)) |action| {
                            try handleClipboardShortcut(self.allocator, page, action);
                        }
                    }
                },
                .key_up => |key_up| {
                    const key = mapVirtualKey(key_up.vk, key_up.modifiers.shift, &key_buf) orelse continue;
                    _ = try page.triggerKeyboardKeyUp(key, key_up.modifiers);
                },
                .text_input => |text_input| {
                    try page.insertText(text_input.bytes[0..text_input.len]);
                },
                .window_blur => try page.triggerWindowBlur(),
            }
        }
    }

    pub fn presentDocument(self: *Win32Backend, title: []const u8, url: []const u8, body: []const u8) !void {
        try self.presentPageView(title, url, body, null);
    }

    pub fn presentPageView(
        self: *Win32Backend,
        title: []const u8,
        url: []const u8,
        body: []const u8,
        display_list: ?*const DisplayList,
    ) !void {
        const next_title = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(next_title);
        const next_url = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(next_url);
        const next_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(next_body);
        const next_display_list = if (display_list) |list|
            try list.cloneOwned(self.allocator)
        else
            null;
        errdefer if (next_display_list) |list| {
            var owned_list = list;
            owned_list.deinit(self.allocator);
        };

        self.presentation_lock.lock();
        defer self.presentation_lock.unlock();

        self.allocator.free(self.presentation_title);
        self.allocator.free(self.presentation_url);
        self.allocator.free(self.presentation_body);
        if (self.presentation_display_list) |*list| {
            list.deinit(self.allocator);
        }

        self.presentation_title = next_title;
        self.presentation_url = next_url;
        self.presentation_body = next_body;
        self.presentation_display_list = next_display_list;
        self.presentation_scroll_px = 0;
        self.presentation_max_scroll_px = 0;
        _ = self.presentation_seq.fetchAdd(1, .acq_rel);
    }

    pub fn saveBitmap(self: *Win32Backend, path: []const u8) bool {
        return savePresentationBitmap(self, path);
    }

    pub fn savePng(self: *Win32Backend, path: []const u8) bool {
        return savePresentationPng(self, path);
    }

    pub fn userClosed(self: *const Win32Backend) bool {
        return self.user_closed.load(.acquire);
    }

    pub fn nextBrowserCommand(self: *Win32Backend) ?BrowserCommand {
        self.command_lock.lock();
        defer self.command_lock.unlock();

        if (self.command_queue.items.len == 0) {
            return null;
        }

        return self.command_queue.orderedRemove(0);
    }

    fn ensureThreadStarted(self: *Win32Backend) bool {
        self.thread_start_lock.lock();
        defer self.thread_start_lock.unlock();

        if (self.thread != null) {
            return true;
        }

        self.thread_started = false;
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch |err| {
            log.warn(.app, "win thread spawn failed", .{ .err = err });
            return false;
        };

        while (!self.thread_started) {
            self.thread_start_cond.wait(&self.thread_start_lock);
        }
        return true;
    }

    fn workerMain(self: *Win32Backend) void {
        self.thread_start_lock.lock();
        self.thread_started = true;
        self.thread_start_cond.signal();
        self.thread_start_lock.unlock();

        var hwnd: ?c.HWND = null;
        var last_resize_seq: u64 = self.resize_seq.load(.acquire);
        var last_presentation_seq: u64 = self.presentation_seq.load(.acquire);
        var creation_blocked = false;

        while (!self.shutdown_requested.load(.acquire)) {
            pumpMessages();

            const should_open = self.open_requested.load(.acquire);
            if (should_open) {
                const was_closed_by_user = self.user_closed.load(.acquire);
                if (hwnd == null and !creation_blocked and !was_closed_by_user) {
                    const created = createWindow(
                        self,
                        self.requested_width.load(.acquire),
                        self.requested_height.load(.acquire),
                    );
                    hwnd = created catch |err| {
                        creation_blocked = true;
                        log.warn(.app, "win create window failed", .{ .err = err });
                        continue;
                    };
                    if (hwnd) |window| {
                        last_resize_seq = self.resize_seq.load(.acquire);
                        last_presentation_seq = self.presentation_seq.load(.acquire);
                        syncWindowPresentation(window, self);
                    }
                }
            } else {
                creation_blocked = false;
                if (hwnd) |window| {
                    destroyWindow(window);
                    hwnd = null;
                }
            }

            if (hwnd) |window| {
                if (c.IsWindow(window) == 0) {
                    hwnd = null;
                    creation_blocked = false;
                } else {
                    const seq = self.resize_seq.load(.acquire);
                    if (seq != last_resize_seq) {
                        setClientSize(window, self.requested_width.load(.acquire), self.requested_height.load(.acquire));
                        last_resize_seq = seq;
                    }
                    const presentation_seq = self.presentation_seq.load(.acquire);
                    if (presentation_seq != last_presentation_seq) {
                        syncWindowPresentation(window, self);
                        last_presentation_seq = presentation_seq;
                    }
                }
            }

            std.Thread.sleep(15 * std.time.ns_per_ms);
        }

        if (hwnd) |window| {
            destroyWindow(window);
        }
    }
};

fn queueInputEvent(self: *Win32Backend, event: Win32Backend.InputEvent) void {
    self.input_lock.lock();
    defer self.input_lock.unlock();
    self.input_events.append(self.allocator, event) catch |err| {
        log.warn(.app, "win input queue overflow", .{ .err = err });
    };
}

const PresentationSnapshot = struct {
    title: []u8,
    url: []u8,
    body: []u8,
    display_list: ?DisplayList,
    scroll_px: i32,
    can_go_back: bool,
    can_go_forward: bool,
    is_loading: bool,
    address_text: []u8,
    address_editing: bool,

    fn deinit(self: PresentationSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.body);
        if (self.display_list) |display_list| {
            var owned_list = display_list;
            owned_list.deinit(allocator);
        }
        allocator.free(self.address_text);
    }
};

const PRESENTATION_HEADER_HEIGHT: c_int = 92;
const PRESENTATION_MARGIN: c_int = 12;
const PRESENTATION_SCROLL_STEP: i32 = 48;
const PRESENTATION_PAGE_STEP: i32 = 320;
const PRESENTATION_ADDRESS_TOP: c_int = 28;
const PRESENTATION_ADDRESS_BOTTOM: c_int = 52;
const PRESENTATION_HINT_TOP: c_int = 58;
const PRESENTATION_HINT_BOTTOM: c_int = 78;
const PRESENTATION_CHROME_BUTTON_WIDTH: c_int = 26;
const PRESENTATION_CHROME_BUTTON_GAP: c_int = 6;
const PRESENTATION_ADDRESS_LEFT_OFFSET: c_int =
    (PRESENTATION_CHROME_BUTTON_WIDTH * 3) + (PRESENTATION_CHROME_BUTTON_GAP * 3);

const ClientPoint = struct {
    x: f64,
    y: f64,
};

const ChromeButtonKind = enum {
    back,
    forward,
    reload,
};

fn presentationHasContent(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.presentation_body.len > 0 or
        backend.presentation_url.len > 0 or
        backend.presentation_title.len > 0 or
        backend.address_input_active;
}

fn copyPresentationSnapshot(backend: *Win32Backend) !PresentationSnapshot {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const address_source = if (backend.address_input_active) backend.address_input.items else backend.presentation_url;
    return .{
        .title = try backend.allocator.dupe(u8, backend.presentation_title),
        .url = try backend.allocator.dupe(u8, backend.presentation_url),
        .body = try backend.allocator.dupe(u8, backend.presentation_body),
        .display_list = if (backend.presentation_display_list) |*display_list|
            try display_list.cloneOwned(backend.allocator)
        else
            null,
        .scroll_px = backend.presentation_scroll_px,
        .can_go_back = backend.presentation_can_go_back,
        .can_go_forward = backend.presentation_can_go_forward,
        .is_loading = backend.presentation_is_loading,
        .address_text = try backend.allocator.dupe(u8, address_source),
        .address_editing = backend.address_input_active,
    };
}

fn presentationClientToPage(
    backend: *Win32Backend,
    x: f64,
    y: f64,
) ?ClientPoint {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const display_list = backend.presentation_display_list orelse return null;
    const scale = display_list.layout_scale;
    if (scale <= 0) {
        return null;
    }

    const content_x = x - @as(f64, @floatFromInt(PRESENTATION_MARGIN + display_list.page_margin));
    const content_y = y - @as(f64, @floatFromInt(PRESENTATION_HEADER_HEIGHT + 8 + display_list.page_margin)) +
        @as(f64, @floatFromInt(backend.presentation_scroll_px));
    if (content_x < 0 or content_y < 0) {
        return null;
    }

    return .{
        .x = content_x / @as(f64, @floatFromInt(scale)),
        .y = content_y / @as(f64, @floatFromInt(scale)),
    };
}

fn presentationHasNavigateAtClientPoint(backend: *Win32Backend, x: f64, y: f64) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return findPresentationNavigateUrlLocked(backend, x, y) != null;
}

fn presentationHasInteractiveAtClientPoint(backend: *Win32Backend, x: f64, y: f64) bool {
    return chromeCommandKindAtClientPointEnabled(backend, x, y) != null or presentationHasNavigateAtClientPoint(backend, x, y);
}

fn presentationCommandAtClientPoint(backend: *Win32Backend, x: f64, y: f64) ?BrowserCommand {
    if (chromeCommandKindAtClientPointEnabled(backend, x, y)) |kind| {
        return switch (kind) {
            .back => .back,
            .forward => .forward,
            .reload => if (presentationChromeShowsStop(backend)) .stop else .reload,
        };
    }
    return presentationNavigateCommandAtClientPoint(backend, x, y);
}

fn presentationNavigateCommandAtClientPoint(backend: *Win32Backend, x: f64, y: f64) ?BrowserCommand {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const url = findPresentationNavigateUrlLocked(backend, x, y) orelse return null;
    const owned = backend.allocator.dupe(u8, url) catch |err| {
        log.warn(.app, "win link hit dupe", .{ .err = err });
        return null;
    };
    return .{ .navigate = owned };
}

fn beginPendingPresentationCommand(backend: *Win32Backend, x: f64, y: f64) bool {
    const command = presentationCommandAtClientPoint(backend, x, y) orelse return false;
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (backend.pending_presentation_command) |pending| {
        pending.deinit(backend.allocator);
    }
    backend.pending_presentation_command = command;
    return true;
}

fn takePendingPresentationCommand(backend: *Win32Backend) ?BrowserCommand {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const command = backend.pending_presentation_command orelse return null;
    backend.pending_presentation_command = null;
    return command;
}

fn cancelPendingPresentationCommand(backend: *Win32Backend) void {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (backend.pending_presentation_command) |command| {
        command.deinit(backend.allocator);
        backend.pending_presentation_command = null;
    }
}

fn findPresentationNavigateUrlLocked(backend: *Win32Backend, x: f64, y: f64) ?[]const u8 {
    const display_list = backend.presentation_display_list orelse return null;

    const content_x = x - @as(f64, @floatFromInt(PRESENTATION_MARGIN));
    const content_y = y - @as(f64, @floatFromInt(PRESENTATION_HEADER_HEIGHT + 8)) +
        @as(f64, @floatFromInt(backend.presentation_scroll_px));
    if (content_x < 0 or content_y < 0) {
        return null;
    }

    const px: i32 = @intFromFloat(content_x);
    const py: i32 = @intFromFloat(content_y);
    var index = display_list.link_regions.items.len;
    while (index > 0) {
        index -= 1;
        const region = display_list.link_regions.items[index];
        if (px >= region.x and py >= region.y and px < region.x + region.width and py < region.y + region.height) {
            return region.url;
        }
    }
    return null;
}

fn chromeButtonRect(kind: ChromeButtonKind) c.RECT {
    const slot: c_int = switch (kind) {
        .back => 0,
        .forward => 1,
        .reload => 2,
    };
    const left = PRESENTATION_MARGIN + (slot * (PRESENTATION_CHROME_BUTTON_WIDTH + PRESENTATION_CHROME_BUTTON_GAP));
    return .{
        .left = left,
        .top = PRESENTATION_ADDRESS_TOP,
        .right = left + PRESENTATION_CHROME_BUTTON_WIDTH,
        .bottom = PRESENTATION_ADDRESS_BOTTOM,
    };
}

fn clientPointInRect(rect: c.RECT, x: f64, y: f64) bool {
    return x >= @as(f64, @floatFromInt(rect.left)) and
        x < @as(f64, @floatFromInt(rect.right)) and
        y >= @as(f64, @floatFromInt(rect.top)) and
        y < @as(f64, @floatFromInt(rect.bottom));
}

fn chromeCommandKindAtClientPoint(x: f64, y: f64) ?ChromeButtonKind {
    return chromeButtonKindAtClientPoint(x, y);
}

fn chromeButtonKindAtClientPoint(x: f64, y: f64) ?ChromeButtonKind {
    inline for ([_]ChromeButtonKind{ .back, .forward, .reload }) |kind| {
        if (clientPointInRect(chromeButtonRect(kind), x, y)) {
            return kind;
        }
    }
    return null;
}

fn chromeCommandKindAtClientPointEnabled(backend: *Win32Backend, x: f64, y: f64) ?ChromeButtonKind {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const kind = chromeButtonKindAtClientPoint(x, y) orelse return null;
    return switch (kind) {
        .back => if (backend.presentation_can_go_back) .back else null,
        .forward => if (backend.presentation_can_go_forward) .forward else null,
        .reload => if (backend.presentation_is_loading or backend.presentation_url.len > 0) .reload else null,
    };
}

fn presentationChromeShowsStop(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.presentation_is_loading;
}

fn setPresentationCursor(backend: *Win32Backend, x: f64, y: f64) void {
    const cursor_id: usize = if (presentationHasInteractiveAtClientPoint(backend, x, y)) 32649 else 32512;
    if (loadCursorResource(cursor_id)) |cursor| {
        _ = c.SetCursor(cursor);
    }
}

fn loadCursorResource(cursor_id: usize) c.HCURSOR {
    return LoadCursorWUnaligned(null, @ptrFromInt(cursor_id));
}

fn queueBrowserCommand(backend: *Win32Backend, command: BrowserCommand) void {
    backend.command_lock.lock();
    defer backend.command_lock.unlock();
    backend.command_queue.append(backend.allocator, command) catch |err| {
        command.deinit(backend.allocator);
        log.warn(.app, "win command queue failed", .{ .err = err });
    };
}

fn beginAddressEdit(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    backend.address_input.clearRetainingCapacity();
    backend.address_input.appendSlice(backend.allocator, backend.presentation_url) catch |err| {
        log.warn(.app, "win address edit failed", .{ .err = err });
        return false;
    };
    backend.address_input_active = true;
    backend.address_input_select_all = true;
    backend.address_pending_high_surrogate = null;
    return true;
}

fn cancelAddressEdit(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.address_input_active) {
        return false;
    }
    backend.address_input_active = false;
    backend.address_input_select_all = false;
    backend.address_input.clearRetainingCapacity();
    backend.address_pending_high_surrogate = null;
    return true;
}

fn commitAddressEdit(hwnd: c.HWND, backend: *Win32Backend) bool {
    _ = hwnd;

    backend.presentation_lock.lock();
    if (!backend.address_input_active) {
        backend.presentation_lock.unlock();
        return false;
    }

    const trimmed = std.mem.trim(u8, backend.address_input.items, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        backend.address_input_active = false;
        backend.address_input_select_all = false;
        backend.address_input.clearRetainingCapacity();
        backend.address_pending_high_surrogate = null;
        backend.presentation_lock.unlock();
        return true;
    }

    const url = backend.allocator.dupe(u8, trimmed) catch |err| {
        log.warn(.app, "win address commit failed", .{ .err = err });
        backend.presentation_lock.unlock();
        return false;
    };
    backend.address_input_active = false;
    backend.address_input_select_all = false;
    backend.address_input.clearRetainingCapacity();
    backend.address_pending_high_surrogate = null;
    backend.presentation_lock.unlock();
    queueBrowserCommand(backend, .{ .navigate = url });
    return true;
}

fn deleteLastAddressCodepoint(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.address_input_active or backend.address_input.items.len == 0) {
        return false;
    }
    if (backend.address_input_select_all) {
        backend.address_input.items.len = 0;
        backend.address_input_select_all = false;
        backend.address_pending_high_surrogate = null;
        return true;
    }

    var start = backend.address_input.items.len;
    while (start > 0) {
        start -= 1;
        if ((backend.address_input.items[start] & 0xC0) != 0x80) {
            break;
        }
    }
    backend.address_input.items.len = start;
    backend.address_pending_high_surrogate = null;
    return true;
}

fn appendAddressCodePoint(backend: *Win32Backend, cp_in: u32) bool {
    if (cp_in == 0 or cp_in > 0x10FFFF) {
        return false;
    }

    const cp: u21 = @intCast(if (cp_in == '\r') @as(u32, '\n') else cp_in);
    if (cp < 0x20 and cp != '\n' and cp != '\t') {
        return false;
    }
    if (!std.unicode.utf8ValidCodepoint(cp)) {
        return false;
    }

    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &bytes) catch return false;

    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    if (!backend.address_input_active) {
        return false;
    }
    if (backend.address_input_select_all) {
        backend.address_input.clearRetainingCapacity();
        backend.address_input_select_all = false;
    }
    backend.address_input.appendSlice(backend.allocator, bytes[0..len]) catch |err| {
        log.warn(.app, "win address append failed", .{ .err = err });
        return false;
    };
    return true;
}

fn appendAddressUtf16Unit(backend: *Win32Backend, code_unit: u16) bool {
    if (std.unicode.utf16IsHighSurrogate(code_unit)) {
        backend.presentation_lock.lock();
        backend.address_pending_high_surrogate = code_unit;
        backend.presentation_lock.unlock();
        return true;
    }
    if (std.unicode.utf16IsLowSurrogate(code_unit)) {
        backend.presentation_lock.lock();
        const high = backend.address_pending_high_surrogate;
        backend.address_pending_high_surrogate = null;
        backend.presentation_lock.unlock();
        if (high) |high_surrogate| {
            return appendAddressCodePoint(
                backend,
                std.unicode.utf16DecodeSurrogatePair(&.{ high_surrogate, code_unit }) catch return false,
            );
        }
        return false;
    }

    backend.presentation_lock.lock();
    backend.address_pending_high_surrogate = null;
    backend.presentation_lock.unlock();
    return appendAddressCodePoint(backend, code_unit);
}

fn appendClipboardToAddress(backend: *Win32Backend) bool {
    const clipboard = readClipboardTextUtf8(backend.allocator) catch |err| {
        log.warn(.app, "win clipboard read failed", .{ .err = err });
        return false;
    } orelse return false;
    defer backend.allocator.free(clipboard);

    const trimmed = std.mem.trim(u8, clipboard, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        return false;
    }

    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    if (!backend.address_input_active) {
        return false;
    }
    if (backend.address_input_select_all) {
        backend.address_input.clearRetainingCapacity();
        backend.address_input_select_all = false;
    }
    backend.address_input.appendSlice(backend.allocator, trimmed) catch |err| {
        log.warn(.app, "win address paste failed", .{ .err = err });
        return false;
    };
    backend.address_pending_high_surrogate = null;
    return true;
}

fn selectAllAddressInput(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    if (!backend.address_input_active) {
        return false;
    }
    backend.address_input_select_all = true;
    backend.address_pending_high_surrogate = null;
    return true;
}

fn addressBarHitTest(x: f64, y: f64) bool {
    return x >= @as(f64, @floatFromInt(PRESENTATION_MARGIN + PRESENTATION_ADDRESS_LEFT_OFFSET)) and
        y >= @as(f64, @floatFromInt(PRESENTATION_ADDRESS_TOP - 4)) and
        y <= @as(f64, @floatFromInt(PRESENTATION_ADDRESS_BOTTOM + 4));
}

fn updatePresentationMaxScroll(backend: *Win32Backend, max_scroll: i32) i32 {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    backend.presentation_max_scroll_px = @max(0, max_scroll);
    if (backend.presentation_scroll_px > backend.presentation_max_scroll_px) {
        backend.presentation_scroll_px = backend.presentation_max_scroll_px;
    }
    if (backend.presentation_scroll_px < 0) {
        backend.presentation_scroll_px = 0;
    }
    return backend.presentation_scroll_px;
}

fn scrollPresentationBy(backend: *Win32Backend, delta: i32) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const unclamped = backend.presentation_scroll_px + delta;
    const clamped = std.math.clamp(unclamped, 0, backend.presentation_max_scroll_px);
    if (clamped == backend.presentation_scroll_px) {
        return false;
    }
    backend.presentation_scroll_px = clamped;
    return true;
}

fn scrollPresentationTo(backend: *Win32Backend, value: i32) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();

    const clamped = std.math.clamp(value, 0, backend.presentation_max_scroll_px);
    if (clamped == backend.presentation_scroll_px) {
        return false;
    }
    backend.presentation_scroll_px = clamped;
    return true;
}

fn syncWindowPresentation(hwnd: c.HWND, backend: *Win32Backend) void {
    const snapshot = copyPresentationSnapshot(backend) catch |err| {
        log.warn(.app, "win snapshot failed", .{ .err = err });
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
        return;
    };
    defer snapshot.deinit(backend.allocator);

    const title = formatWindowTitle(backend.allocator, snapshot.title, snapshot.url) catch |err| {
        log.warn(.app, "win title format failed", .{ .err = err });
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
        return;
    };
    defer backend.allocator.free(title);

    setWindowTextUtf8(hwnd, title);
    _ = c.InvalidateRect(hwnd, null, c.TRUE);
}

fn formatWindowTitle(allocator: std.mem.Allocator, title: []const u8, url: []const u8) ![]u8 {
    const trimmed_title = std.mem.trim(u8, title, &std.ascii.whitespace);
    if (trimmed_title.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} - Lightpanda Browser", .{trimmed_title});
    }
    const trimmed_url = std.mem.trim(u8, url, &std.ascii.whitespace);
    if (trimmed_url.len > 0) {
        return std.fmt.allocPrint(allocator, "{s} - Lightpanda Browser", .{trimmed_url});
    }
    return allocator.dupe(u8, "Lightpanda Browser");
}

fn setWindowTextUtf8(hwnd: c.HWND, text: []const u8) void {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(utf16);
    _ = c.SetWindowTextW(hwnd, utf16.ptr);
}

fn drawChromeButton(hdc: c.HDC, rect: c.RECT, label: []const u8, enabled: bool) void {
    const fill = if (enabled)
        c.CreateSolidBrush(c.RGB(245, 245, 245))
    else
        c.CreateSolidBrush(c.RGB(236, 236, 236));
    if (fill != null) {
        defer _ = c.DeleteObject(fill);
        var fill_rect = rect;
        _ = c.FillRect(hdc, &fill_rect, fill);
    }

    const border = if (enabled)
        c.CreateSolidBrush(c.RGB(180, 180, 180))
    else
        c.CreateSolidBrush(c.RGB(210, 210, 210));
    if (border != null) {
        defer _ = c.DeleteObject(border);
        var border_rect = rect;
        _ = c.FrameRect(hdc, &border_rect, border);
    }

    const previous_color = c.SetTextColor(hdc, if (enabled) c.RGB(32, 32, 32) else c.RGB(150, 150, 150));
    defer _ = c.SetTextColor(hdc, previous_color);

    var text_rect = rect;
    drawPresentationText(
        hdc,
        &text_rect,
        label,
        c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOPREFIX,
    );
}

fn drawPresentationText(hdc: c.HDC, rect: *c.RECT, text: []const u8, flags: c.UINT) void {
    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, text) catch return;
    defer std.heap.c_allocator.free(utf16);
    if (utf16.len == 0) {
        return;
    }
    _ = c.DrawTextW(hdc, utf16.ptr, @intCast(utf16.len), rect, flags);
}

fn colorRef(color: DisplayColor) c.COLORREF {
    return @as(c.COLORREF, color.r) |
        (@as(c.COLORREF, color.g) << 8) |
        (@as(c.COLORREF, color.b) << 16);
}

fn ensureGdiplusStarted(backend: *Win32Backend) bool {
    if (backend.gdiplus_started) {
        return true;
    }

    var input = GdiplusStartupInput{
        .GdiplusVersion = 1,
        .DebugEventCallback = null,
        .SuppressBackgroundThread = c.FALSE,
        .SuppressExternalCodecs = c.FALSE,
    };
    var token: c.ULONG_PTR = 0;
    const status = GdiplusStartup(&token, &input, null);
    if (status != GDIP_STATUS_OK) {
        log.warn(.app, "win gdiplus startup failed", .{ .status = status });
        return false;
    }

    backend.gdiplus_token = token;
    backend.gdiplus_started = true;
    return true;
}

fn downloadHttpImageCacheFile(backend: *Win32Backend, url: []const u8) ![]u8 {
    const wide_url = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, url);
    defer std.heap.c_allocator.free(wide_url);

    var wide_path: [c.MAX_PATH + 1]u16 = [_]u16{0} ** (c.MAX_PATH + 1);
    const hr = c.URLDownloadToCacheFileW(
        null,
        wide_url.ptr,
        &wide_path,
        wide_path.len,
        0,
        null,
    );
    if (hr != 0) {
        return error.UrlDownloadFailed;
    }

    const path_len = std.mem.indexOfScalar(u16, wide_path[0..], 0) orelse wide_path.len;
    return std.unicode.utf16LeToUtf8Alloc(backend.allocator, wide_path[0..path_len]);
}

const CachedImageSource = struct {
    path: []u8,
    owns_file: bool = false,
};

fn localFilePathFromUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    if (!std.ascii.startsWithIgnoreCase(url, "file://")) {
        return error.UnsupportedImageUrl;
    }

    const after_scheme = url["file://".len..];
    const end = std.mem.indexOfAny(u8, after_scheme, "?#") orelse after_scheme.len;
    var raw_path = after_scheme[0..end];

    if (std.mem.startsWith(u8, raw_path, "localhost/")) {
        raw_path = raw_path["localhost".len..];
    }

    raw_path = std.mem.trimLeft(u8, raw_path, "/");
    if (raw_path.len == 0) {
        return error.InvalidFileUrl;
    }

    const unescaped = try URL.unescape(allocator, raw_path);
    defer if (unescaped.ptr != raw_path.ptr) allocator.free(unescaped);

    const owned = try allocator.dupe(u8, unescaped);
    for (owned) |*ch| {
        if (ch.* == '/') {
            ch.* = '\\';
        }
    }
    return owned;
}

fn parseDataUriBytes(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, src, "data:")) {
        return error.InvalidDataUrl;
    }

    const uri = src[5..];
    const data_starts = std.mem.indexOfScalar(u8, uri, ',') orelse return error.InvalidDataUrl;
    const data = uri[data_starts + 1 ..];

    const unescaped = try URL.unescape(allocator, data);
    const metadata = uri[0..data_starts];
    if (!std.mem.endsWith(u8, metadata, ";base64")) {
        defer if (unescaped.ptr != data.ptr) allocator.free(unescaped);
        return allocator.dupe(u8, unescaped);
    }
    defer if (unescaped.ptr != data.ptr) allocator.free(unescaped);

    var stripped = try std.ArrayList(u8).initCapacity(allocator, unescaped.len);
    defer stripped.deinit(allocator);
    for (unescaped) |cch| {
        if (!std.ascii.isWhitespace(cch)) {
            stripped.appendAssumeCapacity(cch);
        }
    }
    const trimmed = std.mem.trimRight(u8, stripped.items, "=");
    if (trimmed.len % 4 == 1) {
        return error.InvalidDataUrl;
    }

    const decoded_size = std.base64.standard_no_pad.Decoder.calcSizeForSlice(trimmed) catch return error.InvalidDataUrl;
    const buffer = try allocator.alloc(u8, decoded_size);
    std.base64.standard_no_pad.Decoder.decode(buffer, trimmed) catch return error.InvalidDataUrl;
    return buffer;
}

fn tempImageCacheFilePath(allocator: std.mem.Allocator, url: []const u8, extension: []const u8) ![]u8 {
    const temp_root = std.process.getEnvVarOwned(allocator, "TEMP") catch try allocator.dupe(u8, ".");
    defer allocator.free(temp_root);

    const cache_dir = try std.fs.path.join(allocator, &.{ temp_root, "lightpanda-image-cache" });
    defer allocator.free(cache_dir);
    if (std.fs.path.isAbsolute(cache_dir)) {
        std.fs.makeDirAbsolute(cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        std.fs.cwd().makePath(cache_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(url);
    const hash = hasher.final();
    return std.fmt.allocPrint(allocator, "{s}\\{x}.{s}", .{ cache_dir, hash, extension });
}

fn dataUriFileExtension(src: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, src, "data:")) {
        return "img";
    }

    const uri = src[5..];
    const data_starts = std.mem.indexOfScalar(u8, uri, ',') orelse return "img";
    const metadata = uri[0..data_starts];
    const media_type = metadata[0 .. std.mem.indexOfScalar(u8, metadata, ';') orelse metadata.len];

    if (std.ascii.eqlIgnoreCase(media_type, "image/png")) return "png";
    if (std.ascii.eqlIgnoreCase(media_type, "image/jpeg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(media_type, "image/jpg")) return "jpg";
    if (std.ascii.eqlIgnoreCase(media_type, "image/gif")) return "gif";
    if (std.ascii.eqlIgnoreCase(media_type, "image/webp")) return "webp";
    if (std.ascii.eqlIgnoreCase(media_type, "image/bmp")) return "bmp";
    return "img";
}

fn writeDataImageCacheFile(backend: *Win32Backend, url: []const u8) ![]u8 {
    const data = try parseDataUriBytes(backend.allocator, url);
    defer backend.allocator.free(data);

    const path = try tempImageCacheFilePath(backend.allocator, url, dataUriFileExtension(url));
    errdefer backend.allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
    return path;
}

fn resolveImageCacheSource(backend: *Win32Backend, url: []const u8) !CachedImageSource {
    if (std.ascii.startsWithIgnoreCase(url, "http://") or
        std.ascii.startsWithIgnoreCase(url, "https://"))
    {
        return .{ .path = try downloadHttpImageCacheFile(backend, url) };
    }
    if (std.ascii.startsWithIgnoreCase(url, "file://")) {
        return .{ .path = try localFilePathFromUrl(backend.allocator, url) };
    }
    if (std.ascii.startsWithIgnoreCase(url, "data:")) {
        return .{ .path = try writeDataImageCacheFile(backend, url), .owns_file = true };
    }
    return error.UnsupportedImageUrl;
}

fn loadCachedImageLocked(backend: *Win32Backend, image: *CachedImage, url: []const u8) void {
    if (!ensureGdiplusStarted(backend)) {
        image.state = .failed;
        return;
    }

    const source = resolveImageCacheSource(backend, url) catch |err| {
        log.warn(.app, "win image src fail", .{ .url = url, .err = err });
        image.state = .failed;
        return;
    };
    const cache_path = source.path;
    errdefer backend.allocator.free(cache_path);

    const wide_path = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, cache_path) catch |err| {
        log.warn(.app, "win image path encode failed", .{ .path = cache_path, .err = err });
        image.state = .failed;
        return;
    };
    defer std.heap.c_allocator.free(wide_path);

    var gp_image: ?*GpImage = null;
    const status = GdipLoadImageFromFile(wide_path.ptr, &gp_image);
    if (status != GDIP_STATUS_OK or gp_image == null) {
        log.warn(.app, "win image decode failed", .{ .status = status, .path = cache_path });
        image.state = .failed;
        return;
    }

    var width: c.UINT = 0;
    var height: c.UINT = 0;
    if (GdipGetImageWidth(gp_image.?, &width) != GDIP_STATUS_OK or
        GdipGetImageHeight(gp_image.?, &height) != GDIP_STATUS_OK)
    {
        _ = GdipDisposeImage(gp_image.?);
        log.warn(.app, "win image dimension failed", .{ .path = cache_path });
        image.state = .failed;
        return;
    }

    image.cache_path = cache_path;
    image.gp_image = gp_image;
    image.width = width;
    image.height = height;
    image.owns_cache_file = source.owns_file;
    image.state = .loaded;
}

fn imagePlaceholderText(image: ImageCommand) []const u8 {
    const alt = std.mem.trim(u8, image.alt, &std.ascii.whitespace);
    if (alt.len > 0) {
        return alt;
    }

    const basename = std.fs.path.basename(image.url);
    if (basename.len > 0 and !std.mem.eql(u8, basename, "/")) {
        return basename;
    }

    return "[image]";
}

fn drawPresentationImagePlaceholder(hdc: c.HDC, rect: c.RECT, image: ImageCommand) void {
    var text_rect = rect;
    text_rect.left += 8;
    text_rect.top += 8;
    text_rect.right -= 8;
    text_rect.bottom -= 8;

    const previous = c.SetTextColor(hdc, colorRef(.{ .r = 110, .g = 110, .b = 110 }));
    defer _ = c.SetTextColor(hdc, previous);

    drawPresentationText(
        hdc,
        &text_rect,
        imagePlaceholderText(image),
        c.DT_CENTER | c.DT_VCENTER | c.DT_WORDBREAK | c.DT_NOPREFIX,
    );
}

fn fitImageRect(rect: c.RECT, image_width: u32, image_height: u32) c.RECT {
    const target_width = rect.right - rect.left;
    const target_height = rect.bottom - rect.top;
    if (target_width <= 0 or target_height <= 0 or image_width == 0 or image_height == 0) {
        return rect;
    }

    const width_scale = @as(f64, @floatFromInt(target_width)) / @as(f64, @floatFromInt(image_width));
    const height_scale = @as(f64, @floatFromInt(target_height)) / @as(f64, @floatFromInt(image_height));
    const scale = @min(width_scale, height_scale);
    const draw_width: c.INT = @max(1, @as(c.INT, @intFromFloat(@round(@as(f64, @floatFromInt(image_width)) * scale))));
    const draw_height: c.INT = @max(1, @as(c.INT, @intFromFloat(@round(@as(f64, @floatFromInt(image_height)) * scale))));
    const offset_x = @divTrunc(target_width - draw_width, 2);
    const offset_y = @divTrunc(target_height - draw_height, 2);

    return .{
        .left = rect.left + offset_x,
        .top = rect.top + offset_y,
        .right = rect.left + offset_x + draw_width,
        .bottom = rect.top + offset_y + draw_height,
    };
}

fn drawPresentationImage(
    backend: *Win32Backend,
    hdc: c.HDC,
    rect: c.RECT,
    image_cmd: ImageCommand,
) void {
    backend.image_cache_lock.lock();
    defer backend.image_cache_lock.unlock();

    const owned_key = backend.allocator.dupe(u8, image_cmd.url) catch {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
        return;
    };
    errdefer backend.allocator.free(owned_key);

    const gop = backend.image_cache.getOrPut(backend.allocator, owned_key) catch {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
        return;
    };
    if (gop.found_existing) {
        backend.allocator.free(owned_key);
    } else {
        gop.key_ptr.* = owned_key;
        gop.value_ptr.* = .{};
    }

    const cached = gop.value_ptr;
    if (cached.state == .unloaded) {
        loadCachedImageLocked(backend, cached, image_cmd.url);
    }

    if (cached.state != .loaded or cached.gp_image == null) {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
        return;
    }

    var graphics: ?*GpGraphics = null;
    if (GdipCreateFromHDC(hdc, &graphics) != GDIP_STATUS_OK or graphics == null) {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
        return;
    }
    defer _ = GdipDeleteGraphics(graphics.?);

    const draw_rect = fitImageRect(rect, cached.width, cached.height);
    const status = GdipDrawImageRectI(
        graphics.?,
        cached.gp_image.?,
        draw_rect.left,
        draw_rect.top,
        draw_rect.right - draw_rect.left,
        draw_rect.bottom - draw_rect.top,
    );
    if (status != GDIP_STATUS_OK) {
        drawPresentationImagePlaceholder(hdc, rect, image_cmd);
    }
}

fn renderPresentationDisplayList(
    backend: *Win32Backend,
    hdc: c.HDC,
    client: c.RECT,
    snapshot: *const PresentationSnapshot,
    scroll_px: i32,
) void {
    const display_list = snapshot.display_list orelse return;
    for (display_list.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect_cmd| {
                var rect = c.RECT{
                    .left = client.left + PRESENTATION_MARGIN + rect_cmd.x,
                    .top = PRESENTATION_HEADER_HEIGHT + 8 + rect_cmd.y - scroll_px,
                    .right = client.left + PRESENTATION_MARGIN + rect_cmd.x + rect_cmd.width,
                    .bottom = PRESENTATION_HEADER_HEIGHT + 8 + rect_cmd.y - scroll_px + rect_cmd.height,
                };
                const brush = c.CreateSolidBrush(colorRef(rect_cmd.color));
                if (brush == null) continue;
                defer _ = c.DeleteObject(brush);
                _ = c.FillRect(hdc, &rect, brush);
            },
            .stroke_rect => |rect_cmd| {
                var rect = c.RECT{
                    .left = client.left + PRESENTATION_MARGIN + rect_cmd.x,
                    .top = PRESENTATION_HEADER_HEIGHT + 8 + rect_cmd.y - scroll_px,
                    .right = client.left + PRESENTATION_MARGIN + rect_cmd.x + rect_cmd.width,
                    .bottom = PRESENTATION_HEADER_HEIGHT + 8 + rect_cmd.y - scroll_px + rect_cmd.height,
                };
                const brush = c.CreateSolidBrush(colorRef(rect_cmd.color));
                if (brush == null) continue;
                defer _ = c.DeleteObject(brush);
                _ = c.FrameRect(hdc, &rect, brush);
            },
            .text => |text_cmd| {
                var rect = c.RECT{
                    .left = client.left + PRESENTATION_MARGIN + text_cmd.x,
                    .top = PRESENTATION_HEADER_HEIGHT + 8 + text_cmd.y - scroll_px,
                    .right = client.left + PRESENTATION_MARGIN + text_cmd.x + text_cmd.width,
                    .bottom = client.bottom + snapshot.display_list.?.content_height,
                };
                const previous = c.SetTextColor(hdc, colorRef(text_cmd.color));
                const font_height: c_int = -@as(c_int, @intCast(@max(@as(i32, 1), text_cmd.font_size)));
                const font = c.CreateFontW(
                    font_height,
                    0,
                    0,
                    0,
                    c.FW_NORMAL,
                    0,
                    @as(c.DWORD, @intFromBool(text_cmd.underline)),
                    0,
                    c.DEFAULT_CHARSET,
                    c.OUT_DEFAULT_PRECIS,
                    c.CLIP_DEFAULT_PRECIS,
                    c.CLEARTYPE_QUALITY,
                    c.DEFAULT_PITCH | c.FF_SWISS,
                    null,
                );
                const previous_font = if (font != null) c.SelectObject(hdc, font) else null;
                defer if (font != null) {
                    _ = c.SelectObject(hdc, previous_font);
                    _ = c.DeleteObject(font);
                };
                drawPresentationText(
                    hdc,
                    &rect,
                    text_cmd.text,
                    c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_NOPREFIX,
                );
                _ = c.SetTextColor(hdc, previous);
            },
            .image => |image_cmd| {
                const rect = c.RECT{
                    .left = client.left + PRESENTATION_MARGIN + image_cmd.x,
                    .top = PRESENTATION_HEADER_HEIGHT + 8 + image_cmd.y - scroll_px,
                    .right = client.left + PRESENTATION_MARGIN + image_cmd.x + image_cmd.width,
                    .bottom = PRESENTATION_HEADER_HEIGHT + 8 + image_cmd.y - scroll_px + image_cmd.height,
                };
                drawPresentationImage(backend, hdc, rect, image_cmd);
            },
        }
    }
}

fn renderPresentationScene(
    backend: *Win32Backend,
    hdc: c.HDC,
    client: c.RECT,
    snapshot: *const PresentationSnapshot,
    scroll_px: i32,
    allocator: std.mem.Allocator,
) void {
    const white_brush = c.CreateSolidBrush(c.RGB(255, 255, 255));
    if (white_brush != null) {
        defer _ = c.DeleteObject(white_brush);
        _ = c.FillRect(hdc, &client, white_brush);
    }
    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    var title_rect = c.RECT{
        .left = client.left + PRESENTATION_MARGIN,
        .top = client.top + 8,
        .right = client.right - PRESENTATION_MARGIN,
        .bottom = client.top + 24,
    };
    const title_text = if (snapshot.title.len > 0) snapshot.title else "Lightpanda Browser";
    drawPresentationText(
        hdc,
        &title_rect,
        title_text,
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );

    drawChromeButton(hdc, chromeButtonRect(.back), "<", snapshot.can_go_back);
    drawChromeButton(hdc, chromeButtonRect(.forward), ">", snapshot.can_go_forward);
    drawChromeButton(
        hdc,
        chromeButtonRect(.reload),
        if (snapshot.is_loading) "X" else "R",
        snapshot.is_loading or snapshot.url.len > 0,
    );

    var address_buf = std.Io.Writer.Allocating.init(allocator);
    defer address_buf.deinit();
    if (snapshot.address_editing) {
        address_buf.writer.print("Address: {s}_", .{snapshot.address_text}) catch return;
    } else if (snapshot.address_text.len > 0) {
        address_buf.writer.print("Address: {s}", .{snapshot.address_text}) catch return;
    } else {
        address_buf.writer.writeAll("Address: Ctrl+L or click here") catch return;
    }

    var address_rect = c.RECT{
        .left = client.left + PRESENTATION_MARGIN + PRESENTATION_ADDRESS_LEFT_OFFSET,
        .top = client.top + PRESENTATION_ADDRESS_TOP,
        .right = client.right - PRESENTATION_MARGIN,
        .bottom = client.top + PRESENTATION_ADDRESS_BOTTOM,
    };
    drawPresentationText(
        hdc,
        &address_rect,
        address_buf.written(),
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );

    var hint_rect = c.RECT{
        .left = client.left + PRESENTATION_MARGIN,
        .top = client.top + PRESENTATION_HINT_TOP,
        .right = client.right - PRESENTATION_MARGIN,
        .bottom = client.top + PRESENTATION_HINT_BOTTOM,
    };
    const hint_text = "Ctrl+L address  Alt+Left back  Alt+Right forward  F5 reload  Esc stop  Ctrl+Shift+S bmp  Ctrl+Shift+P png";
    drawPresentationText(
        hdc,
        &hint_rect,
        hint_text,
        c.DT_LEFT | c.DT_TOP | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX,
    );

    _ = c.MoveToEx(hdc, client.left + PRESENTATION_MARGIN, PRESENTATION_HEADER_HEIGHT, null);
    _ = c.LineTo(hdc, client.right - PRESENTATION_MARGIN, PRESENTATION_HEADER_HEIGHT);

    if (snapshot.display_list) |_| {
        renderPresentationDisplayList(backend, hdc, client, snapshot, scroll_px);
        return;
    }

    const body_text = if (snapshot.body.len > 0) snapshot.body else "Loading page...";
    const body_utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, body_text) catch return;
    defer std.heap.c_allocator.free(body_utf16);

    if (body_utf16.len == 0) {
        return;
    }

    var measure_rect = c.RECT{
        .left = 0,
        .top = 0,
        .right = @max(1, client.right - (PRESENTATION_MARGIN * 2)),
        .bottom = 0,
    };
    _ = c.DrawTextW(
        hdc,
        body_utf16.ptr,
        @intCast(body_utf16.len),
        &measure_rect,
        c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_NOPREFIX | c.DT_CALCRECT,
    );

    const content_height = measure_rect.bottom - measure_rect.top;

    var body_rect = c.RECT{
        .left = client.left + PRESENTATION_MARGIN,
        .top = PRESENTATION_HEADER_HEIGHT + 8 - scroll_px,
        .right = client.right - PRESENTATION_MARGIN,
        .bottom = PRESENTATION_HEADER_HEIGHT + 8 - scroll_px + content_height,
    };
    _ = c.DrawTextW(
        hdc,
        body_utf16.ptr,
        @intCast(body_utf16.len),
        &body_rect,
        c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_NOPREFIX,
    );
}

fn renderWindowPresentation(hwnd: c.HWND, backend: *Win32Backend) void {
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps);
    defer _ = c.EndPaint(hwnd, &ps);
    if (hdc == null) {
        return;
    }

    const snapshot = copyPresentationSnapshot(backend) catch |err| {
        log.warn(.app, "win snapshot failed", .{ .err = err });
        return;
    };
    defer snapshot.deinit(backend.allocator);

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const visible_height = @max(0, client.bottom - PRESENTATION_HEADER_HEIGHT - PRESENTATION_MARGIN);
    const scroll_px = if (snapshot.display_list) |display_list|
        updatePresentationMaxScroll(backend, display_list.content_height - visible_height)
    else
        snapshot.scroll_px;

    renderPresentationScene(backend, hdc, client, &snapshot, scroll_px, backend.allocator);
}

const BitmapFileHeader = extern struct {
    bfType: u16,
    bfSize: u32,
    bfReserved1: u16,
    bfReserved2: u16,
    bfOffBits: u32,
};

const RenderedPresentation = struct {
    snapshot: PresentationSnapshot,
    width: c_int,
    height: c_int,
    pixels: []u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *RenderedPresentation) void {
        self.snapshot.deinit(self.allocator);
        self.allocator.free(self.pixels);
    }
};

fn openOutputFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, .{});
    }
    return std.fs.cwd().createFile(path, .{});
}

fn capturePresentationPixels(backend: *Win32Backend) !RenderedPresentation {
    const snapshot = try copyPresentationSnapshot(backend);
    errdefer snapshot.deinit(backend.allocator);

    const width = clampU32ToCInt(backend.requested_width.load(.acquire));
    const height = clampU32ToCInt(backend.requested_height.load(.acquire));
    if (width <= 0 or height <= 0) {
        return error.InvalidDimensions;
    }

    const mem_dc = c.CreateCompatibleDC(null);
    if (mem_dc == null) {
        return error.CreateCompatibleDcFailed;
    }
    defer _ = c.DeleteDC(mem_dc);

    var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = width;
    bmi.bmiHeader.biHeight = -height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var bits: ?*anyopaque = null;
    const hbitmap = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
    if (hbitmap == null or bits == null) {
        return error.CreateDibSectionFailed;
    }
    defer _ = c.DeleteObject(hbitmap);

    const previous_bitmap = c.SelectObject(mem_dc, hbitmap);
    defer _ = c.SelectObject(mem_dc, previous_bitmap);

    const client = c.RECT{
        .left = 0,
        .top = 0,
        .right = width,
        .bottom = height,
    };
    renderPresentationScene(backend, mem_dc, client, &snapshot, snapshot.scroll_px, backend.allocator);

    const pixel_bytes = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const owned_pixels = try backend.allocator.alloc(u8, pixel_bytes);
    errdefer backend.allocator.free(owned_pixels);

    const src_pixels: [*]u8 = @ptrCast(bits.?);
    @memcpy(owned_pixels, src_pixels[0..pixel_bytes]);

    return .{
        .snapshot = snapshot,
        .width = width,
        .height = height,
        .pixels = owned_pixels,
        .allocator = backend.allocator,
    };
}

fn savePresentationPngAuto(backend: *Win32Backend) bool {
    const filename = std.fmt.allocPrint(
        backend.allocator,
        "lightpanda-screenshot-{d}.png",
        .{std.time.timestamp()},
    ) catch |err| {
        log.warn(.app, "win png name fail", .{ .err = err });
        return false;
    };
    defer backend.allocator.free(filename);
    return savePresentationPng(backend, filename);
}

fn savePresentationBitmapAuto(backend: *Win32Backend) bool {
    const filename = std.fmt.allocPrint(
        backend.allocator,
        "lightpanda-screenshot-{d}.bmp",
        .{std.time.timestamp()},
    ) catch |err| {
        log.warn(.app, "win bmp name failed", .{ .err = err });
        return false;
    };
    defer backend.allocator.free(filename);
    return savePresentationBitmap(backend, filename);
}

fn savePresentationBitmap(backend: *Win32Backend, path: []const u8) bool {
    var rendered = capturePresentationPixels(backend) catch |err| {
        log.warn(.app, "win snapshot failed", .{ .err = err });
        return false;
    };
    defer rendered.deinit();

    const pixel_bytes = rendered.pixels.len;
    const headers_bytes = @sizeOf(BitmapFileHeader) + @sizeOf(c.BITMAPINFOHEADER);
    const file = openOutputFile(path) catch |err| {
        log.warn(.app, "win bmp create failed", .{ .err = err });
        return false;
    };
    defer file.close();

    const file_header = BitmapFileHeader{
        .bfType = 0x4D42,
        .bfSize = @intCast(headers_bytes + pixel_bytes),
        .bfReserved1 = 0,
        .bfReserved2 = 0,
        .bfOffBits = headers_bytes,
    };
    var bmi_header: c.BITMAPINFOHEADER = std.mem.zeroes(c.BITMAPINFOHEADER);
    bmi_header.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi_header.biWidth = rendered.width;
    bmi_header.biHeight = -rendered.height;
    bmi_header.biPlanes = 1;
    bmi_header.biBitCount = 32;
    bmi_header.biCompression = c.BI_RGB;

    file.writeAll(std.mem.asBytes(&file_header)) catch |err| {
        log.warn(.app, "win bmp write failed", .{ .err = err });
        return false;
    };
    file.writeAll(std.mem.asBytes(&bmi_header)) catch |err| {
        log.warn(.app, "win bmp write failed", .{ .err = err });
        return false;
    };

    file.writeAll(rendered.pixels[0..pixel_bytes]) catch |err| {
        log.warn(.app, "win bmp write failed", .{ .err = err });
        return false;
    };
    log.info(.app, "win bmp saved", .{ .path = path });
    return true;
}

fn savePresentationPng(backend: *Win32Backend, path: []const u8) bool {
    var rendered = capturePresentationPixels(backend) catch |err| {
        log.warn(.app, "win snapshot failed", .{ .err = err });
        return false;
    };
    defer rendered.deinit();

    var file = openOutputFile(path) catch |err| {
        log.warn(.app, "win png create fail", .{ .err = err });
        return false;
    };
    defer file.close();

    writePngFromBgra(
        &file,
        @intCast(rendered.width),
        @intCast(rendered.height),
        rendered.pixels,
        backend.allocator,
    ) catch |err| {
        log.warn(.app, "win png write fail", .{ .err = err });
        return false;
    };
    log.info(.app, "win png saved", .{ .path = path });
    return true;
}

fn writePngFromBgra(
    file: *std.fs.File,
    width: u32,
    height: u32,
    bgra_pixels: []const u8,
    allocator: std.mem.Allocator,
) !void {
    try file.writeAll("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    storeBigEndianU32(ihdr[0..4], width);
    storeBigEndianU32(ihdr[4..8], height);
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writePngChunk(file, "IHDR".*, &ihdr);

    const row_bytes = @as(usize, width) * 3 + 1;
    const scanline_bytes = row_bytes * @as(usize, height);
    const scanlines = try allocator.alloc(u8, scanline_bytes);
    defer allocator.free(scanlines);

    var src_index: usize = 0;
    var dst_index: usize = 0;
    for (0..height) |_| {
        scanlines[dst_index] = 0;
        dst_index += 1;
        for (0..width) |_| {
            scanlines[dst_index + 0] = bgra_pixels[src_index + 2];
            scanlines[dst_index + 1] = bgra_pixels[src_index + 1];
            scanlines[dst_index + 2] = bgra_pixels[src_index + 0];
            src_index += 4;
            dst_index += 3;
        }
    }

    try writePngIdatStored(file, scanlines);
    try writePngChunk(file, "IEND".*, &.{});
}

fn writePngChunk(file: *std.fs.File, chunk_type: [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    storeBigEndianU32(&len_buf, @intCast(data.len));
    try file.writeAll(&len_buf);
    try file.writeAll(&chunk_type);
    try file.writeAll(data);

    var crc = crc32Init();
    crc = crc32Update(crc, &chunk_type);
    crc = crc32Update(crc, data);
    var crc_buf: [4]u8 = undefined;
    storeBigEndianU32(&crc_buf, crc32Final(crc));
    try file.writeAll(&crc_buf);
}

fn writePngIdatStored(file: *std.fs.File, data: []const u8) !void {
    const block_count = if (data.len == 0) 1 else (data.len + 65534) / 65535;
    const compressed_len = 2 + data.len + block_count * 5 + 4;

    var len_buf: [4]u8 = undefined;
    storeBigEndianU32(&len_buf, @intCast(compressed_len));
    try file.writeAll(&len_buf);

    const chunk_type = "IDAT".*;
    try file.writeAll(&chunk_type);

    var crc = crc32Init();
    crc = crc32Update(crc, &chunk_type);

    const zlib_header = [_]u8{ 0x78, 0x01 };
    try file.writeAll(&zlib_header);
    crc = crc32Update(crc, &zlib_header);

    var offset: usize = 0;
    while (true) {
        const remaining = data.len - offset;
        const block_len: u16 = @intCast(@min(remaining, 65535));
        const final_block = remaining <= 65535;
        const block_header = [_]u8{if (final_block) 0x01 else 0x00};
        try file.writeAll(&block_header);
        crc = crc32Update(crc, &block_header);

        const len_bytes = [_]u8{
            @truncate(block_len),
            @truncate(block_len >> 8),
            @truncate(~block_len),
            @truncate((~block_len) >> 8),
        };
        try file.writeAll(&len_bytes);
        crc = crc32Update(crc, &len_bytes);

        if (block_len > 0) {
            const block = data[offset .. offset + block_len];
            try file.writeAll(block);
            crc = crc32Update(crc, block);
            offset += block_len;
        }

        if (final_block) {
            break;
        }
    }

    var adler_buf: [4]u8 = undefined;
    storeBigEndianU32(&adler_buf, adler32(data));
    try file.writeAll(&adler_buf);
    crc = crc32Update(crc, &adler_buf);

    var crc_buf: [4]u8 = undefined;
    storeBigEndianU32(&crc_buf, crc32Final(crc));
    try file.writeAll(&crc_buf);
}

fn storeBigEndianU32(buf: []u8, value: u32) void {
    buf[0] = @truncate(value >> 24);
    buf[1] = @truncate(value >> 16);
    buf[2] = @truncate(value >> 8);
    buf[3] = @truncate(value);
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn crc32Init() u32 {
    return 0xFFFF_FFFF;
}

fn crc32Update(initial: u32, data: []const u8) u32 {
    var crc = initial;
    for (data) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            const mask: u32 = @bitCast(-@as(i32, @intCast(crc & 1)));
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return crc;
}

fn crc32Final(crc: u32) u32 {
    return ~crc;
}

fn handlePresentationScrollKey(hwnd: c.HWND, backend: *Win32Backend, vk: u32) bool {
    if (!presentationHasContent(backend)) {
        return false;
    }

    const changed = switch (vk) {
        c.VK_UP => scrollPresentationBy(backend, -PRESENTATION_SCROLL_STEP),
        c.VK_DOWN => scrollPresentationBy(backend, PRESENTATION_SCROLL_STEP),
        c.VK_PRIOR => scrollPresentationBy(backend, -PRESENTATION_PAGE_STEP),
        c.VK_NEXT => scrollPresentationBy(backend, PRESENTATION_PAGE_STEP),
        c.VK_HOME => scrollPresentationTo(backend, 0),
        c.VK_END => scrollPresentationTo(backend, std.math.maxInt(i32)),
        else => false,
    };
    if (changed) {
        _ = c.InvalidateRect(hwnd, null, c.TRUE);
    }
    return changed;
}

fn presentationAddressEditing(backend: *Win32Backend) bool {
    backend.presentation_lock.lock();
    defer backend.presentation_lock.unlock();
    return backend.address_input_active;
}

fn handlePresentationShortcutKey(
    hwnd: c.HWND,
    backend: *Win32Backend,
    vk: u32,
    modifiers: Page.KeyboardModifiers,
) bool {
    if (!presentationHasContent(backend)) {
        return false;
    }

    if (presentationAddressEditing(backend)) {
        const handled = switch (vk) {
            c.VK_ESCAPE => cancelAddressEdit(backend),
            c.VK_RETURN => commitAddressEdit(hwnd, backend),
            c.VK_BACK => deleteLastAddressCodepoint(backend),
            'A' => modifiers.ctrl and selectAllAddressInput(backend),
            'V' => modifiers.ctrl and appendClipboardToAddress(backend),
            else => false,
        };
        if (handled) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
        }
        return handled;
    }

    if (modifiers.ctrl and vk == 'L') {
        if (beginAddressEdit(backend)) {
            _ = c.InvalidateRect(hwnd, null, c.TRUE);
            return true;
        }
        return false;
    }
    if (vk == c.VK_ESCAPE and presentationChromeShowsStop(backend)) {
        queueBrowserCommand(backend, .stop);
        return true;
    }
    if ((modifiers.alt or modifiers.meta) and vk == c.VK_LEFT) {
        queueBrowserCommand(backend, .back);
        return true;
    }
    if ((modifiers.alt or modifiers.meta) and vk == c.VK_RIGHT) {
        queueBrowserCommand(backend, .forward);
        return true;
    }
    if (vk == c.VK_F5 or (modifiers.ctrl and vk == 'R')) {
        queueBrowserCommand(backend, .reload);
        return true;
    }
    if (modifiers.ctrl and modifiers.shift and vk == 'S') {
        return savePresentationBitmapAuto(backend);
    }
    if (modifiers.ctrl and modifiers.shift and vk == 'P') {
        return savePresentationPngAuto(backend);
    }

    return false;
}

const ClipboardShortcutAction = enum {
    copy,
    cut,
    paste,
};

fn clipboardShortcutAction(vk: u32, modifiers: Page.KeyboardModifiers) ?ClipboardShortcutAction {
    const only_primary_accel = (modifiers.ctrl or modifiers.meta) and !modifiers.alt and !modifiers.shift;
    if (only_primary_accel) {
        return switch (vk) {
            'C' => .copy,
            'X' => .cut,
            'V' => .paste,
            c.VK_INSERT => .copy,
            else => null,
        };
    }

    const only_shift = modifiers.shift and !modifiers.ctrl and !modifiers.meta and !modifiers.alt;
    if (only_shift) {
        return switch (vk) {
            c.VK_INSERT => .paste,
            c.VK_DELETE => .cut,
            else => null,
        };
    }

    return null;
}

fn handleClipboardShortcut(allocator: std.mem.Allocator, page: *Page, action: ClipboardShortcutAction) !void {
    switch (action) {
        .copy => {
            if (!(try page.triggerClipboardEvent("copy"))) {
                return;
            }
            const selection = page.getActiveTextSelection() orelse return;
            _ = try writeClipboardTextUtf8(allocator, selection);
        },
        .cut => {
            if (!(try page.triggerClipboardEvent("cut"))) {
                return;
            }
            const selection = page.getActiveTextSelection() orelse return;
            if (try writeClipboardTextUtf8(allocator, selection)) {
                _ = try page.deleteActiveTextSelection();
            }
        },
        .paste => {
            if (!(try page.triggerClipboardEvent("paste"))) {
                return;
            }
            const text = try readClipboardTextUtf8(allocator) orelse return;
            defer allocator.free(text);
            try page.insertText(text);
        },
    }
}

fn writeClipboardTextUtf8(allocator: std.mem.Allocator, text: []const u8) !bool {
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(utf16);

    const utf16_full = utf16[0 .. utf16.len + 1];
    const utf16_bytes = std.mem.sliceAsBytes(utf16_full);

    const handle = c.GlobalAlloc(c.GMEM_MOVEABLE, utf16_bytes.len);
    if (handle == null) {
        return false;
    }

    var ownership_transferred = false;
    defer if (!ownership_transferred) {
        _ = c.GlobalFree(handle);
    };

    const data = c.GlobalLock(handle) orelse return false;
    defer _ = c.GlobalUnlock(handle);

    const dst: [*]u8 = @ptrCast(data);
    @memcpy(dst[0..utf16_bytes.len], utf16_bytes);

    if (c.OpenClipboard(null) == 0) {
        return false;
    }
    defer _ = c.CloseClipboard();

    if (c.EmptyClipboard() == 0) {
        return false;
    }

    if (c.SetClipboardData(c.CF_UNICODETEXT, handle) == null) {
        return false;
    }

    ownership_transferred = true;
    return true;
}

fn readClipboardTextUtf8(allocator: std.mem.Allocator) !?[]u8 {
    if (c.OpenClipboard(null) == 0) {
        return null;
    }
    defer _ = c.CloseClipboard();

    const handle = c.GetClipboardData(c.CF_UNICODETEXT);
    if (handle == null) {
        return null;
    }

    const data = c.GlobalLock(handle) orelse return null;
    defer _ = c.GlobalUnlock(handle);

    const utf16_ptr: [*:0]const u16 = @ptrCast(@alignCast(data));
    const utf16 = std.mem.span(utf16_ptr);
    if (utf16.len == 0) {
        return null;
    }
    return try std.unicode.utf16LeToUtf8Alloc(allocator, utf16);
}

fn mapVirtualKey(vk: u32, shift: bool, key_buf: *[2]u8) ?[]const u8 {
    switch (vk) {
        c.VK_SHIFT, c.VK_LSHIFT, c.VK_RSHIFT => return "Shift",
        c.VK_CONTROL, c.VK_LCONTROL, c.VK_RCONTROL => return "Control",
        c.VK_MENU, c.VK_LMENU, c.VK_RMENU => return "Alt",
        c.VK_LWIN, c.VK_RWIN => return "Meta",
        c.VK_CAPITAL => return "CapsLock",
        c.VK_NUMLOCK => return "NumLock",
        c.VK_SCROLL => return "ScrollLock",
        c.VK_PAUSE => return "Pause",
        c.VK_RETURN => return "Enter",
        c.VK_TAB => return "Tab",
        c.VK_BACK => return "Backspace",
        c.VK_DELETE => return "Delete",
        c.VK_INSERT => return "Insert",
        c.VK_CLEAR => return "Clear",
        c.VK_SNAPSHOT => return "PrintScreen",
        c.VK_APPS => return "ContextMenu",
        c.VK_ESCAPE => return "Escape",
        c.VK_SPACE => return " ",
        c.VK_LEFT => return "ArrowLeft",
        c.VK_RIGHT => return "ArrowRight",
        c.VK_UP => return "ArrowUp",
        c.VK_DOWN => return "ArrowDown",
        c.VK_HOME => return "Home",
        c.VK_END => return "End",
        c.VK_PRIOR => return "PageUp",
        c.VK_NEXT => return "PageDown",
        c.VK_F1 => return "F1",
        c.VK_F2 => return "F2",
        c.VK_F3 => return "F3",
        c.VK_F4 => return "F4",
        c.VK_F5 => return "F5",
        c.VK_F6 => return "F6",
        c.VK_F7 => return "F7",
        c.VK_F8 => return "F8",
        c.VK_F9 => return "F9",
        c.VK_F10 => return "F10",
        c.VK_F11 => return "F11",
        c.VK_F12 => return "F12",
        else => {},
    }

    if (vk >= 0x41 and vk <= 0x5A) {
        const upper: u8 = @intCast(vk);
        key_buf[0] = if (shift) upper else std.ascii.toLower(upper);
        return key_buf[0..1];
    }
    if (vk >= 0x30 and vk <= 0x39) {
        const digit: u8 = @intCast(vk);
        key_buf[0] = if (shift) mapShiftedDigit(digit) else digit;
        return key_buf[0..1];
    }
    if (vk >= c.VK_NUMPAD0 and vk <= c.VK_NUMPAD9) {
        key_buf[0] = @intCast('0' + (vk - c.VK_NUMPAD0));
        return key_buf[0..1];
    }

    switch (vk) {
        c.VK_OEM_MINUS => {
            key_buf[0] = if (shift) '_' else '-';
            return key_buf[0..1];
        },
        c.VK_OEM_PLUS => {
            key_buf[0] = if (shift) '+' else '=';
            return key_buf[0..1];
        },
        c.VK_OEM_COMMA => {
            key_buf[0] = if (shift) '<' else ',';
            return key_buf[0..1];
        },
        c.VK_OEM_PERIOD => {
            key_buf[0] = if (shift) '>' else '.';
            return key_buf[0..1];
        },
        c.VK_OEM_1 => {
            key_buf[0] = if (shift) ':' else ';';
            return key_buf[0..1];
        },
        c.VK_OEM_2 => {
            key_buf[0] = if (shift) '?' else '/';
            return key_buf[0..1];
        },
        c.VK_OEM_3 => {
            key_buf[0] = if (shift) '~' else '`';
            return key_buf[0..1];
        },
        c.VK_OEM_4 => {
            key_buf[0] = if (shift) '{' else '[';
            return key_buf[0..1];
        },
        c.VK_OEM_5 => {
            key_buf[0] = if (shift) '|' else '\\';
            return key_buf[0..1];
        },
        c.VK_OEM_6 => {
            key_buf[0] = if (shift) '}' else ']';
            return key_buf[0..1];
        },
        c.VK_OEM_7 => {
            key_buf[0] = if (shift) '"' else '\'';
            return key_buf[0..1];
        },
        c.VK_MULTIPLY => {
            key_buf[0] = '*';
            return key_buf[0..1];
        },
        c.VK_ADD => {
            key_buf[0] = '+';
            return key_buf[0..1];
        },
        c.VK_SUBTRACT => {
            key_buf[0] = '-';
            return key_buf[0..1];
        },
        c.VK_DECIMAL => {
            key_buf[0] = '.';
            return key_buf[0..1];
        },
        c.VK_DIVIDE => {
            key_buf[0] = '/';
            return key_buf[0..1];
        },
        else => {},
    }
    return null;
}

fn mapShiftedDigit(digit: u8) u8 {
    return switch (digit) {
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
        else => digit,
    };
}

fn keyStateDown(vk: c_int) bool {
    return (@as(u16, @bitCast(c.GetKeyState(vk))) & 0x8000) != 0;
}

fn keyboardModifiersFromKeyState() Page.KeyboardModifiers {
    return .{
        .ctrl = keyStateDown(c.VK_CONTROL),
        .shift = keyStateDown(c.VK_SHIFT),
        .alt = keyStateDown(c.VK_MENU),
        .meta = keyStateDown(c.VK_LWIN) or keyStateDown(c.VK_RWIN),
    };
}

fn mouseButtonsFromWParam(wparam: c.WPARAM) u16 {
    var buttons: u16 = 0;
    if ((wparam & c.MK_LBUTTON) != 0) buttons |= 1;
    if ((wparam & c.MK_RBUTTON) != 0) buttons |= 2;
    if ((wparam & c.MK_MBUTTON) != 0) buttons |= 4;
    if ((wparam & c.MK_XBUTTON1) != 0) buttons |= 8;
    if ((wparam & c.MK_XBUTTON2) != 0) buttons |= 16;
    return buttons;
}

fn mouseModifiersFromWParam(wparam: c.WPARAM) Page.MouseModifiers {
    const key_mods = keyboardModifiersFromKeyState();
    return .{
        .alt = key_mods.alt,
        .ctrl = key_mods.ctrl,
        .meta = key_mods.meta,
        .shift = key_mods.shift,
        .buttons = mouseButtonsFromWParam(wparam),
    };
}

fn clientCoordFromLParam(lparam: c.LPARAM) ClientPoint {
    const raw: usize = @bitCast(lparam);
    const x_word: u16 = @intCast(raw & 0xFFFF);
    const y_word: u16 = @intCast((raw >> 16) & 0xFFFF);
    const x: i16 = @bitCast(x_word);
    const y: i16 = @bitCast(y_word);
    return .{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
    };
}

fn clientCoordForWheel(hwnd: c.HWND, lparam: c.LPARAM) ClientPoint {
    const raw: usize = @bitCast(lparam);
    const x_word: u16 = @intCast(raw & 0xFFFF);
    const y_word: u16 = @intCast((raw >> 16) & 0xFFFF);

    var point = c.POINT{
        .x = @as(i16, @bitCast(x_word)),
        .y = @as(i16, @bitCast(y_word)),
    };
    _ = c.ScreenToClient(hwnd, &point);
    return .{
        .x = @floatFromInt(point.x),
        .y = @floatFromInt(point.y),
    };
}

fn wheelDeltaFromWParam(wparam: c.WPARAM) f64 {
    const delta_word: u16 = @intCast((wparam >> 16) & 0xFFFF);
    const delta: i16 = @bitCast(delta_word);
    return @floatFromInt(delta);
}

fn keyRepeatFromLParam(lparam: c.LPARAM) bool {
    const raw: usize = @bitCast(lparam);
    return ((raw >> 30) & 1) != 0;
}

fn xButtonFromWParam(wparam: c.WPARAM) ?Page.MouseButton {
    const xbtn_word: u16 = @intCast((wparam >> 16) & 0xFFFF);
    return switch (xbtn_word) {
        c.XBUTTON1 => .fourth,
        c.XBUTTON2 => .fifth,
        else => null,
    };
}

fn queueTextCodePoint(backend: *Win32Backend, cp_in: u32) void {
    if (cp_in == 0) {
        return;
    }
    if (cp_in > 0x10FFFF) {
        return;
    }

    const cp: u21 = @intCast(if (cp_in == '\r') @as(u32, '\n') else cp_in);
    if (cp < 0x20 and cp != '\n') {
        return;
    }
    if (cp == 0x7F) {
        return;
    }
    if (!std.unicode.utf8ValidCodepoint(cp)) {
        return;
    }

    var text_input: Win32Backend.TextInputEvent = .{
        .bytes = undefined,
        .len = 0,
    };
    const len = std.unicode.utf8Encode(cp, &text_input.bytes) catch return;
    text_input.len = @intCast(len);
    queueInputEvent(backend, .{ .text_input = text_input });
}

fn queueTextFromUtf16Unit(backend: *Win32Backend, code_unit: u16) void {
    if (std.unicode.utf16IsHighSurrogate(code_unit)) {
        backend.pending_high_surrogate = code_unit;
        return;
    }
    if (std.unicode.utf16IsLowSurrogate(code_unit)) {
        const high = backend.pending_high_surrogate orelse return;
        backend.pending_high_surrogate = null;
        queueTextCodePoint(backend, std.unicode.utf16DecodeSurrogatePair(&.{ high, code_unit }) catch return);
        return;
    }

    backend.pending_high_surrogate = null;
    queueTextCodePoint(backend, code_unit);
}

fn queueImeResultString(hwnd: c.HWND, backend: *Win32Backend, lparam: c.LPARAM) void {
    const flags: usize = @bitCast(lparam);
    if ((flags & c.GCS_RESULTSTR) == 0) {
        return;
    }

    const himc = c.ImmGetContext(hwnd);
    if (himc == null) {
        return;
    }
    defer _ = c.ImmReleaseContext(hwnd, himc);

    const bytes_len_long = c.ImmGetCompositionStringW(himc, c.GCS_RESULTSTR, null, 0);
    if (bytes_len_long <= 0) {
        return;
    }

    const bytes_len: usize = @intCast(bytes_len_long);
    if (bytes_len == 0) {
        return;
    }

    const unit_count = bytes_len / @sizeOf(u16);
    if (unit_count == 0) {
        return;
    }

    backend.ime_composing = true;
    backend.pending_high_surrogate = null;

    var stack_units: [64]u16 = undefined;
    if (unit_count <= stack_units.len) {
        const written_long = c.ImmGetCompositionStringW(
            himc,
            c.GCS_RESULTSTR,
            @ptrCast(stack_units[0..unit_count].ptr),
            @intCast(bytes_len),
        );
        if (written_long <= 0) {
            return;
        }
        const written_units = @as(usize, @intCast(written_long)) / @sizeOf(u16);
        for (stack_units[0..written_units]) |unit| {
            queueTextFromUtf16Unit(backend, unit);
        }
        backend.suppress_wm_char_units +|= @intCast(written_units);
        return;
    }

    const units = backend.allocator.alloc(u16, unit_count) catch return;
    defer backend.allocator.free(units);

    const written_long = c.ImmGetCompositionStringW(
        himc,
        c.GCS_RESULTSTR,
        @ptrCast(units.ptr),
        @intCast(bytes_len),
    );
    if (written_long <= 0) {
        return;
    }
    const written_units = @as(usize, @intCast(written_long)) / @sizeOf(u16);
    for (units[0..written_units]) |unit| {
        queueTextFromUtf16Unit(backend, unit);
    }
    backend.suppress_wm_char_units +|= @intCast(written_units);
}

fn hasImeCompositionString(lparam: c.LPARAM) bool {
    const flags: usize = @bitCast(lparam);
    return (flags & c.GCS_COMPSTR) != 0;
}

const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("LightpandaHeadedWindowClass");
const WINDOW_TITLE = std.unicode.utf8ToUtf16LeStringLiteral("Lightpanda Browser");

const WINDOW_STYLE: c.DWORD = c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU | c.WS_MINIMIZEBOX;
const WINDOW_EX_STYLE: c.DWORD = c.WS_EX_APPWINDOW;

fn registerWindowClass() !void {
    const hinstance = c.GetModuleHandleW(null);
    if (hinstance == null) {
        return error.MissingModuleHandle;
    }

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.hCursor = loadCursorResource(32512);
    wc.hIcon = null;
    wc.hIconSm = null;
    wc.hbrBackground = null;
    wc.lpszClassName = WINDOW_CLASS_NAME.ptr;

    if (c.RegisterClassExW(&wc) == 0) {
        const err = c.GetLastError();
        if (err != c.ERROR_CLASS_ALREADY_EXISTS) {
            return error.RegisterClassFailed;
        }
    }
}

fn createWindow(backend: *Win32Backend, width: u32, height: u32) !c.HWND {
    try registerWindowClass();

    const hinstance = c.GetModuleHandleW(null);
    if (hinstance == null) {
        return error.MissingModuleHandle;
    }

    const size = adjustedWindowSize(width, height);
    const hwnd = c.CreateWindowExW(
        WINDOW_EX_STYLE,
        WINDOW_CLASS_NAME.ptr,
        WINDOW_TITLE.ptr,
        WINDOW_STYLE,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        size.width,
        size.height,
        null,
        null,
        hinstance,
        @ptrCast(backend),
    );

    if (hwnd == null) {
        return error.CreateWindowFailed;
    }

    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.SetActiveWindow(hwnd);
    _ = c.SetFocus(hwnd);

    return hwnd;
}

fn destroyWindow(hwnd: c.HWND) void {
    if (c.IsWindow(hwnd) != 0) {
        _ = c.DestroyWindow(hwnd);
    }
}

fn setClientSize(hwnd: c.HWND, width: u32, height: u32) void {
    const size = adjustedWindowSize(width, height);
    _ = c.SetWindowPos(
        hwnd,
        null,
        0,
        0,
        size.width,
        size.height,
        c.SWP_NOMOVE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_NOACTIVATE,
    );
}

fn adjustedWindowSize(width: u32, height: u32) struct { width: c_int, height: c_int } {
    var rect = c.RECT{
        .left = 0,
        .top = 0,
        .right = clampU32ToCInt(width),
        .bottom = clampU32ToCInt(height),
    };
    _ = c.AdjustWindowRectEx(&rect, WINDOW_STYLE, c.FALSE, WINDOW_EX_STYLE);

    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

fn clampU32ToCInt(v: u32) c_int {
    const max = @as(u32, @intCast(std.math.maxInt(c_int)));
    return @intCast(@min(v, max));
}

fn pumpMessages() void {
    var msg: c.MSG = undefined;
    while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

fn getBackendPtr(hwnd: c.HWND) ?*Win32Backend {
    const value = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (value == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(value)));
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_NCCREATE => {
            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const backend_ptr = cs.lpCreateParams orelse return 0;
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @intCast(@intFromPtr(backend_ptr)));
            return 1;
        },
        c.WM_CLOSE => {
            if (getBackendPtr(hwnd)) |backend| {
                backend.user_closed.store(true, .release);
                backend.pending_high_surrogate = null;
                backend.ime_composing = false;
                backend.suppress_wm_char_units = 0;
            }
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_KILLFOCUS => {
            if (getBackendPtr(hwnd)) |backend| {
                backend.pending_high_surrogate = null;
                backend.ime_composing = false;
                backend.suppress_wm_char_units = 0;
                queueInputEvent(backend, .window_blur);
            }
            return 0;
        },
        c.WM_LBUTTONDOWN, c.WM_MBUTTONDOWN, c.WM_RBUTTONDOWN => {
            if (getBackendPtr(hwnd)) |backend| {
                const client_pos = clientCoordFromLParam(lparam);
                if (msg == c.WM_LBUTTONDOWN and presentationHasContent(backend) and addressBarHitTest(client_pos.x, client_pos.y)) {
                    cancelPendingPresentationCommand(backend);
                    _ = c.SetFocus(hwnd);
                    if (beginAddressEdit(backend)) {
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 0;
                }
                if (msg == c.WM_LBUTTONDOWN and presentationHasContent(backend) and beginPendingPresentationCommand(backend, client_pos.x, client_pos.y)) {
                    _ = c.SetFocus(hwnd);
                    _ = c.SetCapture(hwnd);
                    return 0;
                }
                cancelPendingPresentationCommand(backend);
                const pos = if (presentationHasContent(backend))
                    presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 0
                else
                    client_pos;
                const button: Page.MouseButton = switch (msg) {
                    c.WM_MBUTTONDOWN => .auxiliary,
                    c.WM_RBUTTONDOWN => .secondary,
                    else => .main,
                };
                _ = c.SetFocus(hwnd);
                _ = c.SetCapture(hwnd);
                queueInputEvent(backend, .{ .mouse_down = .{
                    .x = pos.x,
                    .y = pos.y,
                    .button = button,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_XBUTTONDOWN => {
            if (getBackendPtr(hwnd)) |backend| {
                if (xButtonFromWParam(wparam)) |button| {
                    const client_pos = clientCoordFromLParam(lparam);
                    const pos = if (presentationHasContent(backend))
                        presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 1
                    else
                        client_pos;
                    _ = c.SetFocus(hwnd);
                    _ = c.SetCapture(hwnd);
                    queueInputEvent(backend, .{ .mouse_down = .{
                        .x = pos.x,
                        .y = pos.y,
                        .button = button,
                        .modifiers = mouseModifiersFromWParam(wparam),
                    } });
                }
            }
            return 1;
        },
        c.WM_LBUTTONUP, c.WM_MBUTTONUP, c.WM_RBUTTONUP => {
            if (getBackendPtr(hwnd)) |backend| {
                const client_pos = clientCoordFromLParam(lparam);
                if (msg == c.WM_LBUTTONUP and presentationHasContent(backend)) {
                    if (takePendingPresentationCommand(backend)) |command| {
                        _ = c.ReleaseCapture();
                        queueBrowserCommand(backend, command);
                        return 0;
                    }
                }
                const pos = if (presentationHasContent(backend))
                    presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 0
                else
                    client_pos;
                const button: Page.MouseButton = switch (msg) {
                    c.WM_MBUTTONUP => .auxiliary,
                    c.WM_RBUTTONUP => .secondary,
                    else => .main,
                };
                _ = c.ReleaseCapture();
                queueInputEvent(backend, .{ .mouse_up = .{
                    .x = pos.x,
                    .y = pos.y,
                    .button = button,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_CAPTURECHANGED => {
            if (getBackendPtr(hwnd)) |backend| {
                cancelPendingPresentationCommand(backend);
            }
            return 0;
        },
        c.WM_XBUTTONUP => {
            if (getBackendPtr(hwnd)) |backend| {
                if (xButtonFromWParam(wparam)) |button| {
                    const client_pos = clientCoordFromLParam(lparam);
                    const pos = if (presentationHasContent(backend))
                        presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 1
                    else
                        client_pos;
                    _ = c.ReleaseCapture();
                    queueInputEvent(backend, .{ .mouse_up = .{
                        .x = pos.x,
                        .y = pos.y,
                        .button = button,
                        .modifiers = mouseModifiersFromWParam(wparam),
                    } });
                }
            }
            return 1;
        },
        c.WM_MOUSEMOVE => {
            if (getBackendPtr(hwnd)) |backend| {
                const client_pos = clientCoordFromLParam(lparam);
                if (presentationHasContent(backend)) {
                    setPresentationCursor(backend, client_pos.x, client_pos.y);
                }
                const pos = if (presentationHasContent(backend))
                    presentationClientToPage(backend, client_pos.x, client_pos.y) orelse return 0
                else
                    client_pos;
                queueInputEvent(backend, .{ .mouse_move = .{
                    .x = pos.x,
                    .y = pos.y,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationHasContent(backend)) {
                    const raw_delta: i16 = @intFromFloat(wheelDeltaFromWParam(wparam));
                    const delta = -@divTrunc(@as(i32, raw_delta), @as(i32, c.WHEEL_DELTA)) * PRESENTATION_SCROLL_STEP;
                    if (scrollPresentationBy(backend, delta)) {
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 0;
                }
                const coord = clientCoordForWheel(hwnd, lparam);
                const wheel_delta = wheelDeltaFromWParam(wparam);
                queueInputEvent(backend, .{ .mouse_wheel = .{
                    .x = coord.x,
                    .y = coord.y,
                    .delta_x = 0,
                    .delta_y = -wheel_delta,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_MOUSEHWHEEL => {
            if (getBackendPtr(hwnd)) |backend| {
                const coord = clientCoordForWheel(hwnd, lparam);
                const wheel_delta = wheelDeltaFromWParam(wparam);
                queueInputEvent(backend, .{ .mouse_wheel = .{
                    .x = coord.x,
                    .y = coord.y,
                    .delta_x = wheel_delta,
                    .delta_y = 0,
                    .modifiers = mouseModifiersFromWParam(wparam),
                } });
            }
            return 0;
        },
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (getBackendPtr(hwnd)) |backend| {
                const vk: u32 = @intCast(wparam & 0xFFFF);
                const modifiers = keyboardModifiersFromKeyState();
                if (handlePresentationShortcutKey(hwnd, backend, vk, modifiers)) {
                    return 0;
                }
                if (presentationAddressEditing(backend)) {
                    return 0;
                }
                if (handlePresentationScrollKey(hwnd, backend, vk)) {
                    return 0;
                }
                const key_down: Win32Backend.InputEvent = .{ .key_down = .{
                    .vk = vk,
                    .modifiers = modifiers,
                    .repeat = keyRepeatFromLParam(lparam),
                } };
                queueInputEvent(backend, key_down);
            }
            return 0;
        },
        c.WM_KEYUP, c.WM_SYSKEYUP => {
            if (getBackendPtr(hwnd)) |backend| {
                const vk: u32 = @intCast(wparam & 0xFFFF);
                const key_up: Win32Backend.InputEvent = .{ .key_up = .{
                    .vk = vk,
                    .modifiers = keyboardModifiersFromKeyState(),
                } };
                queueInputEvent(backend, key_up);
            }
            return 0;
        },
        c.WM_IME_COMPOSITION => {
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationAddressEditing(backend)) {
                    return 0;
                }
                if (hasImeCompositionString(lparam)) {
                    backend.ime_composing = true;
                }
                queueImeResultString(hwnd, backend, lparam);
            }
            return 0;
        },
        c.WM_IME_STARTCOMPOSITION => {
            if (getBackendPtr(hwnd)) |backend| {
                backend.ime_composing = true;
                backend.pending_high_surrogate = null;
                backend.suppress_wm_char_units = 0;
            }
            return 0;
        },
        c.WM_IME_ENDCOMPOSITION => {
            if (getBackendPtr(hwnd)) |backend| {
                backend.ime_composing = false;
                backend.pending_high_surrogate = null;
                backend.suppress_wm_char_units = 0;
            }
            return 0;
        },
        c.WM_CHAR, c.WM_SYSCHAR => {
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationAddressEditing(backend)) {
                    const code_unit: u16 = @intCast(wparam & 0xFFFF);
                    if (code_unit != '\r' and code_unit != 0x0008 and appendAddressUtf16Unit(backend, code_unit)) {
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 0;
                }
                if (backend.suppress_wm_char_units > 0) {
                    backend.suppress_wm_char_units -= 1;
                    return 0;
                }
                const code_unit: u16 = @intCast(wparam & 0xFFFF);
                queueTextFromUtf16Unit(backend, code_unit);
            }
            return 0;
        },
        c.WM_IME_CHAR => return 0,
        c.WM_UNICHAR => {
            if (@as(u32, @intCast(wparam)) == 0xFFFF) {
                return 1;
            }
            if (getBackendPtr(hwnd)) |backend| {
                if (presentationAddressEditing(backend)) {
                    if (appendAddressCodePoint(backend, @intCast(wparam))) {
                        _ = c.InvalidateRect(hwnd, null, c.TRUE);
                    }
                    return 1;
                }
                queueTextCodePoint(backend, @intCast(wparam));
            }
            return 1;
        },
        c.WM_PAINT => {
            if (getBackendPtr(hwnd)) |backend| {
                renderWindowPresentation(hwnd, backend);
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_DESTROY => return 0,
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

test "win32 mapVirtualKey includes modifiers and shifted digits" {
    var key_buf: [2]u8 = undefined;

    try std.testing.expectEqualStrings("Control", mapVirtualKey(c.VK_CONTROL, false, &key_buf).?);
    try std.testing.expectEqualStrings("Shift", mapVirtualKey(c.VK_SHIFT, false, &key_buf).?);
    try std.testing.expectEqualStrings("Alt", mapVirtualKey(c.VK_MENU, false, &key_buf).?);
    try std.testing.expectEqualStrings("Meta", mapVirtualKey(c.VK_LWIN, false, &key_buf).?);
    try std.testing.expectEqualStrings("!", mapVirtualKey('1', true, &key_buf).?);
    try std.testing.expectEqualStrings(")", mapVirtualKey('0', true, &key_buf).?);
}

test "win32 mouse button mask includes xbuttons" {
    const wparam: c.WPARAM = c.MK_LBUTTON | c.MK_XBUTTON1 | c.MK_XBUTTON2;
    try std.testing.expectEqual(@as(u16, 25), mouseButtonsFromWParam(wparam));
    try std.testing.expectEqual(Page.MouseButton.fourth, xButtonFromWParam(c.XBUTTON1 << 16).?);
    try std.testing.expectEqual(Page.MouseButton.fifth, xButtonFromWParam(c.XBUTTON2 << 16).?);
}

test "win32 utf16 text queue normalizes enter and decodes surrogate pair" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    queueTextFromUtf16Unit(&backend, 0x0003);
    queueTextFromUtf16Unit(&backend, '\r');
    queueTextFromUtf16Unit(&backend, 0xD83D);
    queueTextFromUtf16Unit(&backend, 0xDE00);

    try std.testing.expectEqual(@as(usize, 2), backend.input_events.items.len);

    const first = backend.input_events.items[0];
    const second = backend.input_events.items[1];

    switch (first) {
        .text_input => |input| try std.testing.expectEqualStrings("\n", input.bytes[0..input.len]),
        else => return error.TestUnexpectedEventType,
    }
    switch (second) {
        .text_input => |input| try std.testing.expectEqualSlices(u8, "\xF0\x9F\x98\x80", input.bytes[0..input.len]),
        else => return error.TestUnexpectedEventType,
    }
}

test "win32 ime helpers decode flags" {
    try std.testing.expect(hasImeCompositionString(@bitCast(@as(isize, c.GCS_COMPSTR))));
    try std.testing.expect(!hasImeCompositionString(0));
}

test "win32 clipboard shortcut detection" {
    try std.testing.expectEqual(ClipboardShortcutAction.copy, clipboardShortcutAction('C', .{ .ctrl = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.cut, clipboardShortcutAction('X', .{ .ctrl = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.paste, clipboardShortcutAction('V', .{ .ctrl = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.copy, clipboardShortcutAction(c.VK_INSERT, .{ .ctrl = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.paste, clipboardShortcutAction(c.VK_INSERT, .{ .shift = true }).?);
    try std.testing.expectEqual(ClipboardShortcutAction.cut, clipboardShortcutAction(c.VK_DELETE, .{ .shift = true }).?);
    try std.testing.expectEqual(@as(?ClipboardShortcutAction, null), clipboardShortcutAction('V', .{ .ctrl = true, .shift = true }));
    try std.testing.expectEqual(@as(?ClipboardShortcutAction, null), clipboardShortcutAction('C', .{ .meta = true, .alt = true }));
}

test "win32 address edit select-all replaces existing value" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com");

    try std.testing.expect(beginAddressEdit(&backend));
    try std.testing.expect(backend.address_input_select_all);
    try std.testing.expect(appendAddressCodePoint(&backend, 'x'));
    try std.testing.expectEqualStrings("x", backend.address_input.items);
    try std.testing.expect(!backend.address_input_select_all);
}

test "win32 address edit ctrl+a then backspace clears all" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com");

    try std.testing.expect(beginAddressEdit(&backend));
    try std.testing.expect(selectAllAddressInput(&backend));
    try std.testing.expect(deleteLastAddressCodepoint(&backend));
    try std.testing.expectEqual(@as(usize, 0), backend.address_input.items.len);
    try std.testing.expect(!backend.address_input_select_all);
}

test "win32 chrome button hit test maps back forward reload" {
    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expectEqual(ChromeButtonKind.back, chromeCommandKindAtClientPoint(24, mid_y).?);
    try std.testing.expectEqual(ChromeButtonKind.forward, chromeCommandKindAtClientPoint(56, mid_y).?);
    try std.testing.expectEqual(ChromeButtonKind.reload, chromeCommandKindAtClientPoint(88, mid_y).?);
}

test "win32 disabled chrome buttons are not interactive" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com");
    backend.presentation_can_go_back = false;
    backend.presentation_can_go_forward = false;

    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expect(chromeCommandKindAtClientPointEnabled(&backend, 24, mid_y) == null);
    try std.testing.expect(chromeCommandKindAtClientPointEnabled(&backend, 56, mid_y) == null);
    try std.testing.expectEqual(ChromeButtonKind.reload, chromeCommandKindAtClientPointEnabled(&backend, 88, mid_y).?);
}

test "win32 reload slot becomes stop while loading" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_is_loading = true;

    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expectEqual(ChromeButtonKind.reload, chromeCommandKindAtClientPointEnabled(&backend, 88, mid_y).?);
    try std.testing.expectEqual(BrowserCommand.stop, presentationCommandAtClientPoint(&backend, 88, mid_y).?);
}

test "win32 reload slot stays reload when idle" {
    var backend = Win32Backend.init(std.testing.allocator, 1, 1);
    defer backend.deinit();

    backend.presentation_url = try std.testing.allocator.dupe(u8, "http://example.com");

    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expectEqual(BrowserCommand.reload, presentationCommandAtClientPoint(&backend, 88, mid_y).?);
}

test "win32 address bar hit test excludes chrome buttons" {
    const mid_y = @as(f64, @floatFromInt((PRESENTATION_ADDRESS_TOP + PRESENTATION_ADDRESS_BOTTOM) / 2));
    try std.testing.expect(!addressBarHitTest(24, mid_y));
    try std.testing.expect(addressBarHitTest(120, mid_y));
}

test "win32 key repeat detection from lparam" {
    try std.testing.expect(!keyRepeatFromLParam(0));
    try std.testing.expect(keyRepeatFromLParam(@bitCast(@as(isize, 1 << 30))));
}
