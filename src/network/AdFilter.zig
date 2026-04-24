const std = @import("std");
const Allocator = std.mem.Allocator;
const lp = @import("lightpanda");
const log = lp.log;

const Config = @import("../Config.zig");

pub const RequestType = enum(u32) {
    document = 0,
    stylesheet = 1,
    image = 2,
    script = 3,
    subdocument = 4,
    xmlhttprequest = 5,
    websocket = 6,
    ping = 7,
    font = 8,
    other = 9,

    pub fn fromURL(url: []const u8) RequestType {
        if (std.mem.endsWith(u8, url, ".css")) return .stylesheet;
        if (std.mem.endsWith(u8, url, ".js")) return .script;
        if (std.mem.endsWith(u8, url, ".png") or
            std.mem.endsWith(u8, url, ".jpg") or
            std.mem.endsWith(u8, url, ".jpeg") or
            std.mem.endsWith(u8, url, ".gif") or
            std.mem.endsWith(u8, url, ".webp") or
            std.mem.endsWith(u8, url, ".svg")) return .image;

        if (std.mem.endsWith(u8, url, ".woff") or
            std.mem.endsWith(u8, url, ".woff2") or
            std.mem.endsWith(u8, url, ".ttf") or
            std.mem.endsWith(u8, url, ".otf") or
            std.mem.endsWith(u8, url, ".eot")) return .font;

        if (std.mem.indexOf(u8, url, "?") != null) {
            if (std.mem.indexOf(u8, url, "type=font") != null) return .font;
            if (std.mem.indexOf(u8, url, "type=stylesheet") != null) return .stylesheet;
            if (std.mem.indexOf(u8, url, "type=script") != null) return .script;
        }

        if (std.mem.indexOf(u8, url, "/api/") != null or
            std.mem.indexOf(u8, url, "/graphql") != null or
            std.mem.indexOf(u8, url, ".json") != null or
            std.mem.indexOf(u8, url, ".xml") != null) return .xmlhttprequest;

        return .other;
    }

    // Return null-terminated strings for safe C FFI usage
    pub fn toString(self: RequestType) [:0]const u8 {
        return switch (self) {
            .document => "document",
            .stylesheet => "stylesheet",
            .image => "image",
            .script => "script",
            .subdocument => "subdocument",
            .xmlhttprequest => "xmlhttprequest",
            .websocket => "websocket",
            .ping => "ping",
            .font => "font",
            .other => "other",
        };
    }
};

pub const AdFilterError = error{
    NoFilterLists,
    EngineCreationFailed,
    FilterListLoadFailed,
    RequestBlocked,
};

const AdblockResult = extern struct {
    matched: bool,
    important: bool,
    has_exception: bool,
    redirect: ?[*:0]u8,
    rewritten_url: ?[*:0]u8,
};

const CFilterList = extern struct {
    data: [*]const u8,
    len: usize,
};

pub const AdFilter = struct {
    engine: ?*anyopaque = null,
    lock: std.Thread.RwLock = .{},

    pub fn init(config: *const Config.AdblockConfig) !AdFilter {
        if (!config.enable) {
            log.info(.http, "Adblock disabled", .{});
            return AdFilter{ .engine = null };
        }

        return try AdFilter.createEngine(config);
    }

    fn createEngine(config: *const Config.AdblockConfig) !AdFilter {
        const lists = config.lists;
        if (lists.len == 0) {
            log.info(.http, "adblock no lists", .{});
            return AdFilter{ .engine = null };
        }

        const engine = try createEngineFromLists(lists);
        if (engine == null) {
            log.err(.http, "Adblock engine creation failed", .{});
            return error.EngineCreationFailed;
        }

        log.info(.http, "adblock engine created", .{ .lists = lists.len });
        return AdFilter{ .engine = engine };
    }

    pub fn shouldBlock(self: *const AdFilter, url: [:0]const u8, source_url: [:0]const u8, request_type: RequestType) bool {
        // Safe const casting because locking is an internal thread-safety mechanic
        // that shouldn't pollute the logical const-ness of the AdFilter.
        var m_self = @constCast(self);
        m_self.lock.lockShared();
        defer m_self.lock.unlockShared();

        if (m_self.engine == null) {
            return false;
        }

        const result = c_adblock_matches(
            m_self.engine,
            url.ptr,
            request_type.toString().ptr,
            source_url.ptr,
        );
        defer {
            if (result.redirect) |redirect| c_adblock_free_string(redirect);
            if (result.rewritten_url) |rewritten_url| c_adblock_free_string(rewritten_url);
        }

        if (result.matched) {
            log.debug(.http, "adblock blocked url", .{ .url = url });
        }

        return result.matched;
    }

    pub fn getCosmeticFilters(self: *const AdFilter, allocator: Allocator, url: [:0]const u8) !?[]u8 {
        var m_self = @constCast(self);
        m_self.lock.lockShared();
        defer m_self.lock.unlockShared();

        if (m_self.engine == null) {
            return null;
        }

        const json_ptr = c_adblock_get_cosmetic_filters(m_self.engine, url.ptr) orelse return null;
        defer c_adblock_free_string(json_ptr);

        return try allocator.dupe(u8, std.mem.span(json_ptr));
    }

    pub fn replaceFilterLists(self: *AdFilter, lists: []const []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.engine == null) {
            return;
        }

        const ffi_lists = try makeCFilterLists(lists);
        defer std.heap.c_allocator.free(ffi_lists);

        const result = c_adblock_replace_filter_lists(self.engine, ffi_lists.ptr, ffi_lists.len);
        if (!result) {
            return error.FilterListLoadFailed;
        }
    }

    pub fn deinit(self: *AdFilter) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.engine) |engine| {
            c_adblock_destroy_engine(engine);
            self.engine = null;
        }
    }
};

fn createEngineFromLists(lists: []const []const u8) !?*anyopaque {
    const ffi_lists = try makeCFilterLists(lists);
    defer std.heap.c_allocator.free(ffi_lists);
    return c_adblock_create_engine_from_lists(ffi_lists.ptr, ffi_lists.len);
}

fn makeCFilterLists(lists: []const []const u8) ![]CFilterList {
    const allocator = std.heap.c_allocator;
    const ffi_lists = try allocator.alloc(CFilterList, lists.len);
    errdefer allocator.free(ffi_lists);

    for (lists, ffi_lists) |list, *ffi_list| {
        ffi_list.* = .{
            .data = list.ptr,
            .len = list.len,
        };
    }

    return ffi_lists;
}

extern fn c_adblock_create_engine() ?*anyopaque;
extern fn c_adblock_create_engine_from_lists(rules: [*]const CFilterList, rules_len: usize) ?*anyopaque;
extern fn c_adblock_replace_filter_lists(engine: ?*anyopaque, rules: [*]const CFilterList, rules_len: usize) bool;
extern fn c_adblock_matches(
    engine: ?*anyopaque,
    url: [*]const u8,
    request_type: [*]const u8,
    source_url: [*]const u8,
) AdblockResult;
extern fn c_adblock_destroy_engine(engine: ?*anyopaque) void;
extern fn c_adblock_get_cosmetic_filters(engine: ?*anyopaque, url: [*]const u8) ?[*:0]u8;
extern fn c_adblock_free_string(s: ?[*:0]u8) void;
