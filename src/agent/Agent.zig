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
const ScriptRuntime = lp.Runtime;
const Credentials = zenai.provider.Credentials;

const App = @import("../App.zig");
const CDPNode = @import("../cdp/Node.zig");
const Conversation = @import("Conversation.zig");
const Terminal = @import("Terminal.zig");
const SlashCommand = @import("SlashCommand.zig");
const settings = @import("settings.zig");
const save = @import("save.zig");
const welcome = @import("welcome.zig");
const string = @import("../string.zig");

const Agent = @This();

/// Raised by init/listModels after they've printed a user-facing message to
/// stderr; callers should exit non-zero without logging more.
pub const UserError = error{
    MissingApiKey,
    MissingProvider,
    ConflictingFlags,
    ModelNotAvailable,
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

/// Skill-like documentation for writing Lightpanda agent script
/// Used in the system prompt of the `/save` command.
const script_skill =
    \\# Writing Lightpanda agent scripts
    \\
    \\Run with:
    \\
    \\```console
    \\./lightpanda agent script.js
    \\```
    \\
    \\## Mental model (get this right first)
    \\
    \\The script runs in its **own V8 context** — neither the page nor Node.js:
    \\
    \\- `Page` is the only global. `new Page()` makes a page and `await page.goto(url)` navigates it; every other primitive is a **method on that page**: `const page = new Page(); await page.goto(url); page.extract({...}); page.click(sel);`.
    \\- No `window`, `document`, DOM, `localStorage` — read pages with `page.extract(...)`, run page-side JS only via `page.evaluate("...")`.
    \\- No `require`, `process`, `fs`, npm. Standard ECMAScript built-ins only (`JSON`, `Map`, template literals, …).
    \\- `page.goto(...)` is **async — always `await` it**. Page methods are **synchronous**: `const data = page.extract({...})`, never `await page.extract(...)`. The script body runs as an async function, so top-level `await` is allowed.
    \\- **Re-navigating reuses the same page**: `await page.goto(url2)` keeps `page` valid and points it at the new URL, discarding the old page — read it before navigating away. Independent URLs don't share a page: make a `new Page()` for each and load them in parallel (fan-out, best practice 2).
    \\- Page `evaluate("...")` cannot see script variables — interpolate values into the string. Script code cannot see page variables.
    \\- Variables persist across navigations within one run, so cross-page aggregation is plain JS.
    \\- **`return <value>` is the script's output**, printed automatically (objects/arrays as JSON). End with `return page.extract({...});` or `return results;`. A bare trailing expression is NOT printed; neither is `console.log(JSON.stringify(...))`.
    \\
    \\## Primitives
    \\
    \\`Page` is the only global; `new Page()` makes a page and everything else is a method on it.
    \\
    \\| Call | Notes |
    \\|------|-------|
    \\| `new Page()` | Makes a page object. No navigation yet — call `page.goto(url)` before any other method. Make several to navigate in parallel (fan-out, best practice 2). |
    \\| `await page.goto(url[, { timeout }])` | **Async — must be `await`ed.** Navigates the page (re-navigating reuses the same object). Waits for `load`. Default timeout 10000 ms. Rejects on navigation failure; a **timeout does NOT reject** (the page may still be usable). |
    \\| `page.close()` | Marks the page done; later method calls on it error. The page is otherwise reclaimed at script end. |
    \\| `page.extract(schema)` | The only primitive returning a real JS value (object/array). See schema below. |
    \\| `page.evaluate(script[, { url, timeout, save }])` | Page-side JS escape hatch; returns text (JSON for objects/arrays). |
    \\| `page.click(sel)` / `page.hover(sel)` | |
    \\| `page.fill(sel, value)` / `page.selectOption(sel, value)` | |
    \\| `page.setChecked(sel[, checked])` | `checked` defaults to `true`. |
    \\| `page.press(sel, key)` / `page.press(null, key)` / `page.press({ key })` | Selector first! `page.press("Enter")` binds "Enter" to `selector` and fails. |
    \\| `page.scroll()` / `page.scroll({ x, y })` | |
    \\| `page.waitForSelector(sel[, { timeout }])` | `waitFor*` default timeout 5000 ms. |
    \\| `page.waitForScript(js[, { timeout }])` | Re-evaluates page JS until truthy. |
    \\| `page.waitForState(state[, { timeout }])` | `"load"`, `"domcontentloaded"`, `"networkalmostidle"`, `"networkidle"`, `"done"`. |
    \\
    \\Calling convention: leading positionals + optional trailing options object, or one object with everything (`page.waitForSelector("#row", { timeout: 2000 })` ≡ `page.waitForSelector({ selector: "#row", timeout: 2000 })`). A bare option positional (`page.waitForSelector("#row", 2000)`) and a field passed both ways are `invalid arguments`. `null` skips a positional. Arguments must be JSON-serializable.
    \\
    \\CSS selectors only — `backendNodeId`s don't exist here. Standard CSS only: no jQuery `:contains()` or Playwright `:has-text()`.
    \\
    \\## extract schema
    \\
    \\Keys = output field names; values pick what to lift (not a JSON Schema):
    \\
    \\```js
    \\const { stories } = page.extract({
    \\  stories: [{
    \\    selector: "tr.athing",          // one record per match
    \\    limit: 5,
    \\    fields: {                        // resolved relative to each match
    \\      title: ".titleline > a",      // first match's text (null if missing)
    \\      url: { selector: ".titleline > a", attr: "href" },
    \\      text: ""                       // "" = the matched element's own text
    \\    }
    \\  }]
    \\});
    \\```
    \\
    \\- `"sel"` → first match's text; `["sel"]` → all matches' text; `{ selector, attr }` / `[{ selector, attr }]` → attribute(s); `limit: N` caps any array form.
    \\- Every value is a string or null — parse numbers in script logic.
    \\- Empty arrays are valid results; if **every** field misses, extract throws ("no schema selector matched any element") → your selectors are wrong, not the page empty.
    \\- An object schema always returns an object (destructure it); a bare array schema returns the array directly.
    \\- No `save:` option in scripts — keep results in variables.
    \\
    \\## Best practices
    \\
    \\1. **Navigate, settle, read.** After `await page.goto` on a dynamic page (feeds, search results, comment threads), call `page.waitForState("networkidle")` or `page.waitForSelector(...)` before extracting. Most static pages are complete at `load` — don't wait blindly.
    \\2. **List-to-detail — fan out independent pages.** Extract the list, then open one page per item and start every navigation together so the detail pages load in parallel instead of one-after-another:
    \\   ```js
    \\   const list = new Page();
    \\   await list.goto(listUrl);
    \\   const { items } = list.extract({ items: [{ selector: "a.row", fields: { url: { attr: "href" } } }] });
    \\
    \\   const pages = items.map(() => new Page());
    \\   await Promise.all(pages.map((p, i) => p.goto(items[i].url)));   // all in flight at once
    \\   return pages.map((p, i) => ({ ...items[i], ...p.extract({ /* schema */ }) }));
    \\   ```
    \\   - Concurrency is bounded by the HTTP connection pool (40 by default, `--http-max-concurrent`); extra navigations queue rather than fail. For long lists, fan out in batches and `page.close()` each page once read so its memory is reclaimed.
    \\   - `Promise.all` rejects the whole batch if any `goto` *fails* (a timeout does not reject); use `Promise.allSettled` when partial results are fine.
    \\   - Walk **serially** on one page (`for (const it of items) { await page.goto(it.url); … }`) only when the steps depend on each other — each page decides the next URL, or they share login/session state.
    \\3. **`evaluate` is a last resort, not a reading tool.** A `querySelectorAll`-and-parse `page.evaluate` block is always wrong: lift the raw strings with `page.extract`, then trim/split/parse them in top-level JS. Reserve `page.evaluate` for behavior that must run inside the page and no builtin covers — and remember its state dies on every navigation/reload, while script variables persist.
    \\4. **Credentials via `$LP_*` placeholders** in any string argument (`page.fill("#pw", "$LP_HN_PASSWORD")`). Never inline a real secret; placeholders resolve inside the Lightpanda process.
    \\5. **Unique selectors.** Disambiguate with attributes/position: `input[type="submit"][value="login"]`, not `input[type="submit"]`.
    \\6. **Let failures fail.** Primitives throw on error and stop the script — only `try/catch` where you have a real fallback (e.g. optional cookie banner: `try { page.click("#accept") } catch {}`).
    \\7. **End with `return <result>`.** `console.log` is for debug output only and doesn't JSON-format objects.
    \\8. Modern, readable JS: `const`/`let`, `for (const x of xs)`, template literals, destructuring, 2-space indent.
    \\9. **Comment the intent of each block.** Put a one-line `//` comment above each logical step describing what it accomplishes toward the goal (not restating the call). One comment per block, not per line — skip self-evident lines:
    \\   ```js
    \\   // Load the Hacker News front page
    \\   const page = new Page();
    \\   await page.goto("https://news.ycombinator.com");
    \\
    \\   // Pull the top 5 stories (title + link)
    \\   const { stories } = page.extract({ stories: [{ selector: "tr.athing", limit: 5, fields: { title: ".titleline > a", url: { selector: ".titleline > a", attr: "href" } } }] });
    \\
    \\   // Open each story page in parallel and read its text
    \\   const pages = stories.map(() => new Page());
    \\   await Promise.all(pages.map((p, i) => p.goto(stories[i].url)));
    \\   ```
    \\
    \\## Common errors
    \\
    \\| Error | Cause / fix |
    \\|-------|-------------|
    \\| `extract is not defined` (or click/fill/…) | These are methods on the page object, not globals → `const page = new Page(); await page.goto(url); page.extract(...)` |
    \\| `Page must be called with new` | `Page(...)` called without `new` → `const page = new Page();` |
    \\| `page is not navigated or has been closed` | A method on a fresh `new Page()` (or a closed page) → `await page.goto(url)` first |
    \\| `page handle is no longer valid` | Used a page after a later `goto` on the **same** page replaced it → read it before navigating away. Sibling pages from other `new Page()` calls stay valid. |
    \\| `document is not defined` | DOM API in script context → use `page.extract` or `page.evaluate` |
    \\| `require is not defined` | Not Node.js |
    \\| `no page loaded - run page.goto(url) first` | Page method before navigation |
    \\| `invalid arguments` | Wrong arity/shape, non-JSON value, or a field set both positionally and in options |
    \\| `extract: no schema selector matched any element` | All schema fields missed → fix selectors |
    \\| `press` fails with one string arg | Selector-first: use `page.press(null, "Enter")` or `page.press({ key: "Enter" })` |
;

// Sytem prompt of the `/save` command
// With the save instructions and the skill-like agent script documentation.
const save_system_prompt = browser_tools.save_synthesis_prompt ++ "\n\n" ++ script_skill;

// Swapped in instead of `save_system_prompt` when the user message carries a
// previously saved script: the "this session" framing above would otherwise
// make the model discard it as out-of-scope.
const save_revision_note =
    \\This save REVISES an existing script, included in the user message. Its
    \\goal spans every session that contributed to it, not just this one. Use
    \\it as the base: keep its steps, structure, and output shape unchanged
    \\except where this session's commands or the user's instruction require
    \\a change, and add what this session contributes. Output the complete
    \\updated script — never a fragment, diff, or continuation.
;
const save_revision_system_prompt = browser_tools.save_synthesis_prompt ++ "\n" ++ save_revision_note ++ "\n" ++ script_skill;

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
model_credentials: ?Credentials,
/// Allocated credentials key (Vertex gcloud token) — other keys are unowned
/// env pointers. The AI client references it: free only after client deinit.
owned_key: ?[:0]const u8,
/// True when the no-LLM state is a persisted preference (remembered null
/// provider or runtime `/provider null`), so `reportSaved` writes
/// `provider = null`. A transient `--no-llm` run leaves it false so saving
/// other settings doesn't clobber the remembered provider.
no_llm_persisted: bool,
model_base_url: ?[:0]const u8,
/// Cached chat-model ids for the current provider, backed by
/// `model_completion_arena`; invalidated on `/provider` switch.
model_completions: ?ModelCompletions,
model_completion_arena: std.heap.ArenaAllocator,
notification: *lp.Notification,
browser: lp.Browser,
session: *lp.Session,
node_registry: CDPNode.Registry,
terminal: Terminal,
save_buffer: Recorder,
save_path: ?[]u8,
script_runtime_mutex: std.Thread.Mutex = .{},
active_script_runtime: ?*ScriptRuntime = null,
conversation: Conversation,
model: []u8,
/// Per-turn reasoning budget for LLM turns. Mutable at runtime via `/effort`.
effort: Config.Effort,
script_file: ?[]const u8,
one_shot_task: ?[]const u8,
one_shot_save: ?[]const u8,
one_shot_attachments: ?[]const []const u8,
cancel_requested: std.atomic.Value(bool) = .init(false),
/// Shuts down the in-flight LLM socket on Ctrl-C so an agent turn aborts
/// mid-request instead of blocking until the model's full response arrives.
http_interrupt: zenai.http.Interrupt = .{},
synthetic_tool_call_id: u32 = 0,
/// Aggregate Anthropic/OpenAI/Gemini token usage across every model call.
/// Printed as a structured `$usage ...` line on stderr at the end of `--task`
/// (one-shot) mode so wrappers can capture per-task cost.
total_usage: zenai.provider.Usage = .{},
/// Set when the last turn ended in a model refusal (safety stop).
last_turn_refused: bool = false,
available_providers: []const []const u8,
/// Cached reachability of each `local_providers` entry, so the per-keystroke
/// `/provider` hinter probes each local server at most once.
local_completable: [local_providers.len]?bool = @splat(null),
api_error_buf: [512]u8 = undefined,
/// Last failure's status+message, surfaced by `runTurn` past `error.ApiError`.
api_error_detail: ?[]const u8 = null,

pub fn init(allocator: std.mem.Allocator, app: *App, opts: Config.Agent) !*Agent {
    var providers_buf: [@typeInfo(Config.AiProvider).@"enum".fields.len]Credentials = undefined;
    const found_providers = settings.availableProviders(&providers_buf);
    const available_providers = try allocator.alloc([]const u8, found_providers.len);
    var provider_count: usize = 0;
    errdefer {
        for (available_providers[0..provider_count]) |p| allocator.free(p);
        allocator.free(available_providers);
    }
    for (found_providers, 0..) |f, i| {
        available_providers[i] = try allocator.dupe(u8, @tagName(f.provider));
        provider_count = i + 1;
    }

    if (opts.task != null and opts.script_file != null) {
        log.fatal(.app, "conflicting flags", .{
            .hint = "--task runs a one-shot turn; drop the positional script or drop --task",
        });
        return error.ConflictingFlags;
    }
    if (opts.save) |save_path| {
        if (opts.task == null) {
            log.fatal(.app, "conflicting flags", .{
                .hint = "--save synthesizes a script from the --task run; pass --task too",
            });
            return error.ConflictingFlags;
        }
        if (save_path.len == 0) {
            log.fatal(.app, "invalid --save filename", .{
                .hint = "--save needs a non-empty file name",
            });
            return error.InvalidFilename;
        }
    }
    if (opts.no_llm and opts.provider != null) {
        log.warn(.app, "ignoring --provider", .{ .reason = "--no-llm takes precedence" });
    }
    if (opts.task == null and opts.attach.items.len > 0) {
        log.warn(.app, "ignoring --attach", .{ .reason = "no --task; attachments are only consumed in one-shot mode" });
    }

    const is_one_shot = opts.task != null;
    const will_repl = !is_one_shot and opts.script_file == null;

    // Load remembered selection up front so a saved null provider can flip the
    // REPL into basic mode before resolution. Pure script runs need nothing.
    const remembered: ?settings.Remembered = if (will_repl or is_one_shot) settings.loadRemembered(allocator) else null;
    defer if (remembered) |r| std.zon.parse.free(allocator, r);

    // A remembered null provider means the user disabled the LLM via
    // `/provider null`; honor it for the REPL only (one-shot --task and script
    // runs always need a model). An explicit --provider overrides it.
    const remembered_no_llm = will_repl and opts.provider == null and
        remembered != null and remembered.?.provider == null;

    // Basic-mode REPL (no LLM) must be opted into via --no-llm or a remembered
    // null provider. Without it the REPL accepts natural language, so an absent
    // API key would only surface at the first non-slash-command line — too late.
    // Pure JavaScript script runs stay allowed: no REPL, no LLM.
    const requires_llm = is_one_shot or (will_repl and !opts.no_llm and !remembered_no_llm);

    // Skip resolve when no client is wanted — else resolveCredentials prints
    // "No API key detected" for a run that does not need one.
    const resolve = !opts.no_llm and requires_llm;

    // Print the banner before resolution so it precedes the interactive picker.
    // The Ollama-only path never prompts, so its banner is deferred (below) to
    // avoid probing the local server a second time just to decide ordering.
    const banner_before = will_repl and (!resolve or settings.hasDetectableKey(opts, remembered));
    if (banner_before) welcome.print(resolve);

    const resolved: ?settings.ResolvedProvider = if (resolve) try settings.resolveCredentials(allocator, opts, remembered, will_repl) else null;
    // Before the ai_client errdefer, so on unwind the client goes first.
    errdefer if (resolved) |r| if (r.key_owned) allocator.free(r.credentials.key);

    if (will_repl and !banner_before and resolved != null) welcome.print(resolve);
    const llm: ?Credentials = if (resolved) |r| r.credentials else null;

    if (llm == null and requires_llm) {
        if (opts.no_llm) {
            std.debug.print("--no-llm forbids LLM use; drop it to run this mode.\n", .{});
        }
        return error.MissingProvider;
    }

    var model = try allocator.dupe(u8, settings.resolveModelName(opts, resolved, remembered));
    errdefer allocator.free(model);

    // The REPL skips this network round trip for snappy startup; an invalid
    // model surfaces on the first turn instead.
    if (llm) |l| if (!will_repl) {
        const remembered_matches = remembered != null and remembered.?.provider == l.provider;
        const explicit = opts.model != null or remembered_matches;
        switch (try settings.reconcileModel(allocator, l, model, opts.base_url, explicit)) {
            .use => |m| {
                allocator.free(model);
                model = m;
            },
            .abort => return error.ModelNotAvailable,
        }
    };

    const effort = settings.resolveEffort(opts, remembered, will_repl, if (resolved) |r| r.credentials.provider else null);
    const verbosity = settings.resolveVerbosity(opts, remembered);

    if (resolved) |r| {
        if (r.source == .picked) {
            settings.saveRemembered(.{ .provider = r.credentials.provider, .model = model, .effort = effort, .verbosity = verbosity }) catch {};
        }
        // provider/model now live in the status bar; just space before the help
        std.debug.print("\n", .{});
    }

    const notification: *lp.Notification = try .init(allocator);
    errdefer notification.deinit();

    const self = try allocator.create(Agent);
    errdefer allocator.destroy(self);

    const history_paths: ?Terminal.HistoryPaths = if (will_repl)
        .{ .normal = ".lp-history", .js = ".lp-history.js" }
    else
        null;

    self.* = .{
        .allocator = allocator,
        .ai_client = null,
        .model_credentials = llm,
        .owned_key = if (resolved) |r| (if (r.key_owned) r.credentials.key else null) else null,
        .no_llm_persisted = remembered_no_llm,
        .model_base_url = opts.base_url,
        .model_completions = null,
        .model_completion_arena = .init(allocator),
        .notification = notification,
        .browser = undefined,
        .session = undefined,
        .node_registry = .init(allocator),
        .terminal = .init(allocator, history_paths, verbosity, will_repl),
        .save_buffer = .init(allocator),
        .save_path = null,
        .conversation = .init(allocator, opts.system_prompt orelse default_system_prompt),
        .model = model,
        .effort = effort,
        .script_file = opts.script_file,
        .one_shot_task = opts.task,
        .one_shot_save = opts.save,
        .one_shot_attachments = if (opts.attach.items.len == 0) null else opts.attach.items,
        .available_providers = available_providers,
    };
    errdefer self.node_registry.deinit();
    errdefer self.terminal.deinit();
    errdefer self.conversation.deinit();
    self.terminal.installLogSink();
    errdefer self.terminal.uninstallLogSink();

    try self.browser.init(app, .{}, null);
    errdefer self.browser.deinit();

    try self.startSession();

    self.ai_client = if (llm) |l| try zenai.provider.Client.init(allocator, l, .{ .base_url = opts.base_url, .retry_policy = .long_running, .bill_to = hfBillTo(l.provider) }) else null;
    errdefer if (self.ai_client) |c| c.deinit(allocator);
    if (self.ai_client) |c| c.setInterrupt(&self.http_interrupt);

    if (will_repl) {
        self.terminal.attachCompleter();
        self.terminal.completion_source = .{
            .context = @ptrCast(self),
            .providers = completionProviders,
            .models = completionModels,
        };
        // The model-list cache fills lazily on the first `/model` completion,
        // so startup never blocks on the network.
        Terminal.setIdleCallback(&idlePump, @ptrCast(self));
    }

    return self;
}

pub fn deinit(self: *Agent) void {
    self.terminal.uninstallLogSink();
    self.save_buffer.deinit();
    if (self.save_path) |p| self.allocator.free(p);
    self.terminal.deinit();
    self.conversation.deinit();
    self.model_completion_arena.deinit();
    self.node_registry.deinit();
    self.browser.deinit();
    self.notification.deinit();
    if (self.ai_client) |ai_client| ai_client.deinit(self.allocator);
    if (self.owned_key) |k| self.allocator.free(k);
    self.allocator.free(self.model);
    for (self.available_providers) |p| self.allocator.free(p);
    self.allocator.free(self.available_providers);
    self.allocator.destroy(self);
}

/// isocline idle hook; returns the delay in ms before the next invocation.
fn idlePump(arg: ?*anyopaque) callconv(.c) c_long {
    const self: *Agent = @ptrCast(@alignCast(arg.?));
    return self.session.idleSlice();
}

/// Create a fresh browser session and wire its cancel hook back to this agent
/// so Ctrl-C aborts in-flight page work. Startup and `/reset`.
fn startSession(self: *Agent) !void {
    self.session = try self.browser.newSession(self.notification);
    self.session.cancel_hook = .{ .context = @ptrCast(self), .check = checkCancel };
    try self.session.enableConsoleCapture();
}

// Compile-time constant; projected once per process to avoid rebuilding per call.
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

/// Called from the sighandler thread. Flips `cancel_requested` for the LLM
/// streaming/HTTP probe and any code polling `Session.isCancelled`, then asks
/// V8 to bail out of whatever JS is running. Both hooks are thread-safe
/// (`Env.terminate` takes a mutex); no terminal touches from this context.
pub fn requestCancel(self: *Agent) void {
    self.cancel_requested.store(true, .release);
    self.http_interrupt.fire();
    {
        self.script_runtime_mutex.lock();
        defer self.script_runtime_mutex.unlock();
        if (self.active_script_runtime) |runtime| {
            runtime.terminate();
        }
    }
    self.browser.env.terminate();
}

/// Lives in main's stack so it can be registered with the sighandler before the
/// agent thread exists. The agent attaches once constructed and detaches before
/// deinit, so the sighandler-thread listener can fire safely whether or not an
/// agent is currently up.
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

/// Roll the agent back to `baseline` messages, clear the V8 termination flag,
/// drop the cancel signal, and surface `error.UserCancelled`. Caller handles
/// any spinner cleanup not already done on its path.
fn drainCancellation(self: *Agent, baseline: usize) error{UserCancelled} {
    self.resetAfterCancel(baseline);
    return error.UserCancelled;
}

/// The side effects of `drainCancellation` without surfacing the error, for
/// void callers (e.g. `/save` synthesis) that just need to clean up.
fn resetAfterCancel(self: *Agent, baseline: usize) void {
    self.conversation.rollback(baseline);
    self.browser.env.cancelTerminate();
    self.cancel_requested.store(false, .release);
    self.http_interrupt.reset();
}

/// One agent turn: the prompt sent to the model, plus optional context — a
/// recorder comment to write before the turn, file attachments to bundle into
/// the first user message, and a display label used in error output.
pub const TurnInput = struct {
    prompt: []const u8,
    record_comment: ?[]const u8 = null,
    capture_for_save: bool = false,
    suppress_answer: bool = false,
    attachments: ?[]const []const u8 = null,
    label: []const u8 = "Request",
};

/// Returns true on success.
pub fn run(self: *Agent) bool {
    if (self.one_shot_task) |task| {
        const saving = self.one_shot_save != null;
        const ok = self.runTurn(.{
            .prompt = task,
            .attachments = self.one_shot_attachments,
            .capture_for_save = saving,
            .record_comment = if (saving) task else null,
            .suppress_answer = saving,
        });
        // Synthesis is a second LLM call that adds to total_usage, so save
        // before printing the cumulative summary.
        if (ok and saving) self.saveOneShot();
        self.printUsageSummary();
        return ok;
    }
    if (self.script_file) |path| {
        return self.runScript(path);
    }
    self.runRepl();
    return true;
}

/// Print single-line cumulative token usage to stderr, so wrappers driving
/// `lightpanda agent --task ...` can capture per-task cost by `grep`-ing the
/// `$usage` prefix. Stable key=value format:
///   $usage prompt=N completion=N total=N cached=N cache_creation=N
/// Fields emit 0 when the provider didn't report them.
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
            self.conversation.prune();
            return false;
        },
        else => {
            self.terminal.printError("{s} failed: {s}", .{ input.label, self.api_error_detail orelse @errorName(err) });
            return false;
        },
    };
    if (!input.suppress_answer) {
        if (text) |t|
            self.terminal.printAssistant(t)
        else if (self.last_turn_refused)
            self.terminal.printInfo("(model declined to respond — safety refusal)", .{})
        else
            self.terminal.printInfo("(no response from model)", .{});
    }
    self.conversation.prune();
    return true;
}

fn runRepl(self: *Agent) void {
    log.debug(.app, "tools loaded", .{ .count = globalTools().len });

    if (self.ai_client != null) {
        const a = Terminal.ansi;
        std.debug.print("  model: {s}{s}  {s}effort: {s}{s}{s}\n", .{ a.dim, self.model, a.reset, a.dim, @tagName(self.effort), a.reset });
    }

    repl: while (true) {
        std.debug.print("\n", .{});
        const line = Terminal.readLine("") orelse break;
        defer Terminal.freeLine(line);

        // Slash commands and idle Ctrl-C set the cancel flag without clearing
        // V8's terminate state; drain both before the next turn.
        if (self.cancel_requested.swap(false, .acq_rel)) {
            self.browser.env.cancelTerminate();
        }

        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.terminal.clearPromptFrame();
            continue;
        }
        std.debug.print("\n", .{});

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        if (self.terminal.jsMode()) {
            // `line` keeps the `$LP_*` placeholder so the secret never reaches
            // the recorder; only the evaluated copy is expanded.
            const script = browser_tools.substituteEnvVars(aa, line) catch line;
            const result = browser_tools.evalScript(aa, self.session, &self.node_registry, script) catch |err| {
                self.terminal.printError("{s}", .{switch (err) {
                    error.OutOfMemory => "out of memory",
                    error.FrameNotLoaded => "no page loaded — run /goto <url> first (Esc exits JS mode)",
                    else => std.fmt.allocPrint(aa, "evaluate failed: {s}", .{@errorName(err)}) catch "evaluate failed",
                }});
                continue :repl;
            };
            // Surface console output: slash commands (and thus /consoleLogs)
            // are unreachable in JS mode, so a console must echo logs itself.
            const logs = std.mem.trimRight(u8, self.session.drainConsoleMessages(), "\n");
            if (logs.len > 0) self.printData(logs);
            if (result.is_error) {
                self.terminal.printError("{s}", .{result.text});
            } else {
                self.printData(result.text);
                self.recordSaveRaw(line);
            }
            continue :repl;
        }

        // A slash command whose `'''…'''` body is still open continues on the
        // following lines until the block closes (the multi-line /extract
        // form). Ctrl-D on the continuation prompt abandons the command.
        const command_text: []const u8 = if (trimmed[0] == '/' and Schema.hasUnclosedTripleQuote(trimmed))
            Terminal.readContinuation(aa, trimmed) orelse continue :repl
        else
            trimmed;

        const slash_split: ?Schema.Split = Schema.parseSlashCommand(command_text);
        if (slash_split) |split| {
            if (SlashCommand.findMeta(split.name)) |meta| {
                if (self.handleMeta(aa, meta, split.rest)) break :repl;
                continue :repl;
            }
        }

        var diag: Schema.Diag = .{};
        const cmd = Command.parseDiag(aa, command_text, &diag) catch |err| switch (err) {
            error.NotASlashCommand => {
                if (self.ai_client == null) {
                    self.terminal.printError("Basic REPL (LLM disabled) accepts only commands. Try /help, or " ++ llm_setup_hint ++ " to enable natural-language prompts.", .{});
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

        switch (cmd) {
            .comment => continue :repl,
            .llm => |lc| {
                var label_buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "/{s}", .{@tagName(lc)}) catch "/?";
                if (!self.requireLlm(label)) continue :repl;
                _ = self.runTurn(.{ .prompt = lc.prompt(), .record_comment = line, .capture_for_save = true, .label = label });
            },
            .tool_call => |tc| {
                self.terminal.beginTool(tc.name(), slash_split.?.rest);
                const result = self.runCommand(aa, cmd);
                self.terminal.endTool();
                self.printCommandResult(cmd, result);
                if (!result.is_error) {
                    self.recordSaveCommand(navigationGoto(aa, tc.tool, tc.args) orelse cmd);
                }
                self.recordSlashToolCall(command_text, tc.name(), tc.args, result) catch |err| {
                    self.terminal.printWarning("LLM conversation out of sync (/{s}: {s}); next prompt may not see this action", .{ tc.name(), @errorName(err) });
                };
            },
        }
    }
}

/// Handle a REPL-only meta slash command — not a tool slash command, never
/// reaches the browser tool dispatcher. Returns `true` if the user asked to quit.
fn handleMeta(self: *Agent, arena: std.mem.Allocator, meta: *const SlashCommand.MetaCommand, rest: []const u8) bool {
    switch (meta.tag) {
        .quit => return true,
        .help => self.printSlashHelp(arena, rest),
        .verbosity => self.setEnumOption("verbosity", &self.terminal.verbosity, rest),
        .effort => self.setEnumOption("effort", &self.effort, rest),
        .usage => self.handleUsage(),
        .clear => self.handleClear(),
        .reset => self.handleReset(),
        .save => self.handleSave(arena, rest),
        .load => self.handleLoad(rest),
        .model => self.handleModel(arena, rest),
        .provider => self.handleProvider(arena, rest),
    }
    return false;
}

/// Shared body of `/verbosity` and `/effort`: bare prints the current level; an
/// argument is parsed against the enum, stored in `target`, and persisted.
/// `name` drives the slash name, usage hint, and report label.
fn setEnumOption(self: *Agent, comptime name: []const u8, target: anytype, rest: []const u8) void {
    const T = @typeInfo(@TypeOf(target)).pointer.child;
    if (rest.len == 0) {
        self.terminal.printInfo(name ++ ": {s}", .{@tagName(target.*)});
        return;
    }
    const level = std.meta.stringToEnum(T, rest) orelse {
        self.terminal.printError("usage: /" ++ name ++ " " ++ Config.tagHint(T) ++ " (got {s})", .{rest});
        return;
    };
    target.* = level;
    self.reportSaved(name, @tagName(level));
}

/// Print cumulative session token usage, broken down so the cache's effect is
/// visible — the REPL otherwise never surfaces the `$usage` line `--task`
/// prints. Reads `total_usage` (accumulated per turn by `processUserMessage`);
/// fresh/cache split semantics live on `Usage`.
fn handleUsage(self: *Agent) void {
    const u = self.total_usage;
    const input = u.inputTokens();
    const output = u.completion_tokens orelse 0;
    if (input == 0 and output == 0) {
        self.terminal.printInfo("usage: no model turns yet this session", .{});
        return;
    }
    self.terminal.printInfo(
        "usage: input={d} (fresh={d} · cache read={d} · cache write={d}), output={d}",
        .{ input, u.prompt_tokens orelse 0, u.cached_tokens orelse 0, u.cache_creation_tokens orelse 0, output },
    );
    if (input > 0) {
        self.terminal.printInfo("cache: {d}% of input served from cache", .{u.cacheHitPercent()});
    }
}

/// Drop everything tied to the conversation: history (system prompt re-seeds
/// lazily next turn), cumulative usage, the recorded action buffer and its save
/// destination, and DOM node IDs. Shared by `/clear` and `/reset`.
fn clearConversation(self: *Agent) void {
    self.conversation.rollback(0);
    self.save_buffer.reset();
    if (self.save_path) |p| self.allocator.free(p);
    self.save_path = null;
    self.total_usage = .{};
    self.node_registry.reset();
}

/// Forget the conversation while leaving the browser session live — loaded page
/// stays put, cookies/logins preserved.
fn handleClear(self: *Agent) void {
    self.clearConversation();
    self.terminal.printInfo("Cleared conversation, usage, and node IDs. Page and cookies kept.", .{});
}

/// Full clean slate: everything `/clear` drops, plus a fresh browser session,
/// so the loaded page, cookies, storage, and history are gone too.
fn handleReset(self: *Agent) void {
    self.startSession() catch |err| {
        self.terminal.printError("reset failed: {s}", .{@errorName(err)});
        return;
    };
    self.clearConversation();
    self.terminal.printInfo("Reset conversation and browser session. Page, cookies, and storage cleared.", .{});
}

fn handleLoad(self: *Agent, rest: []const u8) void {
    const path = std.mem.trim(u8, rest, &std.ascii.whitespace);
    if (path.len == 0) {
        self.terminal.printError("usage: /load <path>", .{});
        return;
    }
    _ = self.runScript(path);
}

const api_keys_hint = settings.api_keys_hint;
const llm_setup_hint = "set an API key (" ++ api_keys_hint ++ ") and run /provider <name>";

/// `/provider <keyword>` disables the LLM and persists it; shared by command
/// parser, autocomplete, and save report so they can't drift apart.
const provider_off_keyword = "null";

/// Keyless local providers (placeholder key), so reachability needs a live probe.
/// Parallel to `local_completable`.
const local_providers = [_]Config.AiProvider{ .ollama, .llama_cpp };

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
        self.terminal.printInfo("Current model: {s}", .{self.model});
        return;
    }
    const ids = completionModels(self, self.allocator);
    // Empty list = fetch failed or unlisted local models; can't confirm, allow.
    if (ids.len != 0 and !string.isOneOf(trimmed, ids)) {
        self.terminal.printError("unknown model: {s}", .{trimmed});
        return;
    }
    self.setModel(trimmed) catch |err| {
        self.terminal.printError("failed to set model: {s}", .{@errorName(err)});
    };
}

/// Persist provider/model/effort/verbosity to `.lp-agent.zon` and report it as
/// "<label>: <value>", appending "(saved to …)" on write success. With no model
/// credentials it persists `provider = null` only when that's an intentional
/// preference (`no_llm_persisted`); a transient --no-llm run reports without saving.
fn reportSaved(self: *Agent, label: []const u8, value: []const u8) void {
    const provider: ?Config.AiProvider = if (self.model_credentials) |c| c.provider else null;
    // A transient --no-llm run has no provider and no intent to persist one;
    // report without saving so we don't clobber the remembered selection.
    if (provider == null and !self.no_llm_persisted) {
        self.terminal.printInfo("{s}: {s}", .{ label, value });
        return;
    }
    if (settings.saveRemembered(.{ .provider = provider, .model = self.model, .effort = self.effort, .verbosity = self.terminal.verbosity })) {
        self.terminal.printInfo("{s}: {s} (saved to {s})", .{ label, value, settings.remembered_path });
    } else |_| {
        self.terminal.printInfo("{s}: {s}", .{ label, value });
    }
}

fn setModel(self: *Agent, model: []const u8) !void {
    const new_model = try self.allocator.dupe(u8, model);
    self.allocator.free(self.model);
    self.model = new_model;
    self.reportSaved("model", self.model);
}

fn handleProvider(self: *Agent, _: std.mem.Allocator, rest: []const u8) void {
    const trimmed = std.mem.trim(u8, rest, &std.ascii.whitespace);

    if (trimmed.len == 0) {
        if (self.model_credentials) |c| {
            self.terminal.printInfo("Current provider: {s}", .{@tagName(c.provider)});
        } else {
            self.terminal.printInfo("Current provider: null — LLM disabled", .{});
        }
        return;
    }

    if (std.mem.eql(u8, trimmed, provider_off_keyword)) {
        self.disableProvider();
        return;
    }

    const provider = std.meta.stringToEnum(Config.AiProvider, trimmed) orelse {
        self.terminal.printError("unknown provider: {s} (or 'null' to disable the LLM)", .{trimmed});
        return;
    };
    // Re-selecting vertex falls through — that's the token-refresh path.
    const vertex_project = provider == .vertex and settings.vertexProjectMode();
    if (self.model_credentials) |current| if (provider == current.provider and !vertex_project) {
        self.terminal.printInfo("provider: {s}", .{@tagName(provider)});
        return;
    };
    if (vertex_project) {
        const token = settings.gcloudAccessToken(self.allocator) catch |err| {
            self.terminal.printError("could not obtain a Vertex access token: {s} (details above)", .{@errorName(err)});
            return;
        };
        self.setProvider(.{ .provider = .vertex, .key = token }, token) catch |err| {
            self.allocator.free(token);
            self.terminal.printError("failed to set provider: {s}", .{@errorName(err)});
        };
        return;
    }
    const key = zenai.provider.envApiKey(provider) orelse {
        if (provider == .vertex) {
            self.terminal.printError("vertex needs VERTEX_API_KEY (express mode) or GOOGLE_CLOUD_PROJECT (project mode, token via gcloud)", .{});
            return;
        }
        self.terminal.printError("no API key for {s}; set {s}", .{ @tagName(provider), zenai.provider.envVarName(provider) });
        return;
    };
    // Ollama's key is a placeholder, so probe the server instead of trusting it.
    if (provider == .ollama and settings.detectLocalProvider(self.allocator, .ollama, self.model_base_url) == null) {
        self.terminal.printError("no Ollama server with a pulled model at {s}", .{self.model_base_url orelse zenai.provider.ollama_default_base_url});
        return;
    }
    if (provider == .llama_cpp and settings.detectLocalProvider(self.allocator, .llama_cpp, self.model_base_url) == null) {
        self.terminal.printError("no llama.cpp server with a loaded model at {s}", .{self.model_base_url orelse zenai.provider.llama_cpp_default_base_url});
        return;
    }
    self.setProvider(.{ .provider = provider, .key = key }, null) catch |err| {
        self.terminal.printError("failed to set provider: {s}", .{@errorName(err)});
    };
}

/// Tear down the LLM client and persist a null provider so the next REPL launch
/// starts in basic mode without re-prompting. Inverse of `setProvider`.
fn disableProvider(self: *Agent) void {
    if (self.ai_client) |client| client.deinit(self.allocator);
    self.ai_client = null;
    if (self.owned_key) |k| self.allocator.free(k);
    self.owned_key = null;
    self.model_credentials = null;
    self.model_completions = null;
    self.no_llm_persisted = true;
    self.reportSaved("provider", provider_off_keyword);
}

/// `HF_BILL_TO` org for routed requests; null for non-HF providers. Without it,
/// requests bill the token owner's personal account instead of the org.
fn hfBillTo(provider: Config.AiProvider) ?[]const u8 {
    if (provider != .huggingface) return null;
    return std.posix.getenv("HF_BILL_TO");
}

/// `owned_key` transfers ownership of an allocated `credentials.key` (Vertex
/// gcloud token) on success; on error the caller still owns it.
fn setProvider(self: *Agent, credentials: Credentials, owned_key: ?[:0]const u8) !void {
    const new_client = try zenai.provider.Client.init(self.allocator, credentials, .{ .base_url = self.model_base_url, .retry_policy = .long_running, .bill_to = hfBillTo(credentials.provider) });
    errdefer new_client.deinit(self.allocator);

    // A same-provider re-select (vertex token refresh) must not reset the model.
    const same_provider = if (self.model_credentials) |c| c.provider == credentials.provider else false;
    const new_model = try self.allocator.dupe(u8, if (same_provider) self.model else zenai.provider.defaultModel(credentials.provider));
    if (self.ai_client) |client| client.deinit(self.allocator);
    if (self.owned_key) |k| self.allocator.free(k);
    self.owned_key = owned_key;
    new_client.setInterrupt(&self.http_interrupt);
    self.ai_client = new_client;
    self.model_credentials = credentials;
    self.no_llm_persisted = false;
    self.model_completions = null;
    self.allocator.free(self.model);
    self.model = new_model;
    self.terminal.printInfo("provider: {s}", .{@tagName(credentials.provider)});
    if (zenai.provider.defaultEffort(credentials.provider)) |e| if (e != self.effort) {
        self.effort = e;
        self.terminal.printInfo("effort: {s} ({s} default)", .{ @tagName(e), @tagName(credentials.provider) });
    };
    self.reportSaved("model", self.model);
    _ = completionModels(self, self.allocator);
}

const PathAndMode = struct { path: []const u8, mode: save.Mode };

fn resolveSavePathAndMode(self: *Agent, arena: std.mem.Allocator, filename: ?[]const u8) ?PathAndMode {
    if (self.save_path) |saved| {
        if (filename) |name| {
            if (!std.mem.eql(u8, saved, name)) {
                self.terminal.printError("already saving to {s}; use /save without a filename to update it", .{saved});
                return null;
            }
        }
        // A repeat save reuses the destination without re-asking: revision
        // when a model can merge, plain append for the verbatim dump.
        return .{ .path = saved, .mode = if (self.ai_client != null) .update else .append };
    } else if (filename) |name| {
        const exists = save.fileExists(name) catch |err| {
            self.terminal.printError("failed to inspect {s}: {s}", .{ name, @errorName(err) });
            return null;
        };
        const mode = if (exists)
            self.promptSaveMode(name) orelse return null
        else
            .replace;
        return .{ .path = name, .mode = mode };
    } else {
        const path = save.randomFilename(arena) catch |err| {
            self.terminal.printError("failed to choose save filename: {s}", .{@errorName(err)});
            return null;
        };
        return .{ .path = path, .mode = .replace };
    }
}

fn handleSave(self: *Agent, arena: std.mem.Allocator, rest: []const u8) void {
    const parsed = save.parseCommand(arena, rest) catch |err| {
        const msg: []const u8 = switch (err) {
            error.UnterminatedQuote => "unterminated filename quote",
            error.EmptyFilename => "filename cannot be empty",
            error.OutOfMemory => "out of memory",
        };
        self.terminal.printError("{s}", .{msg});
        return;
    };

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
    // `self.save_path` (subsequent saves to the same destination); only the
    // former needs persisting into agent-owned memory.
    var new_save_path: ?[]u8 = if (self.save_path == null)
        self.allocator.dupe(u8, path) catch |err| {
            self.terminal.printError("failed to remember save destination {s}: {s}", .{ path, @errorName(err) });
            return;
        }
    else
        null;
    defer if (new_save_path) |p| self.allocator.free(p);

    save.writeContentFile(path, self.save_buffer.bytes(), mode) catch |err| {
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

fn promptSaveMode(self: *Agent, path: []const u8) ?save.Mode {
    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} already exists. Pick save mode:", .{path}) catch
        "File already exists. Pick save mode:";
    const with_llm = self.ai_client != null;
    const modes: []const save.Mode = if (with_llm)
        &.{ .update, .append, .replace }
    else
        &.{ .append, .replace };
    const labels: []const [:0]const u8 = if (with_llm)
        &.{
            "update — revise the saved script with this session's actions and the prompt",
            "append — keep the file as-is and add the new script at the end",
            "replace — discard the file and write a fresh script",
        }
    else
        &.{
            "append — add the recorded commands at the end",
            "replace — overwrite with the recorded commands",
        };
    const idx = Terminal.promptNumberedChoice(header, labels, 0) catch {
        self.terminal.printInfo("Save cancelled.", .{});
        return null;
    };
    return modes[idx];
}

fn failSave(self: *Agent, reason: []const u8) void {
    self.terminal.printError("save failed: {s}", .{reason});
}

/// Roll the in-flight save turn back out of the conversation, then report the
/// failure — so a doomed `/save` synthesis never leaks its messages into history.
fn abortSave(self: *Agent, baseline: usize, reason: []const u8) void {
    self.conversation.rollback(baseline);
    self.failSave(reason);
}

/// Save synthesis warrants more reasoning than a normal turn. `.none` stays off
/// so users can opt out on models that reject `reasoning_effort` (e.g. Mistral).
fn bumpedEffort(effort: Config.Effort) Config.Effort {
    return switch (effort) {
        .none => .none,
        .minimal => .low,
        .low => .medium,
        .medium => .high,
        .high, .xhigh => .xhigh,
    };
}

/// LLM-synthesized `/save`: hand the model the builtin catalog, the full
/// conversation, and the deterministic record of what ran, then write the
/// idiomatic script it returns.
fn synthesizeSave(self: *Agent, arena: std.mem.Allocator, filename: ?[]const u8, prompt: ?[]const u8) void {
    // With nothing recorded and no prompt, a re-synthesis has nothing to act
    // on — it would just re-roll the previous output.
    if (self.save_buffer.bytes().len == 0 and prompt == null) {
        if (self.save_path) |saved| {
            self.terminal.printWarning("nothing ran since the last save; run more commands or give a prompt to revise {s}, e.g. /save <what to change>", .{saved});
        } else {
            self.terminal.printWarning("nothing to save yet; run some commands or give a prompt, e.g. /save <what the script should do>", .{});
        }
        return;
    }

    const resolved = self.resolveSavePathAndMode(arena, filename) orelse return;
    self.synthesizeSaveTo(arena, resolved.path, resolved.mode, prompt);
}

/// One-shot `--task ... --save`: overwrites the destination without the REPL's
/// interactive file-exists prompt. The task doubles as the synthesis prompt so
/// the empty-buffer guard in `synthesizeSaveTo` never trips.
fn saveOneShot(self: *Agent) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const path = save.ensureJsExtension(arena.allocator(), self.one_shot_save.?) catch self.one_shot_save.?;
    self.synthesizeSaveTo(arena.allocator(), path, .replace, self.one_shot_task.?);
}

/// LLM synthesis + write for an already-resolved destination. Shared by the
/// interactive `/save` and one-shot `--save`.
fn synthesizeSaveTo(self: *Agent, arena: std.mem.Allocator, path: []const u8, mode: save.Mode, prompt: ?[]const u8) void {
    const provider_client = self.ai_client.?;

    // Only update feeds the saved script back to the model; append stays
    // blind — the script is synthesized from this session alone and written
    // after the existing content.
    const previous_script: ?[]const u8 = if (mode == .update)
        save.readScript(arena, path) catch |err| {
            self.terminal.printError("failed to read {s}: {s}", .{ path, @errorName(err) });
            return;
        }
    else
        null;

    self.conversation.ensureSystemPrompt() catch return self.failSave("out of memory");

    // Swap the dedicated save_system_prompt in as the system prompt for this one turn;
    // regular turns keep the driver prompt. (`messages[0]` is the system
    // message — rollback and prune never touch it.)
    const plain_system = self.conversation.messages.items[0].content;
    self.conversation.messages.items[0].content = if (previous_script != null) save_revision_system_prompt else save_system_prompt;
    defer self.conversation.messages.items[0].content = plain_system;

    const ma = self.conversation.arena.allocator();
    const baseline = self.conversation.messages.items.len;

    const user_msg = self.buildSaveSynthesisMessage(ma, path, previous_script, prompt) catch return self.failSave("out of memory");
    self.conversation.messages.append(self.allocator, .{ .role = .user, .content = user_msg }) catch return self.failSave("out of memory");

    self.http_interrupt.reset();
    self.terminal.spinner.start();
    var result = provider_client.runTools(
        self.model,
        &self.conversation.messages,
        self.allocator,
        ma,
        .{ .context = @ptrCast(self), .callFn = handleToolCall },
        .{
            .tools = &.{},
            .max_turns = 1,
            .max_tokens = 8192,
            .tool_choice = .none,
            .effort = bumpedEffort(self.effort),
            .cancel = .{ .context = @ptrCast(self), .checkFn = checkCancel },
        },
    ) catch |err| {
        self.terminal.spinner.cancel();
        if (self.cancel_requested.load(.acquire)) {
            self.resetAfterCancel(baseline);
            return;
        }
        log.err(.app, "AI save synthesis error", .{ .err = err });
        return self.abortSave(baseline, @errorName(err));
    };
    self.terminal.spinner.stop();
    defer result.deinit();
    self.total_usage.add(result.usage);

    if (result.cancelled) {
        self.resetAfterCancel(baseline);
        return;
    }

    const raw = result.text orelse return self.abortSave(baseline, "the model returned no script");

    // `result.text` lives in the conversation arena, freed by the rollback
    // below; copy into the command arena first (scrubbing may return its input
    // as-is).
    const owned = arena.dupe(u8, save.stripCodeFence(raw)) catch return self.abortSave(baseline, "out of memory");
    const script = browser_tools.reverseSubstituteEnvVars(arena, owned) catch return self.abortSave(baseline, "out of memory");

    // The save turn is a meta-action; keep it out of the ongoing conversation.
    self.conversation.rollback(baseline);

    save.writeContentFile(path, script, mode) catch |err| {
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

fn buildSaveSynthesisMessage(self: *Agent, arena: std.mem.Allocator, path: []const u8, previous_script: ?[]const u8, prompt: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (previous_script) |script| {
        try w.print("\nThe previously saved script in {s}, the base you are revising:\n", .{path});
        try w.writeAll(script);
    }
    const recorded = self.save_buffer.bytes();
    if (recorded.len > 0) {
        const since: []const u8 = if (previous_script != null) " since the last save" else " this session";
        try w.print("\nCommands and JS that actually ran{s}:\n", .{since});
        try w.writeAll(recorded);
    }
    if (prompt) |p| {
        try w.writeAll("\nThe user's instruction for this script:\n");
        try w.writeAll(p);
    }
    return out.written();
}

fn logSaveBufferError(self: *Agent, err: anyerror) void {
    self.terminal.printError("save buffer disabled: {s}", .{@errorName(err)});
}

fn recordSaveCommand(self: *Agent, cmd: Command) void {
    self.save_buffer.record(cmd) catch |err| self.logSaveBufferError(err);
}

/// Synthesize the `goto` a navigating read tool performed (`markdown {url}`, …)
/// so `/save` can replay it; null when it didn't navigate. The result borrows
/// `args`/`arena` — record it before either is freed.
fn navigationGoto(arena: std.mem.Allocator, tool: BrowserTool, args: ?std.json.Value) ?Command {
    if (!tool.navigatesToUrl()) return null;
    const a = args orelse return null;
    if (a != .object) return null;
    const url = a.object.get("url") orelse return null;
    if (url != .string or url.string.len == 0) return null;
    var obj: std.json.ObjectMap = .init(arena);
    obj.put("url", url) catch return null;
    return Command.fromToolCall(.goto, .{ .object = obj });
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
                "/verbosity " ++ Config.tagHint(Config.AgentVerbosity) ++ " — set REPL agent verbosity (currently: {s}). Bare /verbosity prints the level.",
                .{@tagName(self.terminal.verbosity)},
            ),
            .effort => self.terminal.printInfo(
                "/effort " ++ Config.tagHint(Config.Effort) ++ " — set per-turn reasoning effort (currently: {s}); saved to {s}. Bare /effort prints the level.",
                .{ @tagName(self.effort), settings.remembered_path },
            ),
            .usage => self.terminal.printInfo(
                "/usage — show cumulative token usage and cache hit rate for this session",
                .{},
            ),
            .clear => self.terminal.printInfo(
                "/clear — forget the conversation (history, usage, recorded actions, node IDs); keeps the loaded page and cookies",
                .{},
            ),
            .reset => self.terminal.printInfo(
                "/reset — full reset: everything /clear does plus a new browser session, dropping the page, cookies, storage, and history",
                .{},
            ),
            .save => self.terminal.printInfo(
                "/save [filename.js] [prompt] — save the session to [filename.js] (a random session-*.js if omitted). With an LLM, synthesizes an idiomatic script from the session and the optional prompt, and a repeat /save with a prompt revises the saved script; with --no-llm, dumps the recorded actions verbatim.",
                .{},
            ),
            .load => self.terminal.printInfo(
                "/load <path> — read a script from disk and run it against the current session; Tab completes file paths",
                .{},
            ),
            .model => self.terminal.printInfo(
                "/model [name] — change the model; Tab completes the provider's models, bare /model shows the current one",
                .{},
            ),
            .provider => self.terminal.printInfo(
                "/provider [name|null] — change the provider, or 'null' to disable the LLM (persisted, so the next launch starts in basic mode); Tab completes detected providers, bare /provider shows the current one",
                .{},
            ),
        }
        return;
    }
    if (self.ai_client != null) {
        for (SlashCommand.llm_commands) |row| {
            if (std.ascii.eqlIgnoreCase(row.name, target)) {
                self.terminal.printInfo("/{s} — {s}", .{ row.name, row.description });
                return;
            }
        }
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
}

/// Caller contract: `cmd` must be `.tool_call` — `.comment` and `.llm` are
/// filtered upstream, having no tool mapping.
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

/// Data output (/extract, /evaluate, /markdown, /tree, …) → plain stdout on
/// success so a caller can pipe it. Everything else routes through
/// `printToolOutcome`, which lays down the green ● / red ● dot shared with the
/// LLM tool-call path. Callers only invoke this for `.tool_call` commands (the
/// comment/login/acceptCookies branches take other paths).
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

/// Re-indent JSON for the terminal; MCP keeps renderJson's compact form.
fn printData(self: *Agent, text: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    self.terminal.printAssistant(Terminal.reindentJson(arena.allocator(), text) orelse text);
}

/// Tracks whether a `/load`-run script emitted any `console.*` output, deciding
/// how `runScript` ends: one that printed nothing freezes the spinner into a
/// `/goto`-style bullet; one that printed leaves its output as the result.
const ScriptOutput = struct {
    terminal: *Terminal,
    emitted: bool = false,

    /// `Runtime.ConsoleObserver` callback: on the first line, clear the live
    /// spinner so output starts clean instead of colliding with the indicator.
    fn observe(context: *anyopaque) void {
        const self: *ScriptOutput = @ptrCast(@alignCast(context));
        if (self.emitted) return;
        self.emitted = true;
        self.terminal.endTool();
    }
};

fn runScript(self: *Agent, path: []const u8) bool {
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

    var output: ScriptOutput = .{ .terminal = &self.terminal };
    runtime.console_observer = .{ .context = @ptrCast(&output), .notify = ScriptOutput.observe };
    self.terminal.beginTool("script", path);
    const result = runtime.runSource(content, path);
    self.terminal.endTool();

    if (result catch |err| {
        self.terminal.printError("Script failed: {s}", .{@errorName(err)});
        return false;
    }) |message| {
        self.terminal.printError("{s}", .{message});
        return false;
    }

    // A script that printed nothing leaves no trace, so freeze the spinner into
    // a green bullet (like /goto); one that printed already showed its result.
    if (!output.emitted) self.terminal.printScriptDone("script", path);
    return true;
}

/// Mirror a user-typed slash command into `self.conversation.messages` as if the
/// LLM had called the tool itself, so the next natural-language turn sees the
/// same conversation shape either way.
fn recordSlashToolCall(
    self: *Agent,
    user_input: []const u8,
    tool_name: []const u8,
    args: ?std.json.Value,
    result: browser_tools.ToolResult,
) !void {
    if (self.ai_client == null) return;
    try self.conversation.ensureSystemPrompt();

    const ma = self.conversation.arena.allocator();
    self.synthetic_tool_call_id += 1;

    const user_content = try ma.dupe(u8, user_input);

    const tool_calls = try ma.alloc(zenai.provider.ToolCall, 1);
    tool_calls[0] = .{
        .id = try std.fmt.allocPrint(ma, "lp-slash-{d}", .{self.synthetic_tool_call_id}),
        .name = try ma.dupe(u8, tool_name),
        .arguments = if (args) |v| try zenai.json.dupeValue(ma, v) else null,
    };

    // capToolOutput returns its input unchanged under the cap; dupe so content
    // doesn't alias the caller's per-iteration arena.
    const capped = capToolOutput(ma, result.text);
    const content = if (capped.ptr == result.text.ptr) try ma.dupe(u8, capped) else capped;

    const tool_results = try ma.alloc(zenai.provider.ToolResult, 1);
    tool_results[0] = .{
        .id = try ma.dupe(u8, tool_calls[0].id),
        .name = try ma.dupe(u8, tool_calls[0].name),
        .content = content,
        .is_error = result.is_error,
    };

    const baseline = self.conversation.messages.items.len;
    errdefer self.conversation.messages.shrinkRetainingCapacity(baseline);
    // User turn before the assistant tool_call satisfies Gemini's rule
    // that a function call must follow a user or function-response turn.
    try self.conversation.messages.append(self.allocator, .{
        .role = .user,
        .content = user_content,
    });
    try self.conversation.messages.append(self.allocator, .{
        .role = .assistant,
        .tool_calls = tool_calls,
    });
    try self.conversation.messages.append(self.allocator, .{
        .role = .tool,
        .tool_results = tool_results,
    });
}

/// Format the client's last failure into `api_error_buf`: HTTP status+message,
/// or the raw error name when there's no status (transport/parse failures).
fn formatApiError(self: *Agent, client: zenai.provider.Client, err: anyerror) []const u8 {
    const e = client.lastError();
    const status = e.status orelse return @errorName(err);
    const hint = if (status == 401 and client == .vertex)
        if (self.owned_key != null)
            " (Vertex token may have expired; run /provider vertex to refresh)"
        else
            " (Vertex express mode needs an express API key — a Gemini Developer key won't work)"
    else
        "";
    if (e.message) |m| {
        if (std.fmt.bufPrint(&self.api_error_buf, "HTTP {d} — {s}{s}", .{ status, m, hint })) |s| return s else |_| {}
    }
    return std.fmt.bufPrint(&self.api_error_buf, "HTTP {d}{s}", .{ status, hint }) catch @errorName(err);
}

/// Returned text lives in `conversation.arena`, valid only until the next prune.
/// Caller must call `conversation.prune()` after consuming it — pruning earlier
/// frees the arena the slice points into. `null` means the model emitted nothing
/// even after the synthesis turn.
fn processUserMessage(self: *Agent, input: TurnInput) !?[]const u8 {
    const ma = self.conversation.arena.allocator();
    self.api_error_detail = null;
    self.http_interrupt.reset();

    try self.conversation.ensureSystemPrompt();

    // Attachments only ride on the first user turn (just after the system prompt).
    const turn_attachments: ?[]const []const u8 =
        if (self.conversation.messages.items.len == 1) input.attachments else null;

    // Roll-back baseline: on API failure the failed user turn would otherwise
    // stay in history and replay on the next attempt.
    const msg_baseline = self.conversation.messages.items.len;

    if (turn_attachments) |paths| {
        const parts = try self.buildUserMessageParts(ma, input.prompt, paths);
        try self.conversation.messages.append(self.allocator, .{
            .role = .user,
            .parts = parts,
        });
    } else {
        try self.conversation.messages.append(self.allocator, .{
            .role = .user,
            .content = try ma.dupe(u8, input.prompt),
        });
    }

    const provider_client = self.ai_client orelse return error.NoAiClient;

    self.terminal.spinner.start();
    var result = provider_client.runTools(
        self.model,
        &self.conversation.messages,
        self.allocator,
        ma,
        .{ .context = @ptrCast(self), .callFn = handleToolCall },
        .{
            .tools = globalTools(),
            .max_turns = 100,
            .max_tool_calls = 200,
            .max_tokens = 4096,
            .tool_choice = .auto,
            // Per-turn reasoning budget; resolved from --effort / .lp-agent.zon
            // / mode default, adjustable at runtime via /effort. Ignored by
            // non-thinking models.
            .effort = self.effort,
            .cancel = .{ .context = @ptrCast(self), .checkFn = checkCancel },
        },
    ) catch |err| {
        self.terminal.spinner.cancel();
        // Ctrl-C can land while runTools unwinds an HTTP error — surface
        // UserCancelled, not ApiError, so the user sees the outcome they asked for.
        if (self.cancel_requested.load(.acquire)) return self.drainCancellation(msg_baseline);
        log.err(.app, "AI API error", .{ .err = err });
        self.api_error_detail = self.formatApiError(provider_client, err);
        self.conversation.rollback(msg_baseline);
        return error.ApiError;
    };
    self.terminal.spinner.stop();
    defer result.deinit();
    self.total_usage.add(result.usage);

    if (result.cancelled) return self.drainCancellation(msg_baseline);

    if (input.capture_for_save) {
        // When the LLM tries multiple `extract` schemas in one turn, only the
        // last successful one is the answer; earlier probes are noise.
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
            const ca = self.conversation.arena.allocator();
            const args = browser_tools.normalizeArgKeys(ca, tool, tc.arguments) catch tc.arguments;
            // Fall back to the navigation a read tool performed, so a
            // markdown/tree-driven turn isn't lost from `/save`.
            const cmd = Command.fromToolCall(tool, args);
            const to_record = if (cmd.isRecorded())
                cmd
            else
                navigationGoto(ca, tool, args) orelse continue;
            if (!recorded_any) {
                if (input.record_comment) |c| self.recordSaveComment(c);
                recorded_any = true;
            }
            self.recordSaveCommand(to_record);
        }
    }

    // Dupe into the conversation arena — RunToolsResult arenas deinit below.
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
        const synth_baseline = self.conversation.messages.items.len;
        try self.conversation.messages.append(self.allocator, .{
            .role = .user,
            .content = try ma.dupe(u8, synthesis_prompt),
        });

        var synth = provider_client.runTools(
            self.model,
            &self.conversation.messages,
            self.allocator,
            ma,
            .{ .context = @ptrCast(self), .callFn = handleToolCall },
            .{
                .tools = &.{},
                .max_turns = 1,
                .max_tokens = 4096,
                .tool_choice = .none,
                // .low caps thinking so reasoning models still emit an answer;
                // `.none` stays off to opt out on models that reject it.
                .effort = if (self.effort == .none) .none else .low,
                .cancel = .{ .context = @ptrCast(self), .checkFn = checkCancel },
            },
        ) catch |err| {
            if (self.cancel_requested.load(.acquire)) return self.drainCancellation(msg_baseline);
            log.err(.app, "AI synthesis error", .{ .err = err });
            self.conversation.rollback(synth_baseline);
            break :blk null;
        };
        defer synth.deinit();
        self.total_usage.add(synth.usage);

        if (synth.cancelled) return self.drainCancellation(msg_baseline);

        break :blk if (synth.text) |text| try ma.dupe(u8, text) else null;
    };

    // NB: pruning is deferred to the caller. `final_text` is in the conversation
    // arena, and `conversation.prune()` may rebuild that arena — running it here
    // would hand the caller a dangling slice.
    return final_text;
}

/// Build a `parts`-based user message when `--attach` was given. Text-ish files
/// are inlined into the text prefix (surrounded by clear markers); binary files
/// (image/audio/pdf) are base64-encoded as provider inline-data parts. Unknown
/// extensions error out so the caller fails loudly instead of silently dropping
/// the attachment.
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

// Cap per-call tool output so heavy pages don't balloon the message arena (and
// the next request body) without bound.
const tool_output_max_bytes: usize = 1 * 1024 * 1024;

fn capToolOutput(allocator: std.mem.Allocator, output: []const u8) []const u8 {
    if (output.len <= tool_output_max_bytes) return output;
    const prefix = string.truncateUtf8(output, tool_output_max_bytes);
    var suffix_buf: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buf, "\n...[truncated, original {d} bytes]", .{output.len}) catch return prefix;
    return std.mem.concat(allocator, u8, &.{ prefix, suffix }) catch prefix;
}

fn handleToolCall(ctx: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8, arguments: ?std.json.Value) zenai.provider.Client.ToolHandler.Result {
    const self: *Agent = @ptrCast(@alignCast(ctx));
    // The spinner doesn't render args, and `agentToolDone` skips the body line
    // at low verbosity — don't pay for the stringify when nobody reads it.
    const needs_args = self.terminal.spinner.isEnabled() or self.terminal.verbosity != .low;
    // Stringify the pre-substitution args so $LP_* placeholders the model
    // emitted stay redacted in the UI.
    const args_str: []const u8 = if (needs_args) (if (arguments) |v|
        std.json.Stringify.valueAlloc(allocator, v, .{}) catch ""
    else
        "") else "";
    self.terminal.spinner.setTool(tool_name, args_str);
    defer self.terminal.spinner.setThinking();

    const outcome: zenai.provider.Client.ToolHandler.Result = if (browser_tools.call(allocator, self.session, &self.node_registry, tool_name, arguments)) |result|
        .{ .content = capToolOutput(allocator, result.text), .is_error = result.is_error }
    else |err|
        .{ .content = std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)}) catch "Error: tool execution failed", .is_error = true };

    self.terminal.agentToolDone(tool_name, args_str, !outcome.is_error);
    if (self.terminal.verbosity == .high) self.terminal.printToolOutcome(tool_name, outcome.content, outcome.is_error);
    return outcome;
}

/// One-shot for `--list-models`: resolve provider+key, fetch chat-capable model
/// IDs, print to stdout one per line.
pub fn listModels(allocator: std.mem.Allocator, opts: Config.Agent) !void {
    if (opts.no_llm) {
        log.fatal(.app, "list-models needs LLM", .{
            .hint = "--no-llm and --list-models conflict; drop --no-llm",
        });
        return error.ConflictingFlags;
    }
    if (opts.task != null or opts.script_file != null) {
        log.fatal(.app, "list-models is exclusive", .{
            .hint = "--list-models only takes --provider/--model/--base-url",
        });
        return error.ConflictingFlags;
    }
    const resolved = (try settings.resolveCredentials(allocator, opts, null, false)) orelse return error.MissingProvider;
    const llm = resolved.credentials;
    defer if (resolved.key_owned) allocator.free(llm.key);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const ids = zenai.provider.listChatModelIds(allocator, arena.allocator(), llm.provider, llm.key, opts.base_url) catch |err| {
        if (llm.provider == .vertex and !settings.vertexProjectMode()) {
            std.debug.print("Vertex express mode cannot list models (the endpoint requires OAuth); set GOOGLE_CLOUD_PROJECT for project mode.\n", .{});
        }
        return err;
    };

    var stdout_file = std.fs.File.stdout().writer(&.{});
    const w = &stdout_file.interface;
    for (ids) |id| try w.print("{s}\n", .{id});
    try w.flush();
}

const ModelCompletions = struct {
    provider: Config.AiProvider,
    /// Empty when the fetch failed — cached so the per-keystroke hinter doesn't
    /// re-hit the network each press.
    ids: []const []const u8,
};

/// `CompletionSource.providers`. Reuses pre-detected available providers to
/// avoid reading environment variables on each autocomplete keypress.
fn completionProviders(context: *anyopaque, arena: std.mem.Allocator) []const []const u8 {
    const self: *Agent = @ptrCast(@alignCast(context));
    // A local server joins completions only when it answers (placeholder key).
    var reachable: [local_providers.len]bool = undefined;
    var extra: usize = 0;
    for (local_providers, 0..) |tag, i| {
        reachable[i] = self.local_completable[i] orelse blk: {
            const v = settings.detectLocalProvider(self.allocator, tag, self.model_base_url) != null;
            self.local_completable[i] = v;
            break :blk v;
        };
        if (reachable[i]) extra += 1;
    }
    const names = arena.alloc([]const u8, self.available_providers.len + 1 + extra) catch return &.{};
    for (self.available_providers, 0..) |p, i| {
        names[i] = arena.dupe(u8, p) catch return &.{};
    }
    var n = self.available_providers.len;
    for (local_providers, reachable) |tag, r| if (r) {
        names[n] = @tagName(tag);
        n += 1;
    };
    names[n] = provider_off_keyword;
    return names;
}

/// `CompletionSource.models`. Blocks on a one-time fetch per provider, caching
/// success or empty so the per-keystroke hinter pays the round-trip once.
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

test {
    _ = save;
    _ = settings;
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
