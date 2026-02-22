const std = @import("std");

pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: ?std.json.Value = null,
    @"error": ?Error = null,
};

pub const Error = struct {
    code: i64,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
};

// Core MCP Types mapping to official specification
pub const InitializeRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    method: []const u8 = "initialize",
    params: InitializeParams,
};

pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: Capabilities,
    clientInfo: Implementation,
};

pub const Capabilities = struct {
    experimental: ?std.json.Value = null,
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
};

pub const RootsCapability = struct {
    listChanged: ?bool = null,
};

pub const SamplingCapability = struct {};

pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
};

pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: Implementation,
};

pub const ServerCapabilities = struct {
    experimental: ?std.json.Value = null,
    logging: ?LoggingCapability = null,
    prompts: ?PromptsCapability = null,
    resources: ?ResourcesCapability = null,
    tools: ?ToolsCapability = null,
};

pub const LoggingCapability = struct {};
pub const PromptsCapability = struct {
    listChanged: ?bool = null,
};
pub const ResourcesCapability = struct {
    subscribe: ?bool = null,
    listChanged: ?bool = null,
};
pub const ToolsCapability = struct {
    listChanged: ?bool = null,
};

pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: std.json.Value,
};

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};
