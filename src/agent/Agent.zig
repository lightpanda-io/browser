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
const Verifier = @import("Verifier.zig");

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
    \\A Pandascript command failed during replay. The command that failed was:
    \\
;

const self_heal_prompt_page_state =
    \\
    \\The current page URL is:
    \\
;

const self_heal_prompt_instructions =
    \\
    \\IMPORTANT:
    \\- Do NOT navigate away from the current page. The page is already loaded and
    \\  contains the element you need — the selector just needs to be fixed.
    \\- Use the tree or interactiveElements tools WITHOUT a url parameter to inspect
    \\  the current page, find the correct selector, and execute the equivalent action.
    \\- ONLY fix the failed command. Do NOT perform any additional actions beyond it.
    \\  The script will continue executing the remaining commands after the heal.
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
verifier: Verifier,
recorder: Recorder,
messages: std.ArrayList(zenai.provider.Message),
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
        .verifier = .{ .tool_executor = tool_executor },
        .recorder = .init(allocator, recorder_path),
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

const Replacement = struct {
    /// Slice into the original content buffer that should be replaced.
    original_span: []const u8,
    /// New text to substitute (includes trailing newline).
    new_text: []const u8,
};

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
    const sa = script_arena.allocator();

    var iter: Command.ScriptIterator = .init(content, sa);
    var last_comment: ?[]const u8 = null;
    var replacements: std.ArrayList(Replacement) = .empty;

    while (iter.next()) |entry| {
        switch (entry.command) {
            .exit => {
                self.terminal.printInfo("EXIT — stopping script.");
                break;
            },
            .comment => {
                // Track the most recent comment — recorded scripts
                // prefix LLM-generated commands with the natural
                // language prompt that produced them, which provides
                // useful context for self-healing.
                if (entry.raw_line.len > 2 and entry.raw_line[0] == '#') {
                    last_comment = std.mem.trim(u8, entry.raw_line[1..], &std.ascii.whitespace);
                }
                continue;
            },
            .natural_language => {
                self.terminal.printErrorFmt("line {d}: unrecognized command: {s}", .{ entry.line_num, entry.raw_line });
                self.flushReplacements(path, content, replacements.items);
                return false;
            },
            .login, .accept_cookies => {
                if (self.ai_client == null) {
                    self.terminal.printErrorFmt("line {d}: {s} requires --provider", .{
                        entry.line_num,
                        entry.raw_line,
                    });
                    self.flushReplacements(path, content, replacements.items);
                    return false;
                }
                const prompt = if (entry.command == .login) login_prompt else accept_cookies_prompt;
                self.processUserMessage(prompt, "") catch |err| {
                    self.terminal.printErrorFmt("line {d}: {s} failed: {s}", .{
                        entry.line_num,
                        entry.raw_line,
                        @errorName(err),
                    });
                    self.flushReplacements(path, content, replacements.items);
                    return false;
                };
            },
            else => {
                self.terminal.printInfoFmt("[{d}] {s}", .{ entry.line_num, entry.raw_line });

                var cmd_arena = std.heap.ArenaAllocator.init(self.allocator);
                defer cmd_arena.deinit();

                const pre_state: ?Verifier.PreState = if (self.self_heal)
                    self.verifier.capturePreState(cmd_arena.allocator(), entry.command)
                else
                    null;

                const result = self.cmd_executor.executeWithResult(cmd_arena.allocator(), entry.command);
                self.cmd_executor.printResult(entry.command, result);

                const verification = if (!result.failed and pre_state != null)
                    self.verifier.verify(cmd_arena.allocator(), entry.command, pre_state.?)
                else
                    Verifier.VerifyResult{ .result = .passed };

                const effective_failed = result.failed or verification.result == .failed;

                if (effective_failed) {
                    if (self.self_heal and self.ai_client != null) {
                        // Retry with wait before LLM escalation for
                        // verification failures (not hard failures).
                        if (!result.failed and isRetryable(entry.command)) {
                            var retried = false;
                            for (0..3) |i| {
                                std.Thread.sleep((500 + i * 250) * std.time.ns_per_ms);
                                self.terminal.printInfo("Retrying command...");
                                const retry_pre = self.verifier.capturePreState(cmd_arena.allocator(), entry.command);
                                const retry_result = self.cmd_executor.executeWithResult(cmd_arena.allocator(), entry.command);
                                if (!retry_result.failed) {
                                    if (self.verifier.verify(cmd_arena.allocator(), entry.command, retry_pre).result != .failed) {
                                        self.cmd_executor.printResult(entry.command, retry_result);
                                        retried = true;
                                        break;
                                    }
                                }
                            }
                            if (retried) continue;
                        }

                        const msg = if (result.failed)
                            "Command failed, attempting self-healing..."
                        else
                            "Command succeeded but verification failed, attempting self-healing...";
                        self.terminal.printInfo(msg);

                        if (self.attemptSelfHeal(entry.raw_line, verification.reason, last_comment, sa)) |healed_cmds| {
                            if (formatReplacement(sa, entry.raw_span, entry.raw_line, healed_cmds)) |replacement| {
                                replacements.append(sa, replacement) catch {};
                            }
                            continue;
                        }
                    }
                    self.terminal.printErrorFmt("line {d}: command failed: {s}", .{
                        entry.line_num,
                        entry.raw_line,
                    });
                    self.flushReplacements(path, content, replacements.items);
                    return false;
                }
            },
        }
    }

    self.flushReplacements(path, content, replacements.items);
    self.terminal.printInfo("Script completed.");
    return true;
}

fn formatReplacement(arena: std.mem.Allocator, original_span: []const u8, raw_line: []const u8, cmds: []const Command.Command) ?Replacement {
    if (cmds.len == 0) return null;
    var aw: std.Io.Writer.Allocating = .init(arena);

    // Only take the first command — the original was a single command,
    // so the replacement should be too. Extra commands from the LLM
    // (e.g., clicking submit after fixing a selector) would break the
    // script sequence since subsequent commands haven't been skipped.
    aw.writer.print("# [Auto-healed] Original: {s}\n", .{raw_line}) catch return null;
    cmds[0].format(&aw.writer) catch return null;
    aw.writer.writeAll("\n") catch return null;

    return .{
        .original_span = original_span,
        .new_text = aw.written(),
    };
}

fn flushReplacements(self: *Self, path: []const u8, content: []const u8, replacements: []const Replacement) void {
    if (replacements.len == 0) return;

    // Write .bak backup of the original script.
    const bak_path = std.fmt.allocPrint(self.allocator, "{s}.bak", .{path}) catch return;
    defer self.allocator.free(bak_path);
    if (std.fs.cwd().createFile(bak_path, .{})) |bak_file| {
        defer bak_file.close();
        bak_file.writeAll(content) catch {};
        self.terminal.printInfoFmt("Backup saved to {s}", .{bak_path});
    } else |_| {}

    const new_content = applyReplacements(self.allocator, content, replacements) catch return;
    defer self.allocator.free(new_content);

    // Atomic write: tmp file then rename.
    const tmp_path = std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path}) catch return;
    defer self.allocator.free(tmp_path);

    const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch return;
    tmp_file.writeAll(new_content) catch {
        tmp_file.close();
        return;
    };
    tmp_file.close();

    std.fs.cwd().rename(tmp_path, path) catch |err| {
        self.terminal.printErrorFmt("Failed to update script: {s}", .{@errorName(err)});
        return;
    };

    self.terminal.printInfoFmt("Script updated with {d} healed command(s).", .{replacements.len});
}

/// Build a new buffer by splicing `replacements` into `content`.
///
/// Invariant: each replacement's `original_span` must alias into `content`
/// (i.e. point within the same allocation) and spans must be in order and
/// non-overlapping. The pointer arithmetic below relies on this to compute
/// byte offsets.
fn applyReplacements(
    allocator: std.mem.Allocator,
    content: []const u8,
    replacements: []const Replacement,
) error{OutOfMemory}![]u8 {
    const content_base = @intFromPtr(content.ptr);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, content.len);
    var pos: usize = 0;
    for (replacements) |r| {
        const r_start = @intFromPtr(r.original_span.ptr) - content_base;
        const r_end = r_start + r.original_span.len;
        try out.appendSlice(allocator, content[pos..r_start]);
        try out.appendSlice(allocator, r.new_text);
        pos = r_end;
    }
    try out.appendSlice(allocator, content[pos..]);
    return out.toOwnedSlice(allocator);
}

fn isRetryable(cmd: Command.Command) bool {
    return switch (cmd) {
        .type_cmd, .check, .click, .select => true,
        else => false,
    };
}

const self_heal_max_attempts = 3;

fn ensureSystemPrompt(self: *Self) !void {
    if (self.messages.items.len == 0) {
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = self.system_prompt,
        });
    }
}

/// When the message list exceeds `prune_high`, drop older turns (keeping
/// the system prompt) so only the last `prune_keep` messages remain.
/// All string data is deep-copied into a fresh arena and the old one freed.
const prune_high = 30;
const prune_keep = 20;

fn pruneMessages(self: *Self) void {
    const msgs = self.messages.items;
    if (msgs.len <= prune_high) return;

    // Keep system prompt (index 0) + the last `prune_keep` messages.
    const tail_start = msgs.len - prune_keep;

    var new_arena = std.heap.ArenaAllocator.init(self.allocator);
    const na = new_arena.allocator();

    // The system prompt's content points into system_prompt (not the arena),
    // so only the tail messages need deep-copying.
    var i: usize = 0;
    for (msgs[tail_start..]) |msg| {
        msgs[1 + i] = dupeMessage(na, msg) orelse {
            // On OOM, abandon the prune — the old arena stays intact.
            new_arena.deinit();
            return;
        };
        i += 1;
    }

    self.messages.shrinkRetainingCapacity(1 + i); // system prompt + copied tail
    self.message_arena.deinit();
    self.message_arena = new_arena;
}

fn dupeMessage(alloc: std.mem.Allocator, msg: zenai.provider.Message) ?zenai.provider.Message {
    return .{
        .role = msg.role,
        .content = if (msg.content) |c| alloc.dupe(u8, c) catch return null else null,
        .tool_calls = if (msg.tool_calls) |tcs| dupeToolCalls(alloc, tcs) catch return null else null,
        .tool_results = if (msg.tool_results) |trs| dupeToolResults(alloc, trs) catch return null else null,
        .parts = if (msg.parts) |ps| dupeParts(alloc, ps) catch return null else null,
    };
}

fn dupeToolCalls(alloc: std.mem.Allocator, calls: []const zenai.provider.ToolCall) ![]const zenai.provider.ToolCall {
    const out = try alloc.alloc(zenai.provider.ToolCall, calls.len);
    for (calls, 0..) |tc, i| {
        out[i] = .{
            .id = try alloc.dupe(u8, tc.id),
            .name = try alloc.dupe(u8, tc.name),
            .arguments = try alloc.dupe(u8, tc.arguments),
            .thought_signature = if (tc.thought_signature) |ts| try alloc.dupe(u8, ts) else null,
        };
    }
    return out;
}

fn dupeToolResults(alloc: std.mem.Allocator, results: []const zenai.provider.ToolResult) ![]const zenai.provider.ToolResult {
    const out = try alloc.alloc(zenai.provider.ToolResult, results.len);
    for (results, 0..) |tr, i| {
        out[i] = .{
            .id = try alloc.dupe(u8, tr.id),
            .name = try alloc.dupe(u8, tr.name),
            .content = try alloc.dupe(u8, tr.content),
            .thought_signature = if (tr.thought_signature) |ts| try alloc.dupe(u8, ts) else null,
        };
    }
    return out;
}

fn dupeParts(alloc: std.mem.Allocator, parts: []const zenai.provider.ContentPart) ![]const zenai.provider.ContentPart {
    const out = try alloc.alloc(zenai.provider.ContentPart, parts.len);
    for (parts, 0..) |p, i| {
        out[i] = switch (p) {
            .text => |t| .{ .text = try alloc.dupe(u8, t) },
            .image => |img| .{ .image = .{
                .data = try alloc.dupe(u8, img.data),
                .mime_type = try alloc.dupe(u8, img.mime_type),
            } },
        };
    }
    return out;
}

/// Runs a single LLM turn and returns the commands it executed, without
/// recording them to the Recorder.  Used by attemptSelfHeal so that the
/// caller can capture healed commands for script rewriting.
fn runHealTurn(self: *Self, prompt: []const u8, arena: std.mem.Allocator) ![]Command.Command {
    const ma = self.message_arena.allocator();

    try self.ensureSystemPrompt();

    try self.messages.append(self.allocator, .{
        .role = .user,
        .content = try ma.dupe(u8, prompt),
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
            .max_tool_calls = 4,
            .max_tokens = 4096,
            .tool_choice = .auto,
        },
    ) catch |err| {
        log.err(.app, "AI API error", .{ .err = err });
        return error.ApiError;
    };
    defer result.deinit();

    var cmds: std.ArrayList(Command.Command) = .empty;
    for (result.tool_calls_made) |tc| {
        if (!std.mem.startsWith(u8, tc.result, "Error:")) {
            if (Command.fromToolCall(ma, tc.name, tc.arguments)) |cmd| {
                cmds.append(arena, cmd) catch {};
            }
        }
    }

    if (result.text) |text| {
        self.terminal.printAssistant(text);
    }

    return cmds.toOwnedSlice(arena) catch &.{};
}

fn attemptSelfHeal(self: *Self, failed_command: []const u8, verify_context: ?[]const u8, context_comment: ?[]const u8, arena: std.mem.Allocator) ?[]Command.Command {
    const ha = self.message_arena.allocator();

    const verify_section = if (verify_context) |ctx|
        std.fmt.allocPrint(ha, "\n\nVerification detected a problem:\n{s}", .{ctx}) catch ""
    else
        "";

    const comment_section = if (context_comment) |c|
        std.fmt.allocPrint(ha, "\n\nThe original user request that generated this command was:\n{s}", .{c}) catch ""
    else
        "";

    const prompt = std.fmt.allocPrint(ha, "{s}{s}{s}{s}{s}{s}{s}", .{
        self_heal_prompt_prefix,
        failed_command,
        self_heal_prompt_page_state,
        self.tool_executor.getCurrentUrl(),
        comment_section,
        verify_section,
        self_heal_prompt_instructions,
    }) catch return null;

    // Save message count so we can roll back between attempts — each failed
    // heal turn would otherwise accumulate in context, confusing the next try.
    const msg_baseline = self.messages.items.len;

    var attempt: u8 = 0;
    while (attempt < self_heal_max_attempts) : (attempt += 1) {
        const cmds = self.runHealTurn(prompt, arena) catch |err| {
            self.terminal.printErrorFmt("self-heal attempt {d}/{d} failed: {s}", .{
                attempt + 1,
                self_heal_max_attempts,
                @errorName(err),
            });
            self.messages.shrinkRetainingCapacity(msg_baseline);
            continue;
        };
        if (cmds.len > 0) {
            self.pruneMessages();
            return cmds;
        }
        self.messages.shrinkRetainingCapacity(msg_baseline);
    }
    return null;
}

fn processUserMessage(self: *Self, user_input: []const u8, record_comment: []const u8) !void {
    const ma = self.message_arena.allocator();

    try self.ensureSystemPrompt();

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
            if (Command.fromToolCall(ma, tc.name, tc.arguments)) |cmd| {
                if (!recorded_any) {
                    if (record_comment.len > 0) self.recorder.recordComment(record_comment);
                    recorded_any = true;
                }
                self.recorder.record(cmd);
            }
        }
    }

    if (result.text) |text| {
        self.terminal.printAssistant(text);
    } else {
        self.terminal.printInfo("(no response from model)");
    }

    self.pruneMessages();
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

// --- Tests ---

test "applyReplacements: empty list returns copy" {
    const content = "CLICK 'a'\nCLICK 'b'\n";
    const out = try applyReplacements(std.testing.allocator, content, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(content, out);
}

test "applyReplacements: single span in the middle" {
    const content = "GOTO https://x\nCLICK 'old'\nCLICK 'tail'\n";
    const span_start = std.mem.indexOf(u8, content, "CLICK 'old'\n").?;
    const span = content[span_start .. span_start + "CLICK 'old'\n".len];
    const replacements = [_]Replacement{
        .{ .original_span = span, .new_text = "CLICK 'new'\n" },
    };
    const out = try applyReplacements(std.testing.allocator, content, &replacements);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "GOTO https://x\nCLICK 'new'\nCLICK 'tail'\n",
        out,
    );
}

test "applyReplacements: multiple non-contiguous spans" {
    const content = "A\nB\nC\nD\nE\n";
    const b_span = content[std.mem.indexOf(u8, content, "B\n").?..][0..2];
    const d_span = content[std.mem.indexOf(u8, content, "D\n").?..][0..2];
    const replacements = [_]Replacement{
        .{ .original_span = b_span, .new_text = "bb\n" },
        .{ .original_span = d_span, .new_text = "dd\n" },
    };
    const out = try applyReplacements(std.testing.allocator, content, &replacements);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("A\nbb\nC\ndd\nE\n", out);
}

test "applyReplacements: replacement at start and end" {
    const content = "first\nmiddle\nlast\n";
    const first_span = content[0..6];
    const last_span = content[std.mem.indexOf(u8, content, "last\n").?..][0..5];
    const replacements = [_]Replacement{
        .{ .original_span = first_span, .new_text = "FIRST\n" },
        .{ .original_span = last_span, .new_text = "LAST\n" },
    };
    const out = try applyReplacements(std.testing.allocator, content, &replacements);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("FIRST\nmiddle\nLAST\n", out);
}

test "applyReplacements: new_text longer and shorter than span" {
    const content = "X\nshort\nY\n";
    const span = content[std.mem.indexOf(u8, content, "short\n").?..][0..6];
    const replacements = [_]Replacement{
        .{ .original_span = span, .new_text = "a much longer replacement line\n" },
    };
    const out = try applyReplacements(std.testing.allocator, content, &replacements);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "X\na much longer replacement line\nY\n",
        out,
    );
}
