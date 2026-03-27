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
    const id = req.id orelse return;
    try server.sendResult(id, .{ .resources = &resource_list });
}

const ReadParams = struct {
    uri: []const u8,
};
const Format = enum { html, markdown };

const ResourceStreamingResult = struct {
    contents: []const struct {
        uri: []const u8,
        mimeType: []const u8,
        text: StreamingText,
    },

    const StreamingText = struct {
        page: *lp.Page,
        format: Format,

        pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
            try jw.beginWriteRaw();
            try jw.writer.writeByte('"');
            var escaped = protocol.JsonEscapingWriter.init(jw.writer);
            switch (self.format) {
                .html => lp.dump.root(self.page.document, .{}, &escaped.writer, self.page) catch |err| {
                    log.err(.mcp, "html dump failed", .{ .err = err });
                    return error.WriteFailed;
                },
                .markdown => lp.markdown.dump(self.page.document.asNode(), .{}, &escaped.writer, self.page) catch |err| {
                    log.err(.mcp, "markdown dump failed", .{ .err = err });
                    return error.WriteFailed;
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
    if (req.params == null or req.id == null) {
        return server.sendError(req.id orelse .{ .integer = -1 }, .InvalidParams, "Missing params");
    }
    const req_id = req.id.?;

    const params = std.json.parseFromValueLeaky(ReadParams, arena, req.params.?, .{ .ignore_unknown_fields = true }) catch {
        return server.sendError(req_id, .InvalidParams, "Invalid params");
    };

    const uri = resource_map.get(params.uri) orelse {
        return server.sendError(req_id, .InvalidRequest, "Resource not found");
    };

    const page = server.session.currentPage() orelse {
        return server.sendError(req_id, .PageNotLoaded, "Page not loaded");
    };

    const format: Format = switch (uri) {
        .@"mcp://page/html" => .html,
        .@"mcp://page/markdown" => .markdown,
    };
    const mime_type: []const u8 = switch (uri) {
        .@"mcp://page/html" => "text/html",
        .@"mcp://page/markdown" => "text/markdown",
    };

    const result: ResourceStreamingResult = .{
        .contents = &.{.{
            .uri = params.uri,
            .mimeType = mime_type,
            .text = .{ .page = page, .format = format },
        }},
    };
    server.sendResult(req_id, result) catch {
        return server.sendError(req_id, .InternalError, "Failed to serialize resource content");
    };
}
