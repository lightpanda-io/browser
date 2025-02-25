const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenAallocator = std.heap.ArenaAllocator;

const Event = @import("telemetry.zig").Event;
const log = std.log.scoped(.telemetry);

const PLAUSIBLE_URL = "http://localhost/api/event";
const EVENT_URL = "https://lightpanda.io/browser-stats";
const DOMAIN_KEY = "localhost";

pub const Plausible = struct {
    uri: std.Uri,
    arena: ArenAallocator,
    client: std.http.Client,
    headers: [2]std.http.Header,

    pub fn init(allocator: Allocator) !Plausible {
        return .{
            .client = .{ .allocator = allocator },
            .arena = std.heap.ArenaAllocator.init(allocator),
            .uri = std.Uri.parse(PLAUSIBLE_URL) catch unreachable,
            .headers = [2]std.http.Header{
                .{ .name = "User-Agent", .value = "lightpanda/1.0" },
                .{ .name = "Content-Type", .value = "application/json" },
            },
        };
    }

    pub fn deinit(self: *Plausible) void {
        self.arena.deinit();
        self.client.deinit();
    }

    pub fn record(self: *Plausible, event: Event) !void {
        defer _ = self.arena.reset(.{ .retain_capacity = {} });
        const body = try std.json.stringifyAlloc(self.arena.allocator(), PlausibleEvent{ .event = event }, .{});

        var server_headers: [2048]u8 = undefined;
        var req = try self.client.open(.POST, self.uri, .{
            .redirect_behavior = .not_allowed,
            .extra_headers = &self.headers,
            .server_header_buffer = &server_headers,
        });
        req.transfer_encoding = .{ .content_length = body.len };
        try req.send();

        try req.writeAll(body);
        try req.finish();
        try req.wait();

        const status = req.response.status;
        if (status != .accepted) {
            log.warn("plausible '{s}' event error: {d}", .{ @tagName(event), @intFromEnum(status) });
        } else {
            log.warn("plausible '{s}' sent", .{@tagName(event)});
        }
    }
};

// wraps a telemetry event so that we can serialize it to plausible's event endpoint
const PlausibleEvent = struct {
    event: Event,

    pub fn jsonStringify(self: PlausibleEvent, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("name");
        try jws.write(@tagName(self.event));
        try jws.objectField("url");
        try jws.write(EVENT_URL);
        try jws.objectField("domain");
        try jws.write(DOMAIN_KEY);
        try jws.objectField("props");
        switch (self.event) {
            inline else => |props| try jws.write(props),
        }
        try jws.endObject();
    }
};

const testing = std.testing;
test "plausible: json event" {
    const json = try std.json.stringifyAlloc(testing.allocator, PlausibleEvent{ .event = .{ .run = .{ .mode = .serve, .version = "over 9000!" } } }, .{});
    defer testing.allocator.free(json);

    try testing.expectEqualStrings(
        \\{"name":"run","url":"https://lightpanda.io/browser-stats","domain":"localhost","props":{"version":"over 9000!","mode":"serve"}}
    , json);
}
