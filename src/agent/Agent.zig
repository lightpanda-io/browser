const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");

const log = lp.log;
const Config = lp.Config;
const App = @import("../App.zig");
const ToolExecutor = @import("ToolExecutor.zig");
const Terminal = @import("Terminal.zig");

const Self = @This();

const default_system_prompt =
    \\You are a web browsing assistant powered by the Lightpanda browser.
    \\You can navigate to websites, read their content, interact with forms,
    \\click links, and extract information.
    \\
    \\When helping the user, navigate to relevant pages and extract information.
    \\Use the semantic_tree or interactiveElements tools to understand page structure
    \\before clicking or filling forms. Be concise in your responses.
;

allocator: std.mem.Allocator,
ai_client: AiClient,
tool_executor: *ToolExecutor,
terminal: Terminal,
messages: std.ArrayListUnmanaged(zenai.provider.Message),
tools: []const zenai.provider.Tool,
model: []const u8,
system_prompt: []const u8,

const AiClient = union(Config.AiProvider) {
    anthropic: *zenai.anthropic.Client,
    openai: *zenai.openai.Client,
    gemini: *zenai.gemini.Client,

    fn toProvider(self: AiClient) zenai.provider.Client {
        return switch (self) {
            .anthropic => |c| .{ .anthropic = c },
            .openai => |c| .{ .openai = c },
            .gemini => |c| .{ .gemini = c },
        };
    }
};

pub fn init(allocator: std.mem.Allocator, app: *App, opts: Config.Agent) !*Self {
    const api_key = opts.api_key orelse getEnvApiKey(opts.provider) orelse {
        log.fatal(.app, "missing API key", .{
            .hint = "Set the API key via --api-key or environment variable",
        });
        return error.MissingApiKey;
    };

    const tool_executor = try ToolExecutor.init(allocator, app);
    errdefer tool_executor.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const ai_client: AiClient = switch (opts.provider) {
        .anthropic => blk: {
            const client = try allocator.create(zenai.anthropic.Client);
            client.* = zenai.anthropic.Client.init(allocator, api_key, .{});
            break :blk .{ .anthropic = client };
        },
        .openai => blk: {
            const client = try allocator.create(zenai.openai.Client);
            client.* = zenai.openai.Client.init(allocator, api_key, .{});
            break :blk .{ .openai = client };
        },
        .gemini => blk: {
            const client = try allocator.create(zenai.gemini.Client);
            client.* = zenai.gemini.Client.init(allocator, api_key, .{});
            break :blk .{ .gemini = client };
        },
    };

    const tools = tool_executor.getTools() catch {
        log.fatal(.app, "failed to initialize tools", .{});
        return error.ToolInitFailed;
    };

    self.* = .{
        .allocator = allocator,
        .ai_client = ai_client,
        .tool_executor = tool_executor,
        .terminal = Terminal.init(null),
        .messages = .empty,
        .tools = tools,
        .model = opts.model orelse defaultModel(opts.provider),
        .system_prompt = opts.system_prompt orelse default_system_prompt,
    };

    return self;
}

pub fn deinit(self: *Self) void {
    self.messages.deinit(self.allocator);
    self.tool_executor.deinit();
    switch (self.ai_client) {
        inline else => |c| {
            c.deinit();
            self.allocator.destroy(c);
        },
    }
    self.allocator.destroy(self);
}

pub fn run(self: *Self) void {
    self.terminal.printInfo("Lightpanda Agent (type 'quit' to exit)");
    self.terminal.printInfo(std.fmt.allocPrint(self.allocator, "Provider: {s}, Model: {s}", .{
        @tagName(std.meta.activeTag(self.ai_client)),
        self.model,
    }) catch "Ready.");

    while (true) {
        const line = self.terminal.readLine("> ") orelse break;
        defer self.terminal.freeLine(line);

        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "quit") or std.mem.eql(u8, line, "exit")) break;

        self.processUserMessage(line) catch |err| {
            const msg = std.fmt.allocPrint(self.allocator, "Request failed: {s}", .{@errorName(err)}) catch "Request failed";
            self.terminal.printError(msg);
        };
    }

    self.terminal.printInfo("Goodbye!");
}

fn processUserMessage(self: *Self, user_input: []const u8) !void {
    // Add system prompt as first message if this is the first user message
    if (self.messages.items.len == 0) {
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = self.system_prompt,
        });
    }

    // Add user message
    try self.messages.append(self.allocator, .{
        .role = .user,
        .content = try self.allocator.dupe(u8, user_input),
    });

    // Loop: send to LLM, execute tool calls, repeat until we get text
    var max_iterations: u32 = 20;
    while (max_iterations > 0) : (max_iterations -= 1) {
        const provider_client = self.ai_client.toProvider();
        var result = provider_client.generateContent(self.model, self.messages.items, .{
            .tools = self.tools,
            .max_tokens = 4096,
        }) catch |err| {
            log.err(.app, "AI API error", .{ .err = err });
            return error.ApiError;
        };
        defer result.deinit();

        // Handle tool calls
        if (result.finish_reason == .tool_call) {
            if (result.tool_calls) |tool_calls| {
                // Add the assistant message with tool calls
                try self.messages.append(self.allocator, .{
                    .role = .assistant,
                    .content = if (result.text) |t| try self.allocator.dupe(u8, t) else null,
                    .tool_calls = try self.dupeToolCalls(tool_calls),
                });

                // Execute each tool call and collect results
                var tool_results: std.ArrayListUnmanaged(zenai.provider.ToolResult) = .empty;
                defer tool_results.deinit(self.allocator);

                for (tool_calls) |tc| {
                    self.terminal.printToolCall(tc.name, tc.arguments);

                    var tool_arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer tool_arena.deinit();

                    const tool_result = self.tool_executor.call(tool_arena.allocator(), tc.name, tc.arguments) catch "Error: tool execution failed";
                    self.terminal.printToolResult(tc.name, tool_result);

                    try tool_results.append(self.allocator, .{
                        .id = try self.allocator.dupe(u8, tc.id),
                        .name = try self.allocator.dupe(u8, tc.name),
                        .content = try self.allocator.dupe(u8, tool_result),
                    });
                }

                // Add tool results as a message
                try self.messages.append(self.allocator, .{
                    .role = .tool,
                    .tool_results = try tool_results.toOwnedSlice(self.allocator),
                });

                continue;
            }
        }

        // Text response
        if (result.text) |text| {
            std.debug.print("\n", .{});
            self.terminal.printAssistant(text);
            std.debug.print("\n\n", .{});

            try self.messages.append(self.allocator, .{
                .role = .assistant,
                .content = try self.allocator.dupe(u8, text),
            });
        }

        break;
    }
}

fn dupeToolCalls(self: *Self, calls: []const zenai.provider.ToolCall) ![]const zenai.provider.ToolCall {
    const duped = try self.allocator.alloc(zenai.provider.ToolCall, calls.len);
    for (calls, 0..) |tc, i| {
        duped[i] = .{
            .id = try self.allocator.dupe(u8, tc.id),
            .name = try self.allocator.dupe(u8, tc.name),
            .arguments = try self.allocator.dupe(u8, tc.arguments),
        };
    }
    return duped;
}

fn getEnvApiKey(provider_type: Config.AiProvider) ?[:0]const u8 {
    return switch (provider_type) {
        .anthropic => std.posix.getenv("ANTHROPIC_API_KEY"),
        .openai => std.posix.getenv("OPENAI_API_KEY"),
        .gemini => std.posix.getenv("GOOGLE_API_KEY") orelse std.posix.getenv("GEMINI_API_KEY"),
    };
}

fn defaultModel(provider_type: Config.AiProvider) []const u8 {
    return switch (provider_type) {
        .anthropic => "claude-sonnet-4-20250514",
        .openai => "gpt-4o",
        .gemini => "gemini-2.5-flash",
    };
}
