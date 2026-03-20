// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License
// for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const builtin = @import("builtin");
const std = @import("std");

const BrowserCommand = @import("BrowserCommand.zig").BrowserCommand;
const Display = @import("Display.zig");
const DisplayList = @import("../render/DisplayList.zig").DisplayList;
const DocumentPainter = @import("../render/DocumentPainter.zig");
const BootState = @import("../sys/boot.zig").BootState;
const Framebuffer = @import("../sys/framebuffer.zig").Framebuffer;
const Host = @import("../sys/host.zig").Host;
const Input = @import("../sys/input.zig").Input;
const log = @import("../log.zig");
const testing = @import("../testing.zig");

const c = if (builtin.os.tag == .windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
}) else struct {};

const DrawRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const BitmapFileHeader = extern struct {
    bfType: u16,
    bfSize: u32,
    bfReserved1: u16,
    bfReserved2: u16,
    bfOffBits: u32,
};

const modifier_shift = 1 << 0;
const modifier_ctrl = 1 << 1;
const modifier_alt = 1 << 2;
const modifier_meta = 1 << 3;
const bare_metal_input_mailbox_file = "bare-metal-input-v1.txt";
const presentation_origin_x = 16;
const presentation_origin_y = 36;

const PointerPoint = struct {
    x: f64,
    y: f64,
    dom_path: ?[]const u16 = null,
};

pub const BareMetalBackend = struct {
    host: *Host,
    page_count: u32 = 0,
    last_viewport_width: u32 = 0,
    last_viewport_height: u32 = 0,
    last_display_hash: u64 = 0,
    last_command_count: usize = 0,
    last_content_height: i32 = 0,
    last_title: []const u8 = &.{},
    last_url: []const u8 = &.{},
    last_is_loading: bool = true,
    last_can_go_back: bool = false,
    last_can_go_forward: bool = false,
    last_zoom_percent: i32 = 100,
    last_pointer_x: i32 = 0,
    last_pointer_y: i32 = 0,
    tab_entries: std.ArrayListUnmanaged(Display.TabEntry) = .{},
    history_entries: std.ArrayListUnmanaged([]u8) = .{},
    download_entries: std.ArrayListUnmanaged(Display.DownloadEntry) = .{},
    active_tab_index: usize = 0,
    history_current_index: usize = 0,
    restore_previous_session: bool = false,
    allow_script_popups: bool = true,
    default_zoom_percent: i32 = 100,
    homepage_url: ?[]u8 = null,
    app_data_path: ?[]u8 = null,
    input_mailbox_offset: u64 = 0,
    command_queue: std.ArrayListUnmanaged(BrowserCommand) = .{},
    presentation_display_list: ?DisplayList = null,

    pub fn init(host: *Host, _: anytype, width: u32, height: u32) @This() {
        host.boot.start();
        host.framebuffer.resize(host.allocator, width, height) catch @panic("bare metal framebuffer init failed");
        var self: @This() = .{
            .host = host,
            .last_viewport_width = width,
            .last_viewport_height = height,
            .last_pointer_x = @as(i32, @intCast(width / 2)),
            .last_pointer_y = @as(i32, @intCast(height / 2)),
        };
        self.renderBootFrame();
        return self;
    }

    pub fn onPageCreated(self: *@This()) bool {
        self.page_count += 1;
        self.host.boot.markRunning();
        self.renderFrame();
        return true;
    }

    pub fn onPageRemoved(self: *@This()) bool {
        if (self.page_count > 0) {
            self.page_count -= 1;
        }
        if (self.page_count == 0) {
            self.host.boot.shutdown();
        }
        self.renderFrame();
        return self.page_count == 0;
    }

    pub fn onViewportChanged(self: *@This(), width: u32, height: u32) void {
        self.last_viewport_width = width;
        self.last_viewport_height = height;
        self.host.framebuffer.resize(self.host.allocator, width, height) catch @panic("bare metal framebuffer resize failed");
        self.last_pointer_x = @as(i32, @intCast(width / 2));
        self.last_pointer_y = @as(i32, @intCast(height / 2));
        self.renderFrame();
    }

    pub fn setNavigationState(self: *@This(), can_go_back: bool, can_go_forward: bool, is_loading: bool, zoom_percent: i32) void {
        self.last_can_go_back = can_go_back;
        self.last_can_go_forward = can_go_forward;
        self.last_is_loading = is_loading;
        self.last_zoom_percent = zoom_percent;
        self.renderFrame();
    }

    pub fn setHistoryEntries(self: *@This(), entries: []const []const u8, current_index: usize) void {
        for (self.history_entries.items) |entry| {
            self.host.allocator.free(entry);
        }
        self.history_entries.deinit(self.host.allocator);
        self.history_entries = .{};
        self.history_current_index = current_index;

        self.history_entries.ensureTotalCapacity(self.host.allocator, entries.len) catch @panic("bare metal history entries allocation failed");
        for (entries) |entry| {
            const owned = self.host.allocator.dupe(u8, entry) catch @panic("bare metal history entry duplicate failed");
            self.history_entries.append(self.host.allocator, owned) catch @panic("bare metal history entry append failed");
        }
        self.renderFrame();
    }
    pub fn setDownloadEntries(self: *@This(), entries: []const Display.DownloadEntry) void {
        for (self.download_entries.items) |entry| {
            self.host.allocator.free(entry.filename);
            self.host.allocator.free(entry.path);
            self.host.allocator.free(entry.status);
        }
        self.download_entries.deinit(self.host.allocator);
        self.download_entries = .{};

        self.download_entries.ensureTotalCapacity(self.host.allocator, entries.len) catch @panic("bare metal download entries allocation failed");
        for (entries) |entry| {
            self.download_entries.append(self.host.allocator, .{
                .filename = self.host.allocator.dupe(u8, entry.filename) catch @panic("bare metal download filename duplicate failed"),
                .path = self.host.allocator.dupe(u8, entry.path) catch @panic("bare metal download path duplicate failed"),
                .status = self.host.allocator.dupe(u8, entry.status) catch @panic("bare metal download status duplicate failed"),
                .removable = entry.removable,
            }) catch @panic("bare metal download entry append failed");
        }
        self.renderFrame();
    }
    pub fn setTabEntries(self: *@This(), entries: []const Display.TabEntry, active_index: usize) void {
        for (self.tab_entries.items) |entry| {
            self.host.allocator.free(entry.title);
            self.host.allocator.free(entry.url);
            self.host.allocator.free(entry.target_name);
        }
        self.tab_entries.deinit(self.host.allocator);
        self.tab_entries = .{};
        self.active_tab_index = active_index;

        self.tab_entries.ensureTotalCapacity(self.host.allocator, entries.len) catch @panic("bare metal tab entries allocation failed");
        for (entries) |entry| {
            self.tab_entries.append(self.host.allocator, .{
                .title = self.host.allocator.dupe(u8, entry.title) catch @panic("bare metal tab title duplicate failed"),
                .url = self.host.allocator.dupe(u8, entry.url) catch @panic("bare metal tab url duplicate failed"),
                .is_loading = entry.is_loading,
                .has_error = entry.has_error,
                .target_name = self.host.allocator.dupe(u8, entry.target_name) catch @panic("bare metal tab target duplicate failed"),
                .popup_source = entry.popup_source,
            }) catch @panic("bare metal tab entry append failed");
        }
        self.renderFrame();
    }
    pub fn setSettingsState(self: *@This(), settings: Display.SettingsState) void {
        self.restore_previous_session = settings.restore_previous_session;
        self.allow_script_popups = settings.allow_script_popups;
        self.default_zoom_percent = settings.default_zoom_percent;
        if (self.homepage_url) |existing| {
            self.host.allocator.free(existing);
            self.homepage_url = null;
        }
        if (settings.homepage_url.len > 0) {
            self.homepage_url = self.host.allocator.dupe(u8, settings.homepage_url) catch @panic("bare metal settings homepage duplicate failed");
        }
        self.renderFrame();
    }
    pub fn setAppDataPath(self: *@This(), path: ?[]const u8) void {
        if (self.app_data_path) |existing| {
            if (path) |next| {
                if (std.mem.eql(u8, existing, next)) {
                    return;
                }
            }
            self.host.allocator.free(existing);
            self.app_data_path = null;
        }

        self.input_mailbox_offset = 0;
        if (path) |next| {
            self.app_data_path = self.host.allocator.dupe(u8, next) catch |err| {
                log.warn(.app, "bare metal appdir copy failed", .{ .err = err });
                return;
            };
        }
    }
    pub fn setHttpRuntime(_: *@This(), _: *anyopaque) void {}
    pub fn setImageRequestCookieJar(_: *@This(), _: ?*anyopaque) void {}

    pub fn dispatchInput(self: *@This(), page: anytype) !void {
        try pollMailboxInput(self);

        const PageType = std.meta.Child(@TypeOf(page));
        const KeyboardModifiers = if (@hasDecl(PageType, "KeyboardModifiers")) PageType.KeyboardModifiers else struct {
            alt: bool = false,
            ctrl: bool = false,
            meta: bool = false,
            shift: bool = false,
        };
        const MouseModifiers = if (@hasDecl(PageType, "MouseModifiers")) PageType.MouseModifiers else struct {
            alt: bool = false,
            ctrl: bool = false,
            meta: bool = false,
            shift: bool = false,
            buttons: u16 = 0,
        };
        const MouseButton = if (@hasDecl(PageType, "MouseButton")) PageType.MouseButton else enum {
            main,
            auxiliary,
            secondary,
            fourth,
            fifth,
        };
        const HasNodePathClick = @hasDecl(PageType, "triggerMouseClickOnNodePathWithResult");

        while (self.host.input.pop()) |event| {
            switch (event) {
                .key => |key| {
                    var key_buf: [8]u8 = undefined;
                    const key_name = keyNameFromCode(&key_buf, key.code);
                    const modifiers: KeyboardModifiers = .{
                        .alt = (key.modifiers & modifier_alt) != 0,
                        .ctrl = (key.modifiers & modifier_ctrl) != 0,
                        .meta = (key.modifiers & modifier_meta) != 0,
                        .shift = (key.modifiers & modifier_shift) != 0,
                    };
                    if (key.pressed) {
                        if (try self.handleShortcutKey(key.code, modifiers)) {
                            continue;
                        }
                        if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and key.code == 'J') {
                            try self.queueBrowserCommand(.page_downloads);
                            continue;
                        }
                        if (std.mem.startsWith(u8, self.last_url, "browser://downloads") and key.code == c.VK_DELETE and !modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift) {
                            if (self.firstRemovableDownloadIndex()) |index| {
                                try self.queueBrowserCommand(.{ .download_remove = index });
                            }
                            continue;
                        }
                    }
                    if (key.pressed) {
                        _ = try page.triggerKeyboardKeyDownWithRepeat(key_name, modifiers, false);
                    } else {
                        _ = try page.triggerKeyboardKeyUp(key_name, modifiers);
                    }
                },
                .move => |move| {
                    const page_point = presentationHit(self, move.x, move.y) orelse clientPointToPage(self, move.x, move.y) orelse continue;
                    self.last_pointer_x = move.x;
                    self.last_pointer_y = move.y;
                    const x = page_point.x;
                    const y = page_point.y;
                    const modifiers: MouseModifiers = mouseModifiersFromMask(MouseModifiers, move.modifiers, 0);
                    try page.triggerMouseMove(x, y, modifiers);
                },
                .pointer => |pointer| {
                    const presentation_hit = presentationHit(self, pointer.x, pointer.y);
                    const page_point = presentation_hit orelse clientPointToPage(self, pointer.x, pointer.y) orelse continue;
                    self.last_pointer_x = pointer.x;
                    self.last_pointer_y = pointer.y;
                    const x = page_point.x;
                    const y = page_point.y;
                    const modifiers: MouseModifiers = mouseModifiersFromMask(
                        MouseModifiers,
                        pointer.modifiers,
                        mouseButtonsFromInput(pointer.button, pointer.pressed),
                    );
                    _ = try page.triggerMouseMove(x, y, modifiers);
                    const button: MouseButton = switch (pointer.button) {
                        .left => .main,
                        .middle => .auxiliary,
                        .right => .secondary,
                    };
                    if (pointer.pressed) {
                        try page.triggerMouseDown(x, y, button, modifiers);
                    } else {
                        try page.triggerMouseUp(x, y, button, modifiers);
                        if (pointer.button == .left) {
                            if (page_point.dom_path) |dom_path| {
                                if (HasNodePathClick) {
                                    const click_result = try page.triggerMouseClickOnNodePathWithResult(dom_path, x, y, button, modifiers);
                                    if (!click_result.dispatched) {
                                        _ = try page.triggerMouseClickWithModifiers(x, y, button, modifiers);
                                    }
                                } else {
                                    _ = try page.triggerMouseClickWithModifiers(x, y, button, modifiers);
                                }
                            } else {
                                _ = try page.triggerMouseClickWithModifiers(x, y, button, modifiers);
                            }
                        }
                    }
                },
                .wheel => |wheel| {
                    const page_point = presentationHit(self, self.last_pointer_x, self.last_pointer_y) orelse clientPointToPage(self, self.last_pointer_x, self.last_pointer_y) orelse continue;
                    const x = page_point.x;
                    const y = page_point.y;
                    const modifiers: MouseModifiers = mouseModifiersFromMask(MouseModifiers, wheel.modifiers, 0);
                    _ = try page.triggerMouseWheel(
                        x,
                        y,
                        @as(f64, @floatFromInt(wheel.delta_x)),
                        @as(f64, @floatFromInt(wheel.delta_y)),
                        modifiers,
                    );
                },
            }
        }
    }

    pub fn presentDocument(self: *@This(), title: []const u8, url: []const u8, body: []const u8) !void {
        self.last_title = title;
        self.last_url = url;
        updateConsoleTitle(self, title, url);
        self.last_command_count = 0;
        self.last_content_height = 0;
        self.last_display_hash = hashPresentation(title, url, body, null);
        clearPresentationDisplayList(self);
        self.renderBootFrame();
    }

    pub fn presentPageView(self: *@This(), title: []const u8, url: []const u8, body: []const u8, display_list: ?*const DisplayList) !void {
        self.last_title = title;
        self.last_url = url;
        updateConsoleTitle(self, title, url);
        if (display_list) |list| {
            var hasher = std.hash.Wyhash.init(0);
            list.hashInto(&hasher);
            self.last_display_hash = hasher.final();
            self.last_command_count = list.commands.items.len;
            self.last_content_height = list.content_height;
            self.host.boot.markRunning();
            const owned = try list.cloneOwned(self.host.allocator);
            clearPresentationDisplayList(self);
            self.presentation_display_list = owned;
        } else {
            self.last_display_hash = hashPresentation(title, url, body, null);
            self.last_command_count = 0;
            self.last_content_height = 0;
            clearPresentationDisplayList(self);
        }
        self.renderFrame();
    }

    pub fn saveBitmap(self: *@This(), path: []const u8) bool {
        return saveFramebufferBitmap(self, path);
    }

    pub fn savePng(self: *@This(), path: []const u8) bool {
        return saveFramebufferPng(self, path);
    }

    pub fn chooseFiles(_: *@This(), _: []const u8, _: bool) ?Display.ChosenFiles {
        return null;
    }

    fn queueBrowserCommand(self: *@This(), command: BrowserCommand) !void {
        errdefer command.deinit(self.host.allocator);
        try self.command_queue.append(self.host.allocator, command);
    }

    fn handleShortcutKey(self: *@This(), key: u32, modifiers: anytype) !bool {
        if (modifiers.ctrl and modifiers.shift and !modifiers.alt and !modifiers.meta and key == 'T') {
            try self.queueBrowserCommand(.tab_reopen_closed);
            return true;
        }
        if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and key == c.VK_TAB) {
            try self.queueBrowserCommand(if (modifiers.shift) .tab_previous else .tab_next);
            return true;
        }
        if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and key == 'T') {
            try self.queueBrowserCommand(.tab_new);
            return true;
        }
        if (modifiers.ctrl and !modifiers.alt and !modifiers.meta and !modifiers.shift and key == 'W') {
            if (self.tab_entries.items.len == 0) {
                return false;
            }
            try self.queueBrowserCommand(.{ .tab_close = self.active_tab_index });
            return true;
        }
        if ((modifiers.alt or modifiers.meta) and !modifiers.ctrl and !modifiers.shift and key == c.VK_HOME) {
            try self.queueBrowserCommand(.home);
            return true;
        }
        return false;
    }

    fn firstRemovableDownloadIndex(self: *@This()) ?usize {
        for (self.download_entries.items, 0..) |entry, index| {
            if (entry.removable) {
                return index;
            }
        }
        return null;
    }

    pub fn nextBrowserCommand(self: *@This()) ?BrowserCommand {
        if (self.command_queue.items.len == 0) {
            return null;
        }
        return self.command_queue.orderedRemove(0);
    }

    pub fn userClosed(self: *const @This()) bool {
        return self.host.boot.state == .stopped;
    }

    pub fn deinit(self: *@This()) void {
        for (self.tab_entries.items) |entry| {
            self.host.allocator.free(entry.title);
            self.host.allocator.free(entry.url);
            self.host.allocator.free(entry.target_name);
        }
        self.tab_entries.deinit(self.host.allocator);
        for (self.history_entries.items) |entry| {
            self.host.allocator.free(entry);
        }
        self.history_entries.deinit(self.host.allocator);
        for (self.download_entries.items) |entry| {
            self.host.allocator.free(entry.filename);
            self.host.allocator.free(entry.path);
            self.host.allocator.free(entry.status);
        }
        self.download_entries.deinit(self.host.allocator);
        while (self.command_queue.items.len > 0) {
            const command = self.command_queue.orderedRemove(self.command_queue.items.len - 1);
            command.deinit(self.host.allocator);
        }
        self.command_queue.deinit(self.host.allocator);
        if (self.homepage_url) |homepage| {
            self.host.allocator.free(homepage);
            self.homepage_url = null;
        }
        if (self.app_data_path) |path| {
            self.host.allocator.free(path);
            self.app_data_path = null;
        }
        clearPresentationDisplayList(self);
        self.host.boot.shutdown();
    }

    fn renderBootFrame(self: *@This()) void {
        self.renderFrame();
    }

    fn renderFrame(self: *@This()) void {
        const fb = &self.host.framebuffer;
        if (fb.width == 0 or fb.height == 0) {
            return;
        }

        const width = @as(i32, @intCast(fb.width));
        const height = @as(i32, @intCast(fb.height));
        const bg = switch (self.host.boot.state) {
            .cold, .banner => @as(u32, 0xFF0B1020),
            .running => @as(u32, 0xFF081720),
            .failed => @as(u32, 0xFF2A1014),
            .stopped => @as(u32, 0xFF111111),
        };
        const chrome = switch (self.host.boot.state) {
            .cold, .banner => @as(u32, 0xFF18253A),
            .running => @as(u32, 0xFF1C2F45),
            .failed => @as(u32, 0xFF5A1F2A),
            .stopped => @as(u32, 0xFF2A2A2A),
        };
        const accent = accentColor(self.last_display_hash, 0);
        const accent2 = accentColor(self.last_display_hash, 16);
        const accent3 = accentColor(self.last_display_hash, 32);
        const has_tabs = self.tab_entries.items.len > 0;
        const has_history = self.history_entries.items.len > 0;
        const has_downloads = self.download_entries.items.len > 0;
        const has_settings = self.homepage_url != null or self.restore_previous_session or !self.allow_script_popups or self.default_zoom_percent != 100;

        fb.fill(bg);
        fb.fillRect(0, 0, width, 28, chrome);
        fb.fillRect(0, height - 20, width, 20, chrome);

        if (self.presentation_display_list) |*list| {
            renderPresentationFrame(self, fb, list);
        } else {
            const body_left = 24;
            const body_top: i32 = if (has_tabs) 64 else 48;
            const body_width: i32 = @max(@as(i32, 0), width - (body_left * 2));
            const loading_width = if (self.last_is_loading) @min(body_width, 240) else @min(body_width, 360);
            const command_width = @min(body_width, 96 + @as(i32, @intCast(@min(self.last_command_count, 24) * 8)));
            const content_width = if (self.last_content_height > 0)
                @min(body_width, 120 + @as(i32, @intCast(@min(@as(usize, @intCast(self.last_content_height)), 480) / 2)))
            else
                @min(body_width, 120);

            if (has_tabs) {
                const tab_strip_top = 30;
                const tab_strip_height = 22;
                fb.fillRect(0, tab_strip_top - 2, width, tab_strip_height + 4, chrome);
                var tab_x: i32 = 12;
                const tab_y = tab_strip_top;
                const tab_height: i32 = 18;
                for (self.tab_entries.items, 0..) |entry, index| {
                    const title_len = if (entry.title.len > 0) entry.title.len else entry.url.len;
                    const title_units: i32 = @as(i32, @intCast(@min(title_len, 24)));
                    var tab_width: i32 = 28 + (title_units * 7);
                    tab_width = @min(tab_width, @max(72, width - tab_x - 12));
                    if (tab_width <= 0) break;

                    var tab_color = accentColor(hashPresentation(entry.title, entry.url, entry.target_name, null), 0);
                    if (entry.has_error) {
                        tab_color = 0xFF9E4C4C;
                    } else if (entry.is_loading) {
                        tab_color = 0xFF3C789E;
                    } else if (index == self.active_tab_index) {
                        tab_color = 0xFF4FA46B;
                    }
                    fb.fillRect(tab_x, tab_y, tab_width, tab_height, tab_color);
                    fb.fillRect(tab_x, tab_y + tab_height - 2, tab_width, 2, chrome);
                    tab_x += tab_width + 6;
                    if (tab_x >= width - 12) {
                        break;
                    }
                }
            }

            fb.fillRect(body_left, body_top, loading_width, 16, accent);
            fb.fillRect(body_left, body_top + 28, command_width, 10, accent2);
            fb.fillRect(body_left, body_top + 46, content_width, 8, accent3);

            if (has_history) {
                const history_top = height - 38;
                fb.fillRect(12, history_top - 2, width - 24, 14, chrome);
                var history_x: i32 = 16;
                for (self.history_entries.items, 0..) |entry, index| {
                    const entry_len = @max(entry.len, 1);
                    const entry_units: i32 = @as(i32, @intCast(@min(entry_len, 32)));
                    var entry_width: i32 = 24 + (entry_units * 4);
                    entry_width = @min(entry_width, @max(32, width - history_x - 16));
                    if (entry_width <= 0) break;

                    var entry_color = accentColor(hashPresentation(entry, "", "", null), 12);
                    if (index == self.history_current_index) {
                        entry_color = 0xFF7FAFF0;
                    }
                    fb.fillRect(history_x, history_top, entry_width, 8, entry_color);
                    history_x += entry_width + 4;
                    if (history_x >= width - 16) {
                        break;
                    }
                }
            }

            if (has_downloads) {
                const download_top = height - 58;
                fb.fillRect(12, download_top - 2, width - 24, 14, chrome);
                var download_x: i32 = 16;
                for (self.download_entries.items, 0..) |entry, index| {
                    const filename_len = @max(entry.filename.len, 1);
                    const status_len = @max(entry.status.len, 1);
                    const combined_units: i32 = @as(i32, @intCast(@min(filename_len + status_len, 36)));
                    var download_width: i32 = 36 + (combined_units * 3);
                    download_width = @min(download_width, @max(36, width - download_x - 16));
                    if (download_width <= 0) break;

                    var download_color = accentColor(hashPresentation(entry.filename, entry.path, entry.status, null), 24);
                    if (!entry.removable) {
                        download_color = 0xFF808080;
                    } else if (index % 2 == 0) {
                        download_color ^= 0x00060606;
                    }
                    fb.fillRect(download_x, download_top, download_width, 8, download_color);
                    download_x += download_width + 4;
                    if (download_x >= width - 16) {
                        break;
                    }
                }
            }

            if (has_settings) {
                const settings_top = body_top + 76;
                fb.fillRect(body_left, settings_top - 2, body_width, 12, chrome);
                const homepage_len: usize = if (self.homepage_url) |homepage| homepage.len else 0;
                const remaining_homepage_width: i32 = if (body_width > 360) body_width - 360 else 0;
                const settings_blocks = [_]struct { width: i32, color: u32 }{
                    .{
                        .width = 120,
                        .color = if (self.restore_previous_session) 0xFF4FA46B else 0xFF9E4C4C,
                    },
                    .{
                        .width = 120,
                        .color = if (self.allow_script_popups) 0xFF4C7AA3 else 0xFF9E4C4C,
                    },
                    .{
                        .width = 96,
                        .color = accentColor(@as(u64, @intCast(self.default_zoom_percent)), 8),
                    },
                    .{
                        .width = @max(@as(i32, 72), @min(remaining_homepage_width, 240)),
                        .color = accentColor(@as(u64, @intCast(homepage_len)), 24),
                    },
                };
                var settings_x: i32 = body_left;
                for (settings_blocks) |block| {
                    const block_width = @min(block.width, @max(32, body_width - (settings_x - body_left) - 8));
                    if (block_width <= 0) break;
                    fb.fillRect(settings_x, settings_top, block_width, 8, block.color);
                    settings_x += block_width + 4;
                    if (settings_x >= body_left + body_width - 16) {
                        break;
                    }
                }
            }

            if (self.host.boot.state == .failed) {
                if (self.host.boot.last_error) |error_text| {
                    const error_width = @min(body_width, 72 + @as(i32, @intCast(@min(error_text.len, 240))));
                    fb.fillRect(body_left, body_top + 70, error_width, 14, @as(u32, 0xFFF06969));
                }
            }
        }
    }
};

fn mouseButtonsFromInput(button: Input.Button, pressed: bool) u16 {
    if (!pressed) {
        return 0;
    }
    return switch (button) {
        .left => 1 << 0,
        .middle => 1 << 1,
        .right => 1 << 2,
    };
}

fn unscalePresentationValue(value: f64, zoom_percent: i32) f64 {
    return value * 100.0 / @as(f64, @floatFromInt(@max(@as(i32, 1), zoom_percent)));
}

fn mouseModifiersFromMask(comptime MouseModifiers: type, modifiers: u8, buttons: u16) MouseModifiers {
    return .{
        .alt = (modifiers & modifier_alt) != 0,
        .ctrl = (modifiers & modifier_ctrl) != 0,
        .meta = (modifiers & modifier_meta) != 0,
        .shift = (modifiers & modifier_shift) != 0,
        .buttons = buttons,
    };
}

fn clientPointToPage(self: *BareMetalBackend, x: i32, y: i32) ?PointerPoint {
    const display_list = self.presentation_display_list orelse return .{
        .x = @as(f64, @floatFromInt(x)),
        .y = @as(f64, @floatFromInt(y)),
        .dom_path = null,
    };

    const content_x = @as(f64, @floatFromInt(x)) - @as(f64, @floatFromInt(presentation_origin_x));
    const content_y = @as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(presentation_origin_y));
    if (content_x < 0 or content_y < 0) {
        return null;
    }

    return .{
        .x = unscalePresentationValue(content_x, display_list.layout_scale) - @as(f64, @floatFromInt(display_list.page_margin)),
        .y = unscalePresentationValue(content_y, display_list.layout_scale) - @as(f64, @floatFromInt(display_list.page_margin)),
        .dom_path = null,
    };
}

fn presentationRegionScreenRect(list: *const DisplayList, x: i32, y: i32, width: i32, height: i32) DrawRect {
    return .{
        .x = presentation_origin_x + scalePresentationValue(x, list.layout_scale),
        .y = presentation_origin_y + scalePresentationValue(y, list.layout_scale),
        .width = @max(@as(i32, 1), scalePresentationValue(width, list.layout_scale)),
        .height = @max(@as(i32, 1), scalePresentationValue(height, list.layout_scale)),
    };
}

fn presentationRegionContains(list: *const DisplayList, screen_x: i32, screen_y: i32, x: i32, y: i32, width: i32, height: i32) bool {
    const rect = presentationRegionScreenRect(list, x, y, width, height);
    return screen_x >= rect.x and screen_y >= rect.y and screen_x < rect.x + rect.width and screen_y < rect.y + rect.height;
}

fn presentationHit(self: *BareMetalBackend, screen_x: i32, screen_y: i32) ?PointerPoint {
    if (self.presentation_display_list) |*list| {
        var best_hit: ?PointerPoint = null;
        var best_z_index: i32 = std.math.minInt(i32);

        for (list.link_regions.items) |region| {
            if (region.dom_path.len == 0) {
                continue;
            }
            if (!presentationRegionContains(list, screen_x, screen_y, region.x, region.y, region.width, region.height)) {
                continue;
            }
            if (best_hit != null and region.z_index < best_z_index) {
                continue;
            }
            best_z_index = region.z_index;
            best_hit = .{
                .x = @as(f64, @floatFromInt(region.x + @divTrunc(region.width, 2))),
                .y = @as(f64, @floatFromInt(region.y + @divTrunc(region.height, 2))),
                .dom_path = region.dom_path,
            };
        }

        for (list.control_regions.items) |region| {
            if (region.dom_path.len == 0) {
                continue;
            }
            if (!presentationRegionContains(list, screen_x, screen_y, region.x, region.y, region.width, region.height)) {
                continue;
            }
            if (best_hit != null and region.z_index < best_z_index) {
                continue;
            }
            best_z_index = region.z_index;
            best_hit = .{
                .x = @as(f64, @floatFromInt(region.x + @divTrunc(region.width, 2))),
                .y = @as(f64, @floatFromInt(region.y + @divTrunc(region.height, 2))),
                .dom_path = region.dom_path,
            };
        }

        return best_hit;
    }
    return null;
}

fn keyNameFromCode(buf: *[8]u8, code: u32) []const u8 {
    return switch (code) {
        8 => "Backspace",
        9 => "Tab",
        13 => "Enter",
        27 => "Escape",
        32 => " ",
        33 => "PageUp",
        34 => "PageDown",
        35 => "End",
        36 => "Home",
        37 => "ArrowLeft",
        38 => "ArrowUp",
        39 => "ArrowRight",
        40 => "ArrowDown",
        46 => "Delete",
        112 => "F1",
        113 => "F2",
        114 => "F3",
        115 => "F4",
        116 => "F5",
        117 => "F6",
        118 => "F7",
        119 => "F8",
        120 => "F9",
        121 => "F10",
        122 => "F11",
        123 => "F12",
        else => blk: {
            if (code > 0x10ffff) {
                break :blk "Unidentified";
            }
            const len = std.unicode.utf8Encode(@as(u21, @intCast(code)), buf) catch break :blk "Unidentified";
            break :blk buf[0..len];
        },
    };
}

fn openProfileDir(path: []const u8) !std.fs.Dir {
    return if (std.fs.path.isAbsolute(path))
        std.fs.openDirAbsolute(path, .{})
    else
        std.fs.cwd().openDir(path, .{});
}

fn parseMailboxBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes")) {
        return true;
    }
    if (std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no")) {
        return false;
    }
    return error.InvalidMailboxInput;
}

fn parseMailboxButton(value: []const u8) !Input.Button {
    if (std.ascii.eqlIgnoreCase(value, "left") or std.ascii.eqlIgnoreCase(value, "main")) {
        return .left;
    }
    if (std.ascii.eqlIgnoreCase(value, "middle") or std.ascii.eqlIgnoreCase(value, "auxiliary")) {
        return .middle;
    }
    if (std.ascii.eqlIgnoreCase(value, "right") or std.ascii.eqlIgnoreCase(value, "secondary")) {
        return .right;
    }
    return error.InvalidMailboxInput;
}

fn parseMailboxI32(value: []const u8) !i32 {
    return std.fmt.parseInt(i32, value, 10) catch error.InvalidMailboxInput;
}

fn parseMailboxU8(value: []const u8) !u8 {
    return std.fmt.parseInt(u8, value, 10) catch error.InvalidMailboxInput;
}

fn parseMailboxU32(value: []const u8) !u32 {
    return std.fmt.parseInt(u32, value, 10) catch error.InvalidMailboxInput;
}

fn processMailboxLine(self: *BareMetalBackend, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) {
        return error.InvalidMailboxInput;
    }

    var parts = std.mem.splitScalar(u8, trimmed, '|');
    const kind = parts.next() orelse return error.InvalidMailboxInput;
    if (std.mem.eql(u8, kind, "key")) {
        const code = try parseMailboxU32(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const pressed = try parseMailboxBool(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const modifiers = try parseMailboxU8(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        try self.host.input.pushKey(self.host.allocator, code, pressed, modifiers);
        return;
    }
    if (std.mem.eql(u8, kind, "command")) {
        const command_name = std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r");
        if (std.ascii.eqlIgnoreCase(command_name, "page_downloads")) {
            try self.queueBrowserCommand(.page_downloads);
            return;
        }
        if (std.ascii.eqlIgnoreCase(command_name, "download_remove")) {
            const index = try parseMailboxU32(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
            try self.queueBrowserCommand(.{ .download_remove = index });
            return;
        }
        return error.InvalidMailboxInput;
    }
    if (std.mem.eql(u8, kind, "move")) {
        const x = try parseMailboxI32(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const y = try parseMailboxI32(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const modifiers = try parseMailboxU8(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        try self.host.input.pushMove(self.host.allocator, x, y, modifiers);
        return;
    }
    if (std.mem.eql(u8, kind, "pointer")) {
        const x = try parseMailboxI32(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const y = try parseMailboxI32(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const button = try parseMailboxButton(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const pressed = try parseMailboxBool(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const modifiers = try parseMailboxU8(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        try self.host.input.pushPointer(self.host.allocator, x, y, button, pressed, modifiers);
        return;
    }
    if (std.mem.eql(u8, kind, "wheel")) {
        const delta_x = try parseMailboxI32(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const delta_y = try parseMailboxI32(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        const modifiers = try parseMailboxU8(std.mem.trim(u8, parts.next() orelse return error.InvalidMailboxInput, " \t\r"));
        try self.host.input.pushWheel(self.host.allocator, delta_x, delta_y, modifiers);
        return;
    }

    return error.InvalidMailboxInput;
}

fn pollMailboxInput(self: *BareMetalBackend) !void {
    const app_data_path = self.app_data_path orelse return;
    var dir = openProfileDir(app_data_path) catch return;
    defer dir.close();

    const file = dir.openFile(bare_metal_input_mailbox_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return,
    };
    defer file.close();

    const stat = file.stat() catch return;
    if (self.input_mailbox_offset > stat.size) {
        self.input_mailbox_offset = 0;
    }
    try file.seekTo(self.input_mailbox_offset);

    const data = file.readToEndAlloc(self.host.allocator, 64 * 1024) catch return;
    defer self.host.allocator.free(data);
    if (data.len == 0) {
        return;
    }

    var complete_len = data.len;
    if (data[data.len - 1] != '\n') {
        if (std.mem.lastIndexOfScalar(u8, data, '\n')) |last_newline| {
            complete_len = last_newline + 1;
        } else {
            return;
        }
    }

    var it = std.mem.splitScalar(u8, data[0..complete_len], '\n');
    while (it.next()) |raw_line| {
        processMailboxLine(self, raw_line) catch |err| switch (err) {
            error.InvalidMailboxInput => continue,
            else => return err,
        };
    }
    self.input_mailbox_offset += complete_len;
}

fn formatBareMetalWindowTitle(allocator: std.mem.Allocator, title: []const u8, url: []const u8) ![]u8 {
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

fn updateConsoleTitle(self: *BareMetalBackend, title: []const u8, url: []const u8) void {
    if (builtin.os.tag != .windows) {
        return;
    }

    const title_text = formatBareMetalWindowTitle(self.host.allocator, title, url) catch return;
    defer self.host.allocator.free(title_text);

    const utf16 = std.unicode.utf8ToUtf16LeAllocZ(std.heap.c_allocator, title_text) catch return;
    defer std.heap.c_allocator.free(utf16);
    _ = c.SetConsoleTitleW(utf16.ptr);
}

fn hashPresentation(title: []const u8, url: []const u8, body: []const u8, display_list: ?*const DisplayList) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(title);
    hasher.update(url);
    hasher.update(body);
    if (display_list) |list| {
        list.hashInto(&hasher);
    }
    return hasher.final();
}

fn accentColor(hash: u64, shift: u6) u32 {
    const mixed = @as(u32, @truncate(hash >> shift));
    return 0xFF202020 | (mixed & 0x00DFDFDF);
}

fn scalePresentationValue(value: i32, zoom_percent: i32) i32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(value)) * @as(f64, @floatFromInt(zoom_percent)) / 100.0));
}

fn clearPresentationDisplayList(self: *BareMetalBackend) void {
    if (self.presentation_display_list) |*list| {
        list.deinit(self.host.allocator);
        self.presentation_display_list = null;
    }
}

fn renderPresentationFrame(self: *BareMetalBackend, fb: *Framebuffer, list: *const DisplayList) void {
    const width = @as(i32, @intCast(fb.width));
    const height = @as(i32, @intCast(fb.height));
    const origin_x = presentation_origin_x;
    const origin_y = presentation_origin_y;
    const content_width = @max(@as(i32, 0), width - (origin_x * 2));
    const content_height = @max(@as(i32, 0), height - origin_y - 20);
    renderDisplayList(self, fb, list, origin_x, origin_y, content_width, content_height);
}

fn renderDisplayList(
    self: *BareMetalBackend,
    fb: *Framebuffer,
    list: *const DisplayList,
    origin_x: i32,
    origin_y: i32,
    content_width: i32,
    content_height: i32,
) void {
    if (list.commands.items.len == 0 or content_width <= 0 or content_height <= 0) {
        return;
    }

    var command_indices: std.ArrayListUnmanaged(usize) = .{};
    defer command_indices.deinit(self.host.allocator);
    command_indices.ensureTotalCapacity(self.host.allocator, list.commands.items.len) catch return;
    for (list.commands.items, 0..) |_, command_index| {
        var insert_at = command_indices.items.len;
        while (insert_at > 0) {
            const previous_index = command_indices.items[insert_at - 1];
            const previous_z = presentationCommandZIndex(list.commands.items[previous_index]);
            const current_z = presentationCommandZIndex(list.commands.items[command_index]);
            if (previous_z < current_z) break;
            if (previous_z == current_z and previous_index < command_index) break;
            insert_at -= 1;
        }
        command_indices.insert(self.host.allocator, insert_at, command_index) catch return;
    }

    const content_clip = DrawRect{
        .x = origin_x,
        .y = origin_y,
        .width = content_width,
        .height = content_height,
    };

    for (command_indices.items) |command_index| {
        const command = list.commands.items[command_index];
        switch (command) {
            .fill_rect => |rect_cmd| {
                if (resolvePresentationCommandRect(list, origin_x, origin_y, rect_cmd.x, rect_cmd.y, rect_cmd.width, rect_cmd.height, rect_cmd.clip_rect, content_clip)) |target| {
                    paintRect(fb, target, rect_cmd.color, rect_cmd.opacity);
                }
            },
            .stroke_rect => |rect_cmd| {
                if (resolvePresentationCommandRect(list, origin_x, origin_y, rect_cmd.x, rect_cmd.y, rect_cmd.width, rect_cmd.height, rect_cmd.clip_rect, content_clip)) |target| {
                    paintStrokeRect(fb, target, rect_cmd.color, rect_cmd.opacity);
                }
            },
            .text => |text_cmd| {
                if (resolvePresentationCommandRect(list, origin_x, origin_y, text_cmd.x, text_cmd.y, text_cmd.width, @max(text_cmd.height, text_cmd.font_size + 8), text_cmd.clip_rect, content_clip)) |target| {
                    paintTextCommand(self.host.allocator, fb, target, text_cmd);
                }
            },
            .image => |image_cmd| {
                if (resolvePresentationCommandRect(list, origin_x, origin_y, image_cmd.x, image_cmd.y, image_cmd.width, image_cmd.height, image_cmd.clip_rect, content_clip)) |target| {
                    paintImageCommand(self.host.allocator, fb, target, image_cmd);
                }
            },
            .canvas => |canvas_cmd| {
                if (resolvePresentationCommandRect(list, origin_x, origin_y, canvas_cmd.x, canvas_cmd.y, canvas_cmd.width, canvas_cmd.height, canvas_cmd.clip_rect, content_clip)) |target| {
                    paintCanvasCommand(fb, target, canvas_cmd);
                }
            },
        }
    }
}

fn presentationCommandZIndex(command: DisplayList.Command) i32 {
    return switch (command) {
        .fill_rect => |rect| rect.z_index,
        .stroke_rect => |rect| rect.z_index,
        .text => |text| text.z_index,
        .image => |image| image.z_index,
        .canvas => |canvas| canvas.z_index,
    };
}

fn resolvePresentationCommandRect(
    list: *const DisplayList,
    origin_x: i32,
    origin_y: i32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    clip_rect: ?DisplayList.ClipRect,
    content_clip: DrawRect,
) ?DrawRect {
    if (width <= 0 or height <= 0) return null;

    const scaled_x = origin_x + scalePresentationValue(x, list.layout_scale);
    const scaled_y = origin_y + scalePresentationValue(y, list.layout_scale);
    const scaled_width = @max(@as(i32, 1), scalePresentationValue(width, list.layout_scale));
    const scaled_height = @max(@as(i32, 1), scalePresentationValue(height, list.layout_scale));

    var target = DrawRect{
        .x = scaled_x,
        .y = scaled_y,
        .width = scaled_width,
        .height = scaled_height,
    };
    if (clip_rect) |clip| {
        const clip_target = DrawRect{
            .x = origin_x + scalePresentationValue(clip.x, list.layout_scale),
            .y = origin_y + scalePresentationValue(clip.y, list.layout_scale),
            .width = @max(@as(i32, 1), scalePresentationValue(clip.width, list.layout_scale)),
            .height = @max(@as(i32, 1), scalePresentationValue(clip.height, list.layout_scale)),
        };
        target = intersectDrawRect(target, clip_target) orelse return null;
    }
    target = intersectDrawRect(target, content_clip) orelse return null;
    return target;
}

fn intersectDrawRect(a: DrawRect, b: DrawRect) ?DrawRect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(a.x + a.width, b.x + b.width);
    const bottom = @min(a.y + a.height, b.y + b.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = left,
        .y = top,
        .width = right - left,
        .height = bottom - top,
    };
}

fn paintRect(fb: *Framebuffer, rect: DrawRect, color: DisplayList.Color, opacity: u8) void {
    if (rect.width <= 0 or rect.height <= 0 or fb.width == 0 or fb.height == 0) return;
    const src_alpha = @as(u16, color.a) * @as(u16, opacity) / 255;
    if (src_alpha == 0) return;
    const argb = colorToArgb(color);
    if (src_alpha >= 255) {
        fb.fillRect(rect.x, rect.y, rect.width, rect.height, argb);
        return;
    }

    const left = @as(i32, @max(rect.x, 0));
    const top = @as(i32, @max(rect.y, 0));
    const right = @as(i32, @min(rect.x + rect.width, @as(i32, @intCast(fb.width))));
    const bottom = @as(i32, @min(rect.y + rect.height, @as(i32, @intCast(fb.height))));
    if (left >= right or top >= bottom) return;

    var y = top;
    while (y < bottom) : (y += 1) {
        var x = left;
        while (x < right) : (x += 1) {
            blendPixel(fb, x, y, color, opacity);
        }
    }
}

fn paintStrokeRect(fb: *Framebuffer, rect: DrawRect, color: DisplayList.Color, opacity: u8) void {
    if (rect.width <= 0 or rect.height <= 0) return;
    paintRect(fb, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1 }, color, opacity);
    if (rect.height > 1) {
        paintRect(fb, .{ .x = rect.x, .y = rect.y + rect.height - 1, .width = rect.width, .height = 1 }, color, opacity);
    }
    if (rect.height > 2) {
        paintRect(fb, .{ .x = rect.x, .y = rect.y + 1, .width = 1, .height = rect.height - 2 }, color, opacity);
        if (rect.width > 1) {
            paintRect(fb, .{ .x = rect.x + rect.width - 1, .y = rect.y + 1, .width = 1, .height = rect.height - 2 }, color, opacity);
        }
    }
}

fn paintTextCommand(allocator: std.mem.Allocator, fb: *Framebuffer, rect: DrawRect, text_cmd: DisplayList.TextCommand) void {
    if (rect.width <= 0 or rect.height <= 0) return;
    if (builtin.os.tag == .windows) {
        paintTextCommandWindows(allocator, fb, rect, text_cmd);
        return;
    }

    const fill_color = if (text_cmd.color.a == 0)
        @as(DisplayList.Color, .{ .r = 224, .g = 224, .b = 224, .a = 255 })
    else
        .{ .r = text_cmd.color.r, .g = text_cmd.color.g, .b = text_cmd.color.b, .a = 255 };
    paintRect(fb, rect, fill_color, text_cmd.opacity);
    paintStrokeRect(fb, rect, .{ .r = 32, .g = 32, .b = 32, .a = 255 }, 96);
}

fn paintImageCommand(allocator: std.mem.Allocator, fb: *Framebuffer, rect: DrawRect, image_cmd: DisplayList.ImageCommand) void {
    _ = allocator;
    if (rect.width <= 0 or rect.height <= 0) return;
    const hash = hashPresentation(image_cmd.url, image_cmd.alt, image_cmd.request_cookie_value, null);
    const fill_color = DisplayList.Color{
        .r = @as(u8, @truncate(hash)),
        .g = @as(u8, @truncate(hash >> 8)),
        .b = @as(u8, @truncate(hash >> 16)),
        .a = 255,
    };
    paintRect(fb, rect, fill_color, image_cmd.opacity);
    paintStrokeRect(fb, rect, .{ .r = 255, .g = 255, .b = 255, .a = 255 }, 255);
}

fn paintCanvasCommand(fb: *Framebuffer, rect: DrawRect, canvas_cmd: DisplayList.CanvasCommand) void {
    if (rect.width <= 0 or rect.height <= 0 or canvas_cmd.pixel_width == 0 or canvas_cmd.pixel_height == 0 or canvas_cmd.pixels.len == 0) {
        return;
    }
    const source_width = @as(i32, @intCast(canvas_cmd.pixel_width));
    const source_height = @as(i32, @intCast(canvas_cmd.pixel_height));
    if (source_width <= 0 or source_height <= 0) return;

    const clipped = intersectDrawRect(rect, .{
        .x = 0,
        .y = 0,
        .width = @as(i32, @intCast(fb.width)),
        .height = @as(i32, @intCast(fb.height)),
    }) orelse return;

    var y = clipped.y;
    while (y < clipped.y + clipped.height) : (y += 1) {
        const source_y = @divTrunc((y - rect.y) * source_height, rect.height);
        var x = clipped.x;
        while (x < clipped.x + clipped.width) : (x += 1) {
            const source_x = @divTrunc((x - rect.x) * source_width, rect.width);
            const source_index = (@as(usize, @intCast(source_y)) * @as(usize, @intCast(source_width)) + @as(usize, @intCast(source_x))) * 4;
            if (source_index + 3 >= canvas_cmd.pixels.len) continue;
            const src_color = DisplayList.Color{
                .r = canvas_cmd.pixels[source_index + 0],
                .g = canvas_cmd.pixels[source_index + 1],
                .b = canvas_cmd.pixels[source_index + 2],
                .a = canvas_cmd.pixels[source_index + 3],
            };
            blendPixel(fb, x, y, src_color, canvas_cmd.opacity);
        }
    }
}

fn blendPixel(fb: *Framebuffer, x: i32, y: i32, color: DisplayList.Color, opacity: u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(fb.width)) or y >= @as(i32, @intCast(fb.height))) return;
    const index = @as(usize, @intCast(y)) * @as(usize, @intCast(fb.width)) + @as(usize, @intCast(x));
    const dst = fb.pixels[index];
    const src_alpha = @as(u32, color.a) * @as(u32, opacity) / 255;
    if (src_alpha == 0) return;
    if (src_alpha >= 255) {
        fb.pixels[index] = colorToArgb(color);
        return;
    }

    const dst_r = @as(u32, (dst >> 16) & 0xFF);
    const dst_g = @as(u32, (dst >> 8) & 0xFF);
    const dst_b = @as(u32, dst & 0xFF);
    const inv = 255 - src_alpha;
    const out_r = (@as(u32, color.r) * src_alpha + dst_r * inv + 127) / 255;
    const out_g = (@as(u32, color.g) * src_alpha + dst_g * inv + 127) / 255;
    const out_b = (@as(u32, color.b) * src_alpha + dst_b * inv + 127) / 255;
    fb.pixels[index] = 0xFF000000 | (out_r << 16) | (out_g << 8) | out_b;
}

fn colorToArgb(color: DisplayList.Color) u32 {
    return (@as(u32, color.a) << 24) | (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | @as(u32, color.b);
}

fn paintTextCommandWindows(allocator: std.mem.Allocator, fb: *Framebuffer, rect: DrawRect, text_cmd: DisplayList.TextCommand) void {
    const clipped = intersectDrawRect(rect, .{
        .x = 0,
        .y = 0,
        .width = @as(i32, @intCast(fb.width)),
        .height = @as(i32, @intCast(fb.height)),
    }) orelse return;
    const text_wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, text_cmd.text) catch return;
    defer allocator.free(text_wide);
    if (text_wide.len == 0) return;

    const temp_width: i32 = if (rect.width > 1) rect.width else 1;
    const temp_height: i32 = if (rect.height > 1) rect.height else 1;
    const hdc = c.CreateCompatibleDC(null);
    if (hdc == null) return;
    defer _ = c.DeleteDC(hdc);

    var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = temp_width;
    bmi.bmiHeader.biHeight = -temp_height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var bits: ?*anyopaque = null;
    const dib = c.CreateDIBSection(hdc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
    if (dib == null or bits == null) return;
    defer _ = c.DeleteObject(dib);

    const old_bitmap = c.SelectObject(hdc, dib);
    defer _ = c.SelectObject(hdc, old_bitmap);

    const dib_pixels: [*]u32 = @ptrCast(@alignCast(bits.?));
    const dib_pixel_count = @as(usize, @intCast(temp_width * temp_height));
    const dib_pixels_slice = dib_pixels[0..dib_pixel_count];
    @memset(dib_pixels_slice, 0xFF010203);

    const font_spec = resolvePresentationFontSpec(text_cmd.font_family);
    const wide_face = std.unicode.utf8ToUtf16LeAllocZ(allocator, font_spec.face_name) catch return;
    defer allocator.free(wide_face);

    const font = c.CreateFontW(
        -@as(c_int, @intCast(@max(@as(i32, 1), text_cmd.font_size))),
        0,
        0,
        0,
        presentationFontWeight(text_cmd.font_weight),
        @intFromBool(text_cmd.italic),
        @intFromBool(text_cmd.underline),
        0,
        c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS,
        c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY,
        font_spec.pitch_family,
        wide_face.ptr,
    );
    if (font == null) return;
    defer _ = c.DeleteObject(font);

    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    _ = c.SetTextAlign(hdc, c.TA_LEFT | c.TA_TOP);
    _ = c.SetTextColor(hdc, c.RGB(text_cmd.color.r, text_cmd.color.g, text_cmd.color.b));
    if (text_cmd.letter_spacing != 0) {
        _ = c.SetTextCharacterExtra(hdc, @as(c_int, @intCast(text_cmd.letter_spacing)));
    }
    const space_count = std.mem.count(u8, text_cmd.text, " ");
    if (space_count > 0 and text_cmd.word_spacing != 0) {
        _ = c.SetTextJustification(hdc, @as(c_int, @intCast(text_cmd.word_spacing * @as(i32, @intCast(space_count)))), @as(c_int, @intCast(space_count)));
    }

    _ = c.TextOutW(hdc, 0, 0, text_wide.ptr, @as(c_int, @intCast(text_wide.len)));

    var row: i32 = 0;
    while (row < temp_height) : (row += 1) {
        var col: i32 = 0;
        while (col < temp_width) : (col += 1) {
            const pixel = dib_pixels[@as(usize, @intCast(row * temp_width + col))];
            if (pixel == 0xFF010203) continue;
            const target_x = rect.x + col;
            const target_y = rect.y + row;
            if (target_x < clipped.x or target_y < clipped.y or target_x >= clipped.x + clipped.width or target_y >= clipped.y + clipped.height) continue;
            const target_index = @as(usize, @intCast(target_y)) * @as(usize, @intCast(fb.width)) + @as(usize, @intCast(target_x));
            const src_color = DisplayList.Color{
                .r = @as(u8, @truncate(pixel >> 16)),
                .g = @as(u8, @truncate(pixel >> 8)),
                .b = @as(u8, @truncate(pixel)),
                .a = text_cmd.color.a,
            };
            blendPixel(fb, target_x, target_y, src_color, text_cmd.opacity);
            _ = target_index;
        }
    }
}

const FontSpec = struct {
    face_name: []const u8,
    pitch_family: u32,
};

fn resolvePresentationFontSpec(font_family_value: []const u8) FontSpec {
    var preferred_specific: []const u8 = "";
    var generic_spec: ?FontSpec = null;

    var families = std.mem.splitScalar(u8, font_family_value, ',');
    while (families.next()) |raw_family| {
        const family = trimPresentationFontFamily(raw_family);
        if (family.len == 0) continue;
        if (presentationGenericFontSpec(family)) |spec| {
            if (generic_spec == null) generic_spec = spec;
            continue;
        }
        if (preferred_specific.len == 0) preferred_specific = family;
    }

    if (preferred_specific.len > 0) {
        return .{
            .face_name = preferred_specific,
            .pitch_family = if (generic_spec) |spec| spec.pitch_family else 0,
        };
    }
    if (generic_spec) |spec| return spec;
    return .{ .face_name = "Segoe UI", .pitch_family = 0 };
}

fn trimPresentationFontFamily(raw_family: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw_family, &std.ascii.whitespace);
    if (trimmed.len >= 2) {
        const quote = trimmed[0];
        if ((quote == '"' or quote == '\'') and trimmed[trimmed.len - 1] == quote) {
            return std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], &std.ascii.whitespace);
        }
    }
    return trimmed;
}

fn presentationGenericFontSpec(family: []const u8) ?FontSpec {
    if (std.ascii.eqlIgnoreCase(family, "sans-serif") or std.ascii.eqlIgnoreCase(family, "system-ui") or std.ascii.eqlIgnoreCase(family, "ui-sans-serif") or std.ascii.eqlIgnoreCase(family, "ui-rounded")) {
        return .{ .face_name = "Segoe UI", .pitch_family = 0 };
    }
    if (std.ascii.eqlIgnoreCase(family, "serif") or std.ascii.eqlIgnoreCase(family, "ui-serif")) {
        return .{ .face_name = "Times New Roman", .pitch_family = 0 };
    }
    if (std.ascii.eqlIgnoreCase(family, "monospace") or std.ascii.eqlIgnoreCase(family, "ui-monospace")) {
        return .{ .face_name = "Consolas", .pitch_family = 0 };
    }
    if (std.ascii.eqlIgnoreCase(family, "cursive")) {
        return .{ .face_name = "Segoe Script", .pitch_family = 0 };
    }
    if (std.ascii.eqlIgnoreCase(family, "fantasy")) {
        return .{ .face_name = "Impact", .pitch_family = 0 };
    }
    if (std.ascii.eqlIgnoreCase(family, "emoji")) {
        return .{ .face_name = "Segoe UI Emoji", .pitch_family = 0 };
    }
    if (std.ascii.eqlIgnoreCase(family, "math")) {
        return .{ .face_name = "Cambria Math", .pitch_family = 0 };
    }
    return null;
}

fn presentationFontWeight(css_weight: i32) i32 {
    return @as(i32, @intCast(std.math.clamp(css_weight, 100, 900)));
}

fn openOutputFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, .{});
    }
    return std.fs.cwd().createFile(path, .{});
}

fn saveFramebufferBitmap(backend: *BareMetalBackend, path: []const u8) bool {
    const fb = &backend.host.framebuffer;
    if (fb.width == 0 or fb.height == 0 or fb.pixels.len == 0) {
        return false;
    }

    var file = openOutputFile(path) catch |err| {
        log.warn(.app, "bare metal bmp create failed", .{ .err = err });
        return false;
    };
    defer file.close();

    const pixel_bytes = std.mem.sliceAsBytes(fb.pixels);
    const headers_bytes = @sizeOf(BitmapFileHeader) + @sizeOf(c.BITMAPINFOHEADER);
    const file_header = BitmapFileHeader{
        .bfType = 0x4D42,
        .bfSize = @intCast(headers_bytes + pixel_bytes.len),
        .bfReserved1 = 0,
        .bfReserved2 = 0,
        .bfOffBits = @intCast(headers_bytes),
    };

    var bmi_header: c.BITMAPINFOHEADER = std.mem.zeroes(c.BITMAPINFOHEADER);
    bmi_header.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi_header.biWidth = @as(i32, @intCast(fb.width));
    bmi_header.biHeight = -@as(i32, @intCast(fb.height));
    bmi_header.biPlanes = 1;
    bmi_header.biBitCount = 32;
    bmi_header.biCompression = c.BI_RGB;

    file.writeAll(std.mem.asBytes(&file_header)) catch |err| {
        log.warn(.app, "bare metal bmp write failed", .{ .err = err });
        return false;
    };
    file.writeAll(std.mem.asBytes(&bmi_header)) catch |err| {
        log.warn(.app, "bare metal bmp write failed", .{ .err = err });
        return false;
    };
    file.writeAll(pixel_bytes) catch |err| {
        log.warn(.app, "bare metal bmp write failed", .{ .err = err });
        return false;
    };

    log.info(.app, "bare metal bmp saved", .{ .path = path });
    return true;
}

fn saveFramebufferPng(backend: *BareMetalBackend, path: []const u8) bool {
    const fb = &backend.host.framebuffer;
    if (fb.width == 0 or fb.height == 0 or fb.pixels.len == 0) {
        return false;
    }

    var file = openOutputFile(path) catch |err| {
        log.warn(.app, "bare metal png create failed", .{ .err = err });
        return false;
    };
    defer file.close();

    writePngFromBgra(
        &file,
        fb.width,
        fb.height,
        std.mem.sliceAsBytes(fb.pixels),
        backend.host.allocator,
    ) catch |err| {
        log.warn(.app, "bare metal png write failed", .{ .err = err });
        return false;
    };

    log.info(.app, "bare metal png saved", .{ .path = path });
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
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        scanlines[dst_index] = 0;
        dst_index += 1;
        var col: u32 = 0;
        while (col < width) : (col += 1) {
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

        if (final_block) break;
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
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

fn crc32Final(crc: u32) u32 {
    return ~crc;
}

test "bare metal backend paints boot and presentation states" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();
    try std.testing.expectEqual(BootState.banner, host.boot.state);
    try std.testing.expectEqual(@as(u32, 320), host.framebuffer.width);
    try std.testing.expectEqual(@as(u32, 180), host.framebuffer.height);

    try backend.presentDocument("title", "url", "body");
    try std.testing.expect(backend.last_display_hash != 0);
    try std.testing.expect(host.framebuffer.pixel(0, 0).? != 0);

    var list = DisplayList{};
    defer list.deinit(std.testing.allocator);
    try list.addFillRect(std.testing.allocator, .{
        .x = 0,
        .y = 0,
        .width = 120,
        .height = 40,
        .color = .{ .r = 255, .g = 0, .b = 0 },
    });
    try backend.presentPageView("title", "url", "body", &list);
    try std.testing.expectEqual(BootState.running, host.boot.state);
    try std.testing.expect(backend.last_command_count > 0);
}

test "bare metal backend drains queued input" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    try host.input.pushKey(std.testing.allocator, 'a', true, modifier_shift);
    try host.input.pushKey(std.testing.allocator, 'a', false, modifier_shift);
    try host.input.pushPointer(std.testing.allocator, 40, 52, .left, true, 0);
    try host.input.pushWheel(std.testing.allocator, 0, -24, 0);

    const FakePage = struct {
        keys_down: usize = 0,
        keys_up: usize = 0,
        moves: usize = 0,
        mouse_down: usize = 0,
        mouse_up: usize = 0,
        clicks: usize = 0,
        wheels: usize = 0,
        last_key_buf: [8]u8 = .{0} ** 8,
        last_key_len: usize = 0,
        last_x: f64 = 0,
        last_y: f64 = 0,

        pub fn triggerKeyboardKeyDownWithRepeat(self: *@This(), key: []const u8, _: anytype, _: bool) !bool {
            self.keys_down += 1;
            std.mem.copyForwards(u8, self.last_key_buf[0..key.len], key);
            self.last_key_len = key.len;
            return true;
        }

        pub fn triggerKeyboardKeyUp(self: *@This(), key: []const u8, _: anytype) !bool {
            self.keys_up += 1;
            std.mem.copyForwards(u8, self.last_key_buf[0..key.len], key);
            self.last_key_len = key.len;
            return true;
        }

        pub fn triggerMouseMove(self: *@This(), x: f64, y: f64, _: anytype) !void {
            self.moves += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseDown(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !void {
            self.mouse_down += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseUp(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !void {
            self.mouse_up += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseClickWithModifiers(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !bool {
            self.clicks += 1;
            self.last_x = x;
            self.last_y = y;
            return true;
        }

        pub fn triggerMouseWheel(self: *@This(), x: f64, y: f64, _: f64, dy: f64, _: anytype) !struct { dispatched: bool, default_prevented: bool, scrolled_element: bool } {
            self.wheels += 1;
            self.last_x = x;
            self.last_y = y;
            return .{ .dispatched = true, .default_prevented = false, .scrolled_element = dy != 0 };
        }
    };

    var page = FakePage{};
    try backend.dispatchInput(&page);

    try std.testing.expectEqual(@as(usize, 1), page.keys_down);
    try std.testing.expectEqual(@as(usize, 1), page.keys_up);
    try std.testing.expectEqualStrings("a", page.last_key_buf[0..page.last_key_len]);
    try std.testing.expectEqual(@as(usize, 1), page.moves);
    try std.testing.expectEqual(@as(usize, 1), page.mouse_down);
    try std.testing.expectEqual(@as(usize, 0), page.mouse_up);
    try std.testing.expectEqual(@as(usize, 1), page.wheels);
    try std.testing.expect(host.input.isEmpty());
}

test "bare metal backend drains mailbox input" {
    const profile_dir = "tmp-bare-metal-mailbox";
    std.fs.cwd().deleteTree(profile_dir) catch {};
    defer std.fs.cwd().deleteTree(profile_dir) catch {};

    var profile = try std.fs.cwd().makeOpenPath(profile_dir, .{});
    defer profile.close();

    {
        var mailbox = try profile.createFile(bare_metal_input_mailbox_file, .{ .truncate = true });
        defer mailbox.close();
        try mailbox.writeAll(
            \\move|11|13|4
            \\key|97|1|1
            \\key|97|0|1
            \\pointer|20|30|left|1|2
            \\pointer|20|30|left|0|2
            \\wheel|0|-24|8
            \\
        );
    }

    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();
    backend.setAppDataPath(profile_dir);

    const FakePage = struct {
        keys_down: usize = 0,
        keys_up: usize = 0,
        moves: usize = 0,
        mouse_down: usize = 0,
        mouse_up: usize = 0,
        clicks: usize = 0,
        wheels: usize = 0,
        last_key_buf: [8]u8 = .{0} ** 8,
        last_key_len: usize = 0,
        last_x: f64 = 0,
        last_y: f64 = 0,

        pub fn triggerKeyboardKeyDownWithRepeat(self: *@This(), key: []const u8, _: anytype, _: bool) !bool {
            self.keys_down += 1;
            std.mem.copyForwards(u8, self.last_key_buf[0..key.len], key);
            self.last_key_len = key.len;
            return true;
        }

        pub fn triggerKeyboardKeyUp(self: *@This(), key: []const u8, _: anytype) !bool {
            self.keys_up += 1;
            std.mem.copyForwards(u8, self.last_key_buf[0..key.len], key);
            self.last_key_len = key.len;
            return true;
        }

        pub fn triggerMouseMove(self: *@This(), x: f64, y: f64, _: anytype) !void {
            self.moves += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseDown(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !void {
            self.mouse_down += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseUp(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !void {
            self.mouse_up += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseClickWithModifiers(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !bool {
            self.clicks += 1;
            self.last_x = x;
            self.last_y = y;
            return true;
        }

        pub fn triggerMouseWheel(self: *@This(), x: f64, y: f64, _: f64, dy: f64, _: anytype) !struct { dispatched: bool, default_prevented: bool, scrolled_element: bool } {
            self.wheels += 1;
            self.last_x = x;
            self.last_y = y;
            return .{ .dispatched = true, .default_prevented = false, .scrolled_element = dy != 0 };
        }
    };

    var page = FakePage{};
    try backend.dispatchInput(&page);

    try std.testing.expectEqual(@as(usize, 1), page.keys_down);
    try std.testing.expectEqual(@as(usize, 1), page.keys_up);
    try std.testing.expectEqualStrings("a", page.last_key_buf[0..page.last_key_len]);
    try std.testing.expectEqual(@as(usize, 3), page.moves);
    try std.testing.expectEqual(@as(usize, 1), page.mouse_down);
    try std.testing.expectEqual(@as(usize, 1), page.mouse_up);
    try std.testing.expectEqual(@as(usize, 1), page.clicks);
    try std.testing.expectEqual(@as(usize, 1), page.wheels);
    try std.testing.expectEqual(@as(f64, 20), page.last_x);
    try std.testing.expectEqual(@as(f64, 30), page.last_y);
    try std.testing.expect(host.input.isEmpty());
}

test "bare metal backend queues rendered download clicks" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 960, 640);
    defer backend.deinit();

    var page = try testing.pageTest("page/rendered_download_activation.html");
    defer page._session.removePage();

    var display_list = try DocumentPainter.paintDocument(std.testing.allocator, page, .{
        .viewport_width = 960,
        .viewport_height = 640,
    });
    defer display_list.deinit(std.testing.allocator);

    try backend.presentPageView("Download Smoke", page.url, "", &display_list);

    const region = blk: {
        for (display_list.link_regions.items) |candidate| {
            if (candidate.download_filename.len > 0) break :blk candidate;
        }
        return error.DownloadLinkMissing;
    };

    const hit = presentationRegionScreenRect(&display_list, region.x, region.y, region.width, region.height);
    const click_x = hit.x + @divTrunc(hit.width, 2);
    const click_y = hit.y + @divTrunc(hit.height, 2);

    try host.input.pushMove(std.testing.allocator, click_x, click_y, 0);
    try host.input.pushPointer(std.testing.allocator, click_x, click_y, .left, true, 0);
    try host.input.pushPointer(std.testing.allocator, click_x, click_y, .left, false, 0);

    try backend.dispatchInput(page);

    var pending_downloads = page._session.takePendingDownloads();
    defer {
        while (pending_downloads.items.len > 0) {
            var pending = pending_downloads.items[pending_downloads.items.len - 1];
            pending_downloads.items.len -= 1;
            pending.deinit(page._session.browser.app.allocator);
        }
        pending_downloads.deinit(page._session.browser.app.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), pending_downloads.items.len);
    try std.testing.expect(std.mem.indexOf(u8, pending_downloads.items[0].url, "artifact.txt") != null);
    try std.testing.expectEqualStrings("example-download.txt", pending_downloads.items[0].suggested_filename);
}

test "bare metal backend prefers presentation link regions for clicks" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();

    var display_list = DisplayList{};
    defer display_list.deinit(std.testing.allocator);
    const region_url = try std.testing.allocator.dupe(u8, "https://example.invalid/artifact.txt");
    defer std.testing.allocator.free(region_url);
    const region_filename = try std.testing.allocator.dupe(u8, "example-download.txt");
    defer std.testing.allocator.free(region_filename);
    const region_path = try std.testing.allocator.dupe(u16, &.{ 1, 2, 3, 4 });
    defer std.testing.allocator.free(region_path);
    const region_target = try std.testing.allocator.dupe(u8, "");
    defer std.testing.allocator.free(region_target);
    try display_list.addLinkRegion(std.testing.allocator, .{
        .x = 20,
        .y = 24,
        .width = 120,
        .height = 20,
        .z_index = 4,
        .url = region_url,
        .dom_path = region_path,
        .download_filename = region_filename,
        .open_in_new_tab = false,
        .target_name = region_target,
    });
    backend.presentation_display_list = try display_list.cloneOwned(std.testing.allocator);

    try host.input.pushPointer(std.testing.allocator, 60, 70, .left, true, 0);
    try host.input.pushPointer(std.testing.allocator, 60, 70, .left, false, 0);

    const FakePage = struct {
        keys_down: usize = 0,
        keys_up: usize = 0,
        node_clicks: usize = 0,
        generic_clicks: usize = 0,
        mouse_down: usize = 0,
        mouse_up: usize = 0,
        moves: usize = 0,
        wheels: usize = 0,
        last_key_buf: [8]u8 = .{0} ** 8,
        last_key_len: usize = 0,
        last_x: f64 = 0,
        last_y: f64 = 0,
        last_dom_path_len: usize = 0,

        pub fn triggerKeyboardKeyDownWithRepeat(self: *@This(), key: []const u8, _: anytype, _: bool) !bool {
            self.keys_down += 1;
            std.mem.copyForwards(u8, self.last_key_buf[0..key.len], key);
            self.last_key_len = key.len;
            return true;
        }

        pub fn triggerKeyboardKeyUp(self: *@This(), key: []const u8, _: anytype) !bool {
            self.keys_up += 1;
            std.mem.copyForwards(u8, self.last_key_buf[0..key.len], key);
            self.last_key_len = key.len;
            return true;
        }

        pub fn triggerMouseMove(self: *@This(), x: f64, y: f64, _: anytype) !void {
            self.moves += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseDown(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !void {
            self.mouse_down += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseUp(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !void {
            self.mouse_up += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseClickWithModifiers(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !bool {
            self.generic_clicks += 1;
            self.last_x = x;
            self.last_y = y;
            return true;
        }

        pub fn triggerMouseClickOnNodePathWithResult(self: *@This(), path: []const u16, x: f64, y: f64, _: anytype, _: anytype) !struct { dispatched: bool, default_prevented: bool } {
            self.node_clicks += 1;
            self.last_dom_path_len = path.len;
            self.last_x = x;
            self.last_y = y;
            return .{ .dispatched = true, .default_prevented = false };
        }

        pub fn triggerMouseWheel(self: *@This(), x: f64, y: f64, _: f64, dy: f64, _: anytype) !struct { dispatched: bool, default_prevented: bool, scrolled_element: bool } {
            self.wheels += 1;
            self.last_x = x;
            self.last_y = y;
            return .{ .dispatched = true, .default_prevented = false, .scrolled_element = dy != 0 };
        }
    };

    var page = FakePage{};
    try backend.dispatchInput(&page);

    try std.testing.expectEqual(@as(usize, 1), page.node_clicks);
    try std.testing.expectEqual(@as(usize, 0), page.generic_clicks);
    try std.testing.expectEqual(@as(usize, 1), page.mouse_down);
    try std.testing.expectEqual(@as(usize, 1), page.mouse_up);
    try std.testing.expectEqual(@as(usize, 2), page.moves);
    try std.testing.expectEqual(@as(usize, 0), page.wheels);
    try std.testing.expectEqual(@as(usize, 4), page.last_dom_path_len);
    try std.testing.expectEqual(@as(f64, 80), page.last_x);
    try std.testing.expectEqual(@as(f64, 34), page.last_y);
    try std.testing.expect(host.input.isEmpty());
}

test "bare metal backend falls back to coordinate clicks when node path click misses" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();

    var display_list = DisplayList{};
    defer display_list.deinit(std.testing.allocator);
    const region_url = try std.testing.allocator.dupe(u8, "https://example.invalid/artifact.txt");
    defer std.testing.allocator.free(region_url);
    const region_filename = try std.testing.allocator.dupe(u8, "example-download.txt");
    defer std.testing.allocator.free(region_filename);
    const region_path = try std.testing.allocator.dupe(u16, &.{ 1, 2, 3, 4 });
    defer std.testing.allocator.free(region_path);
    const region_target = try std.testing.allocator.dupe(u8, "");
    defer std.testing.allocator.free(region_target);
    try display_list.addLinkRegion(std.testing.allocator, .{
        .x = 20,
        .y = 24,
        .width = 120,
        .height = 20,
        .z_index = 4,
        .url = region_url,
        .dom_path = region_path,
        .download_filename = region_filename,
        .open_in_new_tab = false,
        .target_name = region_target,
    });
    backend.presentation_display_list = try display_list.cloneOwned(std.testing.allocator);

    try host.input.pushPointer(std.testing.allocator, 60, 70, .left, true, 0);
    try host.input.pushPointer(std.testing.allocator, 60, 70, .left, false, 0);

    const FakePage = struct {
        node_clicks: usize = 0,
        generic_clicks: usize = 0,
        mouse_down: usize = 0,
        mouse_up: usize = 0,
        moves: usize = 0,
        last_dom_path_len: usize = 0,
        last_x: f64 = 0,
        last_y: f64 = 0,

        pub fn triggerKeyboardKeyDownWithRepeat(self: *@This(), _: []const u8, _: anytype, _: bool) !bool {
            return self.generic_clicks >= 0;
        }

        pub fn triggerKeyboardKeyUp(self: *@This(), _: []const u8, _: anytype) !bool {
            return self.generic_clicks >= 0;
        }

        pub fn triggerMouseMove(self: *@This(), x: f64, y: f64, _: anytype) !void {
            self.moves += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseDown(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !void {
            self.mouse_down += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseUp(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !void {
            self.mouse_up += 1;
            self.last_x = x;
            self.last_y = y;
        }

        pub fn triggerMouseClickOnNodePathWithResult(self: *@This(), path: []const u16, x: f64, y: f64, _: anytype, _: anytype) !struct { dispatched: bool, default_prevented: bool } {
            self.node_clicks += 1;
            self.last_dom_path_len = path.len;
            self.last_x = x;
            self.last_y = y;
            return .{ .dispatched = false, .default_prevented = false };
        }

        pub fn triggerMouseClickWithModifiers(self: *@This(), x: f64, y: f64, _: anytype, _: anytype) !bool {
            self.generic_clicks += 1;
            self.last_x = x;
            self.last_y = y;
            return true;
        }

        pub fn triggerMouseWheel(_: *@This(), _: f64, _: f64, _: f64, _: f64, _: anytype) !struct { dispatched: bool, default_prevented: bool, scrolled_element: bool } {
            return .{ .dispatched = true, .default_prevented = false, .scrolled_element = false };
        }
    };

    var page = FakePage{};
    try backend.dispatchInput(&page);

    try std.testing.expectEqual(@as(usize, 1), page.node_clicks);
    try std.testing.expectEqual(@as(usize, 1), page.generic_clicks);
    try std.testing.expectEqual(@as(usize, 1), page.mouse_down);
    try std.testing.expectEqual(@as(usize, 1), page.mouse_up);
    try std.testing.expectEqual(@as(usize, 2), page.moves);
    try std.testing.expectEqual(@as(usize, 4), page.last_dom_path_len);
    try std.testing.expectEqual(@as(f64, 80), page.last_x);
    try std.testing.expectEqual(@as(f64, 34), page.last_y);
    try std.testing.expect(host.input.isEmpty());
}

test "bare metal backend queues downloads shortcut and removal command" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();

    const FakePage = struct {
        key_down: usize = 0,
        key_up: usize = 0,

        pub fn triggerKeyboardKeyDownWithRepeat(self: *@This(), _: []const u8, _: anytype, _: bool) !bool {
            self.key_down += 1;
            return true;
        }

        pub fn triggerKeyboardKeyUp(self: *@This(), _: []const u8, _: anytype) !bool {
            self.key_up += 1;
            return true;
        }

        pub fn triggerMouseMove(_: *@This(), _: f64, _: f64, _: anytype) !void {
            return;
        }

        pub fn triggerMouseDown(_: *@This(), _: f64, _: f64, _: anytype, _: anytype) !void {
            return;
        }

        pub fn triggerMouseUp(_: *@This(), _: f64, _: f64, _: anytype, _: anytype) !void {
            return;
        }

        pub fn triggerMouseClickWithModifiers(self: *@This(), _: f64, _: f64, _: anytype, _: anytype) !bool {
            return self.key_down >= 0;
        }

        pub fn triggerMouseWheel(_: *@This(), _: f64, _: f64, _: f64, _: f64, _: anytype) !struct { dispatched: bool, default_prevented: bool, scrolled_element: bool } {
            return .{ .dispatched = true, .default_prevented = false, .scrolled_element = false };
        }
    };

    var page = FakePage{};
    try host.input.pushKey(std.testing.allocator, 'J', true, modifier_ctrl);
    try host.input.pushKey(std.testing.allocator, 'J', false, modifier_ctrl);
    try backend.dispatchInput(&page);

    try std.testing.expectEqual(@as(usize, 0), page.key_down);
    try std.testing.expectEqual(@as(usize, 1), page.key_up);
    try std.testing.expectEqual(BrowserCommand.page_downloads, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(@as(?BrowserCommand, null), backend.nextBrowserCommand());

    backend.setDownloadEntries(&[_]Display.DownloadEntry{
        .{
            .filename = "example-download.txt",
            .path = "C:/tmp/example-download.txt",
            .status = "Complete 1 B",
            .removable = true,
        },
    });
    backend.last_url = "browser://downloads";

    page = .{};
    try host.input.pushKey(std.testing.allocator, 46, true, 0);
    try host.input.pushKey(std.testing.allocator, 46, false, 0);
    try backend.dispatchInput(&page);

    const command = backend.nextBrowserCommand() orelse return error.TestExpected;
    try std.testing.expectEqual(BrowserCommand{ .download_remove = 0 }, command);
    try std.testing.expectEqual(@as(?BrowserCommand, null), backend.nextBrowserCommand());
}

test "bare metal shortcut keys enqueue browser commands" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();

    const tabs = [_]Display.TabEntry{
        .{
            .title = "One",
            .url = "http://one.test/",
            .is_loading = false,
            .has_error = false,
            .target_name = "",
            .popup_source = .none,
        },
        .{
            .title = "Two",
            .url = "http://two.test/",
            .is_loading = false,
            .has_error = false,
            .target_name = "",
            .popup_source = .none,
        },
        .{
            .title = "Three",
            .url = "http://three.test/",
            .is_loading = false,
            .has_error = false,
            .target_name = "",
            .popup_source = .none,
        },
    };
    backend.setTabEntries(tabs[0..], 1);

    const FakePage = struct {
        key_down: usize = 0,
        key_up: usize = 0,

        pub fn triggerKeyboardKeyDownWithRepeat(self: *@This(), _: []const u8, _: anytype, _: bool) !bool {
            self.key_down += 1;
            return true;
        }

        pub fn triggerKeyboardKeyUp(self: *@This(), _: []const u8, _: anytype) !bool {
            self.key_up += 1;
            return true;
        }

        pub fn triggerMouseMove(_: *@This(), _: f64, _: f64, _: anytype) !void {}

        pub fn triggerMouseDown(_: *@This(), _: f64, _: f64, _: anytype, _: anytype) !void {}

        pub fn triggerMouseUp(_: *@This(), _: f64, _: f64, _: anytype, _: anytype) !void {}

        pub fn triggerMouseClickWithModifiers(_: *@This(), _: f64, _: f64, _: anytype, _: anytype) !bool {
            return true;
        }

        pub fn triggerMouseWheel(_: *@This(), _: f64, _: f64, _: f64, _: f64, _: anytype) !struct { dispatched: bool, default_prevented: bool, scrolled_element: bool } {
            return .{ .dispatched = true, .default_prevented = false, .scrolled_element = false };
        }
    };

    var page = FakePage{};
    try host.input.pushKey(std.testing.allocator, c.VK_HOME, true, modifier_alt);
    try host.input.pushKey(std.testing.allocator, c.VK_HOME, false, modifier_alt);
    try host.input.pushKey(std.testing.allocator, 'T', true, modifier_ctrl);
    try host.input.pushKey(std.testing.allocator, 'T', false, modifier_ctrl);
    try host.input.pushKey(std.testing.allocator, c.VK_TAB, true, modifier_ctrl);
    try host.input.pushKey(std.testing.allocator, c.VK_TAB, false, modifier_ctrl);
    try host.input.pushKey(std.testing.allocator, c.VK_TAB, true, modifier_ctrl | modifier_shift);
    try host.input.pushKey(std.testing.allocator, c.VK_TAB, false, modifier_ctrl | modifier_shift);
    try host.input.pushKey(std.testing.allocator, 'W', true, modifier_ctrl);
    try host.input.pushKey(std.testing.allocator, 'W', false, modifier_ctrl);

    try backend.dispatchInput(&page);

    try std.testing.expectEqual(@as(usize, 0), page.key_down);
    try std.testing.expectEqual(@as(usize, 5), page.key_up);
    try std.testing.expectEqual(BrowserCommand.home, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand.tab_new, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand.tab_next, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand.tab_previous, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(BrowserCommand{ .tab_close = 1 }, backend.nextBrowserCommand().?);
    try std.testing.expectEqual(@as(?BrowserCommand, null), backend.nextBrowserCommand());
}

test "bare metal mailbox command queues download removal" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();

    try processMailboxLine(&backend, "command|download_remove|0");

    const command = backend.nextBrowserCommand() orelse return error.TestExpected;
    try std.testing.expectEqual(BrowserCommand{ .download_remove = 0 }, command);
    try std.testing.expectEqual(@as(?BrowserCommand, null), backend.nextBrowserCommand());
}

test "bare metal backend retains tab and history state" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();

    const tabs = [_]Display.TabEntry{
        .{
            .title = "Start",
            .url = "browser://start",
            .is_loading = false,
            .has_error = false,
            .target_name = "",
            .popup_source = .script,
        },
        .{
            .title = "Tabs",
            .url = "browser://tabs",
            .is_loading = true,
            .has_error = false,
            .target_name = "",
            .popup_source = .anchor,
        },
    };
    const history = [_][]const u8{
        "browser://start",
        "browser://tabs",
    };

    backend.setTabEntries(tabs[0..], 1);
    backend.setHistoryEntries(history[0..], 0);

    try std.testing.expectEqual(@as(usize, 2), backend.tab_entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), backend.history_entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), backend.active_tab_index);
    try std.testing.expectEqual(@as(usize, 0), backend.history_current_index);
    try std.testing.expectEqualStrings("Start", backend.tab_entries.items[0].title);
    try std.testing.expectEqualStrings("browser://tabs", backend.history_entries.items[1]);
}

test "bare metal backend retains download and settings state" {
    var host = Host.initMock(std.testing.allocator);
    defer host.deinit();

    var backend = BareMetalBackend.init(&host, std.testing.allocator, 320, 180);
    defer backend.deinit();

    const downloads = [_]Display.DownloadEntry{
        .{
            .filename = "report.pdf",
            .path = "/tmp/report.pdf",
            .status = "completed",
            .removable = true,
        },
        .{
            .filename = "archive.zip",
            .path = "/tmp/archive.zip",
            .status = "in progress",
            .removable = false,
        },
    };

    backend.setDownloadEntries(downloads[0..]);
    backend.setSettingsState(.{
        .restore_previous_session = true,
        .allow_script_popups = false,
        .default_zoom_percent = 125,
        .homepage_url = "browser://start",
    });

    try std.testing.expectEqual(@as(usize, 2), backend.download_entries.items.len);
    try std.testing.expectEqualStrings("report.pdf", backend.download_entries.items[0].filename);
    try std.testing.expectEqualStrings("in progress", backend.download_entries.items[1].status);
    try std.testing.expect(backend.restore_previous_session);
    try std.testing.expect(!backend.allow_script_popups);
    try std.testing.expectEqual(@as(i32, 125), backend.default_zoom_percent);
    try std.testing.expectEqualStrings("browser://start", backend.homepage_url.?);
}
