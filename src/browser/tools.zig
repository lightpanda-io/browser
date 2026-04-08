const std = @import("std");
const lp = @import("lightpanda");

const DOMNode = @import("webapi/Node.zig");
const CDPNode = @import("../cdp/Node.zig");
const Selector = @import("webapi/selector/Selector.zig");

pub const ToolError = error{
    PageNotLoaded,
    InvalidParams,
    NodeNotFound,
    NavigationFailed,
    InternalError,
};

/// Result from evaluate that may represent a JS error (not a tool failure).
pub const EvalResult = struct {
    text: []const u8,
    is_error: bool = false,
};

pub const GotoParams = struct {
    url: [:0]const u8,
    timeout: ?u32 = null,
    waitUntil: ?lp.Config.WaitUntil = null,
};

pub const UrlParams = struct {
    url: ?[:0]const u8 = null,
    timeout: ?u32 = null,
    waitUntil: ?lp.Config.WaitUntil = null,
};

const NodeAndPage = struct { node: *DOMNode, page: *lp.Page };

// --- Tool dispatch ---

const Action = enum {
    goto,
    navigate,
    markdown,
    links,
    nodeDetails,
    interactiveElements,
    structuredData,
    detectForms,
    evaluate,
    eval,
    semantic_tree,
    click,
    fill,
    scroll,
    waitForSelector,
    hover,
    press,
    selectOption,
    setChecked,
    findElement,
    getEnv,
    consoleLogs,
    getUrl,
    getCookies,
};

const action_map = std.StaticStringMap(Action).initComptime(.{
    .{ "goto", .goto },
    .{ "navigate", .navigate },
    .{ "markdown", .markdown },
    .{ "links", .links },
    .{ "nodeDetails", .nodeDetails },
    .{ "interactiveElements", .interactiveElements },
    .{ "structuredData", .structuredData },
    .{ "detectForms", .detectForms },
    .{ "evaluate", .evaluate },
    .{ "eval", .eval },
    .{ "semantic_tree", .semantic_tree },
    .{ "click", .click },
    .{ "fill", .fill },
    .{ "scroll", .scroll },
    .{ "waitForSelector", .waitForSelector },
    .{ "hover", .hover },
    .{ "press", .press },
    .{ "selectOption", .selectOption },
    .{ "setChecked", .setChecked },
    .{ "findElement", .findElement },
    .{ "getEnv", .getEnv },
    .{ "consoleLogs", .consoleLogs },
    .{ "getUrl", .getUrl },
    .{ "getCookies", .getCookies },
});

/// Execute a tool by name. Returns the result text.
/// For `evaluate`/`eval`, use `callEval` to distinguish JS errors from tool errors.
pub fn call(
    session: *lp.Session,
    registry: *CDPNode.Registry,
    arena: std.mem.Allocator,
    tool_name: []const u8,
    arguments: ?std.json.Value,
) ToolError![]const u8 {
    const action = action_map.get(tool_name) orelse return ToolError.InvalidParams;

    return switch (action) {
        .goto, .navigate => execGoto(session, registry, arena, arguments),
        .markdown => execMarkdown(session, registry, arena, arguments),
        .links => execLinks(session, registry, arena, arguments),
        .nodeDetails => execNodeDetails(session, registry, arena, arguments),
        .interactiveElements => execInteractiveElements(session, registry, arena, arguments),
        .structuredData => execStructuredData(session, registry, arena, arguments),
        .detectForms => execDetectForms(session, registry, arena, arguments),
        .evaluate, .eval => blk: {
            const result = execEvaluate(session, registry, arena, arguments);
            break :blk result.text;
        },
        .semantic_tree => execSemanticTree(session, registry, arena, arguments),
        .click => execClick(session, registry, arena, arguments),
        .fill => execFill(session, registry, arena, arguments),
        .scroll => execScroll(session, registry, arena, arguments),
        .waitForSelector => execWaitForSelector(session, registry, arena, arguments),
        .hover => execHover(session, registry, arena, arguments),
        .press => execPress(session, registry, arena, arguments),
        .selectOption => execSelectOption(session, registry, arena, arguments),
        .setChecked => execSetChecked(session, registry, arena, arguments),
        .findElement => execFindElement(session, registry, arena, arguments),
        .getEnv => execGetEnv(arena, arguments),
        .consoleLogs => execConsoleLogs(session, arena),
        .getUrl => execGetUrl(session),
        .getCookies => execGetCookies(session, arena),
    };
}

/// Like `call`, but for evaluate/eval returns the full EvalResult with is_error flag.
pub fn callEval(
    session: *lp.Session,
    registry: *CDPNode.Registry,
    arena: std.mem.Allocator,
    arguments: ?std.json.Value,
) EvalResult {
    return execEvaluate(session, registry, arena, arguments);
}

/// Check if a tool name is recognized.
pub fn isKnownTool(tool_name: []const u8) bool {
    return action_map.get(tool_name) != null;
}

// --- Tool implementations ---

fn execGoto(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = parseArgsOrErr(GotoParams, arena, arguments) orelse return ToolError.InvalidParams;
    try performGoto(session, registry, args.url, args.timeout, args.waitUntil);
    return "Navigated successfully.";
}

fn execMarkdown(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.markdown.dump(page.document.asNode(), .{}, &aw.writer, page) catch
        return ToolError.InternalError;
    return aw.written();
}

fn execLinks(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const links_list = lp.links.collectLinks(arena, page.document.asNode(), page) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    for (links_list, 0..) |href, i| {
        if (i > 0) aw.writer.writeByte('\n') catch {};
        aw.writer.writeAll(href) catch {};
    }
    return aw.written();
}

fn execSemanticTree(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const TreeParams = struct {
        url: ?[:0]const u8 = null,
        backendNodeId: ?u32 = null,
        maxDepth: ?u32 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrDefault(TreeParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    var root_node = page.document.asNode();
    if (args.backendNodeId) |node_id| {
        if (registry.lookup_by_id.get(node_id)) |n| {
            root_node = n.dom;
        }
    }

    const st = lp.SemanticTree{
        .dom_node = root_node,
        .registry = registry,
        .page = page,
        .arena = arena,
        .prune = true,
        .max_depth = args.maxDepth orelse std.math.maxInt(u32) - 1,
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    st.textStringify(&aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execNodeDetails(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { backendNodeId: CDPNode.Id };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;

    _ = session.currentPage() orelse return ToolError.PageNotLoaded;

    const node = registry.lookup_by_id.get(args.backendNodeId) orelse
        return ToolError.NodeNotFound;

    const page = session.currentPage().?;
    const details = lp.SemanticTree.getNodeDetails(arena, node.dom, registry, page) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(&details, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execInteractiveElements(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const elements = lp.interactive.collectInteractiveElements(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;
    lp.interactive.registerNodes(elements, registry) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(elements, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execStructuredData(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const data = lp.structured_data.collectStructuredData(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(data, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execDetectForms(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = try ensurePage(session, registry, args.url, args.timeout, args.waitUntil);

    const forms_data = lp.forms.collectForms(arena, page.document.asNode(), page) catch
        return ToolError.InternalError;
    lp.forms.registerNodes(forms_data, registry) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(forms_data, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execEvaluate(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) EvalResult {
    const Params = struct {
        script: [:0]const u8,
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return .{ .text = "Error: missing 'script' argument", .is_error = true };
    const page = ensurePage(session, registry, args.url, args.timeout, args.waitUntil) catch return .{ .text = "Error: page not loaded", .is_error = true };

    var ls: lp.js.Local.Scope = undefined;
    page.js.localScope(&ls);
    defer ls.deinit();

    var try_catch: lp.js.TryCatch = undefined;
    try_catch.init(&ls.local);
    defer try_catch.deinit();

    const js_result = ls.local.compileAndRun(args.script, null) catch |err| {
        const caught = try_catch.caughtOrError(arena, err);
        var aw: std.Io.Writer.Allocating = .init(arena);
        caught.format(&aw.writer) catch {};
        return .{ .text = aw.written(), .is_error = true };
    };

    return .{ .text = js_result.toStringSliceWithAlloc(arena) catch "undefined" };
}

fn execClick(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const resolved = if (args.selector) |sel|
        try resolveBySelector(session, sel)
    else if (args.backendNodeId) |nid|
        try resolveNodeAndPage(session, registry, nid)
    else
        return ToolError.InvalidParams;

    lp.actions.click(resolved.node, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    // If the click triggered a navigation (e.g. form submission, link click),
    // wait for it to complete.
    if (session.queued_navigation.items.len != 0) {
        var runner = session.runner(.{}) catch return ToolError.InternalError;
        runner.wait(.{ .ms = 10000, .until = .done }) catch return ToolError.NavigationFailed;
    }

    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const page_title = page.getTitle() catch null;
    if (args.selector) |sel| {
        return std.fmt.allocPrint(arena, "Clicked element (selector: {s}). Page url: {s}, title: {s}", .{
            sel, page.url, page_title orelse "(none)",
        }) catch return ToolError.InternalError;
    }
    return std.fmt.allocPrint(arena, "Clicked element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId.?,
        page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execFill(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        selector: ?[]const u8 = null,
        text: []const u8 = "",
        value: []const u8 = "",
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const text = if (args.text.len > 0) args.text else if (args.value.len > 0) args.value else return ToolError.InvalidParams;
    const resolved = if (args.selector) |sel|
        try resolveBySelector(session, sel)
    else if (args.backendNodeId) |nid|
        try resolveNodeAndPage(session, registry, nid)
    else
        return ToolError.InvalidParams;

    lp.actions.fill(resolved.node, text, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const page_title = resolved.page.getTitle() catch null;
    if (args.selector) |sel| {
        return std.fmt.allocPrint(arena, "Filled element (selector: {s}) with \"{s}\". Page url: {s}, title: {s}", .{
            sel, text, resolved.page.url, page_title orelse "(none)",
        }) catch return ToolError.InternalError;
    }
    return std.fmt.allocPrint(arena, "Filled element (backendNodeId: {d}) with \"{s}\". Page url: {s}, title: {s}", .{
        args.backendNodeId.?,
        text,
        resolved.page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execScroll(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const args = parseArgsOrDefault(Params, arena, arguments);
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;

    var target_node: ?*DOMNode = null;
    if (args.backendNodeId) |node_id| {
        const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
        target_node = node.dom;
    }

    lp.actions.scroll(target_node, args.x, args.y, page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const page_title = page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Scrolled to x: {d}, y: {d}. Page url: {s}, title: {s}", .{
        args.x orelse 0,
        args.y orelse 0,
        page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execWaitForSelector(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        selector: [:0]const u8,
        timeout: ?u32 = null,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;

    _ = session.currentPage() orelse return ToolError.PageNotLoaded;

    const timeout_ms = args.timeout orelse 5000;

    const node = lp.actions.waitForSelector(args.selector, timeout_ms, session) catch |err| {
        if (err == error.InvalidSelector) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const registered = registry.register(node) catch return ToolError.InternalError;
    return std.fmt.allocPrint(arena, "Element found. backendNodeId: {d}", .{registered.id}) catch return ToolError.InternalError;
}

fn execHover(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { backendNodeId: CDPNode.Id };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const resolved = try resolveNodeAndPage(session, registry, args.backendNodeId);

    lp.actions.hover(resolved.node, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const page_title = resolved.page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Hovered element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId,
        resolved.page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execPress(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        key: []const u8,
        backendNodeId: ?CDPNode.Id = null,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;

    const page = session.currentPage() orelse return ToolError.PageNotLoaded;

    var target_node: ?*DOMNode = null;
    if (args.backendNodeId) |node_id| {
        const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
        target_node = node.dom;
    }

    lp.actions.press(target_node, args.key, page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    // Pressing Enter on a form input triggers implicit form submission.
    if (session.queued_navigation.items.len != 0) {
        var runner = session.runner(.{}) catch return ToolError.InternalError;
        runner.wait(.{ .ms = 10000, .until = .done }) catch return ToolError.NavigationFailed;
    }

    const current_page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const page_title = current_page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Pressed key '{s}'. Page url: {s}, title: {s}", .{
        args.key,
        current_page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execSelectOption(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: CDPNode.Id,
        value: []const u8,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const resolved = try resolveNodeAndPage(session, registry, args.backendNodeId);

    lp.actions.selectOption(resolved.node, args.value, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const page_title = resolved.page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Selected option '{s}' (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.value,
        args.backendNodeId,
        resolved.page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execSetChecked(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        backendNodeId: CDPNode.Id,
        checked: bool,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const resolved = try resolveNodeAndPage(session, registry, args.backendNodeId);

    lp.actions.setChecked(resolved.node, args.checked, resolved.page) catch |err| {
        if (err == error.InvalidNodeType) return ToolError.InvalidParams;
        return ToolError.InternalError;
    };

    const state_str = if (args.checked) "checked" else "unchecked";
    const page_title = resolved.page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Set element (backendNodeId: {d}) to {s}. Page url: {s}, title: {s}", .{
        args.backendNodeId,
        state_str,
        resolved.page.url,
        page_title orelse "(none)",
    }) catch return ToolError.InternalError;
}

fn execFindElement(session: *lp.Session, registry: *CDPNode.Registry, arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct {
        role: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };
    const args = parseArgsOrDefault(Params, arena, arguments);

    if (args.role == null and args.name == null) return ToolError.InvalidParams;

    const page = session.currentPage() orelse return ToolError.PageNotLoaded;

    const elements = lp.interactive.collectInteractiveElements(page.document.asNode(), arena, page) catch
        return ToolError.InternalError;

    var matches: std.ArrayListUnmanaged(lp.interactive.InteractiveElement) = .empty;
    for (elements) |el| {
        if (args.role) |role| {
            const el_role = el.role orelse continue;
            if (!std.ascii.eqlIgnoreCase(el_role, role)) continue;
        }
        if (args.name) |name| {
            const el_name = el.name orelse continue;
            if (!containsIgnoreCase(el_name, name)) continue;
        }
        matches.append(arena, el) catch return ToolError.InternalError;
    }

    const matched = matches.toOwnedSlice(arena) catch return ToolError.InternalError;
    lp.interactive.registerNodes(matched, registry) catch
        return ToolError.InternalError;

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(matched, .{}, &aw.writer) catch return ToolError.InternalError;
    return aw.written();
}

fn execGetEnv(arena: std.mem.Allocator, arguments: ?std.json.Value) ToolError![]const u8 {
    const Params = struct { name: []const u8 };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return ToolError.InvalidParams;
    const name_z = arena.dupeZ(u8, args.name) catch return ToolError.InternalError;
    const value = std.posix.getenv(name_z) orelse
        return std.fmt.allocPrint(arena, "Environment variable '{s}' is not set", .{args.name}) catch ToolError.InternalError;
    return value;
}

fn execConsoleLogs(
    session: *lp.Session,
    arena: std.mem.Allocator,
) ToolError![]const u8 {
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const messages = page.console_messages.items;
    if (messages.len == 0) return "No console messages.";

    var aw: std.Io.Writer.Allocating = .init(arena);
    const writer = &aw.writer;
    for (messages) |msg| {
        writer.print("[{s}] {s}\n", .{ @tagName(msg.level), msg.text }) catch return ToolError.InternalError;
    }
    page.console_messages.clearRetainingCapacity();
    return aw.written();
}

fn execGetUrl(session: *lp.Session) ToolError![]const u8 {
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    return page.url;
}

fn execGetCookies(session: *lp.Session, arena: std.mem.Allocator) ToolError![]const u8 {
    const cookies = session.cookie_jar.cookies.items;
    if (cookies.len == 0) return "No cookies.";

    var aw: std.Io.Writer.Allocating = .init(arena);
    const writer = &aw.writer;
    for (cookies) |*cookie| {
        writer.print("{s}={s}", .{ cookie.name, cookie.value }) catch return ToolError.InternalError;
        writer.print("; domain={s}; path={s}", .{ cookie.domain, cookie.path }) catch return ToolError.InternalError;
        if (cookie.secure) writer.writeAll("; Secure") catch return ToolError.InternalError;
        if (cookie.http_only) writer.writeAll("; HttpOnly") catch return ToolError.InternalError;
        writer.writeAll("\n") catch return ToolError.InternalError;
    }
    return aw.written();
}

// --- Shared helpers ---

fn ensurePage(session: *lp.Session, registry: *CDPNode.Registry, url: ?[:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) ToolError!*lp.Page {
    if (url) |u| {
        try performGoto(session, registry, u, timeout, waitUntil);
    }
    return session.currentPage() orelse ToolError.PageNotLoaded;
}

fn performGoto(session: *lp.Session, registry: *CDPNode.Registry, url: [:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) ToolError!void {
    if (session.page != null) {
        registry.reset();
        session.removePage();
    }
    const page = session.createPage() catch return ToolError.NavigationFailed;
    _ = page.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    }) catch return ToolError.NavigationFailed;

    var runner = session.runner(.{}) catch return ToolError.NavigationFailed;
    runner.wait(.{
        .ms = timeout orelse 10000,
        .until = waitUntil orelse .done,
    }) catch return ToolError.NavigationFailed;
}

fn resolveNodeAndPage(session: *lp.Session, registry: *CDPNode.Registry, node_id: CDPNode.Id) ToolError!NodeAndPage {
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const node = registry.lookup_by_id.get(node_id) orelse return ToolError.NodeNotFound;
    return .{ .node = node.dom, .page = page };
}

fn resolveBySelector(session: *lp.Session, selector: []const u8) ToolError!NodeAndPage {
    const page = session.currentPage() orelse return ToolError.PageNotLoaded;
    const element = Selector.querySelector(page.document.asNode(), selector, page) catch return ToolError.InvalidParams;
    const node = (element orelse return ToolError.NodeNotFound).asNode();
    return .{ .node = node, .page = page };
}

fn parseArgsOrDefault(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value) T {
    const args_raw = arguments orelse return .{};
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch .{};
}

fn parseArgsOrErr(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value) ?T {
    const args_raw = arguments orelse return null;
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch null;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;
    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}
