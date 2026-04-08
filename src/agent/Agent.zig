const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");

const log = lp.log;
const Config = lp.Config;
const App = @import("../App.zig");
const ToolExecutor = @import("ToolExecutor.zig");
const Terminal = @import("Terminal.zig");
const Command = @import("Command.zig");
const CommandExecutor = @import("CommandExecutor.zig");
const Recorder = @import("Recorder.zig");

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

const self_heal_prompt_prefix =
    \\A Pandascript command failed during replay. The original intent was:
    \\
;

const self_heal_prompt_suffix =
    \\
    \\The command that failed was:
    \\
;

const self_heal_prompt_page_state =
    \\
    \\Please analyze the current page state and execute the equivalent action.
    \\Use the available tools to accomplish the original intent.
;

const login_prompt =
    \\Find the login form on the current page. Fill in the credentials using
    \\environment variables (look for $LP_EMAIL or $LP_USERNAME for the username
    \\field, and $LP_PASSWORD for the password field). Handle any cookie banners
    \\or popups first, then submit the login form.
;

const accept_cookies_prompt =
    \\Find and dismiss the cookie consent banner on the current page.
    \\Look for "Accept", "Accept All", "I agree", or similar buttons and click them.
;

allocator: std.mem.Allocator,
ai_client: ?zenai.provider.Client,
tool_executor: *ToolExecutor,
terminal: Terminal,
cmd_executor: CommandExecutor,
recorder: Recorder,
messages: std.ArrayListUnmanaged(zenai.provider.Message),
message_arena: std.heap.ArenaAllocator,
tools: []const zenai.provider.Tool,
model: []const u8,
system_prompt: []const u8,
script_file: ?[]const u8,
record_file: ?[]const u8,

pub fn init(allocator: std.mem.Allocator, app: *App, opts: Config.Agent) !*Self {
    const is_script_mode = opts.script_file != null;

    // API key is only required for REPL mode and self-healing
    const api_key: ?[:0]const u8 = getEnvApiKey(opts.provider) orelse if (!is_script_mode) {
        log.fatal(.app, "missing API key", .{
            .hint = "Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY",
        });
        return error.MissingApiKey;
    } else null;

    const tool_executor = try ToolExecutor.init(allocator, app);
    errdefer tool_executor.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const ai_client: ?zenai.provider.Client = if (api_key) |key| switch (opts.provider) {
        inline else => |tag| blk: {
            const ProviderClient = zenai.provider.Client;
            const ClientPtr = @FieldType(ProviderClient, @tagName(tag));
            const Client = @typeInfo(ClientPtr).pointer.child;
            const client = try allocator.create(Client);
            const url: ?[]const u8 = opts.base_url orelse if (tag == .ollama) "http://localhost:11434/v1" else null;
            client.* = Client.init(allocator, key, if (url) |u| .{ .base_url = u } else .{});
            break :blk @unionInit(ProviderClient, @tagName(tag), client);
        },
    } else null;

    const tools = tool_executor.getTools() catch {
        log.fatal(.app, "failed to initialize tools", .{});
        return error.ToolInitFailed;
    };

    self.* = .{
        .allocator = allocator,
        .ai_client = ai_client,
        .tool_executor = tool_executor,
        .terminal = Terminal.init(null),
        .cmd_executor = undefined,
        .recorder = Recorder.init(opts.record_file),
        .messages = .empty,
        .message_arena = std.heap.ArenaAllocator.init(allocator),
        .tools = tools,
        .model = opts.model orelse defaultModel(opts.provider),
        .system_prompt = opts.system_prompt orelse default_system_prompt,
        .script_file = opts.script_file,
        .record_file = opts.record_file,
    };

    self.cmd_executor = CommandExecutor.init(allocator, tool_executor, &self.terminal);

    return self;
}

pub fn deinit(self: *Self) void {
    self.recorder.deinit();
    self.message_arena.deinit();
    self.messages.deinit(self.allocator);
    self.tool_executor.deinit();
    if (self.ai_client) |ai_client| {
        switch (ai_client) {
            inline else => |c| {
                c.deinit();
                self.allocator.destroy(c);
            },
        }
    }
    self.allocator.destroy(self);
}

pub fn run(self: *Self) void {
    if (self.script_file) |script_file| {
        self.runScript(script_file);
    } else {
        self.runRepl();
    }
}

fn runRepl(self: *Self) void {
    self.terminal.printInfo("Lightpanda Agent (type 'quit' to exit)");
    log.debug(.app, "tools loaded", .{ .count = self.tools.len });
    const info = if (self.ai_client) |ai_client|
        std.fmt.allocPrint(self.allocator, "Provider: {s}, Model: {s}", .{
            @tagName(std.meta.activeTag(ai_client)),
            self.model,
        }) catch null
    else
        null;
    self.terminal.printInfo(info orelse "Ready.");
    if (info) |i| self.allocator.free(i);

    while (true) {
        const line = self.terminal.readLine("> ") orelse break;
        defer self.terminal.freeLine(line);

        if (line.len == 0) continue;

        const cmd = Command.parse(line);
        switch (cmd) {
            .exit => break,
            .comment => continue,
            .login => {
                self.recorder.recordComment("# INTENT: LOGIN");
                self.processUserMessage(login_prompt) catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "LOGIN failed: {s}", .{@errorName(err)}) catch "LOGIN failed";
                    self.terminal.printError(msg);
                };
            },
            .accept_cookies => {
                self.recorder.recordComment("# INTENT: ACCEPT_COOKIES");
                self.processUserMessage(accept_cookies_prompt) catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "ACCEPT_COOKIES failed: {s}", .{@errorName(err)}) catch "ACCEPT_COOKIES failed";
                    self.terminal.printError(msg);
                };
            },
            .natural_language => {
                // "quit" as a convenience alias
                if (std.mem.eql(u8, line, "quit")) break;

                self.processUserMessage(line) catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "Request failed: {s}", .{@errorName(err)}) catch "Request failed";
                    self.terminal.printError(msg);
                };
            },
            else => {
                self.cmd_executor.execute(cmd);
                self.recorder.record(cmd);
            },
        }
    }

    self.terminal.printInfo("Goodbye!");
}

fn runScript(self: *Self, path: []const u8) void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(self.allocator, "Failed to open script '{s}': {s}", .{ path, @errorName(err) }) catch "Failed to open script";
        self.terminal.printError(msg);
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
        const msg = std.fmt.allocPrint(self.allocator, "Failed to read script: {s}", .{@errorName(err)}) catch "Failed to read script";
        self.terminal.printError(msg);
        return;
    };
    defer self.allocator.free(content);

    const script_info = std.fmt.allocPrint(self.allocator, "Running script: {s}", .{path}) catch null;
    self.terminal.printInfo(script_info orelse "Running script...");
    if (script_info) |i| self.allocator.free(i);

    var script_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer script_arena.deinit();

    var iter = Command.ScriptIterator.init(content, script_arena.allocator());
    var last_intent: ?[]const u8 = null;

    while (iter.next()) |entry| {
        switch (entry.command) {
            .exit => {
                self.terminal.printInfo("EXIT — stopping script.");
                return;
            },
            .comment => {
                // Track # INTENT: comments for self-healing
                if (std.mem.startsWith(u8, entry.raw_line, "# INTENT:")) {
                    last_intent = std.mem.trim(u8, entry.raw_line["# INTENT:".len..], &std.ascii.whitespace);
                }
                continue;
            },
            .natural_language => {
                const msg = std.fmt.allocPrint(self.allocator, "line {d}: unrecognized command: {s}", .{ entry.line_num, entry.raw_line }) catch "unrecognized command";
                self.terminal.printError(msg);
                return;
            },
            .login, .accept_cookies => {
                // High-level commands require LLM
                if (self.ai_client == null) {
                    const msg = std.fmt.allocPrint(self.allocator, "line {d}: {s} requires an API key for LLM resolution", .{
                        entry.line_num,
                        entry.raw_line,
                    }) catch "LLM required";
                    self.terminal.printError(msg);
                    return;
                }
                const prompt = if (entry.command == .login) login_prompt else accept_cookies_prompt;
                self.processUserMessage(prompt) catch |err| {
                    const msg = std.fmt.allocPrint(self.allocator, "line {d}: {s} failed: {s}", .{
                        entry.line_num,
                        entry.raw_line,
                        @errorName(err),
                    }) catch "command failed";
                    self.terminal.printError(msg);
                    return;
                };
            },
            else => {
                const line_info = std.fmt.allocPrint(self.allocator, "[{d}] {s}", .{ entry.line_num, entry.raw_line }) catch null;
                self.terminal.printInfo(line_info orelse entry.raw_line);
                if (line_info) |li| self.allocator.free(li);

                // Execute with result checking for self-healing
                var cmd_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer cmd_arena.deinit();

                const result = self.cmd_executor.executeWithResult(cmd_arena.allocator(), entry.command);
                self.terminal.printAssistant(result.output);
                std.debug.print("\n", .{});

                if (result.failed) {
                    // Attempt self-healing via LLM
                    if (self.ai_client != null) {
                        self.terminal.printInfo("Command failed, attempting self-healing...");
                        if (self.attemptSelfHeal(last_intent, entry.raw_line)) {
                            continue;
                        }
                    }
                    const msg = std.fmt.allocPrint(self.allocator, "line {d}: command failed: {s}", .{
                        entry.line_num,
                        entry.raw_line,
                    }) catch "command failed";
                    self.terminal.printError(msg);
                    return;
                }
            },
        }
    }

    self.terminal.printInfo("Script completed.");
}

/// Attempt to self-heal a failed command by asking the LLM to resolve it.
fn attemptSelfHeal(self: *Self, intent: ?[]const u8, failed_command: []const u8) bool {
    var heal_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer heal_arena.deinit();
    const ha = heal_arena.allocator();

    // Build the self-healing prompt
    const prompt = std.fmt.allocPrint(ha, "{s}{s}{s}{s}{s}", .{
        self_heal_prompt_prefix,
        intent orelse "(no recorded intent)",
        self_heal_prompt_suffix,
        failed_command,
        self_heal_prompt_page_state,
    }) catch return false;

    self.processUserMessage(prompt) catch return false;
    return true;
}

fn processUserMessage(self: *Self, user_input: []const u8) !void {
    const ma = self.message_arena.allocator();

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
        .content = try ma.dupe(u8, user_input),
    });

    const provider_client = self.ai_client orelse return error.NoAiClient;

    var result = provider_client.runTools(
        self.model,
        &self.messages,
        self.allocator,
        ma,
        .{ .context = @ptrCast(self), .callFn = &handleToolCall },
        .{
            .tools = self.tools,
            .max_tokens = 4096,
            .tool_choice = .auto,
        },
    ) catch |err| {
        log.err(.app, "AI API error", .{ .err = err });
        return error.ApiError;
    };
    defer result.deinit();

    // Record tool calls as Pandascript
    for (result.tool_calls_made) |tc| {
        if (!std.mem.startsWith(u8, tc.result, "Error:")) {
            self.recordToolCall(ma, tc.name, tc.arguments);
        }
    }

    if (result.text) |text| {
        std.debug.print("\n", .{});
        self.terminal.printAssistant(text);
        std.debug.print("\n\n", .{});
    } else {
        self.terminal.printInfo("(no response from model)");
    }
}

fn handleToolCall(ctx: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8, arguments: []const u8) []const u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.terminal.printToolCall(tool_name, arguments);
    const tool_result = self.tool_executor.call(allocator, tool_name, arguments) catch "Error: tool execution failed";
    self.terminal.printToolResult(tool_name, tool_result);
    return tool_result;
}

/// Convert a tool call (name + JSON arguments) into a Pandascript command and record it.
fn recordToolCall(self: *Self, arena: std.mem.Allocator, tool_name: []const u8, arguments: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, arguments, .{}) catch return;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };

    const cmd: ?Command.Command = if (std.mem.eql(u8, tool_name, "goto") or std.mem.eql(u8, tool_name, "navigate")) blk: {
        break :blk switch (obj.get("url") orelse break :blk null) {
            .string => |s| .{ .goto = s },
            else => null,
        };
    } else if (std.mem.eql(u8, tool_name, "click")) blk: {
        if (obj.get("selector")) |sel_val| {
            break :blk switch (sel_val) {
                .string => |s| .{ .click = s },
                else => null,
            };
        }
        // Can't meaningfully record a backendNodeId as Pandascript
        break :blk null;
    } else if (std.mem.eql(u8, tool_name, "fill")) blk: {
        const sel = switch (obj.get("selector") orelse break :blk null) {
            .string => |s| s,
            else => break :blk null,
        };
        const val = switch (obj.get("value") orelse break :blk null) {
            .string => |s| s,
            else => break :blk null,
        };
        break :blk .{ .type_cmd = .{ .selector = sel, .value = val } };
    } else if (std.mem.eql(u8, tool_name, "evaluate") or std.mem.eql(u8, tool_name, "eval")) blk: {
        break :blk switch (obj.get("script") orelse break :blk null) {
            .string => |s| .{ .eval_js = s },
            else => null,
        };
    } else null;

    if (cmd) |c| {
        self.recorder.record(c);
    }
}

fn getEnvApiKey(provider_type: Config.AiProvider) ?[:0]const u8 {
    return switch (provider_type) {
        .anthropic => std.posix.getenv("ANTHROPIC_API_KEY"),
        .openai => std.posix.getenv("OPENAI_API_KEY"),
        .gemini => std.posix.getenv("GOOGLE_API_KEY") orelse std.posix.getenv("GEMINI_API_KEY"),
        .ollama => "ollama",
    };
}

fn defaultModel(provider_type: Config.AiProvider) []const u8 {
    return switch (provider_type) {
        .anthropic => "claude-sonnet-4-20250514",
        .openai => "gpt-4o",
        .gemini => "gemini-2.5-flash",
        .ollama => "gemma4",
    };
}
