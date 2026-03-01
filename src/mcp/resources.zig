const std = @import("std");

const lp = @import("lightpanda");

const protocol = @import("protocol.zig");
const Server = @import("Server.zig");

pub fn handleList(server: *Server, req: protocol.Request) !void {
    const resources = [_]protocol.Resource{
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

    const result = struct {
        resources: []const protocol.Resource,
    }{
        .resources = &resources,
    };

    try sendResult(server, req.id.?, result);
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
        uri: []const u8,
        format: enum { html, markdown },

        pub fn jsonStringify(self: @This(), jw: *std.json.Stringify) !void {
            try jw.beginObject();
            try jw.objectField("uri");
            try jw.write(self.uri);
            try jw.objectField("mimeType");
            try jw.write(if (self.format == .html) "text/html" else "text/markdown");
            try jw.objectField("text");

            try jw.beginWriteRaw();
            try jw.writer.writeByte('"');
            var escaped = protocol.JsonEscapingWriter.init(jw.writer);
            switch (self.format) {
                .html => try lp.dump.root(self.server.page.document, .{}, &escaped.writer, self.server.page),
                .markdown => try lp.markdown.dump(self.server.page.document.asNode(), .{}, &escaped.writer, self.server.page),
            }
            try jw.writer.writeByte('"');
            jw.endWriteRaw();

            try jw.endObject();
        }
    };
};

pub fn handleRead(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null) {
        return sendError(server, req.id.?, -32602, "Missing params");
    }

    const params = std.json.parseFromValueLeaky(ReadParams, arena, req.params.?, .{ .ignore_unknown_fields = true }) catch {
        return sendError(server, req.id.?, -32602, "Invalid params");
    };

    if (std.mem.eql(u8, params.uri, "mcp://page/html")) {
        const result = ResourceStreamingResult{
            .contents = &.{.{
                .uri = params.uri,
                .mimeType = "text/html",
                .text = .{ .server = server, .uri = params.uri, .format = .html },
            }},
        };
        try sendResult(server, req.id.?, result);
    } else if (std.mem.eql(u8, params.uri, "mcp://page/markdown")) {
        const result = ResourceStreamingResult{
            .contents = &.{.{
                .uri = params.uri,
                .mimeType = "text/markdown",
                .text = .{ .server = server, .uri = params.uri, .format = .markdown },
            }},
        };
        try sendResult(server, req.id.?, result);
    } else {
        return sendError(server, req.id.?, -32602, "Resource not found");
    }
}

pub fn sendResult(server: *Server, id: std.json.Value, result: anytype) !void {
    const GenericResponse = struct {
        jsonrpc: []const u8 = "2.0",
        id: std.json.Value,
        result: @TypeOf(result),
    };
    try server.sendResponse(GenericResponse{
        .id = id,
        .result = result,
    });
}

pub fn sendError(server: *Server, id: std.json.Value, code: i64, message: []const u8) !void {
    try server.sendResponse(protocol.Response{
        .id = id,
        .@"error" = protocol.Error{
            .code = code,
            .message = message,
        },
    });
}
