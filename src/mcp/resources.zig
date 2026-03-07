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
    try server.sendResult(req.id.?, .{ .resources = &resource_list });
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

const ResourceUri = enum {
    @"mcp://page/html",
    @"mcp://page/markdown",
};

const resource_map = std.StaticStringMap(ResourceUri).initComptime(.{
    .{ "mcp://page/html", .@"mcp://page/html" },
    .{ "mcp://page/markdown", .@"mcp://page/markdown" },
});

pub fn handleRead(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null) {
        return server.sendError(req.id.?, .InvalidParams, "Missing params");
    }

    const params = std.json.parseFromValueLeaky(ReadParams, arena, req.params.?, .{ .ignore_unknown_fields = true }) catch {
        return server.sendError(req.id.?, .InvalidParams, "Invalid params");
    };

    const uri = resource_map.get(params.uri) orelse {
        return server.sendError(req.id.?, .InvalidRequest, "Resource not found");
    };

    switch (uri) {
        .@"mcp://page/html" => {
            const result: ResourceStreamingResult = .{
                .contents = &.{.{
                    .uri = params.uri,
                    .mimeType = "text/html",
                    .text = .{ .server = server, .format = .html },
                }},
            };
            try server.sendResult(req.id.?, result);
        },
        .@"mcp://page/markdown" => {
            const result: ResourceStreamingResult = .{
                .contents = &.{.{
                    .uri = params.uri,
                    .mimeType = "text/markdown",
                    .text = .{ .server = server, .format = .markdown },
                }},
            };
            try server.sendResult(req.id.?, result);
        },
    }
}

const testing = @import("../testing.zig");
