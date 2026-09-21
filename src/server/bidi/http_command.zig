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

// The HTTP session's commands, a second entry point onto the BiDi driver.
// The loop parses a request into a Command and parks its connection; the
// worker runs it as a BiDi.Command, which answers the parked request.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../browser/js/js.zig");
const Frame = @import("../../browser/Frame.zig");
const Node = @import("../../browser/webapi/Node.zig");

const Method = @import("../http.zig").Connection.Method;

const BiDi = @import("BiDi.zig");
const input = @import("input.zig");
const remote_value = @import("remote_value.zig");
const browsing_context = @import("browsing_context.zig");

const Allocator = std.mem.Allocator;

// The key of a WebDriver element reference: {"element-6066-…": "<sharedId>"}
pub const element_key = "element-6066-11e4-a52e-4f735466cecf";

pub const Command = union(enum) {
    navigate_to: NavigateTo,
    get_current_url,
    refresh,
    get_title,
    get_window_handle,
    get_window_handles,
    get_page_source,
    take_screenshot,
    perform_actions: PerformActions,
    release_actions,
    find_element: Find,
    find_elements: Find,
    find_element_from_element: FindFrom,
    find_elements_from_element: FindFrom,
    get_active_element,
    get_element_text: ElementId,
    get_element_tag_name: ElementId,
    get_element_attribute: ElementName,
    get_element_property: ElementName,
    get_element_css_value: ElementName,
    get_element_rect: ElementId,
    is_element_enabled: ElementId,
    is_element_selected: ElementId,
};

pub const NavigateTo = struct {
    url: [:0]const u8,
};

pub const PerformActions = struct {
    actions: []const std.json.Value,
};

// A command's path parameters are its leading fields (see `parse`); the rest
// come from the body.
pub const ElementId = struct {
    id: []const u8,
};

pub const ElementName = struct {
    id: []const u8,
    name: []const u8,
};

pub const Find = struct {
    using: Using,
    value: []const u8,
};

pub const FindFrom = struct {
    id: []const u8,
    using: Using,
    value: []const u8,
};

// The location strategies, whose wire values don't fit an enum literal. The
// tags are browsing_context.Locator's, so one maps onto the other.
pub const Using = enum {
    css,
    xpath,
    tag_name,
    link_text,
    partial_link_text,

    const wire = std.StaticStringMap(Using).initComptime(.{
        .{ "css selector", .css },
        .{ "xpath", .xpath },
        .{ "tag name", .tag_name },
        .{ "link text", .link_text },
        .{ "partial link text", .partial_link_text },
    });

    pub fn jsonParse(arena: Allocator, source: anytype, opts: std.json.ParseOptions) !Using {
        const name = try std.json.innerParse([]const u8, arena, source, opts);
        return wire.get(name) orelse error.UnexpectedToken;
    }
};

const Route = struct {
    method: Method,
    path: []const u8, // everything following /session/{id}
    command: std.meta.Tag(Command),
    segments: []const Segment,
    parameters: []const []const u8, // parameter names, in order that we capture them

    const Segment = union(enum) {
        literal: []const u8,
        parameter: []const u8, // {name}
    };

    fn init(comptime method: Method, comptime path: []const u8, comptime command: std.meta.Tag(Command)) Route {
        comptime var segments: []const Segment = &.{};
        comptime var parameters: []const []const u8 = &.{};
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            const parsed: Segment = if (segment.len > 1 and segment[0] == '{') blk: {
                if (segment[segment.len - 1] != '}') {
                    @compileError(path ++ ": '" ++ segment ++ "' is missing its closing brace");
                }
                const name = segment[1 .. segment.len - 1];
                parameters = parameters ++ [_][]const u8{name};
                break :blk .{ .parameter = name };
            } else .{ .literal = segment };

            segments = segments ++ [_]Segment{parsed};
        }

        return .{
            .method = method,
            .path = path,
            .command = command,
            .segments = segments,
            .parameters = parameters,
        };
    }

    fn match(comptime self: Route, path: []const u8, captured: [][]const u8) bool {
        var it = std.mem.splitScalar(u8, path, '/');
        comptime var i: usize = 0;
        inline for (self.segments) |segment| {
            const part = it.next() orelse return false;
            switch (segment) {
                .literal => |literal| if (!std.mem.eql(u8, literal, part)) {
                    return false;
                },
                .parameter => {
                    if (part.len == 0) {
                        return false;
                    }
                    captured[i] = part;
                    comptime i += 1;
                },
            }
        }
        return it.next() == null;
    }

    fn build(
        comptime self: Route,
        arena: Allocator,
        captured: []const []const u8,
        body: []const u8,
    ) ParseError!Command {
        const name = @tagName(self.command);

        const T = @FieldType(Command, name);
        if (comptime self.parameters.len == 0) {
            return @unionInit(Command, name, try parseBody(T, arena, body));
        }

        var value: T = undefined;
        inline for (self.parameters, 0..) |parameter, i| {
            // path is the connection's read buffer, reused once the request is parked
            @field(value, parameter) = try arena.dupe(u8, captured[i]);
        }
        const parsed = try parseBody(Body(T, self.parameters), arena, body);
        inline for (@typeInfo(@TypeOf(parsed)).@"struct".fields) |field| {
            @field(value, field.name) = @field(parsed, field.name);
        }
        return @unionInit(Command, name, value);
    }
};

// First match wins: literals need to come before parameters
const routes = [_]Route{
    .init(.POST, "/url", .navigate_to),
    .init(.GET, "/url", .get_current_url),
    .init(.POST, "/refresh", .refresh),
    .init(.GET, "/title", .get_title),
    .init(.GET, "/window", .get_window_handle),
    .init(.GET, "/window/handles", .get_window_handles),
    .init(.GET, "/source", .get_page_source),
    .init(.GET, "/screenshot", .take_screenshot),
    .init(.POST, "/actions", .perform_actions),
    .init(.DELETE, "/actions", .release_actions),
    .init(.POST, "/element", .find_element),
    .init(.POST, "/elements", .find_elements),
    .init(.GET, "/element/active", .get_active_element),
    .init(.POST, "/element/{id}/element", .find_element_from_element),
    .init(.POST, "/element/{id}/elements", .find_elements_from_element),
    .init(.GET, "/element/{id}/text", .get_element_text),
    .init(.GET, "/element/{id}/name", .get_element_tag_name),
    .init(.GET, "/element/{id}/rect", .get_element_rect),
    .init(.GET, "/element/{id}/enabled", .is_element_enabled),
    .init(.GET, "/element/{id}/selected", .is_element_selected),
    .init(.GET, "/element/{id}/attribute/{name}", .get_element_attribute),
    .init(.GET, "/element/{id}/property/{name}", .get_element_property),
    .init(.GET, "/element/{id}/css/{name}", .get_element_css_value),
};

pub const ParseError = error{
    UnknownCommand,
    InvalidArgument,
    OutOfMemory,
};

// Loop. Everything the command references is allocated in `arena`.
pub fn parse(arena: Allocator, method: Method, path: []const u8, body: []const u8) ParseError!Command {
    inline for (routes) |route| {
        if (route.method == method) {
            var captured: [route.parameters.len][]const u8 = undefined;
            if (route.match(path, &captured)) {
                return route.build(arena, &captured, body);
            }
        }
    }

    // A known path with the wrong method is W3C's "unknown method" (405). It
    // costs a second pass over the routes to tell apart, and no client cares:
    // Selenium picks its error class off the body's code, never the status.
    return error.UnknownCommand;
}

// What's left of a command once its path parameters, which are its leading
// fields, are taken out: the part that comes from the body.
fn Body(comptime T: type, comptime parameters: []const []const u8) type {
    const fields = @typeInfo(T).@"struct".fields;
    for (parameters, fields[0..parameters.len]) |parameter, field| {
        if (!std.mem.eql(u8, parameter, field.name)) {
            @compileError(@typeName(T) ++ ": field '" ++ field.name ++ "' should be the path parameter '" ++ parameter ++ "'");
        }
    }

    const rest = fields[parameters.len..];
    var field_names: [rest.len][:0]const u8 = undefined;
    var types: [rest.len]type = undefined;
    var attrs: [rest.len]std.builtin.Type.StructField.Attributes = undefined;
    for (rest, 0..) |field, i| {
        field_names[i] = field.name;
        types[i] = field.type;
        attrs[i] = .{ .@"align" = field.alignment, .default_value_ptr = field.default_value_ptr };
    }
    return @Struct(.auto, null, &field_names, &types, &attrs);
}

// Both are split on '/', so a leading empty segment lines up on either side.

fn parseBody(comptime T: type, arena: Allocator, body: []const u8) ParseError!T {
    if (T == void) {
        // POSTs without parameters still send a body ("{}"); nothing to read
        return {};
    }
    if (@typeInfo(T).@"struct".fields.len == 0) {
        // everything the command takes came from the path
        return .{};
    }
    return std.json.parseFromSliceLeaky(T, arena, body, .{
        .ignore_unknown_fields = true,
        // body is the connection's read buffer, if we park the connection, that
        // buffer will be re-used. Our result cannot point into it.
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArgument,
    };
}

// Worker.
pub fn process(cmd: *BiDi.Command) !void {
    switch (cmd.input.http) {
        .navigate_to => |p| return navigateTo(cmd, p),
        .get_current_url => return getCurrentUrl(cmd),
        .refresh => return refresh(cmd),
        .get_title => return getTitle(cmd),
        .get_window_handle => return getWindowHandle(cmd),
        .get_window_handles => return getWindowHandles(cmd),
        .get_page_source => return getPageSource(cmd),
        .take_screenshot => return takeScreenshot(cmd),
        .perform_actions => |p| return performActions(cmd, p),
        .release_actions => return releaseActions(cmd),
        .find_element => |p| return findElement(cmd, p.using, p.value, null),
        .find_elements => |p| return findElements(cmd, p.using, p.value, null),
        .find_element_from_element => |p| return findElement(cmd, p.using, p.value, p.id),
        .find_elements_from_element => |p| return findElements(cmd, p.using, p.value, p.id),
        .get_active_element => return getActiveElement(cmd),
        .get_element_text => |p| return getElementText(cmd, p),
        .get_element_tag_name => |p| return getElementTagName(cmd, p),
        .get_element_attribute => |p| return getElementAttribute(cmd, p),
        .get_element_property => |p| return getElementProperty(cmd, p),
        .get_element_css_value => |p| return getElementCssValue(cmd, p),
        .get_element_rect => |p| return getElementRect(cmd, p),
        .is_element_enabled => |p| return isElementEnabled(cmd, p),
        .is_element_selected => |p| return isElementSelected(cmd, p),
    }
}

// POST /session/{id}/url.
fn navigateTo(cmd: *BiDi.Command, p: NavigateTo) !void {
    const ctx = (try currentContext(cmd)) orelse return;
    return browsing_context.navigate(cmd, ctx, .{ .url = p.url, .wait = .complete });
}

// GET /session/{id}/url
fn getCurrentUrl(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    return cmd.sendResult(frame.url);
}

// POST /session/{id}/refresh.
fn refresh(cmd: *BiDi.Command) !void {
    const ctx = (try currentContext(cmd)) orelse return;
    return browsing_context.reload(cmd, ctx, .complete);
}

// GET /session/{id}/title
fn getTitle(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    return cmd.sendResult((try frame.getTitle()) orelse "");
}

// GET /session/{id}/window. The handle is the BiDi context id
fn getWindowHandle(cmd: *BiDi.Command) !void {
    const ctx = (try currentContext(cmd)) orelse return;
    return cmd.sendResult(&ctx.id);
}

// GET /session/{id}/window/handles
fn getWindowHandles(cmd: *BiDi.Command) !void {
    const ctx = (try currentContext(cmd)) orelse return;
    return cmd.sendResult(&[_][]const u8{&ctx.id});
}

// GET /session/{id}/source
fn getPageSource(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    var aw: std.Io.Writer.Allocating = .init(cmd.arena);
    try lp.dump.root(frame.window._document, .{ .shadow = .skip }, &aw.writer, frame);
    return cmd.sendResult(aw.written());
}

// GET /session/{id}/screenshot.
fn takeScreenshot(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const opts: lp.screenshot.Opts = .fromViewport(cmd.bidi.browser.getViewport(), false);
    const shot = try lp.screenshot.preparePng(cmd.arena, .{ .root = frame.window._document.asNode() }, opts, frame);
    return cmd.sendResult(shot);
}

// POST /session/{id}/actions.
fn performActions(cmd: *BiDi.Command, p: PerformActions) !void {
    _ = (try currentContext(cmd)) orelse return;
    return input.perform(cmd, p.actions);
}

// DELETE /session/{id}/actions
fn releaseActions(cmd: *BiDi.Command) !void {
    _ = (try currentContext(cmd)) orelse return;
    return input.release(cmd);
}

// POST /session/{id}/element, POST /session/{id}/element/{id}/element
fn findElement(cmd: *BiDi.Command, using: Using, value: []const u8, from: ?[]const u8) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const root = (try findRoot(cmd, frame, from)) orelse return;
    const nodes = (try locate(cmd, root, using, value, 1, frame)) orelse return;
    if (nodes.len == 0) {
        return cmd.sendError("no such element", "no matching element");
    }
    return cmd.sendResult(try reference(cmd, nodes[0]));
}

// POST /session/{id}/elements, POST /session/{id}/element/{id}/elements
fn findElements(cmd: *BiDi.Command, using: Using, value: []const u8, from: ?[]const u8) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const root = (try findRoot(cmd, frame, from)) orelse return;
    const nodes = (try locate(cmd, root, using, value, std.math.maxInt(u32), frame)) orelse return;

    const references = try cmd.arena.alloc(Reference, nodes.len);
    for (nodes, references) |node, *ref| {
        ref.* = try reference(cmd, node);
    }
    return cmd.sendResult(references);
}

// The document, or the element a "from element" search starts at.
fn findRoot(cmd: *BiDi.Command, frame: *Frame, from: ?[]const u8) !?*Node {
    const id = from orelse return frame.window._document.asNode();
    const element = (try requireElement(cmd, id)) orelse return null;
    return element.asNode();
}

fn locate(cmd: *BiDi.Command, root: *Node, using: Using, value: []const u8, max: u32, frame: *Frame) !?[]const *Node {
    const locator: browsing_context.Locator = switch (using) {
        inline else => |tag| @unionInit(browsing_context.Locator, @tagName(tag), value),
    };

    return locator.locate(cmd.arena, root, max, frame) catch |err| switch (err) {
        error.InvalidSelector, error.NodeSetExpected => {
            try cmd.sendError("invalid selector", "invalid selector");
            return null;
        },
        else => return err,
    };
}

// GET /session/{id}/element/active
fn getActiveElement(cmd: *BiDi.Command) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const element = frame.window._document.getActiveElement() orelse {
        return cmd.sendError("no such element", "no active element");
    };
    return cmd.sendResult(try reference(cmd, element.asNode()));
}

// GET /session/{id}/element/{id}/text.
fn getElementText(cmd: *BiDi.Command, p: ElementId) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const element = (try requireElement(cmd, p.id)) orelse return;

    var aw: std.Io.Writer.Allocating = .init(cmd.arena);
    element.getInnerText(&aw.writer, frame) catch |err| switch (err) {
        error.NotHtmlElement => try element.asNode().getTextContent(&aw.writer),
        else => return err,
    };
    return cmd.sendResult(aw.written());
}

// GET /session/{id}/element/{id}/name. Lowercase, like every other driver.
fn getElementTagName(cmd: *BiDi.Command, p: ElementId) !void {
    const element = (try requireElement(cmd, p.id)) orelse return;
    return cmd.sendResult(element.getTagNameLower());
}

// GET /session/{id}/element/{id}/attribute/{name}
fn getElementAttribute(cmd: *BiDi.Command, p: ElementName) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const element = (try requireElement(cmd, p.id)) orelse return;

    if (isBooleanAttribute(p.name)) {
        // a boolean attribute is "true" or nothing at all, never its value
        if (try element.hasAttribute(.wrap(p.name), frame)) {
            return cmd.sendResult("true");
        }
        return cmd.sendDone();
    }

    // the String stays in a local: str() can point into the String itself
    const value = (try element.getAttribute(.wrap(p.name), frame)) orelse return cmd.sendDone();
    return cmd.sendResult(value.str());
}

// GET /session/{id}/element/{id}/property/{name}
fn getElementProperty(cmd: *BiDi.Command, p: ElementName) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const element = (try requireElement(cmd, p.id)) orelse return;

    var scope: js.Local.Scope = undefined;
    frame.js.localScope(&scope);
    defer scope.deinit();

    const object = (try scope.local.zigValueToJs(element, .{})).toObject();
    const value = object.get(p.name) catch {
        return cmd.sendError("javascript error", "the property threw");
    };

    // A node is an element reference; anything else is JSON as V8 writes it.
    // taggedOpaque reads an internal field, so the value has to be an object.
    if (value.isObject()) {
        if (value.taggedOpaque()) |tagged| {
            if (tagged.as(Node)) |node| {
                return cmd.sendResult(try reference(cmd, node));
            }
        }
    }
    return cmd.sendResult(value);
}

// GET /session/{id}/element/{id}/css/{name}
fn getElementCssValue(cmd: *BiDi.Command, p: ElementName) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const element = (try requireElement(cmd, p.id)) orelse return;
    const style = try frame.window.getComputedStyle(element, null, frame);
    return cmd.sendResult(style.asCSSStyleDeclaration().getPropertyValue(p.name, frame));
}

// GET /session/{id}/element/{id}/rect. Absolute, so the viewport rect plus
// however far the page is scrolled.
fn getElementRect(cmd: *BiDi.Command, p: ElementId) !void {
    const frame = (try currentFrame(cmd)) orelse return;
    const element = (try requireElement(cmd, p.id)) orelse return;
    const rect = try element.getBoundingClientRect(frame);
    const window = frame.window;
    return cmd.sendResult(.{
        .x = rect.getX() + @as(f64, @floatFromInt(window.getScrollX())),
        .y = rect.getY() + @as(f64, @floatFromInt(window.getScrollY())),
        .width = rect.getWidth(),
        .height = rect.getHeight(),
    });
}

// GET /session/{id}/element/{id}/enabled
fn isElementEnabled(cmd: *BiDi.Command, p: ElementId) !void {
    const element = (try requireElement(cmd, p.id)) orelse return;
    return cmd.sendResult(element.isDisabled() == false);
}

// GET /session/{id}/element/{id}/selected
fn isElementSelected(cmd: *BiDi.Command, p: ElementId) !void {
    const element = (try requireElement(cmd, p.id)) orelse return;

    if (element.is(Node.Element.Html.Input)) |input_element| {
        return cmd.sendResult(switch (input_element._input_type) {
            .checkbox, .radio => input_element.getChecked(),
            else => false,
        });
    }
    if (element.is(Node.Element.Html.Option)) |option| {
        return cmd.sendResult(option.getSelected());
    }
    return cmd.sendResult(false);
}

// {"element-6066-…": "<sharedId>"}: a WebDriver element reference is the
// node registry's id, the same one BiDi hands out.
const Reference = struct {
    shared_id: []const u8,

    pub fn jsonStringify(self: Reference, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField(element_key);
        try jws.write(self.shared_id);
        try jws.endObject();
    }
};

fn reference(cmd: *BiDi.Command, node: *Node) !Reference {
    const registered = try cmd.bidi.node_registry.register(node);
    return .{ .shared_id = try std.fmt.allocPrint(cmd.arena, "{d}", .{registered.id}) };
}

// Answers the command and returns null when the reference doesn't resolve.
fn requireElement(cmd: *BiDi.Command, id: []const u8) !?*Node.Element {
    const node = remote_value.nodeFromSharedId(&cmd.bidi.node_registry, .{ .string = id }) catch {
        // ids are dropped on navigation, so a stale one is unknown by then
        try cmd.sendError("no such element", "unknown element reference");
        return null;
    };

    const element = node.is(Node.Element) orelse {
        try cmd.sendError("no such element", "not an element");
        return null;
    };

    if (node.isConnected() == false) {
        try cmd.sendError("stale element reference", "element is no longer attached to the document");
        return null;
    }
    return element;
}

// HTML's boolean attributes: present means "true", absent means null, and
// the attribute's own value never shows up.
const boolean_attributes = std.StaticStringMap(void).initComptime(.{
    .{"allowfullscreen"}, .{"async"},          .{"autofocus"},  .{"autoplay"},
    .{"checked"},         .{"controls"},       .{"default"},    .{"defer"},
    .{"disabled"},        .{"formnovalidate"}, .{"hidden"},     .{"inert"},
    .{"ismap"},           .{"itemscope"},      .{"loop"},       .{"multiple"},
    .{"muted"},           .{"nomodule"},       .{"novalidate"}, .{"open"},
    .{"playsinline"},     .{"readonly"},       .{"required"},   .{"reversed"},
    .{"selected"},
});

fn isBooleanAttribute(name: []const u8) bool {
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) {
        return false;
    }
    return boolean_attributes.has(std.ascii.lowerString(buf[0..name.len], name));
}

fn currentContext(cmd: *BiDi.Command) !?*browsing_context.Context {
    if (cmd.bidi.browsing_context) |*ctx| {
        return ctx;
    }
    return browsing_context.openContext(cmd.bidi) catch |err| switch (err) {
        error.CreatePage => {
            try cmd.sendError("unknown error", "failed to create page");
            return null;
        },
        else => return err,
    };
}

fn currentFrame(cmd: *BiDi.Command) !?*Frame {
    _ = (try currentContext(cmd)) orelse return null;
    return cmd.bidi.user_context.session.currentFrame() orelse {
        try cmd.sendError("no such window", "no frame");
        return null;
    };
}

const testing = @import("testing.zig");
test "bidi.http_command: parse" {
    const arena = testing.arena;

    {
        const command = try parse(arena, .POST, "/url", "{\"url\":\"about:blank\",\"extra\":1}");
        try testing.expectEqual("about:blank", command.navigate_to.url);
    }

    {
        // parameterless commands ignore the body
        const command = try parse(arena, .POST, "/refresh", "{}");
        try testing.expect(command == .refresh);
    }

    {
        const command = try parse(arena, .POST, "/actions", "{\"actions\":[{\"type\":\"none\",\"id\":\"n\",\"actions\":[]}]}");
        try testing.expectEqual(1, command.perform_actions.actions.len);
    }

    {
        const command = try parse(arena, .POST, "/element", "{\"using\":\"css selector\",\"value\":\"#a\"}");
        try testing.expectEqual(.css, command.find_element.using);
        try testing.expectEqual("#a", command.find_element.value);
    }

    {
        // a path parameter and a body
        const command = try parse(arena, .POST, "/element/7/elements", "{\"using\":\"link text\",\"value\":\"go\"}");
        try testing.expectEqual("7", command.find_elements_from_element.id);
        try testing.expectEqual(.link_text, command.find_elements_from_element.using);
        try testing.expectEqual("go", command.find_elements_from_element.value);
    }

    {
        // two path parameters, no body
        const command = try parse(arena, .GET, "/element/7/attribute/data-x", "");
        try testing.expectEqual("7", command.get_element_attribute.id);
        try testing.expectEqual("data-x", command.get_element_attribute.name);
    }

    // a literal segment wins over the parameter that would also match it
    try testing.expect(try parse(arena, .GET, "/element/active", "") == .get_active_element);
    try testing.expect(try parse(arena, .GET, "/element/7/text", "") == .get_element_text);

    try testing.expect(try parse(arena, .GET, "/url", "") == .get_current_url);
    try testing.expect(try parse(arena, .GET, "/window/handles", "") == .get_window_handles);
    try testing.expect(try parse(arena, .DELETE, "/actions", "") == .release_actions);

    // a known path with the wrong method is an unknown command too
    try testing.expectError(error.UnknownCommand, parse(arena, .PUT, "/url", ""));
    try testing.expectError(error.UnknownCommand, parse(arena, .POST, "/title", "{}"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/actions", "{}"));
    try testing.expectError(error.UnknownCommand, parse(arena, .POST, "/nope", "{}"));
    try testing.expectError(error.UnknownCommand, parse(arena, .POST, "/element/7/text", "{}"));
    try testing.expectError(error.UnknownCommand, parse(arena, .GET, "/element//text", ""));
    try testing.expectError(error.UnknownCommand, parse(arena, .GET, "/element/7/text/more", ""));
    try testing.expectError(error.UnknownCommand, parse(arena, .GET, "/element/7", ""));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/element", "{\"using\":\"nope\",\"value\":\"x\"}"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/element/7/element", "{\"using\":\"xpath\"}"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/url", "not json"));
    try testing.expectError(error.InvalidArgument, parse(arena, .POST, "/url", "{}"));
}
