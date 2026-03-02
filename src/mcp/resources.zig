const std = @import("std");

const lp = @import("lightpanda");
const log = lp.log;

const protocol = @import("protocol.zig");
const Server = @import("Server.zig");

pub const resource_list = [_]protocol.Resource{
    .{
        .uri = "mcp://page/html",
        .name = "Page HTML",
        .description = "The serialized HTML DOM of the current page",
        .mimeType = "text/html",
    },
    .{
        .uri = "mcp://page/markdown",
        .name = "Page Markdown",
        .description = "The token-efficient markdown representation of the current page",
        .mimeType = "text/markdown",
    },
};

pub fn handleList(server: *Server, req: protocol.Request) !void {
    const result = struct {
        resources: []const protocol.Resource,
    }{
        .resources = &resource_list,
    };

    try server.sendResult(req.id.?, result);
}

const ReadParams = struct {
    uri: []const u8,
};

const ResourceStreamingResult = struct {
    contents: []const struct {
        uri: []const u8,
        mimeType: []const u8,
        text: StreamingText,
    },

    const StreamingText = struct {
        server: *Server,
        format: enum { html, markdown },

        pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
            try jw.beginWriteRaw();
            try jw.writer.writeByte('"');
            var escaped = protocol.JsonEscapingWriter.init(jw.writer);
            switch (self.format) {
                .html => lp.dump.root(self.server.page.document, .{}, &escaped.writer, self.server.page) catch |err| {
                    log.err(.mcp, "html dump failed", .{ .err = err });
                },
                .markdown => lp.markdown.dump(self.server.page.document.asNode(), .{}, &escaped.writer, self.server.page) catch |err| {
                    log.err(.mcp, "markdown dump failed", .{ .err = err });
                },
            }
            try jw.writer.writeByte('"');
            jw.endWriteRaw();
        }
    };
};

pub fn handleRead(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null) {
        return server.sendError(req.id.?, .InvalidParams, "Missing params");
    }

    const params = std.json.parseFromValueLeaky(ReadParams, arena, req.params.?, .{ .ignore_unknown_fields = true }) catch {
        return server.sendError(req.id.?, .InvalidParams, "Invalid params");
    };

    if (std.mem.eql(u8, params.uri, "mcp://page/html")) {
        const result: ResourceStreamingResult = .{
            .contents = &.{.{
                .uri = params.uri,
                .mimeType = "text/html",
                .text = .{ .server = server, .format = .html },
            }},
        };
        try server.sendResult(req.id.?, result);
    } else if (std.mem.eql(u8, params.uri, "mcp://page/markdown")) {
        const result: ResourceStreamingResult = .{
            .contents = &.{.{
                .uri = params.uri,
                .mimeType = "text/markdown",
                .text = .{ .server = server, .format = .markdown },
            }},
        };
        try server.sendResult(req.id.?, result);
    } else {
        return server.sendError(req.id.?, .InvalidRequest, "Resource not found");
    }
}

const testing = @import("../testing.zig");

test "resource_list contains expected resources" {
    try testing.expect(resource_list.len >= 2);
    try testing.expectString("mcp://page/html", resource_list[0].uri);
    try testing.expectString("mcp://page/markdown", resource_list[1].uri);
}

test "ReadParams parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const raw = "{\"uri\": \"mcp://page/html\"}";
    const parsed = try std.json.parseFromSlice(ReadParams, aa, raw, .{});
    try testing.expectString("mcp://page/html", parsed.value.uri);
}
