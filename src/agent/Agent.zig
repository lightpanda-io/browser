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
    \\Use the tree or interactiveElements tools to understand page structure
    \\before clicking or filling forms. Be concise in your responses.
    \\
    \\IMPORTANT RULES:
    \\- NEVER use backendNodeId with click, fill, hover, selectOption, or setChecked.
    \\  Always use a CSS selector. Use findElement to resolve a description into a
    \\  CSS selector if needed.
    \\  Example: click with selector "#login-btn", NOT with backendNodeId 42.
    \\- Use specific CSS selectors that uniquely identify elements. Include
    \\  distinguishing attributes like value, name, or position to avoid ambiguity.
    \\  Example: input[type="submit"][value="login"], NOT just input[type="submit"].
    \\- When filling credentials, pass environment variable references like
    \\  $LP_USERNAME and $LP_PASSWORD directly as the value — they will be
    \\  resolved automatically. Do NOT use getEnv to resolve them first.
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
self_heal: bool,
interactive: bool,

pub fn init(allocator: std.mem.Allocator, app: *App, opts: Config.Agent) !*Self {
    // Pure replay (positional script, no -i) skips the REPL.
    const will_repl = opts.interactive or opts.script_file == null;

    // --self-heal needs a provider to heal through.
    if (opts.self_heal and opts.provider == null) {
        log.fatal(.app, "missing --provider", .{
            .hint = "--self-heal requires --provider; drop one or add the other",
        });
        return error.SelfHealWithoutProvider;
    }

    // An API key is only required when the REPL will run — pure replay with
    // a provider is fine without one since no AI turn ever executes.
    const api_key: ?[:0]const u8 = if (opts.provider) |p|
        getEnvApiKey(p) orelse if (will_repl) {
            log.fatal(.app, "missing API key", .{
                .hint = "Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY",
            });
            return error.MissingApiKey;
        } else null
    else
        null;

    const tool_executor = try ToolExecutor.init(allocator, app);
    errdefer tool_executor.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const ai_client: ?zenai.provider.Client = if (api_key) |key| switch (opts.provider.?) {
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

    // Persist REPL history in a cwd-relative `.lp-history`; skipped in pure replay.
    const history_path: ?[:0]const u8 = if (will_repl) ".lp-history" else null;

    // `-i <file>` means "replay then grow this file"; a script path alone is
    // pure replay and must not be mutated.
    const recorder_path: ?[]const u8 = if (opts.interactive) opts.script_file else null;

    self.* = .{
        .allocator = allocator,
        .ai_client = ai_client,
        .tool_executor = tool_executor,
        .terminal = Terminal.init(history_path),
        .cmd_executor = undefined,
        .recorder = Recorder.init(recorder_path),
        .messages = .empty,
        .message_arena = std.heap.ArenaAllocator.init(allocator),
        .tools = tools,
        .model = if (opts.provider) |p| (opts.model orelse defaultModel(p)) else "",
        .system_prompt = opts.system_prompt orelse default_system_prompt,
        .script_file = opts.script_file,
        .self_heal = opts.self_heal,
        .interactive = opts.interactive,
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

/// Returns true on success. Interactive mode always returns true; pure
/// replay mirrors `runScript`'s result.
pub fn run(self: *Self) bool {
    if (self.script_file) |path| {
        const script_ok = self.runScript(path);
        if (!self.interactive) return script_ok;
    }
    self.runRepl();
    return true;
}

fn runRepl(self: *Self) void {
    self.terminal.printInfo("Lightpanda Agent (type 'quit' to exit)");
    log.debug(.app, "tools loaded", .{ .count = self.tools.len });
    if (self.ai_client) |ai_client| {
        self.terminal.printInfoFmt("Provider: {s}, Model: {s}", .{ @tagName(std.meta.activeTag(ai_client)), self.model });
    } else {
        self.terminal.printInfo("Dumb REPL (no --provider) — Pandascript only. Pass --provider for natural-language, LOGIN, and ACCEPT_COOKIES.");
    }

    repl: while (true) {
        const line = self.terminal.readLine("> ") orelse break;
        defer self.terminal.freeLine(line);

        if (line.len == 0) continue;

        const cmd = Command.parse(line);

        if (cmd.needsLlm() and self.ai_client == null) {
            self.terminal.printError("This command requires --provider. Pandascript commands (GOTO, CLICK, EXTRACT, ...) work without one.");
            continue;
        }

        switch (cmd) {
            .exit => break :repl,
            .comment => continue :repl,
            .login => self.processUserMessage(login_prompt, line) catch |err| {
                self.terminal.printErrorFmt("LOGIN failed: {s}", .{@errorName(err)});
            },
            .accept_cookies => self.processUserMessage(accept_cookies_prompt, line) catch |err| {
                self.terminal.printErrorFmt("ACCEPT_COOKIES failed: {s}", .{@errorName(err)});
            },
            .natural_language => self.processUserMessage(line, line) catch |err| {
                self.terminal.printErrorFmt("Request failed: {s}", .{@errorName(err)});
            },
            else => {
                self.cmd_executor.execute(cmd);
                self.recorder.record(cmd);
            },
        }
    }

    self.terminal.printInfo("Goodbye!");
}

fn runScript(self: *Self, path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        self.terminal.printErrorFmt("Failed to open script '{s}': {s}", .{ path, @errorName(err) });
        return false;
    };
    defer file.close();

    const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
        self.terminal.printErrorFmt("Failed to read script: {s}", .{@errorName(err)});
        return false;
    };
    defer self.allocator.free(content);

    self.terminal.printInfoFmt("Running script: {s}", .{path});

    var script_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer script_arena.deinit();

    var iter = Command.ScriptIterator.init(content, script_arena.allocator());
    var last_intent: ?[]const u8 = null;

    while (iter.next()) |entry| {
        switch (entry.command) {
            .exit => {
                self.terminal.printInfo("EXIT — stopping script.");
                return true;
            },
            .comment => {
                if (std.mem.startsWith(u8, entry.raw_line, "# INTENT:")) {
                    last_intent = std.mem.trim(u8, entry.raw_line["# INTENT:".len..], &std.ascii.whitespace);
                }
                continue;
            },
            .natural_language => {
                self.terminal.printErrorFmt("line {d}: unrecognized command: {s}", .{ entry.line_num, entry.raw_line });
                return false;
            },
            .login, .accept_cookies => {
                if (self.ai_client == null) {
                    self.terminal.printErrorFmt("line {d}: {s} requires --provider", .{
                        entry.line_num,
                        entry.raw_line,
                    });
                    return false;
                }
                const prompt = if (entry.command == .login) login_prompt else accept_cookies_prompt;
                self.processUserMessage(prompt, "") catch |err| {
                    self.terminal.printErrorFmt("line {d}: {s} failed: {s}", .{
                        entry.line_num,
                        entry.raw_line,
                        @errorName(err),
                    });
                    return false;
                };
            },
            else => {
                self.terminal.printInfoFmt("[{d}] {s}", .{ entry.line_num, entry.raw_line });

                var cmd_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer cmd_arena.deinit();

                const result = self.cmd_executor.executeWithResult(cmd_arena.allocator(), entry.command);
                self.cmd_executor.printResult(entry.command, result);

                if (result.failed) {
                    if (self.self_heal and self.ai_client != null) {
                        self.terminal.printInfo("Command failed, attempting self-healing...");
                        if (self.attemptSelfHeal(last_intent, entry.raw_line)) {
                            continue;
                        }
                    }
                    self.terminal.printErrorFmt("line {d}: command failed: {s}", .{
                        entry.line_num,
                        entry.raw_line,
                    });
                    return false;
                }
            },
        }
    }

    self.terminal.printInfo("Script completed.");
    return true;
}

const self_heal_max_attempts = 3;

fn attemptSelfHeal(self: *Self, intent: ?[]const u8, failed_command: []const u8) bool {
    var heal_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer heal_arena.deinit();
    const ha = heal_arena.allocator();

    const prompt = std.fmt.allocPrint(ha, "{s}{s}{s}{s}{s}", .{
        self_heal_prompt_prefix,
        intent orelse "(no recorded intent)",
        self_heal_prompt_suffix,
        failed_command,
        self_heal_prompt_page_state,
    }) catch return false;

    var attempt: u8 = 0;
    while (attempt < self_heal_max_attempts) : (attempt += 1) {
        self.processUserMessage(prompt, "") catch |err| {
            self.terminal.printErrorFmt("self-heal attempt {d}/{d} failed: {s}", .{
                attempt + 1,
                self_heal_max_attempts,
                @errorName(err),
            });
            continue;
        };
        return true;
    }
    return false;
}

fn processUserMessage(self: *Self, user_input: []const u8, record_comment: []const u8) !void {
    const ma = self.message_arena.allocator();

    if (self.messages.items.len == 0) {
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = self.system_prompt,
        });
    }

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

    var recorded_any = false;
    for (result.tool_calls_made) |tc| {
        if (!std.mem.startsWith(u8, tc.result, "Error:")) {
            if (toolCallToCommand(ma, tc.name, tc.arguments)) |cmd| {
                if (!recorded_any) {
                    if (record_comment.len > 0) self.recorder.recordComment(record_comment);
                    recorded_any = true;
                }
                self.recorder.record(cmd);
            }
        }
    }

    if (result.text) |text| {
        std.debug.print("\n", .{});
        self.terminal.printAssistant(text);
        std.debug.print("\n", .{});
    } else {
        self.terminal.printInfo("(no response from model)");
    }
}

fn handleToolCall(ctx: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8, arguments: []const u8) []const u8 {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.terminal.printToolCall(tool_name, arguments);
    const tool_result = self.tool_executor.call(allocator, tool_name, arguments) catch |err| blk: {
        break :blk std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}) catch "Error: tool execution failed";
    };
    self.terminal.printToolResult(tool_name, tool_result);
    return tool_result;
}

fn toolCallToCommand(arena: std.mem.Allocator, tool_name: []const u8, arguments: []const u8) ?Command.Command {
    const action = std.meta.stringToEnum(lp.tools.Action, tool_name) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, arguments, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    return switch (action) {
        .goto => .{ .goto = getJsonString(obj, "url") orelse return null },
        .click => .{ .click = getJsonString(obj, "selector") orelse return null },
        .hover => .{ .hover = getJsonString(obj, "selector") orelse return null },
        .eval => .{ .eval_js = getJsonString(obj, "script") orelse return null },
        .waitForSelector => .{ .wait = getJsonString(obj, "selector") orelse return null },
        .fill => .{ .type_cmd = .{
            .selector = getJsonString(obj, "selector") orelse return null,
            .value = getJsonString(obj, "value") orelse return null,
        } },
        .selectOption => .{ .select = .{
            .selector = getJsonString(obj, "selector") orelse return null,
            .value = getJsonString(obj, "value") orelse return null,
        } },
        .setChecked => .{ .check = .{
            .selector = getJsonString(obj, "selector") orelse return null,
            .checked = switch (obj.get("checked") orelse return null) {
                .bool => |b| b,
                else => return null,
            },
        } },
        .scroll => blk: {
            if (obj.get("backendNodeId") != null) break :blk null;
            const x: i32 = switch (obj.get("x") orelse std.json.Value{ .integer = 0 }) {
                .integer => |i| @intCast(i),
                else => 0,
            };
            const y: i32 = switch (obj.get("y") orelse std.json.Value{ .integer = 0 }) {
                .integer => |i| @intCast(i),
                else => 0,
            };
            break :blk .{ .scroll = .{ .x = x, .y = y } };
        },
        else => null,
    };
}

fn getJsonString(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
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
        .anthropic => "claude-haiku-4-5-20251001",
        .openai => "gpt-5.4-nano-2026-03-17",
        .gemini => "gemini-3.1-flash-lite-preview",
        .ollama => "gemma3",
    };
}
