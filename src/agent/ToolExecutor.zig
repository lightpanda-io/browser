const std = @import("std");
const lp = @import("lightpanda");
const zenai = @import("zenai");

const App = @import("../App.zig");
const HttpClient = @import("../browser/HttpClient.zig");
const CDPNode = @import("../cdp/Node.zig");
const mcp_tools = @import("../mcp/tools.zig");
const protocol = @import("../mcp/protocol.zig");

const Self = @This();

allocator: std.mem.Allocator,
app: *App,
http_client: *HttpClient,
notification: *lp.Notification,
browser: lp.Browser,
session: *lp.Session,
node_registry: CDPNode.Registry,
tool_schema_arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator, app: *App) !*Self {
    const http_client = try HttpClient.init(allocator, &app.network);
    errdefer http_client.deinit();

    const notification = try lp.Notification.init(allocator);
    errdefer notification.deinit();

    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var browser = try lp.Browser.init(app, .{ .http_client = http_client });
    errdefer browser.deinit();

    self.* = .{
        .allocator = allocator,
        .app = app,
        .http_client = http_client,
        .notification = notification,
        .browser = browser,
        .session = undefined,
        .node_registry = CDPNode.Registry.init(allocator),
        .tool_schema_arena = std.heap.ArenaAllocator.init(allocator),
    };

    self.session = try self.browser.newSession(self.notification);
    return self;
}

pub fn deinit(self: *Self) void {
    self.tool_schema_arena.deinit();
    self.node_registry.deinit();
    self.browser.deinit();
    self.notification.deinit();
    self.http_client.deinit();
    self.allocator.destroy(self);
}

/// Returns the list of tools in zenai provider.Tool format.
pub fn getTools(self: *Self) ![]const zenai.provider.Tool {
    const arena = self.tool_schema_arena.allocator();
    const tools = try arena.alloc(zenai.provider.Tool, mcp_tools.tool_list.len);
    for (mcp_tools.tool_list, 0..) |t, i| {
        const parsed = try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            t.inputSchema,
            .{},
        );
        tools[i] = .{
            .name = t.name,
            .description = t.description orelse "",
            .parameters = parsed,
        };
    }
    return tools;
}

/// Execute a tool by name with JSON arguments, returning the result as a string.
pub fn call(self: *Self, arena: std.mem.Allocator, tool_name: []const u8, arguments_json: []const u8) ![]const u8 {
    const arguments = if (arguments_json.len > 0)
        (std.json.parseFromSlice(std.json.Value, arena, arguments_json, .{}) catch
            return "Error: invalid JSON arguments").value
    else
        null;

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
    });

    const action = action_map.get(tool_name) orelse return "Error: unknown tool";

    return switch (action) {
        .goto, .navigate => self.execGoto(arena, arguments),
        .markdown => self.execMarkdown(arena, arguments),
        .links => self.execLinks(arena, arguments),
        .nodeDetails => self.execNodeDetails(arena, arguments),
        .interactiveElements => self.execInteractiveElements(arena, arguments),
        .structuredData => self.execStructuredData(arena, arguments),
        .detectForms => self.execDetectForms(arena, arguments),
        .evaluate, .eval => self.execEvaluate(arena, arguments),
        .semantic_tree => self.execSemanticTree(arena, arguments),
        .click => self.execClick(arena, arguments),
        .fill => self.execFill(arena, arguments),
        .scroll => self.execScroll(arena, arguments),
        .waitForSelector => self.execWaitForSelector(arena, arguments),
    };
}

fn execGoto(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const GotoParams = struct {
        url: [:0]const u8,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrErr(GotoParams, arena, arguments) orelse return "Error: missing or invalid 'url' argument";
    self.performGoto(args.url, args.timeout, args.waitUntil) catch return "Error: navigation failed";
    return "Navigated successfully.";
}

fn execMarkdown(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const UrlParams = struct {
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = self.ensurePage(args.url, args.timeout, args.waitUntil) catch return "Error: page not loaded";

    var aw: std.Io.Writer.Allocating = .init(arena);
    lp.markdown.dump(page.window._document.asNode(), .{}, &aw.writer, page) catch return "Error: failed to generate markdown";
    return aw.written();
}

fn execLinks(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const UrlParams = struct {
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = self.ensurePage(args.url, args.timeout, args.waitUntil) catch return "Error: page not loaded";

    const links_list = lp.links.collectLinks(arena, page.window._document.asNode(), page) catch
        return "Error: failed to collect links";

    var aw: std.Io.Writer.Allocating = .init(arena);
    for (links_list, 0..) |href, i| {
        if (i > 0) aw.writer.writeByte('\n') catch {};
        aw.writer.writeAll(href) catch {};
    }
    return aw.written();
}

fn execNodeDetails(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const Params = struct { backendNodeId: CDPNode.Id };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return "Error: missing backendNodeId";

    _ = self.session.currentPage() orelse return "Error: page not loaded";

    const node = self.node_registry.lookup_by_id.get(args.backendNodeId) orelse
        return "Error: node not found";

    const page = self.session.currentPage().?;
    const details = lp.SemanticTree.getNodeDetails(arena, node.dom, &self.node_registry, page) catch
        return "Error: failed to get node details";

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(&details, .{}, &aw.writer) catch return "Error: serialization failed";
    return aw.written();
}

fn execInteractiveElements(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const UrlParams = struct {
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = self.ensurePage(args.url, args.timeout, args.waitUntil) catch return "Error: page not loaded";

    const elements = lp.interactive.collectInteractiveElements(page.window._document.asNode(), arena, page) catch
        return "Error: failed to collect interactive elements";
    lp.interactive.registerNodes(elements, &self.node_registry) catch
        return "Error: failed to register nodes";

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(elements, .{}, &aw.writer) catch return "Error: serialization failed";
    return aw.written();
}

fn execStructuredData(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const UrlParams = struct {
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = self.ensurePage(args.url, args.timeout, args.waitUntil) catch return "Error: page not loaded";

    const data = lp.structured_data.collectStructuredData(page.window._document.asNode(), arena, page) catch
        return "Error: failed to collect structured data";
    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(data, .{}, &aw.writer) catch return "Error: serialization failed";
    return aw.written();
}

fn execDetectForms(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const UrlParams = struct {
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrDefault(UrlParams, arena, arguments);
    const page = self.ensurePage(args.url, args.timeout, args.waitUntil) catch return "Error: page not loaded";

    const forms_data = lp.forms.collectForms(arena, page.window._document.asNode(), page) catch
        return "Error: failed to collect forms";
    lp.forms.registerNodes(forms_data, &self.node_registry) catch
        return "Error: failed to register form nodes";

    var aw: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.value(forms_data, .{}, &aw.writer) catch return "Error: serialization failed";
    return aw.written();
}

fn execEvaluate(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const Params = struct {
        script: [:0]const u8,
        url: ?[:0]const u8 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return "Error: missing 'script' argument";
    const page = self.ensurePage(args.url, args.timeout, args.waitUntil) catch return "Error: page not loaded";

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
        return aw.written();
    };

    return js_result.toStringSliceWithAlloc(arena) catch "undefined";
}

fn execSemanticTree(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const TreeParams = struct {
        url: ?[:0]const u8 = null,
        backendNodeId: ?u32 = null,
        maxDepth: ?u32 = null,
        timeout: ?u32 = null,
        waitUntil: ?lp.Config.WaitUntil = null,
    };
    const args = parseArgsOrDefault(TreeParams, arena, arguments);
    const page = self.ensurePage(args.url, args.timeout, args.waitUntil) catch return "Error: page not loaded";

    var root_node = page.window._document.asNode();
    if (args.backendNodeId) |node_id| {
        if (self.node_registry.lookup_by_id.get(node_id)) |n| {
            root_node = n.dom;
        }
    }

    const st = lp.SemanticTree{
        .dom_node = root_node,
        .registry = &self.node_registry,
        .page = page,
        .arena = arena,
        .prune = true,
        .max_depth = args.maxDepth orelse std.math.maxInt(u32) - 1,
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    st.textStringify(&aw.writer) catch return "Error: failed to generate semantic tree";
    return aw.written();
}

fn execClick(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const Params = struct { backendNodeId: CDPNode.Id };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return "Error: missing backendNodeId";

    const page = self.session.currentPage() orelse return "Error: page not loaded";
    const node = self.node_registry.lookup_by_id.get(args.backendNodeId) orelse return "Error: node not found";

    lp.actions.click(node.dom, page) catch |err| {
        if (err == error.InvalidNodeType) return "Error: node is not an HTML element";
        return "Error: failed to click element";
    };

    const page_title = page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Clicked element (backendNodeId: {d}). Page url: {s}, title: {s}", .{
        args.backendNodeId,
        page.url,
        page_title orelse "(none)",
    }) catch "Clicked element.";
}

fn execFill(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const Params = struct {
        backendNodeId: CDPNode.Id,
        text: []const u8,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return "Error: missing backendNodeId or text";

    const page = self.session.currentPage() orelse return "Error: page not loaded";
    const node = self.node_registry.lookup_by_id.get(args.backendNodeId) orelse return "Error: node not found";

    lp.actions.fill(node.dom, args.text, page) catch |err| {
        if (err == error.InvalidNodeType) return "Error: node is not an input, textarea or select";
        return "Error: failed to fill element";
    };

    const page_title = page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Filled element (backendNodeId: {d}) with \"{s}\". Page url: {s}, title: {s}", .{
        args.backendNodeId,
        args.text,
        page.url,
        page_title orelse "(none)",
    }) catch "Filled element.";
}

fn execScroll(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const Params = struct {
        backendNodeId: ?CDPNode.Id = null,
        x: ?i32 = null,
        y: ?i32 = null,
    };
    const args = parseArgsOrDefault(Params, arena, arguments);
    const page = self.session.currentPage() orelse return "Error: page not loaded";

    var target_node: ?*@import("../browser/webapi/Node.zig") = null;
    if (args.backendNodeId) |node_id| {
        const node = self.node_registry.lookup_by_id.get(node_id) orelse return "Error: node not found";
        target_node = node.dom;
    }

    lp.actions.scroll(target_node, args.x, args.y, page) catch |err| {
        if (err == error.InvalidNodeType) return "Error: node is not an element";
        return "Error: failed to scroll";
    };

    const page_title = page.getTitle() catch null;
    return std.fmt.allocPrint(arena, "Scrolled to x: {d}, y: {d}. Page url: {s}, title: {s}", .{
        args.x orelse 0,
        args.y orelse 0,
        page.url,
        page_title orelse "(none)",
    }) catch "Scrolled.";
}

fn execWaitForSelector(self: *Self, arena: std.mem.Allocator, arguments: ?std.json.Value) []const u8 {
    const Params = struct {
        selector: [:0]const u8,
        timeout: ?u32 = null,
    };
    const args = parseArgsOrErr(Params, arena, arguments) orelse return "Error: missing 'selector' argument";

    _ = self.session.currentPage() orelse return "Error: page not loaded";

    const timeout_ms = args.timeout orelse 5000;

    const node = lp.actions.waitForSelector(args.selector, timeout_ms, self.session) catch |err| {
        if (err == error.InvalidSelector) return "Error: invalid selector";
        if (err == error.Timeout) return "Error: timeout waiting for selector";
        return "Error: failed waiting for selector";
    };

    const registered = self.node_registry.register(node) catch return "Element found.";
    return std.fmt.allocPrint(arena, "Element found. backendNodeId: {d}", .{registered.id}) catch "Element found.";
}

fn ensurePage(self: *Self, url: ?[:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) !*lp.Page {
    if (url) |u| {
        try self.performGoto(u, timeout, waitUntil);
    }
    return self.session.currentPage() orelse error.PageNotLoaded;
}

fn performGoto(self: *Self, url: [:0]const u8, timeout: ?u32, waitUntil: ?lp.Config.WaitUntil) !void {
    const session = self.session;
    if (session.page != null) {
        session.removePage();
    }
    const page = try session.createPage();
    _ = try page.navigate(url, .{
        .reason = .address_bar,
        .kind = .{ .push = null },
    });

    var runner = try session.runner(.{});
    try runner.wait(.{
        .ms = timeout orelse 10000,
        .until = waitUntil orelse .done,
    });
}

fn parseArgsOrDefault(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value) T {
    const args_raw = arguments orelse return .{};
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch .{};
}

fn parseArgsOrErr(comptime T: type, arena: std.mem.Allocator, arguments: ?std.json.Value) ?T {
    const args_raw = arguments orelse return null;
    return std.json.parseFromValueLeaky(T, arena, args_raw, .{ .ignore_unknown_fields = true }) catch null;
}
