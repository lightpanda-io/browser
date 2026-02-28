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

pub fn handleRead(server: *Server, arena: std.mem.Allocator, req: protocol.Request) !void {
    if (req.params == null) {
        return sendError(server, req.id.?, -32602, "Missing params");
    }

    const params = std.json.parseFromValueLeaky(ReadParams, arena, req.params.?, .{}) catch {
        return sendError(server, req.id.?, -32602, "Invalid params");
    };

    if (std.mem.eql(u8, params.uri, "mcp://page/html")) {
        var aw = std.Io.Writer.Allocating.init(arena);
        lp.dump.root(server.page.document, .{}, &aw.writer, server.page) catch {
            return sendError(server, req.id.?, -32603, "Internal error reading HTML");
        };

        const contents = [_]struct {
            uri: []const u8,
            mimeType: []const u8,
            text: []const u8,
        }{.{
            .uri = params.uri,
            .mimeType = "text/html",
            .text = aw.written(),
        }};
        try sendResult(server, req.id.?, .{ .contents = &contents });
    } else if (std.mem.eql(u8, params.uri, "mcp://page/markdown")) {
        var aw = std.Io.Writer.Allocating.init(arena);
        lp.markdown.dump(server.page.document.asNode(), .{}, &aw.writer, server.page) catch {
            return sendError(server, req.id.?, -32603, "Internal error reading Markdown");
        };

        const contents = [_]struct {
            uri: []const u8,
            mimeType: []const u8,
            text: []const u8,
        }{.{
            .uri = params.uri,
            .mimeType = "text/markdown",
            .text = aw.written(),
        }};
        try sendResult(server, req.id.?, .{ .contents = &contents });
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
