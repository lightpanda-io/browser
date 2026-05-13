const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");

const log = lp.log;
const Config = lp.Config;
const App = @import("../App.zig");
const ToolExecutor = @import("ToolExecutor.zig");
const Terminal = @import("Terminal.zig");
const Command = lp.script.Command;
const Recorder = lp.script.Recorder;
const Verifier = lp.script.Verifier;
const CommandExecutor = @import("CommandExecutor.zig");
const SlashCommand = @import("SlashCommand.zig");
const script = lp.script;

const Self = @This();

const default_system_prompt = script.mcp_driver_guidance ++
    \\
    \\Agent-specific behavior:
    \\- Call a tool for every browser action. NEVER claim you performed an
    \\  action, visited a page, or saw content without actually calling the
    \\  corresponding tool. If a task needs a capability Lightpanda lacks
    \\  (images, PDFs, audio), say so honestly rather than improvising.
    \\- Be decisive and concise. Prefer few, well-chosen tool calls over many
    \\  probes. If extraction repeatedly fails or the site errors, commit to a
    \\  best-effort answer rather than thrashing.
    \\- An honest "the site blocked access" beats a fabricated answer every time.
    \\- If the user asks for account-scoped information (their karma, profile,
    \\  history, inbox, dashboard, settings, etc.) and the page shows you are
    \\  not signed in, attempt to log in proactively before reporting that the
    \\  data is unavailable. Find the login link or form on the current page
    \\  (interactiveElements or findElement), dismiss any cookie banner first,
    \\  call getEnv with no `name` argument to see which LP_* credentials are
    \\  available, then fill the username/password fields with the matching
    \\  $LP_* placeholders (prefer site-prefixed forms like $LP_HN_USERNAME /
    \\  $LP_HN_PASSWORD; fall back to unprefixed $LP_USERNAME / $LP_PASSWORD)
    \\  and submit. Only fall back to "I couldn't access X" if no credentials
    \\  are set, the form is missing, or the credentials are rejected — and
    \\  say which.
;

const self_heal_prompt_prefix =
    \\A PandaScript command failed during replay. The command that failed was:
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
    \\- If the action is blocked by a popup, cookie banner, or surprise modal,
    \\  handle it first (e.g., click "Accept") before executing the fixed command.
    \\- ONLY fix the failed command and handle immediate blockers. STOP immediately
    \\  once the intent of the original command is achieved.
    \\  The script will continue executing the remaining commands after the heal.
;

const login_prompt =
    \\Find the login form on the current page. Fill in the credentials using
    \\$LP_* placeholders — the substitution happens inside the Lightpanda
    \\subprocess so the secret never enters your context. Do NOT call getEnv
    \\with a credential name (it would return the value).
    \\
    \\Call getEnv with NO `name` argument first to see which LP_* variables
    \\are set (names only, values never included). Then pick:
    \\- Site-prefixed form (LP_<SITE>_<FIELD>) when the list shows one for
    \\  the current site — e.g. $LP_HN_USERNAME for news.ycombinator.com,
    \\  $LP_GH_TOKEN for github.com.
    \\- Otherwise fall back to the unprefixed $LP_USERNAME / $LP_PASSWORD
    \\  (or $LP_EMAIL) form.
    \\
    \\Handle any cookie banners or popups first, then submit the form by
    \\clicking its submit button or pressing Enter in a filled field — there
    \\is no dedicated submit tool.
;

const accept_cookies_prompt =
    \\Find and dismiss the cookie consent banner on the current page.
    \\Look for "Accept", "Accept All", "I agree", or similar buttons and click them.
;

const synthesis_prompt =
    \\You have used your tool budget or cannot finish the exploration.
    \\Give your best final answer NOW based ONLY on what you actually observed
    \\via tool calls in this conversation. Do NOT fall back to prior knowledge —
    \\if your snapshots show only cookie banners, 403/access-denied pages,
    \\blocked search results, or empty bodies, say that explicitly
    \\(e.g. "the page was blocked by a cookie wall and I could not extract X").
    \\Do not invent details that are not visible in the tool outputs above.
    \\Do not call any more tools.
    \\Respond with ONLY the answer — one word, one number, one short phrase,
    \\or a brief honest explanation of why the page could not be read.
    \\No prefix, no markdown.
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
model: []u8,
system_prompt: []const u8,
script_file: ?[]const u8,
self_heal: bool,
interactive: bool,
one_shot_task: ?[]const u8,
one_shot_attachments: ?[]const []const u8,
slash_schemas: []const SlashCommand.SchemaInfo,

pub fn init(allocator: std.mem.Allocator, app: *App, opts: Config.Agent) !*Self {
    if (opts.task != null and opts.script_file != null) {
        log.fatal(.app, "conflicting flags", .{
            .hint = "--task runs a one-shot turn; drop the positional script or drop --task",
        });
        return error.ConflictingFlags;
    }
    if (opts.self_heal and opts.script_file == null) {
        log.fatal(.app, "self-heal needs a script", .{
            .hint = "--self-heal rewrites a recorded .lp on drift; pass a script path",
        });
        return error.ConflictingFlags;
    }
    if (opts.no_llm and opts.provider != null) {
        log.warn(.app, "ignoring --provider", .{ .reason = "--no-llm takes precedence" });
    }

    const is_one_shot = opts.task != null;
    const will_repl = !is_one_shot and (opts.interactive or opts.script_file == null);
    const needs_llm = will_repl or is_one_shot;

    // Precedence: --no-llm > --provider > env auto-detect.
    const effective_provider: ?Config.AiProvider = if (opts.no_llm)
        null
    else if (opts.provider) |p|
        p
    else
        try autoDetectProvider();

    // The REPL itself can run without an LLM (basic mode), but --task,
    // --self-heal, and --pick-model genuinely need one.
    const requires_llm = is_one_shot or opts.self_heal or opts.pick_model;
    if (effective_provider == null and requires_llm) {
        const hint: []const u8 = if (opts.no_llm)
            "drop --no-llm, then set an API key or pass --provider"
        else if (opts.self_heal)
            "--self-heal needs an LLM; set an API key or pass --provider"
        else if (opts.pick_model)
            "--pick-model needs an LLM; set an API key or pass --provider"
        else
            "set an API key (ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY) or pass --provider";
        log.fatal(.app, "no LLM available", .{ .hint = hint });
        return error.MissingProvider;
    }

    const api_key = try resolveApiKey(effective_provider, needs_llm);

    // Resolve model BEFORE the heavy init so --pick-model's prompt fires
    // before tool_executor / ai_client setup.
    // Precedence: --model > --pick-model > defaultModel.
    const model: []u8 = if (opts.pick_model and effective_provider != null and api_key != null)
        try pickModel(allocator, effective_provider.?, api_key.?, opts.base_url)
    else if (opts.model) |m|
        try allocator.dupe(u8, m)
    else if (effective_provider) |p|
        try allocator.dupe(u8, zenai.provider.defaultModel(p))
    else
        try allocator.dupe(u8, "");
    errdefer allocator.free(model);

    const tool_executor: *ToolExecutor = try .init(allocator, app);
    errdefer tool_executor.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const ai_client: ?zenai.provider.Client = if (api_key) |key| switch (effective_provider.?) {
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
    errdefer if (ai_client) |c| switch (c) {
        inline else => |client| {
            client.deinit();
            allocator.destroy(client);
        },
    };

    const history_path: ?[:0]const u8 = if (will_repl) ".lp-history" else null;

    // `-i <file>` means "replay then grow this file"; a script path alone is
    // pure replay and must not be mutated.
    const recorder_path: ?[]const u8 = if (opts.interactive) opts.script_file else null;

    // Reuse the executor's schema arena: the parsed schemas in `tools` already
    // live there, and the cache must outlive only as long as those do.
    const slash_schemas: []const SlashCommand.SchemaInfo = if (will_repl)
        SlashCommand.buildSchemas(tool_executor.schemaAllocator(), tool_executor.tools) catch {
            log.fatal(.app, "failed to build slash schemas", .{});
            return error.SlashSchemaInitFailed;
        }
    else
        &.{};

    self.* = .{
        .allocator = allocator,
        .ai_client = ai_client,
        .tool_executor = tool_executor,
        .terminal = .init(allocator, history_path, opts.verbosity, will_repl),
        .cmd_executor = undefined,
        .verifier = .{ .session = tool_executor.session, .node_registry = &tool_executor.node_registry },
        .recorder = .init(allocator, recorder_path),
        .messages = .empty,
        .message_arena = .init(allocator),
        .model = model,
        .system_prompt = opts.system_prompt orelse default_system_prompt,
        .script_file = opts.script_file,
        .self_heal = opts.self_heal,
        .interactive = opts.interactive,
        .one_shot_task = opts.task,
        .one_shot_attachments = if (opts.task_attachments.items.len == 0) null else opts.task_attachments.items,
        .slash_schemas = slash_schemas,
    };

    self.cmd_executor = CommandExecutor.init(allocator, tool_executor, &self.terminal);

    if (will_repl) self.terminal.attachCompleter(slash_schemas);

    if (self.recorder.path) |p| {
        self.terminal.printInfoFmt("recording to {s}", .{p});
    } else if (self.recorder.init_error) |reason| {
        self.terminal.printErrorFmt("recording disabled: {s}", .{reason});
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.recorder.deinit();
    self.terminal.deinit();
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
    self.allocator.free(self.model);
    self.allocator.destroy(self);
}

/// One agent turn: the prompt sent to the model, plus optional context
/// (a recorder comment to write before the turn, file attachments to bundle
/// into the first user message, and a display label used in error output).
pub const TurnInput = struct {
    prompt: []const u8,
    record_comment: ?[]const u8 = null,
    attachments: ?[]const []const u8 = null,
    label: []const u8 = "Request",
};

/// Returns true on success.
pub fn run(self: *Self) bool {
    if (self.one_shot_task) |task| return self.runTurn(.{
        .prompt = task,
        .attachments = self.one_shot_attachments,
    });
    if (self.script_file) |path| {
        const script_ok = self.runScript(path);
        if (!self.interactive) return script_ok;
    }
    self.runRepl();
    return true;
}

/// Final answer goes to stdout; errors go to stderr, so a caller can
/// pipe stdout to capture a clean answer.
fn runTurn(self: *Self, input: TurnInput) bool {
    const text = self.processUserMessage(input) catch |err| switch (err) {
        error.UnsupportedAttachment, error.AttachmentReadFailed => return false,
        else => {
            self.terminal.printErrorFmt("{s} failed: {s}", .{ input.label, @errorName(err) });
            return false;
        },
    };
    if (text) |t| self.terminal.printAssistant(t) else self.terminal.printInfo("(no response from model)");
    return true;
}

fn runRepl(self: *Self) void {
    self.terminal.printInfo("Lightpanda Agent (type '/quit' to exit)");
    self.terminal.printInfo("Tab completes/cycles through commands; the dim grey ghost shows the first match.");
    log.debug(.app, "tools loaded", .{ .count = self.tool_executor.tools.len });
    if (self.ai_client) |ai_client| {
        self.terminal.printInfoFmt("Provider: {s}, Model: {s}", .{ @tagName(std.meta.activeTag(ai_client)), self.model });
    } else {
        self.terminal.printInfo("Basic REPL — PandaScript only. Set an API key or pass --provider for natural-language, LOGIN, and ACCEPT_COOKIES (and drop --no-llm if you set it).");
    }

    repl: while (true) {
        const line = Terminal.readLine("") orelse break;
        defer Terminal.freeLine(line);

        if (line.len == 0) continue;

        if (line[0] == '/') {
            if (self.handleSlash(line[1..])) break :repl;
            continue :repl;
        }

        const cmd = Command.parse(line);

        // Distinguish "you mistyped a PandaScript command" from "this is
        // natural language for the LLM". Both fall through to
        // `.natural_language` in Command.parse, but the first should never
        // hit the LLM-needed error path.
        if (std.meta.activeTag(cmd) == .natural_language) {
            if (Command.keywordSyntax(line)) |kc| {
                if (kc.args) |args| {
                    self.terminal.printErrorFmt("Usage: {s} {s}", .{ kc.name, args });
                } else {
                    self.terminal.printErrorFmt("{s} takes no arguments", .{kc.name});
                }
                continue;
            }
        }

        if (cmd.needsLlm() and self.ai_client == null) {
            self.terminal.printError("This command needs an LLM. Set an API key or pass --provider (and drop --no-llm if you set it). PandaScript commands (GOTO, CLICK, EXTRACT, ...) work without one.");
            continue;
        }

        switch (cmd) {
            .comment => continue :repl,
            .login => _ = self.runTurn(.{ .prompt = login_prompt, .record_comment = line, .label = "LOGIN" }),
            .accept_cookies => _ = self.runTurn(.{ .prompt = accept_cookies_prompt, .record_comment = line, .label = "ACCEPT_COOKIES" }),
            .natural_language => _ = self.runTurn(.{ .prompt = line, .record_comment = line }),
            else => {
                const split = SlashCommand.splitNameRest(line) orelse continue :repl;
                self.terminal.beginTool(split.name, split.rest);
                var arena: std.heap.ArenaAllocator = .init(self.allocator);
                defer arena.deinit();
                const result = self.cmd_executor.executeWithResult(arena.allocator(), cmd);
                self.terminal.endTool(!result.failed);
                self.cmd_executor.printResult(cmd, result);
                self.recorder.record(cmd);
            },
        }
    }

    self.terminal.printInfo("Goodbye!");
}

/// Handle a REPL line that started with `/`. Returns `true` if the user asked
/// to quit (`/quit`), `false` otherwise. All errors are printed and
/// swallowed — the REPL must not die from a malformed slash command.
fn handleSlash(self: *Self, body: []const u8) bool {
    const split = SlashCommand.splitNameRest(body) orelse {
        self.terminal.printError("Empty slash command. Try /help.");
        return false;
    };
    const name = split.name;
    const rest = split.rest;

    if (std.mem.eql(u8, name, "quit")) return true;
    if (std.mem.eql(u8, name, "help")) {
        self.printSlashHelp(rest);
        return false;
    }

    const schema = SlashCommand.findSchema(self.slash_schemas, name) orelse {
        self.printSlashParseError(error.UnknownTool, name);
        return false;
    };

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const args_json = SlashCommand.parseArgs(aa, schema, rest) catch |err| {
        self.printSlashParseError(err, name);
        return false;
    };

    if (std.mem.eql(u8, schema.tool_name, @tagName(lp.tools.Action.eval))) {
        // callEval surfaces the is_error flag separately from the text;
        // tool_executor.call discards it.
        const eval_script = extractEvalScript(aa, args_json) catch {
            self.terminal.printError("eval requires a `script` argument.");
            return false;
        };
        self.terminal.beginTool(schema.tool_name, rest);
        const result = self.tool_executor.callEval(aa, eval_script);
        self.terminal.endTool(!result.is_error);
        if (result.is_error) {
            self.terminal.printErrorFmt("eval: {s}", .{result.text});
        } else {
            self.terminal.printToolResult(schema.tool_name, result.text);
        }
        return false;
    }

    self.terminal.beginTool(schema.tool_name, rest);
    if (self.tool_executor.call(aa, schema.tool_name, args_json)) |result| {
        self.terminal.endTool(true);
        self.terminal.printToolResult(schema.tool_name, result);
    } else |err| {
        self.terminal.endTool(false);
        self.terminal.printErrorFmt("{s}: {s}", .{ schema.tool_name, @errorName(err) });
    }
    return false;
}

fn printSlashHelp(self: *Self, target: []const u8) void {
    if (target.len == 0) {
        self.terminal.printInfo("Slash commands (no LLM, REPL only):");
        for (self.slash_schemas) |s| {
            const summary = firstSentence(s.description);
            self.terminal.printInfoFmt("  /{s} — {s}", .{ s.tool_name, summary });
        }
        self.terminal.printInfo("Meta: /help [name], /quit");
        return;
    }
    const lookup = if (target[0] == '/') target[1..] else target;
    if (std.ascii.eqlIgnoreCase(lookup, "help")) {
        self.terminal.printInfo("/help [name] — show help for a slash command, or list all when [name] is omitted");
        return;
    }
    if (std.ascii.eqlIgnoreCase(lookup, "quit")) {
        self.terminal.printInfo("/quit — exit the REPL");
        return;
    }
    const schema = SlashCommand.findSchema(self.slash_schemas, lookup) orelse {
        self.terminal.printErrorFmt("unknown tool: {s}", .{lookup});
        return;
    };
    self.terminal.printInfoFmt("/{s} — {s}", .{ schema.tool_name, schema.description });

    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const pretty: []const u8 = blk: {
        const v = std.json.parseFromSliceLeaky(std.json.Value, aa, schema.input_schema_raw, .{}) catch break :blk schema.input_schema_raw;
        var aw: std.Io.Writer.Allocating = .init(aa);
        std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, &aw.writer) catch break :blk schema.input_schema_raw;
        break :blk aw.written();
    };
    self.terminal.printInfoFmt("schema:\n{s}", .{pretty});
}

fn printSlashParseError(self: *Self, err: SlashCommand.ParseError, name: []const u8) void {
    const reason: []const u8 = switch (err) {
        error.UnknownTool => "unknown tool",
        error.MissingName => return self.terminal.printError("missing tool name. Try /help."),
        error.MissingRequired => "missing required argument",
        error.MalformedKv => "malformed key=value. Use key=value or {json}",
        error.PositionalNotAllowed => "positional only works for tools with one required field. Use key=value",
        error.UnterminatedQuote => "unterminated quote",
        error.OutOfMemory => return self.terminal.printError("out of memory"),
    };
    self.terminal.printErrorFmt("{s}: {s}. Try /help {s}.", .{ name, reason, name });
}

fn firstSentence(text: []const u8) []const u8 {
    // Sentence boundary = period followed by whitespace (or end of string).
    // Plain "." is too aggressive — descriptions reference "console.log",
    // "JSON-LD, OpenGraph, etc.", and similar abbreviations.
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '.')) |idx| : (i = idx + 1) {
        if (idx + 1 == text.len or std.ascii.isWhitespace(text[idx + 1])) return text[0..idx];
    }
    return text;
}

fn extractEvalScript(arena: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    if (args_json.len == 0) return error.MissingScript;
    const parsed = std.json.parseFromSliceLeaky(struct { script: []const u8 }, arena, args_json, .{ .ignore_unknown_fields = true }) catch return error.MissingScript;
    return parsed.script;
}

const Replacement = script.Replacement;

fn runScript(self: *Self, path: []const u8) bool {
    self.terminal.printInfoFmt("Running script: {s}", .{path});

    var script_arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer script_arena.deinit();
    const sa = script_arena.allocator();

    const content = std.fs.cwd().readFileAlloc(sa, path, 10 * 1024 * 1024) catch |err| {
        self.terminal.printErrorFmt("Failed to read script '{s}': {s}", .{ path, @errorName(err) });
        return false;
    };

    var iter: Command.ScriptIterator = .init(sa, content);
    var last_comment: ?[]const u8 = null;
    var replacements: std.ArrayList(Replacement) = .empty;

    while (true) {
        const entry = (iter.next() catch |err| {
            self.terminal.printErrorFmt("line {d}: {s} parsing script", .{ iter.line_num, @errorName(err) });
            self.flushReplacements(path, content, replacements.items);
            return false;
        }) orelse break;
        switch (entry.command) {
            .comment => {
                // Recorded scripts prefix LLM-generated commands with the
                // natural-language prompt that produced them; keep the
                // last one around so self-heal can use it as context.
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
                const text = self.processUserMessage(.{ .prompt = prompt }) catch |err| {
                    self.terminal.printErrorFmt("line {d}: {s} failed: {s}", .{
                        entry.line_num,
                        entry.raw_line,
                        @errorName(err),
                    });
                    self.flushReplacements(path, content, replacements.items);
                    return false;
                };
                if (text) |t| self.terminal.printAssistant(t);
            },
            else => {
                self.terminal.printInfoFmt("[{d}] {s}", .{ entry.line_num, entry.raw_line });
                switch (self.runActionEntry(sa, entry, last_comment)) {
                    .ok => {},
                    .healed => |r| replacements.append(sa, r) catch |err| {
                        self.terminal.printErrorFmt(
                            "line {d}: out of memory recording heal: {s} (script left unchanged)",
                            .{ entry.line_num, @errorName(err) },
                        );
                        return false;
                    },
                    .fail => {
                        self.flushReplacements(path, content, replacements.items);
                        return false;
                    },
                }
            },
        }
    }

    self.flushReplacements(path, content, replacements.items);
    self.terminal.printInfo("Script completed.");
    return true;
}

const ActionOutcome = union(enum) {
    ok,
    healed: Replacement,
    /// The per-line error has already been printed; caller must not re-report.
    fail,
};

/// Execute one action-style script entry, including post-execution
/// verification, transient-failure retry, and LLM self-heal escalation.
fn runActionEntry(self: *Self, sa: std.mem.Allocator, entry: Command.ScriptIterator.Entry, last_comment: ?[]const u8) ActionOutcome {
    var cmd_arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer cmd_arena.deinit();
    const ca = cmd_arena.allocator();

    const result = self.cmd_executor.executeWithResult(ca, entry.command);
    self.cmd_executor.printResult(entry.command, result);

    const verification = if (!result.failed and self.self_heal)
        self.verifier.verify(ca, entry.command)
    else
        Verifier.VerifyResult{ .result = .inconclusive };

    if (!result.failed and verification.result != .failed) return .ok;

    if (self.self_heal and self.ai_client != null) {
        // Verification-only failures often resolve with a brief wait
        // (animations, lazy-load); skip the LLM round-trip when they do.
        if (!result.failed and isRetryable(entry.command) and self.retryCommand(ca, entry.command)) {
            return .ok;
        }

        const msg = if (result.failed)
            "Command failed, attempting self-healing..."
        else
            "Command succeeded but verification failed, attempting self-healing...";
        self.terminal.printInfo(msg);

        if (self.attemptSelfHeal(sa, entry.raw_line, verification.reason, last_comment)) |healed_cmds| {
            const replacement = script.formatHealReplacement(sa, entry.raw_span, entry.raw_line, healed_cmds) catch |err| {
                self.terminal.printErrorFmt(
                    "line {d}: failed to record heal: {s} (script left unchanged)",
                    .{ entry.line_num, @errorName(err) },
                );
                return .fail;
            };
            return .{ .healed = replacement };
        }
    }
    self.terminal.printErrorFmt("line {d}: command failed: {s}", .{
        entry.line_num,
        entry.raw_line,
    });
    return .fail;
}

/// Re-run a verification-failed command with bounded backoff. Returns true
/// once both execution and verification pass, false after 3 attempts.
fn retryCommand(self: *Self, ca: std.mem.Allocator, cmd: Command.Command) bool {
    for (0..3) |i| {
        std.Thread.sleep((500 + i * 250) * std.time.ns_per_ms);
        self.terminal.printInfo("Retrying command...");
        const retry_result = self.cmd_executor.executeWithResult(ca, cmd);
        if (retry_result.failed) continue;
        if (self.verifier.verify(ca, cmd).result == .failed) continue;
        self.cmd_executor.printResult(cmd, retry_result);
        return true;
    }
    return false;
}

fn flushReplacements(self: *Self, path: []const u8, content: []const u8, replacements: []const Replacement) void {
    if (replacements.len == 0) return;
    script.writeAtomic(self.allocator, std.fs.cwd(), path, content, replacements) catch |err| {
        self.terminal.printErrorFmt(
            "Failed to update script {s}: {s} (script left unchanged)",
            .{ path, @errorName(err) },
        );
        return;
    };
    self.terminal.printInfoFmt(
        "Script updated with {d} healed command(s); backup at {s}.bak",
        .{ replacements.len, path },
    );
}

fn isRetryable(cmd: Command.Command) bool {
    return switch (cmd) {
        .type_cmd, .check, .select => true,
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

// Drop older turns once `prune_high` is hit; survivors are deep-copied so
// the old arena (which still pins dropped strings) can be released.
const prune_high = 30;
const prune_keep = 20;

fn pruneMessages(self: *Self) void {
    const msgs = self.messages.items;
    if (msgs.len <= prune_high) return;

    const tail_start = zenai.provider.safeTruncationStart(msgs, msgs.len - prune_keep) orelse return;

    // Dupe the kept tail into a scratch slice in the new arena first. Only
    // mutate self.messages once every dupe has succeeded — otherwise a
    // partial failure would leave self.messages.items[1..] pointing into
    // the freed `new_arena`.
    var new_arena: std.heap.ArenaAllocator = .init(self.allocator);
    const duped = zenai.provider.dupeMessages(new_arena.allocator(), msgs[tail_start..]) catch {
        new_arena.deinit();
        return;
    };

    // System prompt at index 0 lives outside the arena and is preserved.
    @memcpy(self.messages.items[1..][0..duped.len], duped);
    self.messages.shrinkRetainingCapacity(1 + duped.len);
    self.message_arena.deinit();
    self.message_arena = new_arena;
}

/// Self-heal must only patch the current page; navigation and arbitrary
/// scripting are blocked even if the model emits them via `goto` / `eval`.
/// docs/agent.md guarantees "no navigation away from the current page".
fn isHealAllowed(cmd: Command.Command) bool {
    return switch (cmd) {
        .goto, .eval_js => false,
        else => true,
    };
}

/// Runs a single LLM turn, captures the commands it called without recording
/// them — so the caller can splice healed commands into the script directly.
fn runHealTurn(self: *Self, arena: std.mem.Allocator, prompt: []const u8) ![]Command.Command {
    const provider_client = self.ai_client orelse return error.NoAiClient;
    const ma = self.message_arena.allocator();

    try self.ensureSystemPrompt();

    try self.messages.append(self.allocator, .{
        .role = .user,
        .content = try ma.dupe(u8, prompt),
    });

    self.terminal.spinner.start();
    var result = provider_client.runTools(
        self.model,
        &self.messages,
        self.allocator,
        ma,
        .{ .context = @ptrCast(self), .callFn = handleToolCall },
        .{
            .tools = self.tool_executor.tools,
            .max_tool_calls = 4,
            .max_tokens = 4096,
            .tool_choice = .auto,
        },
    ) catch |err| {
        self.terminal.spinner.cancel();
        log.err(.app, "AI API error", .{ .err = err });
        return error.ApiError;
    };
    self.terminal.spinner.stop();
    defer result.deinit();

    var cmds: std.ArrayList(Command.Command) = .empty;
    for (result.tool_calls_made) |tc| {
        if (tc.is_error) continue;
        const args = tc.arguments orelse continue;
        const cmd = Command.fromToolCallValue(tc.name, args) orelse continue;
        if (!isHealAllowed(cmd)) {
            self.terminal.printInfoFmt(
                "self-heal: ignoring {s} (navigation and eval are not allowed during heal)",
                .{tc.name},
            );
            continue;
        }
        try cmds.append(arena, cmd);
    }

    if (result.text) |text| {
        self.terminal.printAssistant(text);
    }

    return cmds.toOwnedSlice(arena);
}

fn attemptSelfHeal(self: *Self, arena: std.mem.Allocator, failed_command: []const u8, verify_context: ?[]const u8, context_comment: ?[]const u8) ?[]Command.Command {
    // Build the prompt in `arena` (the caller's per-replay arena), not in
    // `message_arena`. The prompt is re-used across attempts, so it must
    // survive arena rebuilds done between failed attempts.
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.print("{s}{s}{s}{s}", .{
        self_heal_prompt_prefix,
        failed_command,
        self_heal_prompt_page_state,
        self.tool_executor.getCurrentUrl(),
    }) catch return null;
    if (context_comment) |c|
        aw.writer.print("\n\nThe original user request that generated this command was:\n{s}", .{c}) catch return null;
    if (verify_context) |ctx|
        aw.writer.print("\n\nVerification detected a problem:\n{s}", .{ctx}) catch return null;
    aw.writer.writeAll(self_heal_prompt_instructions) catch return null;
    const prompt = aw.written();

    // Save message count so we can roll back between attempts — each failed
    // heal turn would otherwise accumulate in context, confusing the next try.
    const msg_baseline = self.messages.items.len;

    var attempt: u8 = 0;
    while (attempt < self_heal_max_attempts) : (attempt += 1) {
        const cmds = self.runHealTurn(arena, prompt) catch |err| {
            self.terminal.printErrorFmt("self-heal attempt {d}/{d} failed: {s}", .{
                attempt + 1,
                self_heal_max_attempts,
                @errorName(err),
            });
            self.rollbackMessages(msg_baseline);
            continue;
        };
        if (cmds.len > 0) {
            self.pruneMessages();
            return cmds;
        }
        self.rollbackMessages(msg_baseline);
        break;
    }
    return null;
}

/// Shrink `self.messages` back to `baseline` and rebuild the arena. Used
/// after a failed turn (API error, self-heal attempt, synthesis) so the
/// next turn doesn't replay the dropped messages and the arena doesn't
/// accumulate their bytes.
fn rollbackMessages(self: *Self, baseline: usize) void {
    self.messages.shrinkRetainingCapacity(baseline);
    self.rebuildMessageArena();
}

/// Rebuild `message_arena` keeping only the messages currently in
/// `self.messages`. Used between failed self-heal attempts so the arena
/// doesn't accumulate prompt/tool-output bytes from doomed turns.
fn rebuildMessageArena(self: *Self) void {
    const msgs = self.messages.items;
    if (msgs.len <= 1) {
        // Only the system prompt (or nothing) remains — the system prompt
        // lives outside the arena, so we can reset freely.
        _ = self.message_arena.reset(.retain_capacity);
        return;
    }

    var new_arena: std.heap.ArenaAllocator = .init(self.allocator);
    // System prompt at index 0 lives outside the arena and is preserved.
    const duped = zenai.provider.dupeMessages(new_arena.allocator(), msgs[1..]) catch {
        new_arena.deinit();
        return;
    };
    @memcpy(self.messages.items[1..][0..duped.len], duped);
    self.message_arena.deinit();
    self.message_arena = new_arena;
}

/// Returned text lives in `message_arena`, so it's only valid until the
/// next prune. `null` means the model emitted nothing even after the
/// synthesis turn.
fn processUserMessage(self: *Self, input: TurnInput) !?[]const u8 {
    const ma = self.message_arena.allocator();

    try self.ensureSystemPrompt();

    // Attachments only ride on the very first user turn (just after the
    // system prompt) — wired into the message's rich `parts`.
    const turn_attachments: ?[]const []const u8 =
        if (self.messages.items.len == 1) input.attachments else null;

    // Save message count so we can roll back on API failure — otherwise the
    // failed user turn stays in history and replays on the next attempt.
    const msg_baseline = self.messages.items.len;

    if (turn_attachments) |paths| {
        const parts = try self.buildUserMessageParts(ma, input.prompt, paths);
        try self.messages.append(self.allocator, .{
            .role = .user,
            .parts = parts,
        });
    } else {
        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = try ma.dupe(u8, input.prompt),
        });
    }

    const provider_client = self.ai_client orelse return error.NoAiClient;

    self.terminal.spinner.start();
    var result = provider_client.runTools(
        self.model,
        &self.messages,
        self.allocator,
        ma,
        .{ .context = @ptrCast(self), .callFn = handleToolCall },
        .{
            .tools = self.tool_executor.tools,
            .max_turns = 30,
            // Safety net; max_turns is the primary terminal.
            .max_tool_calls = 200,
            .max_tokens = 4096,
            .tool_choice = .auto,
            // Cap per-turn reasoning so thinking models don't burn
            // minutes per turn. Ignored by non-thinking models.
            .thinking_budget = 2048,
        },
    ) catch |err| {
        self.terminal.spinner.cancel();
        log.err(.app, "AI API error", .{ .err = err });
        self.rollbackMessages(msg_baseline);
        return error.ApiError;
    };
    self.terminal.spinner.stop();
    defer result.deinit();

    if (self.recorder.isActive()) {
        var recorded_any = false;
        for (result.tool_calls_made) |tc| {
            if (tc.is_error) continue;
            const args = tc.arguments orelse continue;
            const cmd = Command.fromToolCallValue(tc.name, args) orelse continue;
            if (!recorded_any) {
                if (input.record_comment) |c| self.recorder.recordComment(c);
                recorded_any = true;
            }
            self.recorder.record(cmd);
        }
        // Recorder self-disables on write failure (disk full, fd closed). Tell
        // the user the recording stopped instead of silently dropping appends.
        if (!self.recorder.isActive()) {
            self.terminal.printError("recording disabled (write failed); see logs");
        }
    }

    // `result.text` and `synth.text` are owned by their RunToolsResult arenas,
    // which are deinited at the end of this function. Dupe into the agent's
    // `message_arena` so the returned slice outlives those arenas.
    const final_text: ?[]const u8 = blk: {
        if (result.text) |text| break :blk try ma.dupe(u8, text);

        // Tool loop ended without a final text — force one more turn that
        // forbids tools and pretraining fallback. Without this, models
        // confabulate answers when the page was blocked or empty.
        log.info(.app, "synthesizing final answer", .{});
        const synth_baseline = self.messages.items.len;
        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = try ma.dupe(u8, synthesis_prompt),
        });

        var synth = provider_client.runTools(
            self.model,
            &self.messages,
            self.allocator,
            ma,
            .{ .context = @ptrCast(self), .callFn = handleToolCall },
            .{
                // tool_choice = .none forbids tools; serializing the full
                // catalog anyway just pads the request body.
                .tools = &.{},
                .max_turns = 1,
                .max_tokens = 4096,
                .tool_choice = .none,
                // Cap thinking on the finalize turn. Fully disabling it (0)
                // leaves reasoning-heavy tasks with no answer at all; letting
                // it run unbounded lets models fill the turn with thoughts
                // and emit nothing as the final text. 512 tokens is enough
                // for the model to pick its answer but not to freewheel.
                .thinking_budget = 512,
            },
        ) catch |err| {
            log.err(.app, "AI synthesis error", .{ .err = err });
            self.rollbackMessages(synth_baseline);
            break :blk null;
        };
        defer synth.deinit();

        break :blk if (synth.text) |text| try ma.dupe(u8, text) else null;
    };

    self.pruneMessages();
    return final_text;
}

/// Build a `parts`-based user message when `--task-attachment` was given.
/// Text-ish files are inlined into the text prefix (surrounded by clear
/// markers); binary files (image/audio/pdf) are base64-encoded and sent as
/// provider inline-data parts. Unknown extensions error out so the caller
/// fails loudly instead of silently dropping the attachment.
fn buildUserMessageParts(
    self: *Self,
    ma: std.mem.Allocator,
    user_input: []const u8,
    paths: []const []const u8,
) ![]const zenai.provider.ContentPart {
    var text_prefix: std.ArrayList(u8) = .empty;
    var inline_parts: std.ArrayList(zenai.provider.ContentPart) = .empty;

    for (paths) |path| {
        const mime = zenai.provider.inferInlineMimeType(path) orelse {
            log.err(.app, "unsupported attachment", .{ .path = path });
            self.terminal.printErrorFmt("unsupported attachment type: {s}", .{path});
            return error.UnsupportedAttachment;
        };

        if (std.mem.startsWith(u8, mime, "text/")) {
            const bytes = std.fs.cwd().readFileAlloc(ma, path, 512 * 1024) catch |err| {
                log.err(.app, "read attachment failed", .{ .path = path, .err = err });
                self.terminal.printErrorFmt("could not read attachment: {s}", .{path});
                return error.AttachmentReadFailed;
            };
            try text_prefix.writer(ma).print(
                "[Attached file: {s}]\n{s}\n[End of attachment]\n\n",
                .{ path, bytes },
            );
        } else {
            const raw = std.fs.cwd().readFileAlloc(ma, path, 20 * 1024 * 1024) catch |err| {
                log.err(.app, "read attachment failed", .{ .path = path, .err = err });
                self.terminal.printErrorFmt("could not read attachment: {s}", .{path});
                return error.AttachmentReadFailed;
            };
            const b64_len = std.base64.standard.Encoder.calcSize(raw.len);
            const b64 = try ma.alloc(u8, b64_len);
            _ = std.base64.standard.Encoder.encode(b64, raw);
            try inline_parts.append(ma, .{ .image = .{
                .data = b64,
                .mime_type = try ma.dupe(u8, mime),
            } });
        }
    }

    var parts: std.ArrayList(zenai.provider.ContentPart) = .empty;
    try text_prefix.appendSlice(ma, user_input);
    try parts.append(ma, .{ .text = try text_prefix.toOwnedSlice(ma) });
    for (inline_parts.items) |p| try parts.append(ma, p);
    return parts.toOwnedSlice(ma);
}

// Cap per-call tool output so heavy pages don't balloon the message arena
// (and the next request body) without bound.
const tool_output_max_bytes: usize = 1 * 1024 * 1024;

fn capToolOutput(allocator: std.mem.Allocator, output: []const u8) []const u8 {
    if (output.len <= tool_output_max_bytes) return output;
    const prefix = output[0..tool_output_max_bytes];
    // Format the suffix into a tiny scratch buffer then concat — avoids
    // duplicating the 1 MiB prefix through `allocPrint`'s format machinery.
    var suffix_buf: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "\n...[truncated, original {d} bytes]", .{output.len}) catch return prefix;
    return std.mem.concat(allocator, u8, &.{ prefix, suffix }) catch prefix;
}

fn handleToolCall(ctx: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8, arguments: ?std.json.Value) zenai.provider.Client.ToolHandler.Result {
    const self: *Self = @ptrCast(@alignCast(ctx));
    // Stringifying tool args is wasted work for non-interactive low-verbosity
    // runs: the spinner doesn't render it and `agentToolDone` skips the bullet
    // line. Skip the alloc when no consumer will read it.
    const needs_args = self.terminal.spinner.enabled or self.terminal.verbosity != .low;
    const args_str: []const u8 = if (needs_args) (if (arguments) |v|
        std.json.Stringify.valueAlloc(allocator, v, .{}) catch ""
    else
        "") else "";
    self.terminal.spinner.setTool(tool_name, args_str);
    defer self.terminal.spinner.setThinking();
    if (self.tool_executor.callValue(allocator, tool_name, arguments)) |output| {
        const capped = capToolOutput(allocator, output);
        self.terminal.agentToolDone(tool_name, args_str, true);
        // Only `high` keeps the per-call body line — benchmark harness parses it.
        if (self.terminal.verbosity == .high) self.terminal.printToolResult(tool_name, capped);
        return .{ .content = capped };
    } else |err| {
        const msg = std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}) catch "Error: tool execution failed";
        // Errors go back to the model so it can self-correct. The red
        // bullet (per-line) or red spinner label is the user-facing
        // failure signal; we only print the body at `high` (harness).
        self.terminal.agentToolDone(tool_name, args_str, false);
        if (self.terminal.verbosity == .high) self.terminal.printToolResult(tool_name, msg);
        return .{ .content = msg, .is_error = true };
    }
}

/// An API key is only required when an LLM turn will actually run. Without a
/// provider, no key is needed.
fn resolveApiKey(provider: ?Config.AiProvider, needs_llm: bool) !?[:0]const u8 {
    const p = provider orelse return null;
    if (zenai.provider.envApiKey(p)) |key| return key;
    if (!needs_llm) return null;
    log.fatal(.app, "missing API key", .{
        .hint = "Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY",
    });
    return error.MissingApiKey;
}

/// One-shot for `--list-models`: resolve the provider (explicit, then env
/// auto-detect), reject `--no-llm`, fetch chat-capable model IDs from the
/// provider, and print them to stdout (one per line).
pub fn listModels(allocator: std.mem.Allocator, opts: Config.Agent) !void {
    if (opts.no_llm) {
        log.fatal(.app, "list-models needs LLM", .{
            .hint = "--no-llm and --list-models conflict; drop --no-llm",
        });
        return error.ConflictingFlags;
    }
    if (opts.task != null or opts.self_heal or opts.interactive or
        opts.script_file != null or opts.pick_model)
    {
        log.fatal(.app, "list-models is exclusive", .{
            .hint = "--list-models only takes --provider/--model/--base-url",
        });
        return error.ConflictingFlags;
    }
    const provider = opts.provider orelse (try autoDetectProvider()) orelse {
        log.fatal(.app, "list-models needs LLM", .{
            .hint = "set ANTHROPIC_API_KEY (or OPENAI_API_KEY / GOOGLE_API_KEY) or pass --provider",
        });
        return error.MissingProvider;
    };
    const api_key = zenai.provider.envApiKey(provider) orelse {
        log.fatal(.app, "missing API key", .{
            .provider = @tagName(provider),
            .env = envVarName(provider),
        });
        return error.MissingApiKey;
    };

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const ids = try zenai.provider.listChatModelIds(allocator, arena.allocator(), provider, api_key, opts.base_url);

    var stdout_file = std.fs.File.stdout().writer(&.{});
    const w = &stdout_file.interface;
    for (ids) |id| try w.print("{s}\n", .{id});
    try w.flush();
}

/// Pick a provider from env keys when `--provider` was not given.
/// Notices go to stderr unconditionally so users always know which mode they're in.
pub fn autoDetectProvider() !?Config.AiProvider {
    const candidates = [_]Config.AiProvider{ .anthropic, .openai, .gemini };
    var found_buf: [candidates.len]Config.AiProvider = undefined;
    var found_len: usize = 0;
    for (candidates) |p| {
        if (zenai.provider.envApiKey(p) != null) {
            found_buf[found_len] = p;
            found_len += 1;
        }
    }
    const found = found_buf[0..found_len];

    return switch (found.len) {
        0 => blk: {
            std.debug.print(
                "No API key detected. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or GOOGLE_API_KEY, or pass --provider — or pass --no-llm for the basic REPL.\n",
                .{},
            );
            break :blk null;
        },
        1 => blk: {
            const p = found[0];
            std.debug.print("Detected {s} — using --provider {s}.\n", .{ envVarName(p), @tagName(p) });
            break :blk p;
        },
        else => try promptForProvider(found),
    };
}

fn envVarName(p: Config.AiProvider) []const u8 {
    return switch (p) {
        .anthropic => "ANTHROPIC_API_KEY",
        .openai => "OPENAI_API_KEY",
        .gemini => "GOOGLE_API_KEY/GEMINI_API_KEY",
        .ollama => "<ollama>",
    };
}

fn promptForProvider(found: []const Config.AiProvider) !Config.AiProvider {
    if (!interactiveTty()) {
        log.fatal(.app, "multiple API keys detected", .{
            .hint = "Pass --provider explicitly when running non-interactively",
        });
        return error.AmbiguousProvider;
    }

    var labels_buf: [@typeInfo(Config.AiProvider).@"enum".fields.len][]const u8 = undefined;
    for (found, 0..) |p, i| labels_buf[i] = @tagName(p);

    const idx = (promptNumberedChoice("Multiple API keys detected. Pick provider:", labels_buf[0..found.len], false, null) catch {
        std.debug.print("Cancelled — pass --provider to skip the picker.\n", .{});
        return error.UserCancelled;
    }) orelse unreachable;
    return found[idx];
}

/// Fetch the provider's chat-capable model list and prompt the user to pick
/// one. Empty input picks the baked-in default. Always returns an owned
/// heap buffer (including for the default case) so the caller has one
/// uniform free path.
fn pickModel(
    allocator: std.mem.Allocator,
    provider: Config.AiProvider,
    api_key: [:0]const u8,
    base_url: ?[:0]const u8,
) ![]u8 {
    if (!interactiveTty()) {
        log.fatal(.app, "pick-model needs a TTY", .{
            .hint = "rerun in a terminal or pass --model explicitly",
        });
        return error.NotInteractive;
    }

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    std.debug.print("Fetching models for {s}…\n", .{@tagName(provider)});
    const ids = zenai.provider.listChatModelIds(allocator, arena.allocator(), provider, api_key, base_url) catch |err| {
        log.fatal(.app, "list models failed", .{ .err = @errorName(err) });
        return err;
    };
    if (ids.len == 0) {
        log.fatal(.app, "no models returned", .{ .provider = @tagName(provider) });
        return error.NoModels;
    }

    const default_model = zenai.provider.defaultModel(provider);
    var default_idx: ?usize = null;
    for (ids, 0..) |id, i| if (std.mem.eql(u8, id, default_model)) {
        default_idx = i;
        break;
    };

    var header_buf: [128]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "Pick model for {s} (Enter for default):", .{@tagName(provider)}) catch
        "Pick model (Enter for default):";

    const result = promptNumberedChoice(header, ids, true, default_idx) catch {
        std.debug.print("Cancelled — pass --model to skip the picker.\n", .{});
        return error.UserCancelled;
    };
    if (result) |idx| return try allocator.dupe(u8, ids[idx]);
    // Honor the baked-in default even when it isn't in the listed ids.
    std.debug.print("Using default: {s}\n", .{default_model});
    return try allocator.dupe(u8, default_model);
}

fn interactiveTty() bool {
    return std.posix.isatty(std.posix.STDIN_FILENO) and std.posix.isatty(std.posix.STDERR_FILENO);
}

/// Numbered TTY picker. With `allow_default`, empty input returns null so
/// the caller can substitute its own default; `default_marker_idx` (if set)
/// just renders `(default)` next to that row. Errors with NoChoice after
/// 3 invalid attempts.
fn promptNumberedChoice(header: []const u8, items: []const []const u8, allow_default: bool, default_marker_idx: ?usize) !?usize {
    var stdin_buf: [128]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&stdin_buf);

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        std.debug.print("{s}\n", .{header});
        for (items, 0..) |item, idx| {
            const marker: []const u8 = if (default_marker_idx) |d| (if (d == idx) " (default)" else "") else "";
            std.debug.print("  {d:>3}) {s}{s}\n", .{ idx + 1, item, marker });
        }
        std.debug.print("> ", .{});

        const line = stdin.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.StreamTooLong, error.ReadFailed => return error.UserCancelled,
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) {
            if (allow_default) return null;
            std.debug.print("Invalid input — type a number.\n", .{});
            continue;
        }
        const choice = std.fmt.parseInt(usize, trimmed, 10) catch {
            const hint: []const u8 = if (allow_default) " (or press Enter for default)" else "";
            std.debug.print("Invalid input — type a number{s}.\n", .{hint});
            continue;
        };
        if (choice >= 1 and choice <= items.len) return choice - 1;
        std.debug.print("Out of range.\n", .{});
    }
    return error.NoChoice;
}

// --- Tests ---

test "isHealAllowed: blocks goto and eval_js, allows page-local commands" {
    try std.testing.expect(!isHealAllowed(.{ .goto = "https://x" }));
    try std.testing.expect(!isHealAllowed(.{ .eval_js = "alert(1)" }));

    try std.testing.expect(isHealAllowed(.{ .click = ".btn" }));
    try std.testing.expect(isHealAllowed(.{ .hover = ".menu" }));
    try std.testing.expect(isHealAllowed(.{ .wait = ".loaded" }));
    try std.testing.expect(isHealAllowed(.{ .type_cmd = .{ .selector = "#u", .value = "x" } }));
    try std.testing.expect(isHealAllowed(.{ .select = .{ .selector = "#s", .value = "x" } }));
    try std.testing.expect(isHealAllowed(.{ .check = .{ .selector = "#c", .checked = true } }));
    try std.testing.expect(isHealAllowed(.{ .scroll = .{ .x = 0, .y = 100 } }));
}
