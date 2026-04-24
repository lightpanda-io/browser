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

    pub fn toString(self: RequestType) []const u8 {
        return switch (self) {
            .document => "DOCUMENT",
            .stylesheet => "STYLESHEET",
            .image => "IMAGE",
            .script => "SCRIPT",
            .subdocument => "SUBDOCUMENT",
            .xmlhttprequest => "XMLHTTPREQUEST",
            .websocket => "WEBSOCKET",
            .ping => "PING",
            .font => "FONT",
            .other => "OTHER",
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
    redirect: [*:0]u8,
    rewritten_url: [*:0]u8,
};

pub const AdFilter = struct {
    engine: ?*anyopaque = null,

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
            log.info(.http, "No filter lists configured, adblock disabled", .{});
            return AdFilter{ .engine = null };
        }

        const allocator = std.heap.c_allocator;

        const first_list = lists[0];
        const first_list_z = try allocator.dupeZ(u8, first_list);
        defer allocator.free(first_list_z);

        const engine = c_adblock_create_engine_with_rules(first_list_z.ptr, first_list_z.len);
        if (engine == null) {
            log.err(.http, "Adblock engine creation failed", .{});
            return error.EngineCreationFailed;
        }

        for (lists[1..]) |list_url| {
            const list_z = try allocator.dupeZ(u8, list_url);
            errdefer allocator.free(list_z);
            _ = c_adblock_add_filter_list(engine, list_z.ptr, list_z.len);
            allocator.free(list_z);
        }

        log.info(.http, "Adblock engine created with {d} filter lists", .{lists.len});
        return AdFilter{ .engine = engine };
    }

    pub fn shouldBlock(self: *const AdFilter, url: [:0]const u8, source_url: [:0]const u8, request_type: RequestType) bool {
        if (self.engine == null) {
            return false;
        }

        const hostname = extractHostname(url) catch return false;
        const source_hostname = if (source_url.len > 0) extractHostname(source_url) catch "" else "";

        const result = c_adblock_matches(
            self.engine,
            url.ptr,
            hostname.ptr,
            source_hostname.ptr,
            request_type.toString().ptr,
            0,
        );

        if (result.matched) {
            log.debug(.http, "adblock blocked url", .{ .url = url });
        }

        return result.matched;
    }

    pub fn getCosmeticFilters(self: *const AdFilter, url: [:0]const u8) ?[]const u8 {
        if (self.engine == null) {
            return null;
        }

        const json_ptr = c_adblock_get_cosmetic_filters(self.engine, url.ptr);
        if (json_ptr == null) {
            return null;
        }

        const json_str = std.mem.span(json_ptr);
        return json_str;
    }

    pub fn deinit(self: *AdFilter) void {
        if (self.engine) |engine| {
            c_adblock_destroy_engine(engine);
        }
    }
};

fn extractHostname(url: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, url, "https://")) {
        const rest = url[8..];
        if (std.mem.indexOf(u8, rest, "/")) |idx| {
            return rest[0..idx];
        }
        return rest;
    }
    if (std.mem.startsWith(u8, url, "http://")) {
        const rest = url[7..];
        if (std.mem.indexOf(u8, rest, "/")) |idx| {
            return rest[0..idx];
        }
        return rest;
    }
    return error.InvalidURL;
}

extern fn c_adblock_create_engine() ?*anyopaque;
extern fn c_adblock_create_engine_with_rules(rules: [*]const u8, rules_len: usize) ?*anyopaque;
extern fn c_adblock_add_filter_list(engine: ?*anyopaque, rules: [*]const u8, rules_len: usize) bool;
extern fn c_adblock_matches(
    engine: ?*anyopaque,
    url: [*]const u8,
    hostname: [*]const u8,
    source_hostname: [*]const u8,
    request_type: [*]const u8,
    third_party: i32,
) AdblockResult;
extern fn c_adblock_destroy_engine(engine: ?*anyopaque) void;
extern fn c_adblock_get_cosmetic_filters(engine: ?*anyopaque, url: [*]const u8) [*:0]u8;
