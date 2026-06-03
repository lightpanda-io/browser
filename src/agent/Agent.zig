// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");
const browser_tools = lp.tools;
const BrowserTool = browser_tools.Tool;
const ProviderTool = zenai.provider.Tool;

const log = lp.log;
const Config = lp.Config;
const Command = lp.Command;
const Schema = lp.Schema;
const Recorder = lp.Recorder;
const Credentials = zenai.provider.Credentials;

const App = @import("../App.zig");
const CDPNode = @import("../cdp/Node.zig");
const Terminal = @import("Terminal.zig");
const SlashCommand = @import("SlashCommand.zig");
const ScriptRuntime = @import("ScriptRuntime.zig");
const settings = @import("settings.zig");
const truncateUtf8 = @import("../string.zig").truncateUtf8;

const Agent = @This();

/// Errors raised by Agent.init / listModels where the function has already
/// printed a human-readable message to stderr. Callers should exit non-zero
/// without further logging.
pub const UserError = error{
    MissingApiKey,
    MissingProvider,
    ConflictingFlags,
};

pub fn isUserError(err: anyerror) bool {
    inline for (@typeInfo(UserError).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    return false;
}

const default_system_prompt = browser_tools.driver_guidance ++
    \\
    \\Agent-specific behavior:
    \\- Call a tool for every browser action. NEVER claim you performed an
    \\  action, visited a page, or saw content without the corresponding tool
    \\  call. If a task needs a capability Lightpanda lacks (images, PDFs,
    \\  audio), say so rather than improvising.
    \\- Verify before answering: when a task asks for a specific value, ranked
    \\  list, or comparison, and your first source is ambiguous, incomplete,
    \\  or the answer is non-obvious, cross-check on ONE more authoritative
    \\  source before committing. For multi-candidate questions (yes/no,
    \\  A/B/C, pick-N), commit to a choice — don't abstain when you have data
    \\  to reason from.
    \\- If the user asks for account-scoped data (karma, profile, inbox, …)
    \\  and the page shows you're not signed in, log in proactively (per
    \\  the Credentials section above) before reporting unavailable.
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

const save_synthesis_prompt =
    \\Write a single Lightpanda agent script (.js) that reproduces what the user
    \\was trying to accomplish in this session. Read the whole conversation — the
    \\natural-language requests, the commands, and the raw JS — and infer the
    \\actual goal. Ignore dead ends: failed attempts, retries, exploratory reads
    \\(tree/markdown/extract probes), and corrections. Keep only the steps that
    \\belong in a clean, repeatable script.
    \\Prefer the builtin functions listed below (goto, click, fill, extract, …)
    \\over raw DOM JavaScript wherever they fit; fall back to eval(...) only for
    \\logic the builtins can't express. End with an extract(...) for any data the
    \\user wanted out.
    \\Output ONLY JavaScript source — no markdown fences, no commentary, no prose
    \\before or after.
;

allocator: std.mem.Allocator,
ai_client: ?zenai.provider.Client,
model_credentials: ?Credentials,
model_base_url: ?[:0]const u8,
/// Cached chat-model ids for the current provider, backed by
/// `model_completion_arena` and invalidated on `/provider` switch.
model_completions: ?ModelCompletions,
model_completion_arena: std.heap.ArenaAllocator,
notification: *lp.Notification,
browser: lp.Browser,
session: *lp.Session,
node_registry: CDPNode.Registry,
terminal: Terminal,
recorder: ?Recorder,
save_buffer: Recorder.Memory,
save_path: ?[]u8,
script_runtime_mutex: std.Thread.Mutex = .{},
active_script_runtime: ?*ScriptRuntime = null,
messages: std.ArrayList(zenai.provider.Message),
message_arena: std.heap.ArenaAllocator,
model: []u8,
system_prompt: []const u8,
script_file: ?[]const u8,
interactive: bool,
one_shot_task: ?[]const u8,
one_shot_attachments: ?[]const []const u8,
cancel_requested: std.atomic.Value(bool) = .init(false),
synthetic_tool_call_id: u32 = 0,
/// Aggregate Anthropic/OpenAI/Gemini token usage across every model call
/// this Agent has made. Printed as a structured `$usage ...` line on stderr
/// at the end of `--task` (one-shot) mode so wrappers can capture
/// per-task cost.
total_usage: zenai.provider.Usage = .{},
/// Set when the last turn ended in a model refusal (safety stop).
last_turn_refused: bool = false,
available_providers: []const []const u8,

fn resolveModelName(opts: Config.Agent, resolved: ?settings.ResolvedProvider, remembered: ?settings.Remembered) []const u8 {
    if (opts.model) |m| return m;
    if (resolved) |r| {
        if (r.source == .remembered) {
            if (remembered) |rem| return rem.model;
        }
        return zenai.provider.defaultModel(r.credentials.provider);
    }
    return "";
}

pub fn init(allocator: std.mem.Allocator, app: *App, opts: Config.Agent) !*Agent {
    var providers_buf: [@typeInfo(Config.AiProvider).@"enum".fields.len]Credentials = undefined;
    const found_providers = settings.availableProviders(&providers_buf);
    const available_providers = try allocator.alloc([]const u8, found_providers.len);
    errdefer {
        for (available_providers) |p| allocator.free(p);
        allocator.free(available_providers);
    }
    for (found_providers, 0..) |f, i| {
        available_providers[i] = try allocator.dupe(u8, @tagName(f.provider));
    }

    if (opts.task != null and opts.script_file != null) {
        log.fatal(.app, "conflicting flags", .{
            .hint = "--task runs a one-shot turn; drop the positional script or drop --task",
        });
        return error.ConflictingFlags;
    }
    if (opts.task != null and opts.interactive) {
        log.fatal(.app, "conflicting flags", .{
            .hint = "--task is one-shot and exits; drop --interactive or drop --task",
        });
        return error.ConflictingFlags;
    }
    if (opts.no_llm and opts.provider != null) {
        log.warn(.app, "ignoring --provider", .{ .reason = "--no-llm takes precedence" });
    }
    if (opts.task == null and opts.attach.items.len > 0) {
        log.warn(.app, "ignoring --attach", .{ .reason = "no --task; attachments are only consumed in one-shot mode" });
    }

    const is_one_shot = opts.task != null;
    const will_repl = !is_one_shot and (opts.interactive or opts.script_file == null);

    // Basic-mode REPL (no LLM) must be opted into via --no-llm. Without it,
    // the REPL accepts natural language and an absent API key would only
    // surface at the first non-slash-command line — too late to be useful.
    // Pure JavaScript script runs stay allowed: no REPL, no LLM needed.
    const requires_llm = is_one_shot or (will_repl and !opts.no_llm);

    // Skip resolve when --no-llm forces no client, or no mode could use one
    // (pure script run) — otherwise resolve prints "No API key detected" for a
    // run that does not need one.
    const resolve = !opts.no_llm and requires_llm;
    const remembered: ?settings.Remembered = if (resolve) settings.loadRemembered(allocator) else null;
    defer if (remembered) |r| std.zon.parse.free(allocator, r);

    // Print the banner before provider resolution so it appears before any
    // interactive "Select a provider" prompt.  On error paths (missing key /
    // no key detected) resolveCredentials prints its own message and the
    // banner is skipped.
    if (will_repl and (!resolve or settings.wouldResolve(opts, remembered))) {
        std.debug.print(Terminal.ansi.bold ++ "\n  Lightpanda Agent" ++ Terminal.ansi.reset ++ " " ++ Terminal.ansi.dim ++ "({s})" ++ Terminal.ansi.reset ++ "\n", .{lp.build_config.version});
    }

    const resolved: ?settings.ResolvedProvider = if (resolve) try settings.resolveCredentials(opts, remembered, will_repl) else null;
    const llm: ?Credentials = if (resolved) |r| r.credentials else null;

    if (llm == null and requires_llm) {
        if (opts.no_llm) {
            std.debug.print("--no-llm forbids LLM use; drop it to run this mode.\n", .{});
        }
        return error.MissingProvider;
    }

    const model = try allocator.dupe(u8, resolveModelName(opts, resolved, remembered));
    errdefer allocator.free(model);

    if (resolved) |r| {
        if (r.source == .picked) {
            settings.saveRemembered(r.credentials.provider, model);
        }
        std.debug.print(Terminal.ansi.dim ++ "  Provider: {s}, Model: {s} ", .{ @tagName(r.credentials.provider), model });
        switch (r.source) {
            .flag => {},
            .remembered => std.debug.print("(from ./.lp-agent.zon) ", .{}),
            .detected => std.debug.print("(auto-selected) ", .{}),
            .picked => std.debug.print("(saved to /.lp-agent.zon) ", .{}),
        }
        std.debug.print("\n\n" ++ Terminal.ansi.reset, .{});
    }

    const notification: *lp.Notification = try .init(allocator);
    errdefer notification.deinit();

    const self = try allocator.create(Agent);
    errdefer allocator.destroy(self);

    const history_path: ?[:0]const u8 = if (will_repl) ".lp-history" else null;

    // `-i <file>` means "run then grow this file"; a script path alone is
    // a pure script run and must not be mutated.
    const recorder_path: ?[]const u8 = if (opts.interactive) opts.script_file else null;

    self.* = .{
        .allocator = allocator,
        .ai_client = null,
        .model_credentials = llm,
        .model_base_url = opts.base_url,
        .model_completions = null,
        .model_completion_arena = .init(allocator),
        .notification = notification,
        .browser = undefined,
        .session = undefined,
        .node_registry = .init(allocator),
        .terminal = .init(allocator, history_path, Config.agentVerbosity(opts), will_repl),
        .recorder = null,
        .save_buffer = .init(allocator),
        .save_path = null,
        .messages = .empty,
        .message_arena = .init(allocator),
        .model = model,
        .system_prompt = opts.system_prompt orelse default_system_prompt,
        .script_file = opts.script_file,
        .interactive = opts.interactive,
        .one_shot_task = opts.task,
        .one_shot_attachments = if (opts.attach.items.len == 0) null else opts.attach.items,
        .available_providers = available_providers,
    };
    errdefer self.node_registry.deinit();
    errdefer self.terminal.deinit();
    errdefer self.message_arena.deinit();
    self.terminal.installLogSink();
    errdefer self.terminal.uninstallLogSink();

    try self.browser.init(app, .{}, null);
    errdefer self.browser.deinit();

    self.session = try self.browser.newSession(notification);
    self.session.cancel_hook = .{ .context = @ptrCast(self), .check = checkCancel };

    self.ai_client = if (llm) |l| try zenai.provider.Client.init(allocator, l, .{ .base_url = opts.base_url, .retry_policy = .long_running }) else null;
    errdefer if (self.ai_client) |c| c.deinit(allocator);

    // An LLM driver reasons about visibility/computed styles, so fetch external
    // stylesheets by default. Pure script runs and --no-llm keep the cheap fast path.
    // The --enable-external-stylesheets flag is already folded into the session
    // default, so this only ever turns the feature on.
    if (self.ai_client != null) {
        self.session.load_external_stylesheets = true;
    }

    if (will_repl) {
        self.terminal.attachCompleter();
        self.terminal.completion_source = .{
            .context = @ptrCast(self),
            .providers = completionProviders,
            .models = completionModels,
        };
        // Warm the model-list cache so the first autocomplete keystroke doesn't
        // block on the network.
        if (self.model_credentials != null) _ = completionModels(self, allocator);
    }

    if (recorder_path) |p| {
        if (Recorder.init(allocator, std.fs.cwd(), p)) |r| {
            self.recorder = r;
            self.terminal.printInfo("recording to {s}", .{r.path});
        } else |err| {
            self.terminal.printError("recording disabled: {s}", .{@errorName(err)});
        }
    }

    return self;
}

pub fn deinit(self: *Agent) void {
    self.terminal.uninstallLogSink();
    if (self.recorder) |*r| r.deinit();
    self.save_buffer.deinit();
    if (self.save_path) |p| self.allocator.free(p);
    self.terminal.deinit();
    self.message_arena.deinit();
    self.model_completion_arena.deinit();
    self.messages.deinit(self.allocator);
    self.node_registry.deinit();
    self.browser.deinit();
    self.notification.deinit();
    if (self.ai_client) |ai_client| ai_client.deinit(self.allocator);
    self.allocator.free(self.model);
    for (self.available_providers) |p| self.allocator.free(p);
    self.allocator.free(self.available_providers);
    self.allocator.destroy(self);
}

// Tool definitions are compile-time constant; project them once per process.
var global_tools_storage: [browser_tools.tool_defs.len]ProviderTool = undefined;
var global_tools_once = std.once(initGlobalTools);

fn initGlobalTools() void {
    for (Schema.all(), 0..) |s, i| {
        global_tools_storage[i] = .{ .name = s.tool_name, .description = s.description, .parameters = s.parameters };
    }
}

fn globalTools() []const ProviderTool {
    global_tools_once.call();
    return global_tools_storage[0..browser_tools.tool_defs.len];
}

/// Called from the sighandler thread. Flips `cancel_requested` for the
/// LLM streaming/HTTP probe and any code polling `Session.isCancelled`,
/// then asks V8 to bail out of whatever JS is currently running. Both
/// hooks are thread-safe (`Env.terminate` takes a mutex); no terminal
/// touches from this context.
pub fn requestCancel(self: *Agent) void {
    self.cancel_requested.store(true, .release);
    {
        self.script_runtime_mutex.lock();
        defer self.script_runtime_mutex.unlock();
        if (self.active_script_runtime) |runtime| {
            runtime.terminate();
        }
    }
    self.browser.env.terminate();
}

/// Lives in main's stack so it can be registered with the sighandler
/// before the agent thread exists. The agent attaches itself once it's
/// constructed and detaches before deinit, so the sighandler-thread
/// listener can fire safely whether or not an agent is currently up.
pub const SigBridge = struct {
    agent: std.atomic.Value(?*Agent) = .init(null),

    pub fn attach(self: *SigBridge, agent: *Agent) void {
        self.agent.store(agent, .release);
    }

    pub fn detach(self: *SigBridge) void {
        self.agent.store(null, .release);
    }

    pub fn onSignal(self: *SigBridge) void {
        const a = self.agent.load(.acquire) orelse return;
        a.requestCancel();
    }
};

fn checkCancel(ctx: *anyopaque) bool {
    const self: *Agent = @ptrCast(@alignCast(ctx));
    return self.cancel_requested.load(.acquire);
}

/// Roll the agent back to `baseline` messages, clear the V8 termination
/// flag, drop the cancel signal, and surface `error.UserCancelled` to the
/// caller. Caller is responsible for any spinner cleanup that hasn't
/// already happened on its path.
fn drainCancellation(self: *Agent, baseline: usize) error{UserCancelled} {
    self.resetAfterCancel(baseline);
    return error.UserCancelled;
}

/// The side effects of `drainCancellation` without surfacing the error, for
/// void callers (e.g. `/save` synthesis) that just need to clean up.
fn resetAfterCancel(self: *Agent, baseline: usize) void {
    self.rollbackMessages(baseline);
    self.browser.env.cancelTerminate();
    self.cancel_requested.store(false, .release);
}

/// One agent turn: the prompt sent to the model, plus optional context
/// (a recorder comment to write before the turn, file attachments to bundle
/// into the first user message, and a display label used in error output).
pub const TurnInput = struct {
    prompt: []const u8,
    record_comment: ?[]const u8 = null,
    capture_for_save: bool = false,
    attachments: ?[]const []const u8 = null,
    label: []const u8 = "Request",
};

/// Returns true on success.
pub fn run(self: *Agent) bool {
    if (self.one_shot_task) |task| {
        const ok = self.runTurn(.{
            .prompt = task,
            .attachments = self.one_shot_attachments,
        });
        self.printUsageSummary();
        return ok;
    }
    if (self.script_file) |path| {
        const script_ok = self.runScript(path);
        if (!self.interactive) return script_ok;
    }
    self.runRepl();
    return true;
}

/// Print a single-line summary of cumulative token usage to stderr, so
/// wrappers driving `lightpanda agent --task ...` can capture per-task cost
/// by `grep`-ing for the `$usage` prefix. Format is stable and key=value:
///   $usage prompt=N completion=N total=N cached=N cache_creation=N
/// Fields are emitted with value 0 when the provider didn't report them.
fn printUsageSummary(self: *Agent) void {
    const u = self.total_usage;
    std.debug.print(
        "$usage prompt={d} completion={d} total={d} cached={d} cache_creation={d}\n",
        .{
            u.prompt_tokens orelse 0,
            u.completion_tokens orelse 0,
            u.total_tokens orelse 0,
            u.cached_tokens orelse 0,
            u.cache_creation_tokens orelse 0,
        },
    );
}

fn runTurn(self: *Agent, input: TurnInput) bool {
    const text = self.processUserMessage(input) catch |err| switch (err) {
        error.UnsupportedAttachment, error.AttachmentReadFailed => return false,
        error.UserCancelled => {
            self.terminal.printInfo("Interrupted.", .{});
            self.pruneMessages();
            return false;
        },
        else => {
            self.terminal.printError("{s} failed: {s}", .{ input.label, @errorName(err) });
            return false;
        },
    };
    if (text) |t|
        self.terminal.printAssistant(t)
    else if (self.last_turn_refused)
        self.terminal.printInfo("(model declined to respond — safety refusal)", .{})
    else
        self.terminal.printInfo("(no response from model)", .{});
    self.pruneMessages();
    return true;
}

fn runRepl(self: *Agent) void {
    if (self.ai_client) |_| {
        self.terminal.printItalic("  Use natural language or slash commands", .{});
    } else {
        self.terminal.printItalic("  Basic REPL (--no-llm) - slash commands only.", .{});
        self.terminal.printDimmed("  To enable natural language, " ++ llm_setup_hint ++ ".", .{});
    }
    self.terminal.printDimmed("  /help to list slash commands\t\t\tTab completes/cycles through commands", .{});
    self.terminal.printDimmed("  /quit to exit", .{});
    self.terminal.printDimmed("  ! for JS mode (eval against the page)\t\tEsc exits JS mode", .{});
    // self.terminal.printInfo("", .{});
    log.debug(.app, "tools loaded", .{ .count = globalTools().len });

    repl: while (true) {
        std.debug.print("\n", .{});
        const line = Terminal.readLine("") orelse break;
        defer Terminal.freeLine(line);
        std.debug.print("\n", .{});

        // Slash commands and idle Ctrl-C set the cancel flag without
        // clearing V8's terminate state; drain both before the next turn.
        if (self.cancel_requested.swap(false, .acq_rel)) {
            self.browser.env.cancelTerminate();
        }

        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // JS mode: evaluate the whole line against the page, bypassing command parsing.
        if (self.terminal.jsMode()) {
            // `line` keeps the `$LP_*` placeholder so the secret never reaches
            // the recorder; only the evaluated copy is expanded.
            const script = browser_tools.substituteEnvVars(aa, line) catch line;
            const result = browser_tools.evalScript(aa, self.session, &self.node_registry, script) catch |err| {
                self.terminal.printError("{s}", .{switch (err) {
                    error.OutOfMemory => "out of memory",
                    error.FrameNotLoaded => "no page loaded — run /goto <url> first (Esc exits JS mode)",
                    else => std.fmt.allocPrint(aa, "eval failed: {s}", .{@errorName(err)}) catch "eval failed",
                }});
                continue :repl;
            };
            // Surface console output: slash commands (and thus /consoleLogs) are
            // unreachable in JS mode, so a console must echo logs itself.
            const logs = std.mem.trimRight(u8, self.session.drainConsoleMessages(), "\n");
            if (logs.len > 0) self.printData(logs);
            if (result.is_error) {
                self.terminal.printError("{s}", .{result.text});
            } else {
                self.printData(result.text);
                if (self.recorder) |*r| r.recordRaw(line);
                self.recordSaveRaw(line);
            }
            continue :repl;
        }

        const slash_split: ?Schema.Split = Schema.parseSlashCommand(trimmed);
        if (slash_split) |split| {
            if (SlashCommand.findMeta(split.name)) |meta| {
                if (self.handleMeta(aa, meta, split.rest)) break :repl;
                continue :repl;
            }
        }

        var diag: Schema.Diag = .{};
        const cmd = Command.parseDiag(aa, line, &diag) catch |err| switch (err) {
            error.NotASlashCommand => {
                if (self.ai_client == null) {
                    self.terminal.printError("Basic REPL (--no-llm) accepts only commands. Try /help, or " ++ llm_setup_hint ++ " to enable natural-language prompts.", .{});
                    continue :repl;
                }
                _ = self.runTurn(.{ .prompt = line, .record_comment = line, .capture_for_save = true });
                continue :repl;
            },
            else => |e| {
                const name = if (slash_split) |sp| sp.name else line;
                self.terminal.printSlashParseError(e, name, &diag);
                continue :repl;
            },
        };

        if (cmd == .llm) {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "/{s}", .{@tagName(cmd.llm)}) catch "/?";
            if (!self.requireLlm(name)) continue :repl;
        }

        switch (cmd) {
            .comment => continue :repl,
            .llm => |lc| {
                var label_buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "/{s}", .{@tagName(lc)}) catch "/?";
                _ = self.runTurn(.{ .prompt = lc.prompt(), .record_comment = line, .capture_for_save = true, .label = label });
            },
            .tool_call => |tc| {
                self.terminal.beginTool(tc.name(), slash_split.?.rest);
                const result = self.runCommand(aa, cmd);
                self.terminal.endTool();
                self.printCommandResult(cmd, result);
                if (!result.is_error) {
                    if (self.recorder) |*r| r.record(cmd);
                    self.recordSaveCommand(cmd);
                }
                self.recordSlashToolCall(trimmed, tc.name(), tc.args, result) catch |err| {
                    self.terminal.printWarning("LLM conversation out of sync (/{s}: {s}); next prompt may not see this action", .{ tc.name(), @errorName(err) });
                };
            },
        }
    }

    self.terminal.printInfo("Goodbye!", .{});
}

/// Handle a REPL-only meta slash command. These aren't tool slash commands
/// and never reach the browser tool dispatcher. Returns `true` if the user
/// asked to quit.
fn handleMeta(self: *Agent, arena: std.mem.Allocator, meta: *const SlashCommand.MetaCommand, rest: []const u8) bool {
    switch (meta.tag) {
        .quit => return true,
        .help => self.printSlashHelp(arena, rest),
        .verbosity => self.handleVerbosity(rest),
        .save => self.handleSave(arena, rest),
        .model => self.handleModel(arena, rest),
        .provider => self.handleProvider(arena, rest),
    }
    return false;
}

fn handleVerbosity(self: *Agent, rest: []const u8) void {
    if (rest.len == 0) {
        self.terminal.printInfo("verbosity: {s}", .{@tagName(self.terminal.verbosity)});
        return;
    }
    const level = std.meta.stringToEnum(Config.AgentVerbosity, rest) orelse {
        self.terminal.printError("usage: /verbosity <low|medium|high> (got {s})", .{rest});
        return;
    };
    self.terminal.verbosity = level;
    self.terminal.printInfo("verbosity: {s}", .{@tagName(level)});
}

const api_keys_hint = settings.api_keys_hint;
const llm_setup_hint = "drop --no-llm and set an API key (" ++ api_keys_hint ++ ")";

fn requireLlm(self: *Agent, name: []const u8) bool {
    if (self.model_credentials == null) {
        self.terminal.printError("{s} requires an LLM — " ++ llm_setup_hint ++ ".", .{name});
        return false;
    }
    return true;
}

fn handleModel(self: *Agent, _: std.mem.Allocator, rest: []const u8) void {
    if (!self.requireLlm("/model")) return;

    const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        self.terminal.printInfo("Current model: {s} (Tab to list)", .{self.model});
        return;
    }
    self.setModel(trimmed) catch |err| {
        self.terminal.printError("failed to set model: {s}", .{@errorName(err)});
    };
}

fn setModel(self: *Agent, model: []const u8) !void {
    const new_model = try self.allocator.dupe(u8, model);
    self.allocator.free(self.model);
    self.model = new_model;
    if (self.model_credentials) |c| settings.saveRemembered(c.provider, self.model);
    self.terminal.printInfo("model: {s}", .{self.model});
}

fn handleProvider(self: *Agent, _: std.mem.Allocator, rest: []const u8) void {
    if (!self.requireLlm("/provider")) return;
    const current = self.model_credentials.?;

    const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        self.terminal.printInfo("Current provider: {s} (Tab to list)", .{@tagName(current.provider)});
        return;
    }

    const provider = std.meta.stringToEnum(Config.AiProvider, trimmed) orelse {
        self.terminal.printError("unknown provider: {s}", .{trimmed});
        return;
    };
    if (provider == current.provider) {
        self.terminal.printInfo("provider: {s}", .{@tagName(provider)});
        return;
    }
    const key = zenai.provider.envApiKey(provider) orelse {
        self.terminal.printError("no API key for {s}; set {s}", .{ @tagName(provider), zenai.provider.envVarName(provider) });
        return;
    };
    self.setProvider(.{ .provider = provider, .key = key }) catch |err| {
        self.terminal.printError("failed to set provider: {s}", .{@errorName(err)});
    };
}

fn setProvider(self: *Agent, credentials: Credentials) !void {
    const new_client = try zenai.provider.Client.init(self.allocator, credentials, .{ .base_url = self.model_base_url, .retry_policy = .long_running });
    errdefer new_client.deinit(self.allocator);

    const new_model = try self.allocator.dupe(u8, zenai.provider.defaultModel(credentials.provider));
    if (self.ai_client) |client| client.deinit(self.allocator);
    self.ai_client = new_client;
    self.model_credentials = credentials;
    self.model_completions = null;
    self.allocator.free(self.model);
    self.model = new_model;
    settings.saveRemembered(credentials.provider, self.model);
    self.terminal.printInfo("provider: {s}", .{@tagName(credentials.provider)});
    self.terminal.printInfo("model: {s}", .{self.model});
    _ = completionModels(self, self.allocator);
}

const SaveMode = enum { replace, append };

const PathAndMode = struct { path: []const u8, mode: SaveMode };

fn resolveSavePathAndMode(self: *Agent, arena: std.mem.Allocator, filename: ?[]const u8) ?PathAndMode {
    if (self.save_path) |saved| {
        if (filename) |name| {
            if (!std.mem.eql(u8, saved, name)) {
                self.terminal.printError("already saving to {s}; use /save without a filename to append to it", .{saved});
                return null;
            }
        }
        return .{ .path = saved, .mode = .append };
    } else if (filename) |name| {
        const exists = fileExists(name) catch |err| {
            self.terminal.printError("failed to inspect {s}: {s}", .{ name, @errorName(err) });
            return null;
        };
        const mode = if (exists)
            self.promptSaveMode(name) orelse return null
        else
            .replace;
        return .{ .path = name, .mode = mode };
    } else {
        const path = randomSaveFilename(arena) catch |err| {
            self.terminal.printError("failed to choose save filename: {s}", .{@errorName(err)});
            return null;
        };
        return .{ .path = path, .mode = .replace };
    }
}

fn handleSave(self: *Agent, arena: std.mem.Allocator, rest: []const u8) void {
    const parsed = parseSaveCommand(rest) catch |err| {
        const msg: []const u8 = switch (err) {
            error.UnterminatedQuote => "unterminated filename quote",
            error.EmptyFilename => "filename cannot be empty",
            error.InvalidFilename => "filename must be a local file name, not a path",
        };
        self.terminal.printError("{s}", .{msg});
        return;
    };

    // With a client, synthesize an idiomatic script from the session intent;
    // the trailing prompt is optional extra steering.
    if (self.ai_client != null) {
        self.synthesizeSave(arena, parsed.filename, parsed.prompt);
        return;
    }

    if (parsed.prompt != null) {
        self.terminal.printWarning("prompt ignored without an LLM; saving the recorded commands as-is", .{});
    }
    const resolved = self.resolveSavePathAndMode(arena, parsed.filename) orelse return;
    const path = resolved.path;
    const mode = resolved.mode;

    // `path` aliases either an arena-owned string (first save) or
    // `self.save_path` (subsequent saves to the same destination); only
    // the former needs to be persisted into agent-owned memory.
    var new_save_path: ?[]u8 = if (self.save_path == null)
        self.allocator.dupe(u8, path) catch |err| {
            self.terminal.printError("failed to remember save destination {s}: {s}", .{ path, @errorName(err) });
            return;
        }
    else
        null;
    defer if (new_save_path) |p| self.allocator.free(p);

    self.writeSaveFile(path, mode) catch |err| {
        self.terminal.printError("failed to save {s}: {s}", .{ path, @errorName(err) });
        return;
    };

    if (new_save_path) |p| {
        self.save_path = p;
        new_save_path = null;
    }
    const saved_lines = self.save_buffer.lines;
    self.save_buffer.reset();
    self.terminal.printInfo("Saved {d} line(s) to {s}", .{ saved_lines, self.save_path.? });
}

const SaveCommand = struct { filename: ?[]const u8, prompt: ?[]const u8 };

/// Split `/save` arguments into an optional filename and an optional trailing
/// natural-language prompt. A quoted leading token is always a filename; an
/// unquoted one is a filename only if it ends in `.js` (otherwise the whole
/// argument is the prompt, and a name is chosen automatically).
fn parseSaveCommand(rest: []const u8) !SaveCommand {
    const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);
    if (trimmed.len == 0) return .{ .filename = null, .prompt = null };

    if (trimmed[0] == '\'' or trimmed[0] == '"') {
        const quote = trimmed[0];
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, quote) orelse return error.UnterminatedQuote;
        const name = trimmed[1..end];
        try validateSaveFilename(name);
        const rest_prompt = std.mem.trim(u8, trimmed[end + 1 ..], &std.ascii.whitespace);
        return .{ .filename = name, .prompt = if (rest_prompt.len == 0) null else rest_prompt };
    }

    const tok_end = std.mem.indexOfAny(u8, trimmed, &std.ascii.whitespace) orelse trimmed.len;
    const first = trimmed[0..tok_end];
    if (std.mem.endsWith(u8, first, ".js")) {
        try validateSaveFilename(first);
        const rest_prompt = std.mem.trim(u8, trimmed[tok_end..], &std.ascii.whitespace);
        return .{ .filename = first, .prompt = if (rest_prompt.len == 0) null else rest_prompt };
    }
    return .{ .filename = null, .prompt = trimmed };
}

fn validateSaveFilename(name: []const u8) !void {
    if (name.len == 0) return error.EmptyFilename;
    if (std.fs.path.isAbsolute(name)) return error.InvalidFilename;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidFilename;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.InvalidFilename;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidFilename;
}

fn randomSaveFilename(arena: std.mem.Allocator) ![]const u8 {
    for (0..100) |_| {
        const n = std.crypto.random.int(u64);
        const path = try std.fmt.allocPrint(arena, "session-{x}.js", .{n});
        if (!(try fileExists(path))) return path;
    }
    return error.NameCollision;
}

fn fileExists(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn promptSaveMode(self: *Agent, path: []const u8) ?SaveMode {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} already exists. Pick save mode:", .{path}) catch
        "File already exists. Pick save mode:";
    const labels: []const []const u8 = &.{ "replace", "append" };
    const idx = Terminal.promptNumberedChoice(header, labels, null) catch {
        self.terminal.printInfo("Save cancelled.", .{});
        return null;
    };
    return if (idx == 0) .replace else .append;
}

fn writeSaveFile(self: *Agent, path: []const u8, mode: SaveMode) !void {
    return writeContentFile(path, self.save_buffer.bytes(), mode);
}

fn writeContentFile(path: []const u8, content: []const u8, mode: SaveMode) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = mode == .replace });
    defer file.close();
    if (mode == .append) {
        try file.seekFromEnd(0);
        const pos = try file.getPos();
        if (pos > 0 and content.len > 0) try file.writeAll("\n");
    }
    try file.writeAll(content);
    if (content.len > 0 and content[content.len - 1] != '\n') try file.writeAll("\n");
}

fn failSave(self: *Agent, reason: []const u8) void {
    self.terminal.printError("save failed: {s}", .{reason});
}

/// LLM-synthesized `/save`: hand the model the builtin catalog, the full
/// conversation, and the deterministic record of what ran, then write the
/// idiomatic script it returns. Always replaces the target file.
fn synthesizeSave(self: *Agent, arena: std.mem.Allocator, filename: ?[]const u8, prompt: ?[]const u8) void {
    const provider_client = self.ai_client.?;

    const path: []const u8 = blk: {
        if (filename) |f| break :blk f;
        if (self.save_path) |p| break :blk p;
        break :blk randomSaveFilename(arena) catch |err| {
            self.terminal.printError("failed to choose save filename: {s}", .{@errorName(err)});
            return;
        };
    };

    self.ensureSystemPrompt() catch return self.failSave("out of memory");

    const ma = self.message_arena.allocator();
    const baseline = self.messages.items.len;

    const user_msg = self.buildSaveSynthesisMessage(ma, prompt) catch return self.failSave("out of memory");
    self.messages.append(self.allocator, .{ .role = .user, .content = user_msg }) catch return self.failSave("out of memory");

    self.terminal.spinner.start();
    var result = provider_client.runTools(
        self.model,
        &self.messages,
        self.allocator,
        ma,
        .{ .context = @ptrCast(self), .callFn = handleToolCall },
        .{
            .tools = &.{},
            .max_turns = 1,
            .max_tokens = 8192,
            .tool_choice = .none,
            .thinking_level = .medium,
            .cancel = .{ .context = @ptrCast(self), .checkFn = checkCancel },
        },
    ) catch |err| {
        self.terminal.spinner.cancel();
        if (self.cancel_requested.load(.acquire)) {
            self.resetAfterCancel(baseline);
            return;
        }
        log.err(.app, "AI save synthesis error", .{ .err = err });
        self.rollbackMessages(baseline);
        return self.failSave(@errorName(err));
    };
    self.terminal.spinner.stop();
    defer result.deinit();
    self.total_usage.add(result.usage);

    if (result.cancelled) {
        self.resetAfterCancel(baseline);
        return;
    }

    const raw = result.text orelse {
        self.rollbackMessages(baseline);
        return self.failSave("the model returned no script");
    };

    // `result.text` lives in `message_arena`, which the rollback below frees;
    // copy into the command arena first (scrubbing may return its input as-is).
    const owned = arena.dupe(u8, stripCodeFence(raw)) catch {
        self.rollbackMessages(baseline);
        return self.failSave("out of memory");
    };
    const script = browser_tools.reverseSubstituteEnvVars(arena, owned) catch {
        self.rollbackMessages(baseline);
        return self.failSave("out of memory");
    };

    // The save turn is a meta-action; keep it out of the ongoing conversation.
    self.rollbackMessages(baseline);

    writeContentFile(path, script, .replace) catch |err| {
        self.terminal.printError("failed to save {s}: {s}", .{ path, @errorName(err) });
        return;
    };

    self.rememberSavePath(path);
    self.save_buffer.reset();
    self.terminal.printInfo("Saved synthesized script to {s}", .{path});
}

/// Persist `path` as the destination reused by a subsequent bare `/save`.
fn rememberSavePath(self: *Agent, path: []const u8) void {
    if (self.save_path) |old| {
        if (std.mem.eql(u8, old, path)) return;
    }
    const dup = self.allocator.dupe(u8, path) catch return;
    if (self.save_path) |old| self.allocator.free(old);
    self.save_path = dup;
}

fn buildSaveSynthesisMessage(self: *Agent, arena: std.mem.Allocator, prompt: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(save_synthesis_prompt);
    try w.writeAll("\n\nBuiltin functions to prefer (call them as JS functions):\n");
    try renderBuiltinCatalog(w);
    const recorded = self.save_buffer.bytes();
    if (recorded.len > 0) {
        try w.writeAll("\nCommands and JS that actually ran this session:\n");
        try w.writeAll(recorded);
    }
    if (prompt) |p| {
        try w.writeAll("\nThe user's instruction for this script:\n");
        try w.writeAll(p);
    }
    return out.written();
}

/// Document the recorded browser tools — the subset callable from a saved
/// script — with their full descriptions, so the model gets each function's
/// argument dialect (e.g. `extract`'s schema format) without being handed the
/// tool schemas a no-tools synthesis turn omits.
fn renderBuiltinCatalog(w: *std.Io.Writer) !void {
    for (Schema.all()) |s| {
        if (!s.tool.isRecorded()) continue;
        try w.print("\n{s}(", .{s.tool_name});
        for (s.required, 0..) |req, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll(req);
        }
        try w.print("):\n{s}\n", .{s.description});
    }
}

/// Strip a surrounding ```` ```lang … ``` ```` markdown fence if the model
/// wrapped its output in one despite being told not to.
fn stripCodeFence(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, t, "```")) return t;
    const first_nl = std.mem.indexOfScalar(u8, t, '\n') orelse return t;
    const body = t[first_nl + 1 ..];
    const close = std.mem.lastIndexOf(u8, body, "```") orelse return std.mem.trim(u8, body, &std.ascii.whitespace);
    return std.mem.trim(u8, body[0..close], &std.ascii.whitespace);
}

fn logSaveBufferError(self: *Agent, err: anyerror) void {
    self.terminal.printError("save buffer disabled: {s}", .{@errorName(err)});
}

fn recordSaveCommand(self: *Agent, cmd: Command) void {
    self.save_buffer.record(cmd) catch |err| self.logSaveBufferError(err);
}

fn recordSaveComment(self: *Agent, comment: []const u8) void {
    self.save_buffer.recordComment(comment) catch |err| self.logSaveBufferError(err);
}

fn recordSaveRaw(self: *Agent, line: []const u8) void {
    self.save_buffer.recordRaw(line) catch |err| self.logSaveBufferError(err);
}

fn printSlashHelp(self: *Agent, arena: std.mem.Allocator, target: []const u8) void {
    if (target.len == 0) {
        const all = Schema.all();
        const browser = arena.alloc(SlashCommand.Help, all.len) catch return;
        for (all, browser) |*s, *e| e.* = .{ .name = s.tool_name, .description = s.summary };
        self.terminal.printHelpSection("Browser commands:", browser);

        if (self.ai_client != null) {
            const llm = arena.alloc(SlashCommand.Help, SlashCommand.llm_commands.len) catch return;
            @memcpy(llm, &SlashCommand.llm_commands);
            self.terminal.printHelpSection("\nLLM commands:", llm);
        }

        const meta = arena.alloc(SlashCommand.Help, SlashCommand.meta_commands.len) catch return;
        for (SlashCommand.meta_commands, meta) |m, *e| e.* = .{ .name = m.name, .description = m.description };
        self.terminal.printHelpSection("\nMeta commands:", meta);
        return;
    }
    if (SlashCommand.findMeta(target)) |meta| {
        switch (meta.tag) {
            .help => self.terminal.printInfo("/help [name] — show help for a command, or list all when [name] is omitted", .{}),
            .quit => self.terminal.printInfo("/quit — exit the REPL", .{}),
            .verbosity => self.terminal.printInfo(
                "/verbosity <low|medium|high> — set REPL agent verbosity (currently: {s}). Bare /verbosity prints the level.",
                .{@tagName(self.terminal.verbosity)},
            ),
            .save => self.terminal.printInfo(
                "/save [filename.js] [prompt] — save the session to [filename.js] (a random session-*.js if omitted). With an LLM, synthesizes an idiomatic script from the session and the optional prompt; with --no-llm, dumps the recorded actions verbatim.",
                .{},
            ),
            .model => self.terminal.printInfo(
                "/model [name] — change the model; Tab completes the provider's models, bare /model shows the current one",
                .{},
            ),
            .provider => self.terminal.printInfo(
                "/provider [name] — change the provider; Tab completes detected providers, bare /provider shows the current one",
                .{},
            ),
        }
        return;
    }
    const tool_schema = Schema.findByName(target) orelse {
        if (Terminal.closestCommand(target)) |near| {
            self.terminal.printError("unknown command: {s}. Did you mean " ++ Terminal.highlightCmd("/help {s}") ++ "?", .{ target, near });
        } else {
            self.terminal.printError("unknown command: {s}", .{target});
        }
        return;
    };
    self.terminal.printInfo("/{s} — {s}", .{ tool_schema.tool_name, tool_schema.description });

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(tool_schema.parameters, .{ .whitespace = .indent_2 }, &aw.writer) catch return;
    self.terminal.printInfo("schema:\n{s}", .{aw.written()});
}

/// Caller contract: `cmd` must be `.tool_call` — `.comment` and `.llm` are
/// filtered upstream because they have no tool mapping.
fn runCommand(self: *Agent, arena: std.mem.Allocator, cmd: Command) browser_tools.ToolResult {
    const tc = switch (cmd) {
        .tool_call => |t| t,
        else => return .{ .text = "internal: command has no tool mapping", .is_error = true },
    };
    return browser_tools.call(arena, self.session, &self.node_registry, tc.name(), tc.args) catch |err| .{
        .text = switch (err) {
            error.OutOfMemory => "out of memory",
            error.FrameNotLoaded => "no page loaded — run /goto <url> first",
            else => std.fmt.allocPrint(arena, "{s} failed: {s}", .{ tc.name(), @errorName(err) }) catch "tool failed",
        },
        .is_error = true,
    };
}

/// Data output (/extract, /eval, /markdown, /tree, …) → plain stdout on
/// success so a caller can pipe it. Everything else routes through
/// `printToolOutcome`, which lays down the green ● / red ● dot shared
/// with the LLM tool-call path. Callers only invoke this for `.tool_call`
/// commands (the comment/login/acceptCookies branches take other paths).
fn printCommandResult(self: *Agent, cmd: Command, result: browser_tools.ToolResult) void {
    const tc = switch (cmd) {
        .tool_call => |t| t,
        else => return,
    };
    if (cmd.producesData() and !result.is_error) {
        self.printData(result.text);
        return;
    }
    self.terminal.printToolOutcome(tc.name(), result.text, result.is_error);
}

// Re-indent JSON for the terminal; MCP keeps renderJson's compact form.
fn printData(self: *Agent, text: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    self.terminal.printAssistant(Terminal.reindentJson(arena.allocator(), text) orelse text);
}

fn runScript(self: *Agent, path: []const u8) bool {
    self.terminal.printInfo("Running script: {s}", .{path});

    var script_arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer script_arena.deinit();

    const content = std.fs.cwd().readFileAlloc(script_arena.allocator(), path, 10 * 1024 * 1024) catch |err| {
        self.terminal.printError("Failed to read script '{s}': {s}", .{ path, @errorName(err) });
        return false;
    };

    const runtime = ScriptRuntime.init(self.allocator, self.browser.app, self.session, &self.node_registry) catch |err| {
        self.terminal.printError("Failed to initialize script runtime: {s}", .{@errorName(err)});
        return false;
    };
    defer runtime.deinit();
    self.script_runtime_mutex.lock();
    self.active_script_runtime = runtime;
    self.script_runtime_mutex.unlock();
    defer {
        self.script_runtime_mutex.lock();
        self.active_script_runtime = null;
        self.script_runtime_mutex.unlock();
        runtime.cancelTerminate();
        self.browser.env.cancelTerminate();
        self.cancel_requested.store(false, .release);
    }

    if (runtime.runSource(content, path) catch |err| {
        self.terminal.printError("Script failed: {s}", .{@errorName(err)});
        return false;
    }) |message| {
        self.terminal.printError("{s}", .{message});
        return false;
    }

    self.terminal.printInfo("Script completed.", .{});
    return true;
}

fn ensureSystemPrompt(self: *Agent) !void {
    if (self.messages.items.len == 0) {
        try self.messages.append(self.allocator, .{
            .role = .system,
            .content = self.system_prompt,
        });
    }
}

/// Mirror a user-typed slash command into `self.messages` as if the LLM
/// had called the tool itself, so the next natural-language turn sees
/// the same conversation shape either way.
fn recordSlashToolCall(
    self: *Agent,
    user_input: []const u8,
    tool_name: []const u8,
    args: ?std.json.Value,
    result: browser_tools.ToolResult,
) !void {
    if (self.ai_client == null) return;
    try self.ensureSystemPrompt();

    const ma = self.message_arena.allocator();
    self.synthetic_tool_call_id += 1;

    const user_content = try ma.dupe(u8, user_input);

    const tool_calls = try ma.alloc(zenai.provider.ToolCall, 1);
    tool_calls[0] = .{
        .id = try std.fmt.allocPrint(ma, "lp-slash-{d}", .{self.synthetic_tool_call_id}),
        .name = try ma.dupe(u8, tool_name),
        .arguments = if (args) |v| try zenai.json.dupeValue(ma, v) else null,
    };

    // capToolOutput returns its input unchanged under the cap; dupe so
    // content doesn't alias the caller's per-iteration arena.
    const capped = capToolOutput(ma, result.text);
    const content = if (capped.ptr == result.text.ptr) try ma.dupe(u8, capped) else capped;

    const tool_results = try ma.alloc(zenai.provider.ToolResult, 1);
    tool_results[0] = .{
        .id = try ma.dupe(u8, tool_calls[0].id),
        .name = try ma.dupe(u8, tool_calls[0].name),
        .content = content,
        .is_error = result.is_error,
    };

    const baseline = self.messages.items.len;
    errdefer self.messages.shrinkRetainingCapacity(baseline);
    // User turn before the assistant tool_call satisfies Gemini's rule
    // that a function call must follow a user or function-response turn.
    try self.messages.append(self.allocator, .{
        .role = .user,
        .content = user_content,
    });
    try self.messages.append(self.allocator, .{
        .role = .assistant,
        .tool_calls = tool_calls,
    });
    try self.messages.append(self.allocator, .{
        .role = .tool,
        .tool_results = tool_results,
    });
}

const prune_high = 30;
const prune_keep = 20;

fn pruneMessages(self: *Agent) void {
    const msgs = self.messages.items;
    if (msgs.len <= prune_high) return;

    const tail_start = zenai.provider.safeTruncationStart(msgs, msgs.len - prune_keep) orelse return;

    // Dupe into the new arena before mutating self.messages — a partial
    // failure would otherwise leave items pointing into a freed arena.
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

/// Shrink `self.messages` back to `baseline` and rebuild the arena. Used
/// after a failed turn (API error, synthesis) so the next turn doesn't
/// replay the dropped messages and the arena doesn't accumulate their bytes.
fn rollbackMessages(self: *Agent, baseline: usize) void {
    self.messages.shrinkRetainingCapacity(baseline);
    self.rebuildMessageArena();
}

/// Rebuild `message_arena` keeping only the messages currently in
/// `self.messages`. Used after a rolled-back turn so the arena doesn't
/// accumulate prompt/tool-output bytes from doomed turns.
fn rebuildMessageArena(self: *Agent) void {
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
/// next prune. The caller is responsible for calling `pruneMessages()`
/// after consuming the returned text — pruning earlier would free the
/// arena the slice points into. `null` means the model emitted nothing
/// even after the synthesis turn.
fn processUserMessage(self: *Agent, input: TurnInput) !?[]const u8 {
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
            .tools = globalTools(),
            .max_turns = 100,
            .max_tool_calls = 200,
            .max_tokens = 4096,
            .tool_choice = .auto,
            // Cap per-turn reasoning so thinking models don't burn
            // minutes per turn. Ignored by non-thinking models.
            .thinking_level = .medium,
            .cancel = .{ .context = @ptrCast(self), .checkFn = checkCancel },
        },
    ) catch |err| {
        self.terminal.spinner.cancel();
        // Ctrl-C can land while runTools is unwinding an HTTP error —
        // surface UserCancelled, not ApiError, so the user sees the
        // outcome they asked for.
        if (self.cancel_requested.load(.acquire)) return self.drainCancellation(msg_baseline);
        log.err(.app, "AI API error", .{ .err = err });
        self.rollbackMessages(msg_baseline);
        return error.ApiError;
    };
    self.terminal.spinner.stop();
    defer result.deinit();
    self.total_usage.add(result.usage);

    if (result.cancelled) return self.drainCancellation(msg_baseline);

    const file_recorder: ?*Recorder = blk: {
        if (self.recorder) |*r| {
            if (r.isActive()) break :blk r;
        }
        break :blk null;
    };
    const record_to_memory = input.capture_for_save;
    if (file_recorder != null or record_to_memory) {
        // When the LLM tries multiple `extract` schemas in one turn, only the
        // last successful one is the answer — earlier probes are noise.
        var last_extract_idx: ?usize = null;
        for (result.tool_calls_made, 0..) |tc, i| {
            const t = std.meta.stringToEnum(BrowserTool, tc.name) orelse continue;
            if (!tc.is_error and t == .extract) last_extract_idx = i;
        }

        var recorded_any = false;
        for (result.tool_calls_made, 0..) |tc, i| {
            if (tc.is_error) continue;
            const tool = std.meta.stringToEnum(BrowserTool, tc.name) orelse continue;
            if (last_extract_idx) |idx| {
                if (tool == .extract and idx != i) continue;
            }
            const args = browser_tools.normalizeArgKeys(self.message_arena.allocator(), tool, tc.arguments) catch tc.arguments;
            const cmd = Command.fromToolCall(tool, args);
            if (!cmd.isRecorded()) continue;
            if (!recorded_any) {
                if (input.record_comment) |c| {
                    if (file_recorder) |r| r.recordComment(c);
                    if (record_to_memory) self.recordSaveComment(c);
                }
                recorded_any = true;
            }
            if (file_recorder) |r| r.record(cmd);
            if (record_to_memory) self.recordSaveCommand(cmd);
        }
        if (file_recorder) |r| {
            if (!r.isActive()) {
                self.terminal.printError("recording disabled (write failed); see logs", .{});
            }
        }
    }

    // Dupe into `message_arena` — RunToolsResult arenas are deinited below.
    self.last_turn_refused = result.finish_reason == .safety;
    const final_text: ?[]const u8 = blk: {
        if (result.text) |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len > 0) break :blk try ma.dupe(u8, text);
        }

        // A refusal is deterministic; re-prompting just refuses again.
        if (self.last_turn_refused) break :blk null;

        // Without a synthesis turn forbidding tools+pretraining, models
        // confabulate when the page was blocked or empty.
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
                .tools = &.{},
                .max_turns = 1,
                .max_tokens = 4096,
                .tool_choice = .none,
                // .low (≈512 tokens) so reasoning models still pick an answer
                // but can't burn the whole turn on thinking and emit nothing.
                .thinking_level = .low,
                .cancel = .{ .context = @ptrCast(self), .checkFn = checkCancel },
            },
        ) catch |err| {
            if (self.cancel_requested.load(.acquire)) return self.drainCancellation(msg_baseline);
            log.err(.app, "AI synthesis error", .{ .err = err });
            self.rollbackMessages(synth_baseline);
            break :blk null;
        };
        defer synth.deinit();
        self.total_usage.add(synth.usage);

        if (synth.cancelled) return self.drainCancellation(msg_baseline);

        break :blk if (synth.text) |text| try ma.dupe(u8, text) else null;
    };

    // NB: pruning is deferred to the caller. `final_text` is allocated in
    // `message_arena`, and `pruneMessages` may rebuild that arena — running
    // it here would hand the caller a dangling slice.
    return final_text;
}

/// Build a `parts`-based user message when `--attach` was given.
/// Text-ish files are inlined into the text prefix (surrounded by clear
/// markers); binary files (image/audio/pdf) are base64-encoded and sent as
/// provider inline-data parts. Unknown extensions error out so the caller
/// fails loudly instead of silently dropping the attachment.
fn buildUserMessageParts(
    self: *Agent,
    ma: std.mem.Allocator,
    user_input: []const u8,
    paths: []const []const u8,
) ![]const zenai.provider.ContentPart {
    var text_prefix: std.ArrayList(u8) = .empty;
    var inline_parts: std.ArrayList(zenai.provider.ContentPart) = .empty;

    for (paths) |path| {
        const mime = zenai.provider.inferInlineMimeType(path) orelse {
            log.err(.app, "unsupported attachment", .{ .path = path });
            self.terminal.printError("unsupported attachment type: {s}", .{path});
            return error.UnsupportedAttachment;
        };

        if (std.mem.startsWith(u8, mime, "text/")) {
            const bytes = std.fs.cwd().readFileAlloc(ma, path, 512 * 1024) catch |err| {
                log.err(.app, "read attachment failed", .{ .path = path, .err = err });
                self.terminal.printError("could not read attachment: {s}", .{path});
                return error.AttachmentReadFailed;
            };
            try text_prefix.writer(ma).print(
                "[Attached file: {s}]\n{s}\n[End of attachment]\n\n",
                .{ path, bytes },
            );
        } else {
            const raw = std.fs.cwd().readFileAlloc(ma, path, 20 * 1024 * 1024) catch |err| {
                log.err(.app, "read attachment failed", .{ .path = path, .err = err });
                self.terminal.printError("could not read attachment: {s}", .{path});
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
    const prefix = truncateUtf8(output, tool_output_max_bytes);
    var suffix_buf: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "\n...[truncated, original {d} bytes]", .{output.len}) catch return prefix;
    return std.mem.concat(allocator, u8, &.{ prefix, suffix }) catch prefix;
}

fn handleToolCall(ctx: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8, arguments: ?std.json.Value) zenai.provider.Client.ToolHandler.Result {
    const self: *Agent = @ptrCast(@alignCast(ctx));
    // The spinner doesn't render args, and `agentToolDone` skips the body
    // line at low verbosity — don't pay for the stringify when nobody reads it.
    const needs_args = self.terminal.spinner.isEnabled() or self.terminal.verbosity != .low;
    // Stringify the pre-substitution args so $LP_* placeholders the model
    // emitted stay redacted in the UI.
    const args_str: []const u8 = if (needs_args) (if (arguments) |v|
        std.json.Stringify.valueAlloc(allocator, v, .{}) catch ""
    else
        "") else "";
    self.terminal.spinner.setTool(tool_name, args_str);
    defer self.terminal.spinner.setThinking();

    if (browser_tools.call(allocator, self.session, &self.node_registry, tool_name, arguments)) |result| {
        const capped = capToolOutput(allocator, result.text);
        self.terminal.agentToolDone(tool_name, args_str, !result.is_error);
        if (self.terminal.verbosity == .high) self.terminal.printToolOutcome(tool_name, capped, result.is_error);
        return .{ .content = capped, .is_error = result.is_error };
    } else |err| {
        const msg = std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}) catch "Error: tool execution failed";
        self.terminal.agentToolDone(tool_name, args_str, false);
        if (self.terminal.verbosity == .high) self.terminal.printToolOutcome(tool_name, msg, true);
        return .{ .content = msg, .is_error = true };
    }
}

/// One-shot for `--list-models`: resolve provider+key, fetch chat-capable
/// model IDs, print to stdout (one per line).
pub fn listModels(allocator: std.mem.Allocator, opts: Config.Agent) !void {
    if (opts.no_llm) {
        log.fatal(.app, "list-models needs LLM", .{
            .hint = "--no-llm and --list-models conflict; drop --no-llm",
        });
        return error.ConflictingFlags;
    }
    if (opts.task != null or opts.interactive or opts.script_file != null) {
        log.fatal(.app, "list-models is exclusive", .{
            .hint = "--list-models only takes --provider/--model/--base-url",
        });
        return error.ConflictingFlags;
    }
    const resolved = (try settings.resolveCredentials(opts, null, false)) orelse return error.MissingProvider;
    const llm = resolved.credentials;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const ids = try zenai.provider.listChatModelIds(allocator, arena.allocator(), llm.provider, llm.key, opts.base_url);

    var stdout_file = std.fs.File.stdout().writer(&.{});
    const w = &stdout_file.interface;
    for (ids) |id| try w.print("{s}\n", .{id});
    try w.flush();
}

const ModelCompletions = struct {
    provider: Config.AiProvider,
    /// Empty when the fetch failed — cached so the per-keystroke hinter doesn't
    /// re-hit the network on every press.
    ids: []const []const u8,
};

/// `CompletionSource.providers`. Reuses pre-detected available providers to avoid
/// reading environment variables on every autocomplete keypress.
fn completionProviders(context: *anyopaque, arena: std.mem.Allocator) []const []const u8 {
    const self: *Agent = @ptrCast(@alignCast(context));
    const names = arena.alloc([]const u8, self.available_providers.len) catch return &.{};
    for (self.available_providers, 0..) |p, i| {
        names[i] = arena.dupe(u8, p) catch return &.{};
    }
    return names;
}

/// `CompletionSource.models`. Blocks on a one-time fetch per provider, caching
/// success or empty so the per-keystroke hinter pays the round-trip only once.
fn completionModels(context: *anyopaque, _: std.mem.Allocator) []const []const u8 {
    const self: *Agent = @ptrCast(@alignCast(context));
    const llm = self.model_credentials orelse return &.{};
    if (self.model_completions) |c| if (c.provider == llm.provider) return c.ids;

    _ = self.model_completion_arena.reset(.retain_capacity);
    const ids = zenai.provider.listChatModelIds(
        self.allocator,
        self.model_completion_arena.allocator(),
        llm.provider,
        llm.key,
        self.model_base_url,
    ) catch &.{};
    self.model_completions = .{ .provider = llm.provider, .ids = ids };
    return ids;
}

test "capToolOutput: passes through when under cap" {
    const ta = std.testing.allocator;
    const out = capToolOutput(ta, "short");
    try std.testing.expectEqualStrings("short", out);
}

// Boundary correctness lives in string.zig's `truncateUtf8` tests; here we only
// assert the agent-specific policy: an over-cap body keeps valid UTF-8 and gains
// the truncation marker.
test "capToolOutput: appends a marker when truncating" {
    const ta = std.testing.allocator;

    // 3-byte Hangul codepoint (U+D55C '한' = 0xED 0x95 0x9C) straddling the cap.
    const cap = tool_output_max_bytes;
    const buf = try ta.alloc(u8, cap + 8);
    defer ta.free(buf);
    @memset(buf[0 .. cap - 1], 'a');
    buf[cap - 1] = 0xED;
    buf[cap + 0] = 0x95;
    buf[cap + 1] = 0x9C;
    @memset(buf[cap + 2 ..], 'b');

    const out = capToolOutput(ta, buf);
    defer if (out.ptr != buf.ptr) ta.free(out);

    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expect(std.mem.indexOf(u8, out, "truncated") != null);
}

test "parseSaveCommand: filename only" {
    const r = try parseSaveCommand("out.js");
    try std.testing.expectEqualStrings("out.js", r.filename.?);
    try std.testing.expect(r.prompt == null);
}

test "parseSaveCommand: filename and prompt" {
    const r = try parseSaveCommand("out.js summarize the login flow");
    try std.testing.expectEqualStrings("out.js", r.filename.?);
    try std.testing.expectEqualStrings("summarize the login flow", r.prompt.?);
}

test "parseSaveCommand: quoted filename keeps trailing prompt" {
    const r = try parseSaveCommand("\"my flow.js\"  do X");
    try std.testing.expectEqualStrings("my flow.js", r.filename.?);
    try std.testing.expectEqualStrings("do X", r.prompt.?);
}

test "parseSaveCommand: prompt only when first token is not a .js name" {
    const r = try parseSaveCommand("make a login script");
    try std.testing.expect(r.filename == null);
    try std.testing.expectEqualStrings("make a login script", r.prompt.?);
}

test "parseSaveCommand: empty is all null" {
    const r = try parseSaveCommand("   ");
    try std.testing.expect(r.filename == null);
    try std.testing.expect(r.prompt == null);
}

test "parseSaveCommand: rejects path-like filenames" {
    try std.testing.expectError(error.InvalidFilename, parseSaveCommand("../evil.js"));
    try std.testing.expectError(error.InvalidFilename, parseSaveCommand("/tmp/x.js"));
    try std.testing.expectError(error.UnterminatedQuote, parseSaveCommand("\"unclosed.js"));
}

test "renderBuiltinCatalog: lists recorded tools, omits read-only ones" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderBuiltinCatalog(&out.writer);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "goto(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "extract(") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "click(") != null);
    // tree/markdown are read-only and not callable from a saved script.
    try std.testing.expect(std.mem.indexOf(u8, text, "tree(") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "markdown(") == null);
}

test "stripCodeFence: unwraps a fenced block and passes plain text through" {
    try std.testing.expectEqualStrings("goto(\"x\");", stripCodeFence("```js\ngoto(\"x\");\n```"));
    try std.testing.expectEqualStrings("goto(\"x\");", stripCodeFence("goto(\"x\");"));
}
