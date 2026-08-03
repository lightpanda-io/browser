//! Minimal W3C WebDriver remote-end command router. The HTTP transport owns
//! framing; this module owns command routing and JSON response semantics.

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("lightpanda");

const cdp_id = @import("../cdp/id.zig");
const Element = @import("../browser/webapi/Element.zig");
const DOMNode = @import("../browser/webapi/Node.zig");
const Input = @import("../browser/webapi/element/html/Input.zig");
const Option = @import("../browser/webapi/element/html/Option.zig");
const Select = @import("../browser/webapi/element/html/Select.zig");
const Selector = @import("../browser/webapi/selector/Selector.zig");
const Server = @import("Server.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;
const JsonObject = std.json.ObjectMap;

const Timeouts = struct {
    script: ?u64 = 30_000,
    page_load: ?u64 = 300_000,
    implicit: ?u64 = 0,
};

const PageLoadStrategy = enum {
    none,
    eager,
    normal,

    fn waitUntil(self: PageLoadStrategy) ?lp.Config.WaitUntil {
        return switch (self) {
            .none => null,
            .eager => .domcontentloaded,
            .normal => .load,
        };
    }
};

const EffectiveCapabilities = struct {
    page_load_strategy: PageLoadStrategy = .normal,
    timeouts: Timeouts = .{},
    proxy_direct: bool = false,
    strict_file_interactability: bool = false,
    unhandled_prompt_behavior: []const u8 = "dismiss and notify",
};

const CapabilityValidationError = struct {
    name: []const u8,
    unknown: bool = false,
};

const Command = enum {
    status,
    new_session,
    delete_session,
    navigate,
    current_url,
    get_title,
    get_page_source,
    get_window_handle,
    get_window_handles,
    close_window,
    get_timeouts,
    set_timeouts,
    find_element,
    find_elements,
    find_element_from_element,
    find_elements_from_element,
    get_active_element,
    get_element_tag_name,
    get_element_attribute,
    is_element_selected,
    is_element_enabled,
};

const Route = struct {
    command: Command,
    alternate: ?Command = null,
    session_id: ?[]const u8 = null,
    element_id: ?[]const u8 = null,
    attribute_name: ?[]const u8 = null,
};

pub fn handle(
    server: *Server,
    arena: Allocator,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    out: *std.Io.Writer,
) !std.http.Status {
    const route = matchRoute(requestPath(target)) orelse
        return sendError(out, .not_found, "unknown command", "Unknown command");
    const command = commandForMethod(route, method) orelse {
        return sendError(out, .method_not_allowed, "unknown method", "Method is not allowed for this command");
    };

    switch (command) {
        .status => return sendValue(out, .{
            .ready = server.webdriverReady(),
            .message = if (server.webdriverReady())
                "Lightpanda WebDriver endpoint is ready"
            else
                "A WebDriver session is active",
        }),
        .new_session => return newSession(server, arena, body, out),
        else => {},
    }

    const session_id = route.session_id.?;
    const session = server.getWebDriverSession(session_id) orelse
        return sendError(out, .not_found, "invalid session id", "No active session with this id");

    if (command == .delete_session) {
        _ = server.closeWebDriverSession(session_id);
        return sendValue(out, @as(?u8, null));
    }

    // Closing the last WebDriver window destroys its session. Do this before
    // entering its isolate, so the normal isolate defer cannot outlive it.
    if (command == .close_window) return closeWindow(server, session_id, session, out);

    server.enterIsolate(session);
    defer server.exitIsolate(session);

    return switch (command) {
        .navigate => navigate(server, session, arena, body, out),
        .current_url => currentUrl(session, out),
        .get_title => getTitle(session, out),
        .get_page_source => getPageSource(session, out),
        .get_window_handle => getWindowHandle(session, out),
        .get_window_handles => getWindowHandles(session, out),
        .get_timeouts => getTimeouts(server, out),
        .set_timeouts => setTimeouts(server, arena, body, out),
        .find_element => findElement(server, session, arena, body, null, out),
        .find_elements => findElements(server, session, arena, body, null, out),
        .find_element_from_element => findElement(server, session, arena, body, route.element_id.?, out),
        .find_elements_from_element => findElements(server, session, arena, body, route.element_id.?, out),
        .get_active_element => getActiveElement(session, out),
        .get_element_tag_name => getElementTagName(session, route.element_id.?, out),
        .get_element_attribute => getElementAttribute(session, arena, route.element_id.?, route.attribute_name.?, out),
        .is_element_selected => isElementSelected(session, route.element_id.?, out),
        .is_element_enabled => isElementEnabled(session, route.element_id.?, out),
        else => unreachable,
    };
}

fn newSession(server: *Server, arena: Allocator, body: []const u8, out: *std.Io.Writer) !std.http.Status {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return sendError(out, .bad_request, "invalid argument", "New Session parameters must be a JSON object");
    defer parsed.deinit();
    if (parsed.value != .object) {
        return sendError(out, .bad_request, "invalid argument", "New Session parameters must be a JSON object");
    }
    if (!server.webdriverReady()) {
        return sendError(out, .internal_server_error, "session not created", "The endpoint already has an active WebDriver session");
    }

    const capabilities_value = parsed.value.object.get("capabilities") orelse
        return sendError(out, .bad_request, "invalid argument", "New Session requires a capabilities object");
    if (capabilities_value != .object) {
        return sendError(out, .bad_request, "invalid argument", "capabilities must be an object");
    }
    const capabilities = capabilities_value.object;

    var always_match: ?JsonObject = null;
    if (capabilities.get("alwaysMatch")) |value| {
        if (value != .object) {
            return sendError(out, .bad_request, "invalid argument", "alwaysMatch must be an object");
        }
        always_match = value.object;
        if (validateCapabilities(value.object)) |err| return sendCapabilityValidationError(arena, out, err);
    }

    var matched: ?EffectiveCapabilities = null;
    if (capabilities.get("firstMatch")) |value| {
        if (value != .array or value.array.items.len == 0) {
            return sendError(out, .bad_request, "invalid argument", "firstMatch must be a non-empty array");
        }

        for (value.array.items) |candidate| {
            if (candidate != .object) {
                return sendError(out, .bad_request, "invalid argument", "Each firstMatch entry must be an object");
            }
            if (validateCapabilities(candidate.object)) |err| return sendCapabilityValidationError(arena, out, err);
            if (hasCapabilityConflict(always_match, candidate.object)) {
                return sendError(out, .bad_request, "invalid argument", "alwaysMatch and firstMatch contain the same capability");
            }
        }

        for (value.array.items) |candidate| {
            if (mergeAndMatch(always_match, candidate.object)) |effective| {
                matched = effective;
                break;
            }
        }
    } else {
        matched = mergeAndMatch(always_match, null);
    }

    const effective = matched orelse {
        return sendError(
            out,
            .internal_server_error,
            "session not created",
            "No firstMatch entry is supported; this endpoint supports browserName=lightpanda, direct networking, acceptInsecureCerts=false, and standard strict file and prompt capabilities",
        );
    };

    const session_id = server.nextWebDriverSessionId(arena) catch
        return sendError(out, .internal_server_error, "session not created", "Could not allocate a session id");
    const session = server.createWebDriverSession(
        session_id,
        effective.page_load_strategy.waitUntil(),
        effective.timeouts.page_load,
        effective.timeouts.script,
        effective.timeouts.implicit,
    ) catch
        return sendError(out, .internal_server_error, "session not created", "Could not create a browser session");
    errdefer _ = server.closeWebDriverSession(session_id);

    return sendValue(out, .{
        .sessionId = session_id,
        .capabilities = .{
            .browserName = "lightpanda",
            .browserVersion = lp.build_config.version,
            .platformName = platformName(),
            .acceptInsecureCerts = false,
            .pageLoadStrategy = @tagName(effective.page_load_strategy),
            .proxy = .{ .proxyType = "direct" },
            .timeouts = .{
                .script = effective.timeouts.script,
                .pageLoad = effective.timeouts.page_load,
                .implicit = effective.timeouts.implicit,
            },
            .strictFileInteractability = effective.strict_file_interactability,
            .setWindowRect = false,
            .userAgent = session.browser.http_client.getUserAgent(),
            .unhandledPromptBehavior = effective.unhandled_prompt_behavior,
        },
    });
}

fn validateCapabilities(capabilities: JsonObject) ?CapabilityValidationError {
    var it = capabilities.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value == .null) continue;

        const valid = if (std.mem.eql(u8, name, "browserName") or
            std.mem.eql(u8, name, "browserVersion") or
            std.mem.eql(u8, name, "platformName"))
            value == .string
        else if (std.mem.eql(u8, name, "acceptInsecureCerts") or
            std.mem.eql(u8, name, "strictFileInteractability"))
            value == .bool
        else if (std.mem.eql(u8, name, "pageLoadStrategy"))
            value == .string and isPageLoadStrategy(value.string)
        else if (std.mem.eql(u8, name, "proxy"))
            value == .object and validProxy(value.object)
        else if (std.mem.eql(u8, name, "timeouts"))
            value == .object and validTimeouts(value.object)
        else if (std.mem.eql(u8, name, "unhandledPromptBehavior"))
            value == .string and isPromptHandler(value.string)
        else if (std.mem.indexOfScalar(u8, name, ':') != null)
            true
        else
            return .{ .name = name, .unknown = true };

        if (!valid) return .{ .name = name };
    }
    return null;
}

fn sendCapabilityValidationError(
    arena: Allocator,
    out: *std.Io.Writer,
    err: CapabilityValidationError,
) !std.http.Status {
    const message = (if (err.unknown)
        std.fmt.allocPrint(arena, "Unknown capability: {s}", .{err.name})
    else
        std.fmt.allocPrint(arena, "Invalid value for capability: {s}", .{err.name})) catch
        return sendError(out, .internal_server_error, "unknown error", "Could not validate capabilities");
    return sendError(out, .bad_request, "invalid argument", message);
}

fn hasCapabilityConflict(always_match: ?JsonObject, first_match: JsonObject) bool {
    const always = always_match orelse return false;
    var it = first_match.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        const primary = always.get(entry.key_ptr.*) orelse continue;
        if (primary != .null) return true;
    }
    return false;
}

fn mergeAndMatch(always_match: ?JsonObject, first_match: ?JsonObject) ?EffectiveCapabilities {
    var effective: EffectiveCapabilities = .{};
    if (!capabilityObjectMatches(&effective, always_match)) return null;
    if (!capabilityObjectMatches(&effective, first_match)) return null;
    return effective;
}

fn capabilityObjectMatches(effective: *EffectiveCapabilities, capabilities: ?JsonObject) bool {
    const object = capabilities orelse return true;
    var it = object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value == .null) continue;

        if (std.mem.eql(u8, name, "browserName")) {
            if (!std.mem.eql(u8, value.string, "lightpanda")) return false;
        } else if (std.mem.eql(u8, name, "browserVersion")) {
            if (!browserVersionMatches(value.string, lp.build_config.version)) return false;
        } else if (std.mem.eql(u8, name, "platformName")) {
            if (!std.mem.eql(u8, value.string, platformName())) return false;
        } else if (std.mem.eql(u8, name, "acceptInsecureCerts") or
            std.mem.eql(u8, name, "strictFileInteractability"))
        {
            if (std.mem.eql(u8, name, "acceptInsecureCerts") and value.bool) return false;
            if (std.mem.eql(u8, name, "strictFileInteractability")) {
                effective.strict_file_interactability = value.bool;
            }
        } else if (std.mem.eql(u8, name, "pageLoadStrategy")) {
            effective.page_load_strategy = std.meta.stringToEnum(PageLoadStrategy, value.string) orelse return false;
        } else if (std.mem.eql(u8, name, "timeouts")) {
            effective.timeouts = deserializeTimeouts(value.object) orelse return false;
        } else if (std.mem.eql(u8, name, "proxy")) {
            if (value.object.count() != 1 or
                !std.mem.eql(u8, value.object.get("proxyType").?.string, "direct"))
            {
                return false;
            }
            effective.proxy_direct = true;
        } else if (std.mem.eql(u8, name, "unhandledPromptBehavior")) {
            if (!isPromptHandler(value.string)) return false;
            effective.unhandled_prompt_behavior = value.string;
        } else {
            // Extension capabilities are valid inputs but only match when this
            // implementation knows how to honor them.
            return false;
        }
    }
    return true;
}

fn browserVersionMatches(requested: []const u8, actual: []const u8) bool {
    var constraints = std.mem.tokenizeAny(u8, requested, " \t\r\n");
    var found = false;
    while (constraints.next()) |constraint| {
        found = true;
        const comparison = versionComparison(constraint, actual) orelse return false;
        if (!comparison) return false;
    }
    return found;
}

fn versionComparison(constraint: []const u8, actual: []const u8) ?bool {
    const Operator = enum { equal, less, less_equal, greater, greater_equal };
    const operator: Operator, const expected = if (std.mem.startsWith(u8, constraint, ">="))
        .{ .greater_equal, constraint[2..] }
    else if (std.mem.startsWith(u8, constraint, "<="))
        .{ .less_equal, constraint[2..] }
    else if (std.mem.startsWith(u8, constraint, ">"))
        .{ .greater, constraint[1..] }
    else if (std.mem.startsWith(u8, constraint, "<"))
        .{ .less, constraint[1..] }
    else
        .{ .equal, constraint };
    if (expected.len == 0) return null;

    const ordering = compareVersion(actual, expected) orelse return null;
    return switch (operator) {
        .equal => ordering == .eq,
        .less => ordering == .lt,
        .less_equal => ordering != .gt,
        .greater => ordering == .gt,
        .greater_equal => ordering != .lt,
    };
}

fn compareVersion(actual: []const u8, expected: []const u8) ?std.math.Order {
    const actual_parts = splitVersion(actual) orelse return null;
    const expected_parts = splitVersion(expected) orelse return null;
    var actual_segments = std.mem.splitScalar(u8, actual_parts.numeric, '.');
    var expected_segments = std.mem.splitScalar(u8, expected_parts.numeric, '.');
    while (true) {
        const actual_segment = actual_segments.next();
        const expected_segment = expected_segments.next();
        if (actual_segment == null and expected_segment == null) break;
        const lhs = if (actual_segment) |segment| parseVersionSegment(segment) orelse return null else 0;
        const rhs = if (expected_segment) |segment| parseVersionSegment(segment) orelse return null else 0;
        const ordering = std.math.order(lhs, rhs);
        if (ordering != .eq) return ordering;
    }

    if (actual_parts.pre) |actual_pre| {
        const expected_pre = expected_parts.pre orelse return .lt;
        return std.mem.order(u8, actual_pre, expected_pre);
    }
    return if (expected_parts.pre == null) .eq else .gt;
}

fn splitVersion(value: []const u8) ?struct { numeric: []const u8, pre: ?[]const u8 } {
    const build_start = std.mem.indexOfScalar(u8, value, '+') orelse value.len;
    const release = value[0..build_start];
    const pre_start = std.mem.indexOfScalar(u8, release, '-');
    const numeric = release[0..(pre_start orelse release.len)];
    if (numeric.len == 0) return null;
    const pre = if (pre_start) |start| release[start + 1 ..] else null;
    if (pre) |identifier| if (identifier.len == 0) return null;
    return .{ .numeric = numeric, .pre = pre };
}

fn parseVersionSegment(segment: []const u8) ?u64 {
    if (segment.len == 0) return null;
    return std.fmt.parseUnsigned(u64, segment, 10) catch null;
}

fn isPageLoadStrategy(value: []const u8) bool {
    return std.mem.eql(u8, value, "none") or
        std.mem.eql(u8, value, "eager") or
        std.mem.eql(u8, value, "normal");
}

fn validTimeouts(timeouts: JsonObject) bool {
    var it = timeouts.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!std.mem.eql(u8, name, "script") and
            !std.mem.eql(u8, name, "pageLoad") and
            !std.mem.eql(u8, name, "implicit"))
        {
            continue;
        }
        if (entry.value_ptr.* != .null and unsignedSafeInteger(entry.value_ptr.*) == null) return false;
    }
    return true;
}

fn deserializeTimeouts(timeouts: JsonObject) ?Timeouts {
    var result: Timeouts = .{};
    var it = timeouts.iterator();
    while (it.next()) |entry| {
        const target = if (std.mem.eql(u8, entry.key_ptr.*, "script"))
            &result.script
        else if (std.mem.eql(u8, entry.key_ptr.*, "pageLoad"))
            &result.page_load
        else if (std.mem.eql(u8, entry.key_ptr.*, "implicit"))
            &result.implicit
        else
            continue;

        if (entry.value_ptr.* == .null) {
            target.* = null;
            continue;
        }
        const value = unsignedSafeInteger(entry.value_ptr.*) orelse return null;
        target.* = value;
    }
    return result;
}

fn unsignedSafeInteger(value: std.json.Value) ?u64 {
    const max_safe_integer: i64 = 9_007_199_254_740_991;
    return switch (value) {
        .integer => |number| if (number >= 0 and number <= max_safe_integer) @intCast(number) else null,
        .float => |number| if (std.math.isFinite(number) and
            number >= 0 and
            number <= @as(f64, @floatFromInt(max_safe_integer)) and
            @floor(number) == number)
            @intFromFloat(number)
        else
            null,
        else => null,
    };
}

fn validProxy(proxy: JsonObject) bool {
    var proxy_type: ?[]const u8 = null;
    var has_pac_url = false;
    var has_socks_proxy = false;
    var has_socks_version = false;

    var it = proxy.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, name, "proxyType")) {
            if (value != .string or !isProxyType(value.string)) return false;
            proxy_type = value.string;
        } else if (std.mem.eql(u8, name, "proxyAutoconfigUrl") or
            std.mem.eql(u8, name, "httpProxy") or
            std.mem.eql(u8, name, "sslProxy") or
            std.mem.eql(u8, name, "socksProxy"))
        {
            if (value != .string) return false;
            if (std.mem.eql(u8, name, "proxyAutoconfigUrl")) {
                if (!lp.URL.canParse(value.string, null)) return false;
                has_pac_url = true;
            } else if (!validProxyEndpoint(name, value.string)) {
                return false;
            }
            has_socks_proxy = has_socks_proxy or std.mem.eql(u8, name, "socksProxy");
        } else if (std.mem.eql(u8, name, "noProxy")) {
            if (value != .array) return false;
            for (value.array.items) |item| if (item != .string) return false;
        } else if (std.mem.eql(u8, name, "socksVersion")) {
            const version = unsignedSafeInteger(value) orelse return false;
            if (version > 255) return false;
            has_socks_version = true;
        } else {
            return false;
        }
    }

    const typ = proxy_type orelse return false;
    if (std.mem.eql(u8, typ, "pac") and !has_pac_url) return false;
    if (has_socks_proxy and !has_socks_version) return false;
    return true;
}

fn validProxyEndpoint(name: []const u8, endpoint: []const u8) bool {
    // The WebDriver value is a host with an optional port, not a URL. Prefix
    // it with the required scheme so the URL parser validates both parts.
    if (endpoint.len == 0) return false;
    for (endpoint) |byte| {
        if (byte <= ' ' or byte == '/' or byte == '?' or byte == '#' or byte == '\\') return false;
    }
    const scheme = if (std.mem.eql(u8, name, "httpProxy"))
        "http"
    else if (std.mem.eql(u8, name, "sslProxy"))
        "https"
    else
        "socks5";
    var buffer: [4096]u8 = undefined;
    const url = std.fmt.bufPrint(&buffer, "{s}://{s}/", .{ scheme, endpoint }) catch return false;
    return lp.URL.canParse(url, null);
}

fn isProxyType(value: []const u8) bool {
    return std.mem.eql(u8, value, "pac") or
        std.mem.eql(u8, value, "direct") or
        std.mem.eql(u8, value, "autodetect") or
        std.mem.eql(u8, value, "system") or
        std.mem.eql(u8, value, "manual");
}

fn isPromptHandler(value: []const u8) bool {
    return std.mem.eql(u8, value, "dismiss") or
        std.mem.eql(u8, value, "accept") or
        std.mem.eql(u8, value, "dismiss and notify") or
        std.mem.eql(u8, value, "accept and notify") or
        std.mem.eql(u8, value, "ignore");
}

fn platformName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "mac",
        .windows => "windows",
        else => @tagName(builtin.os.tag),
    };
}

const element_key = "element-6066-11e4-a52e-4f735466cecf";

const ElementReference = struct {
    session_id: []const u8,
    node_id: u32,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        var buffer: [48]u8 = undefined;
        const id = std.fmt.bufPrint(&buffer, "{s}-{d}", .{ self.session_id, self.node_id }) catch unreachable;
        try jw.beginObject();
        try jw.objectField(element_key);
        try jw.write(id);
        try jw.endObject();
    }
};

const Locator = struct {
    using: []const u8,
    value: []const u8,
};

fn parseLocator(arena: Allocator, body: []const u8, out: *std.Io.Writer) !?Locator {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        _ = try sendError(out, .bad_request, "invalid argument", "Locator parameters must contain string using and value fields");
        return null;
    };
    if (parsed != .object) {
        _ = try sendError(out, .bad_request, "invalid argument", "Locator parameters must contain string using and value fields");
        return null;
    }
    const using = parsed.object.get("using") orelse {
        _ = try sendError(out, .bad_request, "invalid argument", "Locator parameters must contain string using and value fields");
        return null;
    };
    const value = parsed.object.get("value") orelse {
        _ = try sendError(out, .bad_request, "invalid argument", "Locator parameters must contain string using and value fields");
        return null;
    };
    if (using != .string or value != .string) {
        _ = try sendError(out, .bad_request, "invalid argument", "Locator parameters must contain string using and value fields");
        return null;
    }
    return .{ .using = using.string, .value = value.string };
}

fn findElement(
    server: *Server,
    session: *Server.Session,
    arena: Allocator,
    body: []const u8,
    parent_id: ?[]const u8,
    out: *std.Io.Writer,
) !std.http.Status {
    const locator = (try parseLocator(arena, body, out)) orelse return .bad_request;
    const root = (try searchRoot(session, parent_id, out)) orelse return .not_found;
    if (!std.mem.eql(u8, locator.using, "css selector")) {
        return sendError(out, .bad_request, "invalid argument", "Only the css selector locator strategy is supported");
    }
    const selectors = parseCssSelectors(arena, locator.value) catch |err|
        return sendSelectorError(out, err);
    var wait = ImplicitWait.init(session, server.webdriverImplicitTimeout());
    defer wait.deinit(session);

    while (true) {
        const frame = (try activeSearchFrame(session, root, out)) orelse return .not_found;
        const element = Selector.queryInTreeOrder(selectors, root.node, frame);
        if (element) |found| {
            return sendValue(out, try elementReference(session, found));
        }

        if (wait.expired(session)) {
            _ = wait.finish(session);
            return sendError(out, .not_found, "no such element", "Unable to locate element");
        }
        if (session.browser.env.terminatePending()) {
            if (wait.finish(session)) {
                return sendError(out, .not_found, "no such element", "Unable to locate element");
            }
            return sendError(out, .internal_server_error, "unknown error", "Element lookup was cancelled");
        }
        waitForImplicitPoll(session, root.frame_id, wait.remaining()) catch |err| {
            if (wait.finish(session)) {
                return sendError(out, .not_found, "no such element", "Unable to locate element");
            }
            return sendError(out, .internal_server_error, "unknown error", @errorName(err));
        };
    }
}

fn findElements(
    server: *Server,
    session: *Server.Session,
    arena: Allocator,
    body: []const u8,
    parent_id: ?[]const u8,
    out: *std.Io.Writer,
) !std.http.Status {
    const locator = (try parseLocator(arena, body, out)) orelse return .bad_request;
    const root = (try searchRoot(session, parent_id, out)) orelse return .not_found;
    if (!std.mem.eql(u8, locator.using, "css selector")) {
        return sendError(out, .bad_request, "invalid argument", "Only the css selector locator strategy is supported");
    }
    const selectors = parseCssSelectors(arena, locator.value) catch |err|
        return sendSelectorError(out, err);
    var wait = ImplicitWait.init(session, server.webdriverImplicitTimeout());
    defer wait.deinit(session);

    while (true) {
        const frame = (try activeSearchFrame(session, root, out)) orelse return .not_found;
        const elements = Selector.queryAll(selectors, root.node, frame) catch
            return sendError(out, .internal_server_error, "unknown error", "Could not query elements");
        const references: ?[]ElementReference = blk: {
            defer elements.deinit(frame._page);
            if (elements._nodes.len == 0) break :blk null;

            const found = try arena.alloc(ElementReference, elements._nodes.len);
            for (elements._nodes, found) |node, *reference| {
                reference.* = try elementReference(session, node.is(Element).?);
            }
            break :blk found;
        };
        if (references) |found| return sendValue(out, found);

        if (wait.expired(session)) {
            _ = wait.finish(session);
            return sendValue(out, [_]ElementReference{});
        }
        if (session.browser.env.terminatePending()) {
            if (wait.finish(session)) return sendValue(out, [_]ElementReference{});
            return sendError(out, .internal_server_error, "unknown error", "Element lookup was cancelled");
        }
        waitForImplicitPoll(session, root.frame_id, wait.remaining()) catch |err| {
            if (wait.finish(session)) return sendValue(out, [_]ElementReference{});
            return sendError(out, .internal_server_error, "unknown error", @errorName(err));
        };
    }
}

const SearchRoot = struct {
    node: *DOMNode,
    document_node: *DOMNode,
    frame_id: u32,
    from_element: bool,
};

fn searchRoot(session: *Server.Session, parent_id: ?[]const u8, out: *std.Io.Writer) !?SearchRoot {
    const frame = primaryFrame(session) orelse {
        _ = try sendError(out, .not_found, "no such window", "Current browsing context has no document");
        return null;
    };
    if (parent_id == null and frame.document.getDocumentElement() == null) {
        _ = try sendError(out, .not_found, "no such element", "Current document has no document element");
        return null;
    }
    const node = if (parent_id) |id|
        ((try resolveElement(session, id, out)) orelse return null).asNode()
    else
        frame.document.asNode();
    return .{
        .node = node,
        .document_node = frame.document.asNode(),
        .frame_id = frame._frame_id,
        .from_element = parent_id != null,
    };
}

fn parseCssSelectors(arena: Allocator, value: []const u8) ![]const Selector.Selector {
    return Selector.parseLeaky(arena, value) catch |err| return Selector.mapErrorToDOM(err);
}

fn sendSelectorError(out: *std.Io.Writer, err: anyerror) !std.http.Status {
    return switch (err) {
        error.SyntaxError => sendError(out, .bad_request, "invalid selector", "Invalid CSS selector"),
        error.OutOfMemory => sendError(out, .internal_server_error, "unknown error", "Could not parse selector"),
        else => sendError(out, .internal_server_error, "unknown error", @errorName(err)),
    };
}

fn activeSearchFrame(
    session: *Server.Session,
    root: SearchRoot,
    out: *std.Io.Writer,
) !?*lp.Frame {
    const frame = primaryFrame(session) orelse {
        _ = try sendError(out, .not_found, "no such window", "Current browsing context has no document");
        return null;
    };
    if (frame.document.asNode() == root.document_node) return frame;

    const code = if (root.from_element) "stale element reference" else "no such element";
    _ = try sendError(out, .not_found, code, "Element search started in an inactive document");
    return null;
}

fn elementReference(session: *Server.Session, element: *Element) !ElementReference {
    const node = try session.node_registry.register(element.asNode());
    session.webdriver_elements.register(node.id);
    return .{ .session_id = session.id, .node_id = node.id };
}

fn resolveElement(session: *Server.Session, id: []const u8, out: *std.Io.Writer) !?*Element {
    const frame = primaryFrame(session) orelse {
        _ = try sendError(out, .not_found, "no such window", "Current browsing context has no document");
        return null;
    };
    const node_id = parseElementId(session, id) orelse {
        _ = try sendError(out, .not_found, "no such element", "Unknown element reference");
        return null;
    };
    if (!session.webdriver_elements.isIssued(node_id)) {
        _ = try sendError(out, .not_found, "no such element", "Unknown element reference");
        return null;
    }
    const node = session.node_registry.lookup_by_id.get(node_id) orelse {
        _ = try sendError(out, .not_found, "stale element reference", "Element belongs to an inactive document");
        return null;
    };
    const element = node.dom.is(Element) orelse {
        _ = try sendError(out, .not_found, "stale element reference", "Element reference no longer identifies an element");
        return null;
    };
    const element_node = element.asNode();
    if (!element_node.isConnected() or element_node.ownerDocument(frame) != frame.document) {
        _ = try sendError(out, .not_found, "stale element reference", "Element is no longer attached to the DOM");
        return null;
    }
    return element;
}

fn parseElementId(session: *const Server.Session, id: []const u8) ?u32 {
    if (id.len <= session.id.len + 1 or
        !std.mem.startsWith(u8, id, session.id) or
        id[session.id.len] != '-')
    {
        return null;
    }
    const suffix = id[session.id.len + 1 ..];
    if (suffix[0] == '0') return null;
    for (suffix) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return std.fmt.parseUnsigned(u32, suffix, 10) catch null;
}

const ImplicitWait = struct {
    timer: std.Io.Timestamp,
    timeout_ms: ?u64,
    deadline_armed: bool,

    fn init(session: *Server.Session, timeout_ms: ?u64) ImplicitWait {
        const deadline_armed = if (timeout_ms) |timeout| timeout > 0 else false;
        if (deadline_armed) session.browser.armExecutionDeadline(timeout_ms);
        return .{
            .timer = .now(lp.io, .boot),
            .timeout_ms = timeout_ms,
            .deadline_armed = deadline_armed,
        };
    }

    fn deinit(self: *ImplicitWait, session: *Server.Session) void {
        if (!self.deadline_armed) return;
        self.deadline_armed = false;
        if (session.browser.disarmExecutionDeadline()) {
            _ = session.browser.env.cancelExecutionDeadlineTerminate();
        }
    }

    fn remaining(self: *const ImplicitWait) ?u64 {
        const timeout = self.timeout_ms orelse return null;
        const elapsed: u64 = @intCast(self.timer.untilNow(lp.io, .boot).toMilliseconds());
        return timeout -| elapsed;
    }

    fn expired(self: *const ImplicitWait, session: *const Server.Session) bool {
        if (session.browser.executionDeadlineFired()) return true;
        return if (self.remaining()) |milliseconds| milliseconds == 0 else false;
    }

    fn finish(self: *ImplicitWait, session: *Server.Session) bool {
        const elapsed = if (self.remaining()) |milliseconds| milliseconds == 0 else false;
        if (!self.deadline_armed) return elapsed;
        self.deadline_armed = false;
        const fired = session.browser.disarmExecutionDeadline();
        if (fired) _ = session.browser.env.cancelExecutionDeadlineTerminate();
        return fired or elapsed;
    }
};

fn waitForImplicitPoll(session: *Server.Session, frame_id: u32, remaining_ms: ?u64) !void {
    const poll_ms: u32 = @intCast(@min(remaining_ms orelse 200, 200));
    if (poll_ms == 0) return;

    var runner = session.session.runner(.{});
    switch (try runner.tickForFrame(frame_id, poll_ms, .{ .until = .done })) {
        .done => lp.io.sleep(.fromMilliseconds(@intCast(@min(poll_ms, 50))), .awake) catch {},
        .ok => |recommended_sleep_ms| {
            if (recommended_sleep_ms > 0) {
                lp.io.sleep(.fromMilliseconds(@intCast(@min(recommended_sleep_ms, poll_ms))), .awake) catch {};
            }
        },
    }
}

fn getElementTagName(session: *Server.Session, id: []const u8, out: *std.Io.Writer) !std.http.Status {
    const element = (try resolveElement(session, id, out)) orelse return .not_found;
    return sendValue(out, element.getTagNameLower());
}

fn getElementAttribute(
    session: *Server.Session,
    arena: Allocator,
    id: []const u8,
    name: []const u8,
    out: *std.Io.Writer,
) !std.http.Status {
    const element = (try resolveElement(session, id, out)) orelse return .not_found;
    const decoded_name = try decodePathSegment(arena, name);
    const html_namespace = "http://www.w3.org/1999/xhtml";
    const frame = primaryFrame(session) orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    const is_html_document = switch (frame.document._type) {
        .html => true,
        else => false,
    };
    const is_html = is_html_document and if (element.getNamespaceURI()) |namespace|
        std.mem.eql(u8, namespace, html_namespace)
    else
        false;
    const lookup_name = if (is_html and containsAsciiUpper(decoded_name))
        try std.ascii.allocLowerString(arena, decoded_name)
    else
        decoded_name;
    const value = element.getAttributeSafe(.wrap(lookup_name)) orelse return sendValue(out, @as(?[]const u8, null));
    return sendValue(out, if (is_html and isBooleanAttribute(decoded_name)) "true" else value);
}

fn decodePathSegment(arena: Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, '%') == null) return value;
    const owned = try arena.dupe(u8, value);
    return std.Uri.percentDecodeInPlace(owned);
}

fn containsAsciiUpper(value: []const u8) bool {
    for (value) |byte| {
        if (std.ascii.isUpper(byte)) return true;
    }
    return false;
}

fn isElementSelected(session: *Server.Session, id: []const u8, out: *std.Io.Writer) !std.http.Status {
    const element = (try resolveElement(session, id, out)) orelse return .not_found;
    const selected = if (element.is(Input)) |input|
        (std.mem.eql(u8, input.getType(), "checkbox") or
            std.mem.eql(u8, input.getType(), "radio")) and input.getChecked()
    else if (element.is(Option)) |option|
        optionIsSelected(option)
    else
        false;
    return sendValue(out, selected);
}

fn optionIsSelected(option: *Option) bool {
    var parent = option.asNode()._parent;
    while (parent) |node| : (parent = node._parent) {
        const element = node.is(Element) orelse continue;
        const select = element.is(Select) orelse continue;
        if (select.getMultiple()) return option.getSelected();
        return select.effectiveOption() == option;
    }
    return option.getSelected();
}

fn isElementEnabled(session: *Server.Session, id: []const u8, out: *std.Io.Writer) !std.http.Status {
    const element = (try resolveElement(session, id, out)) orelse return .not_found;
    const frame = primaryFrame(session) orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    const is_xml = switch (frame.document._type) {
        .xml => true,
        else => false,
    };
    return sendValue(out, !is_xml and !isWebDriverDisabled(element));
}

fn isWebDriverDisabled(element: *Element) bool {
    if (element.isDisabled()) return true;
    if (element.getTag() != .option and element.getTag() != .optgroup) return false;

    var parent = element.asNode()._parent;
    while (parent) |node| : (parent = node._parent) {
        const ancestor = node.is(Element) orelse continue;
        if (ancestor.getTag() == .select) return ancestor.isDisabled();
    }
    return false;
}

fn isBooleanAttribute(name: []const u8) bool {
    const attributes = [_][]const u8{
        "allowfullscreen",                 "alpha",
        "async",                           "autofocus",
        "autoplay",                        "checked",
        "compact",                         "controls",
        "declare",                         "default",
        "defer",                           "disabled",
        "formnovalidate",                  "headingreset",
        "hidden",                          "inert",
        "ismap",                           "itemscope",
        "loop",                            "multiple",
        "muted",                           "nohref",
        "nomodule",                        "noresize",
        "noshade",                         "novalidate",
        "nowrap",                          "open",
        "playsinline",                     "readonly",
        "required",                        "reversed",
        "selected",                        "shadowrootclonable",
        "shadowrootcustomelementregistry", "shadowrootdelegatesfocus",
        "shadowrootserializable",
    };
    for (attributes) |attribute| {
        if (std.ascii.eqlIgnoreCase(name, attribute)) return true;
    }
    return false;
}

fn navigate(
    server: *Server,
    session: *Server.Session,
    arena: Allocator,
    body: []const u8,
    out: *std.Io.Writer,
) !std.http.Status {
    const Params = struct { url: [:0]const u8 };
    var parsed = std.json.parseFromSlice(Params, arena, body, .{ .ignore_unknown_fields = true }) catch
        return sendError(out, .bad_request, "invalid argument", "Navigate To requires a URL string");
    defer parsed.deinit();
    _ = primaryFrame(session) orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    if (!lp.URL.canParse(parsed.value.url, null)) {
        return sendError(out, .bad_request, "invalid argument", "Navigate To requires an absolute URL");
    }

    const result = lp.tools.gotoLiteral(
        session.session,
        parsed.value.url,
        server.webdriverPageLoadTimeout(),
        server.webdriverPageLoadWait(),
    ) catch |err| {
        const status: std.http.Status = if (err == error.InvalidParams) .bad_request else .internal_server_error;
        const code = if (err == error.InvalidParams) "invalid argument" else "unknown error";
        return sendError(out, status, code, @errorName(err));
    };
    if (result == .timeout) {
        return sendError(out, .internal_server_error, "timeout", "Navigation exceeded the session page load timeout");
    }
    return sendValue(out, @as(?u8, null));
}

fn currentUrl(session: *Server.Session, out: *std.Io.Writer) !std.http.Status {
    const frame = primaryFrame(session) orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    return sendValue(out, frame.url);
}

fn getTitle(session: *Server.Session, out: *std.Io.Writer) !std.http.Status {
    const frame = primaryFrame(session) orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    const title = frame.getTitle() catch |err|
        return sendError(out, .internal_server_error, "unknown error", @errorName(err));
    return sendValue(out, title orelse "");
}

fn getPageSource(session: *Server.Session, out: *std.Io.Writer) !std.http.Status {
    const frame = primaryFrame(session) orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    return sendValue(out, PageSource{ .frame = frame });
}

fn getActiveElement(session: *Server.Session, out: *std.Io.Writer) !std.http.Status {
    const frame = primaryFrame(session) orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    const element = frame.document.getActiveElement() orelse
        return sendError(out, .not_found, "no such element", "Current document has no active element");
    return sendValue(out, try elementReference(session, element));
}

fn getWindowHandle(session: *Server.Session, out: *std.Io.Writer) !std.http.Status {
    const page = session.session.primaryPage() orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    return sendValue(out, cdp_id.toFrameId(page.frame_id));
}

fn getWindowHandles(session: *Server.Session, out: *std.Io.Writer) !std.http.Status {
    const page = session.session.primaryPage() orelse return sendValue(out, [_][]const u8{});
    const window_handle = cdp_id.toFrameId(page.frame_id);
    return sendValue(out, [_][]const u8{&window_handle});
}

fn closeWindow(server: *Server, session_id: []const u8, session: *Server.Session, out: *std.Io.Writer) !std.http.Status {
    const has_window = blk: {
        server.enterIsolate(session);
        defer server.exitIsolate(session);
        break :blk session.session.primaryPage() != null;
    };
    if (!has_window) {
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    }
    _ = server.closeWebDriverSession(session_id);
    return sendValue(out, [_][]const u8{});
}

fn primaryFrame(session: *Server.Session) ?*lp.Frame {
    const page = session.session.primaryPage() orelse return null;
    return session.session.findFrameByFrameId(page.frame_id);
}

const PageSource = struct {
    frame: *lp.Frame,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        var escaped = protocol.JsonEscapingWriter.init(jw.writer);
        // WebDriver serializes the document element first, not the Document
        // node, so a doctype is neither preserved nor synthesized here.
        const node = if (self.frame.document.getDocumentElement()) |document_element|
            document_element.asNode()
        else
            self.frame.document.asNode();
        lp.dump.deep(node, .{ .shadow = .skip }, &escaped.writer, self.frame) catch return error.WriteFailed;
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
    }
};

fn getTimeouts(server: *const Server, out: *std.Io.Writer) !std.http.Status {
    return sendValue(out, .{
        .script = server.webdriverScriptTimeout(),
        .pageLoad = server.webdriverPageLoadTimeout(),
        .implicit = server.webdriverImplicitTimeout(),
    });
}

fn setTimeouts(
    server: *Server,
    arena: Allocator,
    body: []const u8,
    out: *std.Io.Writer,
) !std.http.Status {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch
        return sendError(out, .bad_request, "invalid argument", "Set Timeouts parameters must be an object");
    defer parsed.deinit();
    if (parsed.value != .object or !validTimeouts(parsed.value.object)) {
        return sendError(out, .bad_request, "invalid argument", "Timeout values must be null or non-negative safe integers");
    }

    // WebDriver replaces the complete timeout configuration. Omitted keys
    // therefore return to their standard defaults; unknown keys are ignored.
    const timeouts = deserializeTimeouts(parsed.value.object).?;
    server.setWebDriverScriptTimeout(timeouts.script);
    server.setWebDriverPageLoadTimeout(timeouts.page_load);
    server.setWebDriverImplicitTimeout(timeouts.implicit);
    return sendValue(out, @as(?u8, null));
}

fn requestPath(target: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    return target[0..end];
}

fn matchRoute(path: []const u8) ?Route {
    if (std.mem.eql(u8, path, "/status")) return .{ .command = .status };
    if (std.mem.eql(u8, path, "/session")) return .{ .command = .new_session };

    const prefix = "/session/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const separator = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (separator == 0) return null;
    const session_id = rest[0..separator];
    const suffix = rest[separator..];

    if (suffix.len == 0) return .{ .command = .delete_session, .session_id = session_id };
    if (std.mem.eql(u8, suffix, "/url")) return .{
        .command = .current_url,
        .alternate = .navigate,
        .session_id = session_id,
    };
    if (std.mem.eql(u8, suffix, "/title")) return .{
        .command = .get_title,
        .session_id = session_id,
    };
    if (std.mem.eql(u8, suffix, "/source")) return .{
        .command = .get_page_source,
        .session_id = session_id,
    };
    if (std.mem.eql(u8, suffix, "/window")) return .{
        .command = .get_window_handle,
        .alternate = .close_window,
        .session_id = session_id,
    };
    if (std.mem.eql(u8, suffix, "/window/handles")) return .{
        .command = .get_window_handles,
        .session_id = session_id,
    };
    if (std.mem.eql(u8, suffix, "/timeouts")) return .{
        .command = .get_timeouts,
        .alternate = .set_timeouts,
        .session_id = session_id,
    };
    if (std.mem.eql(u8, suffix, "/element")) return .{
        .command = .find_element,
        .session_id = session_id,
    };
    if (std.mem.eql(u8, suffix, "/elements")) return .{
        .command = .find_elements,
        .session_id = session_id,
    };
    if (std.mem.eql(u8, suffix, "/element/active")) return .{
        .command = .get_active_element,
        .session_id = session_id,
    };
    if (matchElementRoute(session_id, suffix)) |route| return route;
    return null;
}

fn matchElementRoute(session_id: []const u8, suffix: []const u8) ?Route {
    const prefix = "/element/";
    if (!std.mem.startsWith(u8, suffix, prefix)) return null;
    const rest = suffix[prefix.len..];
    const separator = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (separator == 0) return null;
    const element_id = rest[0..separator];
    const command_suffix = rest[separator..];

    const command: Command, const attribute_name: ?[]const u8 = if (std.mem.eql(u8, command_suffix, "/element"))
        .{ .find_element_from_element, null }
    else if (std.mem.eql(u8, command_suffix, "/elements"))
        .{ .find_elements_from_element, null }
    else if (std.mem.eql(u8, command_suffix, "/name"))
        .{ .get_element_tag_name, null }
    else if (std.mem.eql(u8, command_suffix, "/selected"))
        .{ .is_element_selected, null }
    else if (std.mem.eql(u8, command_suffix, "/enabled"))
        .{ .is_element_enabled, null }
    else if (std.mem.startsWith(u8, command_suffix, "/attribute/") and
        command_suffix.len > "/attribute/".len and
        std.mem.indexOfScalar(u8, command_suffix["/attribute/".len..], '/') == null)
        .{ .get_element_attribute, command_suffix["/attribute/".len..] }
    else
        return null;

    return .{
        .command = command,
        .session_id = session_id,
        .element_id = element_id,
        .attribute_name = attribute_name,
    };
}

fn commandForMethod(route: Route, method: std.http.Method) ?Command {
    if (method == commandMethod(route.command)) return route.command;
    if (route.alternate) |alternate| {
        if (method == commandMethod(alternate)) return alternate;
    }
    return null;
}

fn commandMethod(command: Command) std.http.Method {
    return switch (command) {
        .status,
        .current_url,
        .get_title,
        .get_page_source,
        .get_window_handle,
        .get_window_handles,
        .get_timeouts,
        .get_active_element,
        .get_element_tag_name,
        .get_element_attribute,
        .is_element_selected,
        .is_element_enabled,
        => .GET,
        .new_session,
        .navigate,
        .set_timeouts,
        .find_element,
        .find_elements,
        .find_element_from_element,
        .find_elements_from_element,
        => .POST,
        .delete_session, .close_window => .DELETE,
    };
}

fn sendValue(out: *std.Io.Writer, value: anytype) !std.http.Status {
    try std.json.Stringify.value(.{ .value = value }, .{}, out);
    return .ok;
}

fn sendError(out: *std.Io.Writer, status: std.http.Status, code: []const u8, message: []const u8) !std.http.Status {
    const ErrorResponse = struct {
        value: struct {
            @"error": []const u8,
            message: []const u8,
            stacktrace: []const u8,
        },
    };
    try std.json.Stringify.value(ErrorResponse{
        .value = .{
            .@"error" = code,
            .message = message,
            .stacktrace = "",
        },
    }, .{}, out);
    return status;
}

test "WebDriver: routes use URL paths and distinguish methods" {
    try std.testing.expectEqualStrings("/status", requestPath("/status?detail=true"));
    try std.testing.expectEqual(Command.status, matchRoute("/status").?.command);
    try std.testing.expectEqual(Command.delete_session, matchRoute("/session/id").?.command);
    const url_route = matchRoute("/session/id/url").?;
    try std.testing.expectEqual(Command.current_url, commandForMethod(url_route, .GET).?);
    try std.testing.expectEqual(Command.navigate, commandForMethod(url_route, .POST).?);
    try std.testing.expect(commandForMethod(url_route, .DELETE) == null);
    const timeouts_route = matchRoute("/session/id/timeouts").?;
    try std.testing.expectEqual(Command.get_timeouts, commandForMethod(timeouts_route, .GET).?);
    try std.testing.expectEqual(Command.set_timeouts, commandForMethod(timeouts_route, .POST).?);
    try std.testing.expectEqual(Command.get_title, commandForMethod(matchRoute("/session/id/title").?, .GET).?);
    try std.testing.expectEqual(Command.get_page_source, commandForMethod(matchRoute("/session/id/source").?, .GET).?);
    const window_route = matchRoute("/session/id/window").?;
    try std.testing.expectEqual(Command.get_window_handle, commandForMethod(window_route, .GET).?);
    try std.testing.expectEqual(Command.close_window, commandForMethod(window_route, .DELETE).?);
    try std.testing.expectEqual(Command.get_window_handles, commandForMethod(matchRoute("/session/id/window/handles").?, .GET).?);
    try std.testing.expectEqual(Command.find_element, commandForMethod(matchRoute("/session/id/element").?, .POST).?);
    try std.testing.expectEqual(Command.find_elements, commandForMethod(matchRoute("/session/id/elements").?, .POST).?);
    try std.testing.expectEqual(Command.get_active_element, commandForMethod(matchRoute("/session/id/element/active").?, .GET).?);
    const child_route = matchRoute("/session/id/element/ref/element").?;
    try std.testing.expectEqualStrings("ref", child_route.element_id.?);
    try std.testing.expectEqual(Command.find_element_from_element, commandForMethod(child_route, .POST).?);
    try std.testing.expectEqual(Command.find_elements_from_element, commandForMethod(matchRoute("/session/id/element/ref/elements").?, .POST).?);
    try std.testing.expectEqual(Command.get_element_tag_name, commandForMethod(matchRoute("/session/id/element/ref/name").?, .GET).?);
    const attribute_route = matchRoute("/session/id/element/ref/attribute/data-kind").?;
    try std.testing.expectEqualStrings("data-kind", attribute_route.attribute_name.?);
    try std.testing.expectEqual(Command.get_element_attribute, commandForMethod(attribute_route, .GET).?);
    try std.testing.expectEqual(Command.is_element_selected, commandForMethod(matchRoute("/session/id/element/ref/selected").?, .GET).?);
    try std.testing.expectEqual(Command.is_element_enabled, commandForMethod(matchRoute("/session/id/element/ref/enabled").?, .GET).?);
    try std.testing.expect(matchRoute("/session/id/element/ref/attribute/") == null);
    try std.testing.expect(matchRoute("/session/id/element/ref/attribute/data/kind") == null);
    try std.testing.expect(commandForMethod(child_route, .GET) == null);
    try std.testing.expect(matchRoute("/session/id/execute/sync") == null);
    try std.testing.expect(matchRoute("/session/id/unknown") == null);
}

test "WebDriver: protocol session validates capabilities and preserves navigation state" {
    const testing = @import("../testing.zig");

    var placeholder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer placeholder.deinit();
    const server = try Server.initWebDriver(testing.allocator, testing.test_app, &placeholder.writer);
    defer server.deinit();
    server.enableIsolateParking();

    var request_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer request_arena.deinit();
    const request_allocator = request_arena.allocator();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try testing.expectEqual(.bad_request, try handle(server, request_allocator, .POST, "/session", "{\"capabilities\":{\"alwaysMatch\":{\"timeouts\":{\"implicit\":\"bad\"}}}}", &out.writer));
    try testing.expect(server.webdriverReady());

    out.clearRetainingCapacity();
    try testing.expectEqual(.bad_request, try handle(server, request_allocator, .POST, "/session", "{\"capabilities\":{\"alwaysMatch\":{\"proxy\":{\"proxyType\":\"pac\"}}}}", &out.writer));
    try testing.expect(server.webdriverReady());

    out.clearRetainingCapacity();
    try testing.expectEqual(.bad_request, try handle(server, request_allocator, .POST, "/session", "{\"capabilities\":{\"alwaysMatch\":{\"proxy\":{\"proxyType\":\"manual\",\"httpProxy\":\"proxy.example:99999\"}}}}", &out.writer));
    try testing.expect(server.webdriverReady());

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, "/session", "{\"capabilities\":{\"alwaysMatch\":{\"pageLoadStrategy\":\"eager\",\"strictFileInteractability\":true,\"timeouts\":{\"script\":1234,\"pageLoad\":5678,\"implicit\":9007199254740991},\"unhandledPromptBehavior\":\"accept\"},\"firstMatch\":[{\"browserName\":\"other\"},{\"browserName\":\"lightpanda\"}]}}", &out.writer));
    var created = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer created.deinit();
    const created_value = created.value.object.get("value").?.object;
    const session_id = created_value.get("sessionId").?.string;
    try testing.expectEqual(@as(usize, 36), session_id.len);
    try testing.expectEqual(lp.Config.WaitUntil.domcontentloaded, server.webdriverPageLoadWait().?);
    try testing.expectEqual(@as(?u64, 5678), server.webdriverPageLoadTimeout());
    try testing.expectEqual(@as(?u64, 1234), server.webdriverScriptTimeout());
    const returned_capabilities = created_value.get("capabilities").?.object;
    try std.testing.expectEqualStrings("eager", returned_capabilities.get("pageLoadStrategy").?.string);
    try testing.expect(returned_capabilities.get("strictFileInteractability").?.bool);
    try std.testing.expectEqualStrings("accept", returned_capabilities.get("unhandledPromptBehavior").?.string);
    const returned_timeouts = returned_capabilities.get("timeouts").?.object;
    try testing.expectEqual(@as(i64, 1234), returned_timeouts.get("script").?.integer);
    try testing.expectEqual(@as(i64, 5678), returned_timeouts.get("pageLoad").?.integer);
    try testing.expectEqual(@as(i64, 9_007_199_254_740_991), returned_timeouts.get("implicit").?.integer);

    const execute_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/execute/sync", .{session_id});
    defer testing.allocator.free(execute_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.not_found, try handle(server, request_allocator, .POST, execute_path, "{\"script\":\"return 1\",\"args\":[]}", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "unknown command" } }, out.writer.buffered());

    const timeouts_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/timeouts", .{session_id});
    defer testing.allocator.free(timeouts_path);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"script\":null,\"pageLoad\":9007199254740991,\"futureTimeout\":\"ignored\"}", &out.writer));
    try testing.expectJson(.{ .value = null }, out.writer.buffered());
    try testing.expectEqual(@as(?u64, null), server.webdriverScriptTimeout());
    try testing.expectEqual(@as(?u64, 9_007_199_254_740_991), server.webdriverPageLoadTimeout());

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, timeouts_path, "", &out.writer));
    try testing.expectJson(.{
        .value = .{
            .script = null,
            .pageLoad = 9_007_199_254_740_991,
            .implicit = 0,
        },
    }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"script\":20}", &out.writer));
    try testing.expectEqual(@as(?u64, 20), server.webdriverScriptTimeout());
    try testing.expectEqual(@as(?u64, 300_000), server.webdriverPageLoadTimeout());
    try testing.expectEqual(@as(?u64, 0), server.webdriverImplicitTimeout());

    const active = server.getWebDriverSession(session_id).?;
    {
        server.enterIsolate(active);
        defer server.exitIsolate(active);

        const frame = active.session.currentFrame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        try testing.expect((try scope.local.compileAndRun("navigator.webdriver === true", null)).isTrue());
    }
    const frame_id_before = active.session.primaryPage().?.frame_id;
    const navigate_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/url", .{session_id});
    defer testing.allocator.free(navigate_path);
    const title_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/title", .{session_id});
    defer testing.allocator.free(title_path);
    const source_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/source", .{session_id});
    defer testing.allocator.free(source_path);
    const window_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/window", .{session_id});
    defer testing.allocator.free(window_path);
    const window_handles_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/window/handles", .{session_id});
    defer testing.allocator.free(window_handles_path);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, window_path, "", &out.writer));
    var initial_window = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer initial_window.deinit();
    const initial_handle = try testing.allocator.dupe(u8, initial_window.value.object.get("value").?.string);
    defer testing.allocator.free(initial_handle);
    try testing.expect(!std.mem.eql(u8, initial_handle, "current"));

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, window_handles_path, "", &out.writer));
    try testing.expectJson(.{ .value = &.{initial_handle} }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"script\":20,\"pageLoad\":20}", &out.writer));
    out.clearRetainingCapacity();
    try testing.expectEqual(.internal_server_error, try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,<script>while(true){}</script>\"}", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "timeout" } }, out.writer.buffered());
    try testing.expectEqual(frame_id_before, active.session.primaryPage().?.frame_id);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"script\":20,\"pageLoad\":0}", &out.writer));
    out.clearRetainingCapacity();
    try testing.expectEqual(.internal_server_error, try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,timeout\"}", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "timeout" } }, out.writer.buffered());
    try testing.expectEqual(frame_id_before, active.session.primaryPage().?.frame_id);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"script\":20}", &out.writer));

    _ = setenv(@constCast("LP_WEBDRIVER_LITERAL"), @constCast("expanded"), 1);
    defer _ = unsetenv(@constCast("LP_WEBDRIVER_LITERAL"));

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,<title>$LP_WEBDRIVER_LITERAL</title>\"}", &out.writer));
    try testing.expectJson(.{ .value = null }, out.writer.buffered());
    try testing.expectEqual(frame_id_before, active.session.primaryPage().?.frame_id);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, navigate_path, "", &out.writer));
    var navigated = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer navigated.deinit();
    const navigated_url = navigated.value.object.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, navigated_url, "$LP_WEBDRIVER_LITERAL") != null);
    try testing.expect(std.mem.indexOf(u8, navigated_url, "expanded") == null);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,<!doctype html><title>escaped &quot;title&quot;</title><body><p>before</p></body>\"}", &out.writer));
    try testing.expectEqual(frame_id_before, active.session.primaryPage().?.frame_id);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, window_path, "", &out.writer));
    try testing.expectJson(.{ .value = initial_handle }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, title_path, "", &out.writer));
    const title_json_escape = [_]u8{ '\\', '"' };
    try testing.expect(std.mem.indexOf(u8, out.writer.buffered(), &title_json_escape) != null);
    try testing.expectJson(.{ .value = "escaped \"title\"" }, out.writer.buffered());

    {
        server.enterIsolate(active);
        defer server.exitIsolate(active);

        const frame = active.session.currentFrame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.compileAndRun("document.body.innerHTML = '<p id=\\\"after\\\">after</p>'", null);
    }
    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, source_path, "", &out.writer));
    var source = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer source.deinit();
    const page_source = source.value.object.get("value").?.string;
    try testing.expect(std.mem.startsWith(u8, page_source, "<html"));
    try testing.expect(std.mem.indexOf(u8, page_source, "<!DOCTYPE") == null);
    try testing.expect(std.mem.indexOf(u8, page_source, "id=\"after\"") != null);
    try testing.expect(std.mem.indexOf(u8, page_source, "before") == null);

    try active.session.cookie_jar.populateFromResponse("https://example.com/", "token=secret; Path=/");
    try testing.expectEqual(@as(usize, 1), active.session.cookie_jar.cookies.items.len);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .DELETE, window_path, "", &out.writer));
    try testing.expectString("{\"value\":[]}", out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(.not_found, try handle(server, request_allocator, .GET, window_path, "", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "invalid session id" } }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, "/session", "{\"capabilities\":{\"alwaysMatch\":{\"pageLoadStrategy\":\"none\",\"timeouts\":{\"pageLoad\":0}}}}", &out.writer));
    var recreated = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer recreated.deinit();
    const recreated_id = recreated.value.object.get("value").?.object.get("sessionId").?.string;
    const recreated_session = server.getWebDriverSession(recreated_id).?;
    try testing.expectEqual(@as(usize, 0), recreated_session.session.cookie_jar.cookies.items.len);
    try testing.expect(server.webdriverPageLoadWait() == null);

    const recreated_navigate_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/url", .{recreated_id});
    defer testing.allocator.free(recreated_navigate_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, recreated_navigate_path, "{\"url\":\"data:text/html,none\"}", &out.writer));
    try testing.expectJson(.{ .value = null }, out.writer.buffered());

    const recreated_delete_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}", .{recreated_id});
    defer testing.allocator.free(recreated_delete_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .DELETE, recreated_delete_path, "", &out.writer));

    var failure_buffer: [1]u8 = undefined;
    var failure_writer: std.Io.Writer = .fixed(&failure_buffer);
    try testing.expectError(error.WriteFailed, handle(server, request_allocator, .POST, "/session", "{\"capabilities\":{\"alwaysMatch\":{}}}", &failure_writer));
    try testing.expect(server.webdriverReady());
    try testing.expectEqual(@as(usize, 0), server.sessions.count());
}

test "WebDriver: pageless sessions return no such window" {
    const testing = @import("../testing.zig");

    var placeholder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer placeholder.deinit();
    const server = try Server.initWebDriver(testing.allocator, testing.test_app, &placeholder.writer);
    defer server.deinit();
    server.enableIsolateParking();

    var request_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer request_arena.deinit();
    const request_allocator = request_arena.allocator();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const session_id = "11111111-1111-4111-8111-111111111111";
    const session = try server.createWebDriverSession(session_id, .load, 300_000, 30_000, 0);
    const navigate_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/url", .{session_id});
    defer testing.allocator.free(navigate_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(
        .ok,
        try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,<p>element</p>\"}", &out.writer),
    );

    var known_element_buffer: [48]u8 = undefined;
    const known_element_id = blk: {
        server.enterIsolate(session);
        defer server.exitIsolate(session);

        const page = session.session.primaryPage().?;
        const element = primaryFrame(session).?.document.getDocumentElement().?;
        const reference = try elementReference(session, element);
        const id = try std.fmt.bufPrint(&known_element_buffer, "{s}-{d}", .{ reference.session_id, reference.node_id });
        page.close();
        try testing.expect(session.session.primaryPage() == null);
        break :blk id;
    };
    try testing.expect(server.getWebDriverSession(session_id) == session);

    out.clearRetainingCapacity();
    try testing.expectEqual(
        .not_found,
        try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"relative\"}", &out.writer),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "no such window" } }, out.writer.buffered());
    try testing.expectEqual(@as(usize, 0), session.session.pages.items.len);

    out.clearRetainingCapacity();
    try testing.expectEqual(
        .not_found,
        try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,should-not-open\"}", &out.writer),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "no such window" } }, out.writer.buffered());
    try testing.expectEqual(@as(usize, 0), session.session.pages.items.len);

    const active_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/element/active", .{session_id});
    defer testing.allocator.free(active_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.not_found, try handle(server, request_allocator, .GET, active_path, "", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "no such window" } }, out.writer.buffered());

    var unknown_element_buffer: [48]u8 = undefined;
    const unknown_element_id = try std.fmt.bufPrint(&unknown_element_buffer, "{s}-999999", .{session_id});
    const element_ids = [_][]const u8{ known_element_id, unknown_element_id, "malformed" };
    for (element_ids) |element_id| {
        const enabled_path = try std.fmt.allocPrint(
            testing.allocator,
            "/session/{s}/element/{s}/enabled",
            .{ session_id, element_id },
        );
        defer testing.allocator.free(enabled_path);

        out.clearRetainingCapacity();
        try testing.expectEqual(.not_found, try handle(server, request_allocator, .GET, enabled_path, "", &out.writer));
        try testing.expectJson(.{ .value = .{ .@"error" = "no such window" } }, out.writer.buffered());
    }
}

fn testFindWebDriverElement(
    server: *Server,
    request_allocator: Allocator,
    session_id: []const u8,
    parent_id: ?[]const u8,
    selector: []const u8,
    out: *std.Io.Writer.Allocating,
) ![]u8 {
    const testing = @import("../testing.zig");
    const path = if (parent_id) |id|
        try std.fmt.allocPrint(testing.allocator, "/session/{s}/element/{s}/element", .{ session_id, id })
    else
        try std.fmt.allocPrint(testing.allocator, "/session/{s}/element", .{session_id});
    defer testing.allocator.free(path);
    const body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"using\":\"css selector\",\"value\":\"{s}\"}}",
        .{selector},
    );
    defer testing.allocator.free(body);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, path, body, &out.writer));
    var response = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer response.deinit();
    const reference = response.value.object.get("value").?.object.get(element_key).?.string;
    return testing.allocator.dupe(u8, reference);
}

fn testGetActiveWebDriverElement(
    server: *Server,
    request_allocator: Allocator,
    session_id: []const u8,
    out: *std.Io.Writer.Allocating,
) ![]u8 {
    const testing = @import("../testing.zig");
    const path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/element/active", .{session_id});
    defer testing.allocator.free(path);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, path, "", &out.writer));
    var response = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer response.deinit();
    const reference = response.value.object.get("value").?.object.get(element_key).?.string;
    return testing.allocator.dupe(u8, reference);
}

fn expectWebDriverElementValue(
    server: *Server,
    request_allocator: Allocator,
    session_id: []const u8,
    element_id: []const u8,
    suffix: []const u8,
    out: *std.Io.Writer.Allocating,
    expected: anytype,
) !void {
    const testing = @import("../testing.zig");
    const path = try std.fmt.allocPrint(
        testing.allocator,
        "/session/{s}/element/{s}{s}",
        .{ session_id, element_id, suffix },
    );
    defer testing.allocator.free(path);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .GET, path, "", &out.writer));
    try testing.expectJson(.{ .value = expected }, out.writer.buffered());
}

test "WebDriver: element retrieval returns stable references and W3C state" {
    const testing = @import("../testing.zig");

    var placeholder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer placeholder.deinit();
    const server = try Server.initWebDriver(testing.allocator, testing.test_app, &placeholder.writer);
    defer server.deinit();
    server.enableIsolateParking();

    var request_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer request_arena.deinit();
    const request_allocator = request_arena.allocator();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try testing.expectEqual(
        .ok,
        try handle(
            server,
            request_allocator,
            .POST,
            "/session",
            "{\"capabilities\":{\"alwaysMatch\":{\"browserName\":\"lightpanda\"}}}",
            &out.writer,
        ),
    );
    var created = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    const session_id = try testing.allocator.dupe(
        u8,
        created.value.object.get("value").?.object.get("sessionId").?.string,
    );
    created.deinit();
    defer testing.allocator.free(session_id);

    const navigate_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/url", .{session_id});
    defer testing.allocator.free(navigate_path);
    const timeouts_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/timeouts", .{session_id});
    defer testing.allocator.free(timeouts_path);
    const delete_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}", .{session_id});
    defer testing.allocator.free(delete_path);

    const page_url =
        "data:text/html," ++
        "<div id='parent' data-kind='group' data:kind='colon'>" ++
        "<span class='item'></span><span class='item' id='hidden' hidden></span></div>" ++
        "<main id='ancestor'><section id='scope'><span class='target'></span></section></main>" ++
        "<i id='duplicate'></i><b id='duplicate'></b>" ++
        "<input id='checked' type='checkbox' checked disabled>" ++
        "<input id='unchecked' type='checkbox' alpha>" ++
        "<select><option id='selected' selected>one</option></select>" ++
        "<select><option id='implicit_selected'>implicit</option></select>" ++
        "<select disabled><optgroup id='disabled_group'><option id='disabled_option'>blocked</option></optgroup></select>" ++
        "<fieldset disabled><legend><input id='legend_input'></legend>" ++
        "<input id='fieldset_input'></fieldset>" ++
        "<fieldset disabled><fieldset disabled><legend><input id='nested_legend_input'></legend></fieldset></fieldset>" ++
        "<p id='remove'>remove</p><p id='adopt'>adopt</p>";
    const navigate_body = try std.fmt.allocPrint(testing.allocator, "{{\"url\":\"{s}\"}}", .{page_url});
    defer testing.allocator.free(navigate_body);

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, navigate_path, navigate_body, &out.writer));

    const default_active_id = try testGetActiveWebDriverElement(server, request_allocator, session_id, &out);
    defer testing.allocator.free(default_active_id);
    const body_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "body", &out);
    defer testing.allocator.free(body_id);
    try std.testing.expectEqualStrings(body_id, default_active_id);

    const active = server.getWebDriverSession(session_id).?;
    {
        server.enterIsolate(active);
        defer server.exitIsolate(active);
        const frame = primaryFrame(active).?;
        const input = frame.document.getElementById("unchecked", frame).?;
        try input.focus(frame);
    }
    const focused_active_id = try testGetActiveWebDriverElement(server, request_allocator, session_id, &out);
    defer testing.allocator.free(focused_active_id);
    const unchecked_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#unchecked", &out);
    defer testing.allocator.free(unchecked_id);
    try std.testing.expectEqualStrings(unchecked_id, focused_active_id);

    const parent_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#parent", &out);
    defer testing.allocator.free(parent_id);
    const parent_again = try testFindWebDriverElement(server, request_allocator, session_id, null, "#parent", &out);
    defer testing.allocator.free(parent_again);
    try std.testing.expectEqualStrings(parent_id, parent_again);
    const selector_list_id = try testFindWebDriverElement(server, request_allocator, session_id, null, ".item, #parent", &out);
    defer testing.allocator.free(selector_list_id);
    try std.testing.expectEqualStrings(parent_id, selector_list_id);
    const root_id = try testFindWebDriverElement(server, request_allocator, session_id, null, ":root", &out);
    defer testing.allocator.free(root_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, root_id, "/name", &out, "html");

    const child_id = try testFindWebDriverElement(server, request_allocator, session_id, parent_id, ".item", &out);
    defer testing.allocator.free(child_id);
    const scope_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#scope", &out);
    defer testing.allocator.free(scope_id);
    const target_id = try testFindWebDriverElement(server, request_allocator, session_id, scope_id, "#ancestor .target", &out);
    defer testing.allocator.free(target_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, parent_id, "/name", &out, "div");
    try expectWebDriverElementValue(server, request_allocator, session_id, parent_id, "/attribute/data-kind", &out, "group");
    try expectWebDriverElementValue(server, request_allocator, session_id, parent_id, "/attribute/data%3Akind", &out, "colon");
    try expectWebDriverElementValue(
        server,
        request_allocator,
        session_id,
        parent_id,
        "/attribute/missing",
        &out,
        @as(?[]const u8, null),
    );

    const child_elements_path = try std.fmt.allocPrint(
        testing.allocator,
        "/session/{s}/element/{s}/elements",
        .{ session_id, parent_id },
    );
    defer testing.allocator.free(child_elements_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(
        .ok,
        try handle(
            server,
            request_allocator,
            .POST,
            child_elements_path,
            "{\"using\":\"css selector\",\"value\":\".item\"}",
            &out.writer,
        ),
    );
    var children = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer children.deinit();
    const child_values = children.value.object.get("value").?.array.items;
    try testing.expectEqual(@as(usize, 2), child_values.len);
    try std.testing.expectEqualStrings(
        child_id,
        child_values[0].object.get(element_key).?.string,
    );

    const all_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/elements", .{session_id});
    defer testing.allocator.free(all_path);
    const find_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}/element", .{session_id});
    defer testing.allocator.free(find_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(
        .ok,
        try handle(
            server,
            request_allocator,
            .POST,
            all_path,
            "{\"using\":\"css selector\",\"value\":\".missing\"}",
            &out.writer,
        ),
    );
    try testing.expectJson(.{ .value = &.{} }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(
        .ok,
        try handle(
            server,
            request_allocator,
            .POST,
            all_path,
            "{\"using\":\"css selector\",\"value\":\".item, #parent\"}",
            &out.writer,
        ),
    );
    var ordered = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer ordered.deinit();
    const ordered_values = ordered.value.object.get("value").?.array.items;
    try testing.expectEqual(@as(usize, 3), ordered_values.len);
    try std.testing.expectEqualStrings(parent_id, ordered_values[0].object.get(element_key).?.string);
    try std.testing.expectEqualStrings(child_id, ordered_values[1].object.get(element_key).?.string);

    out.clearRetainingCapacity();
    try testing.expectEqual(
        .ok,
        try handle(
            server,
            request_allocator,
            .POST,
            all_path,
            "{\"using\":\"css selector\",\"value\":\"#duplicate\"}",
            &out.writer,
        ),
    );
    var duplicates = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.writer.buffered(), .{});
    defer duplicates.deinit();
    try testing.expectEqual(@as(usize, 2), duplicates.value.object.get("value").?.array.items.len);

    const hidden_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#hidden", &out);
    defer testing.allocator.free(hidden_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, hidden_id, "/attribute/hidden", &out, "true");
    try expectWebDriverElementValue(server, request_allocator, session_id, hidden_id, "/attribute/HIDDEN", &out, "true");

    const checked_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#checked", &out);
    defer testing.allocator.free(checked_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, checked_id, "/selected", &out, true);
    try expectWebDriverElementValue(server, request_allocator, session_id, checked_id, "/enabled", &out, false);

    try expectWebDriverElementValue(server, request_allocator, session_id, unchecked_id, "/selected", &out, false);
    try expectWebDriverElementValue(server, request_allocator, session_id, unchecked_id, "/attribute/alpha", &out, "true");

    const selected_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#selected", &out);
    defer testing.allocator.free(selected_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, selected_id, "/selected", &out, true);

    const implicit_selected_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#implicit_selected", &out);
    defer testing.allocator.free(implicit_selected_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, implicit_selected_id, "/selected", &out, true);

    const disabled_group_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#disabled_group", &out);
    defer testing.allocator.free(disabled_group_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, disabled_group_id, "/enabled", &out, false);

    const disabled_option_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#disabled_option", &out);
    defer testing.allocator.free(disabled_option_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, disabled_option_id, "/enabled", &out, false);

    const legend_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#legend_input", &out);
    defer testing.allocator.free(legend_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, legend_id, "/enabled", &out, true);

    const fieldset_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#fieldset_input", &out);
    defer testing.allocator.free(fieldset_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, fieldset_id, "/enabled", &out, false);

    const nested_legend_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#nested_legend_input", &out);
    defer testing.allocator.free(nested_legend_id);
    try expectWebDriverElementValue(server, request_allocator, session_id, nested_legend_id, "/enabled", &out, false);

    out.clearRetainingCapacity();
    try testing.expectEqual(
        .bad_request,
        try handle(server, request_allocator, .POST, all_path, "{\"using\":\"css selector\"}", &out.writer),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "invalid argument" } }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(
        .bad_request,
        try handle(
            server,
            request_allocator,
            .POST,
            all_path,
            "{\"using\":[99,115,115,32,115,101,108,101,99,116,111,114],\"value\":\"div\"}",
            &out.writer,
        ),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "invalid argument" } }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(
        .bad_request,
        try handle(
            server,
            request_allocator,
            .POST,
            all_path,
            "{\"using\":\"tag name\",\"value\":\"div\"}",
            &out.writer,
        ),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "invalid argument" } }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(
        .bad_request,
        try handle(
            server,
            request_allocator,
            .POST,
            all_path,
            "{\"using\":\"css selector\",\"value\":\"#bad[\"}",
            &out.writer,
        ),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "invalid selector" } }, out.writer.buffered());

    {
        server.enterIsolate(active);
        defer server.exitIsolate(active);
        const frame = active.session.currentFrame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.compileAndRun(
            "setTimeout(() => { const el = document.createElement('p'); el.id = 'later'; document.body.append(el); }, 25)",
            null,
        );
    }
    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"implicit\":250}", &out.writer));
    const later_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#later", &out);
    defer testing.allocator.free(later_id);

    const remove_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#remove", &out);
    defer testing.allocator.free(remove_id);
    {
        server.enterIsolate(active);
        defer server.exitIsolate(active);
        const frame = active.session.currentFrame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.compileAndRun("document.querySelector('#remove').remove()", null);
    }
    const removed_path = try std.fmt.allocPrint(
        testing.allocator,
        "/session/{s}/element/{s}/name",
        .{ session_id, remove_id },
    );
    defer testing.allocator.free(removed_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.not_found, try handle(server, request_allocator, .GET, removed_path, "", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "stale element reference" } }, out.writer.buffered());

    const unknown_path = try std.fmt.allocPrint(
        testing.allocator,
        "/session/{s}/element/{s}-4294967295/name",
        .{ session_id, session_id },
    );
    defer testing.allocator.free(unknown_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.not_found, try handle(server, request_allocator, .GET, unknown_path, "", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "no such element" } }, out.writer.buffered());

    const unknown_child_path = try std.fmt.allocPrint(
        testing.allocator,
        "/session/{s}/element/{s}-4294967295/element",
        .{ session_id, session_id },
    );
    defer testing.allocator.free(unknown_child_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(
        .not_found,
        try handle(
            server,
            request_allocator,
            .POST,
            unknown_child_path,
            "{\"using\":\"css selector\",\"value\":\"#bad[\"}",
            &out.writer,
        ),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "no such element" } }, out.writer.buffered());

    const noncanonical_path = try std.fmt.allocPrint(
        testing.allocator,
        "/session/{s}/element/{s}-0{s}/name",
        .{ session_id, session_id, parent_id[session_id.len + 1 ..] },
    );
    defer testing.allocator.free(noncanonical_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.not_found, try handle(server, request_allocator, .GET, noncanonical_path, "", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "no such element" } }, out.writer.buffered());

    const adopt_id = try testFindWebDriverElement(server, request_allocator, session_id, null, "#adopt", &out);
    defer testing.allocator.free(adopt_id);
    {
        server.enterIsolate(active);
        defer server.exitIsolate(active);
        const frame = active.session.currentFrame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.compileAndRun(
            "globalThis.otherDocument = document.implementation.createHTMLDocument('other'); otherDocument.body.append(document.querySelector('#adopt'))",
            null,
        );
    }
    const adopted_path = try std.fmt.allocPrint(
        testing.allocator,
        "/session/{s}/element/{s}/name",
        .{ session_id, adopt_id },
    );
    defer testing.allocator.free(adopted_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.not_found, try handle(server, request_allocator, .GET, adopted_path, "", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "stale element reference" } }, out.writer.buffered());

    const fragment_body = try std.fmt.allocPrint(testing.allocator, "{{\"url\":\"{s}#fragment\"}}", .{page_url});
    defer testing.allocator.free(fragment_body);
    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, navigate_path, fragment_body, &out.writer));
    try expectWebDriverElementValue(server, request_allocator, session_id, parent_id, "/name", &out, "div");

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"pageLoad\":0}", &out.writer));
    out.clearRetainingCapacity();
    try testing.expectEqual(
        .internal_server_error,
        try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,aborted\"}", &out.writer),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "timeout" } }, out.writer.buffered());
    try expectWebDriverElementValue(server, request_allocator, session_id, parent_id, "/name", &out, "div");

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"implicit\":0}", &out.writer));
    out.clearRetainingCapacity();
    try testing.expectEqual(
        .ok,
        try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,<p>next</p>\"}", &out.writer),
    );
    const stale_path = try std.fmt.allocPrint(
        testing.allocator,
        "/session/{s}/element/{s}/name",
        .{ session_id, parent_id },
    );
    defer testing.allocator.free(stale_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.not_found, try handle(server, request_allocator, .GET, stale_path, "", &out.writer));
    try testing.expectJson(.{ .value = .{ .@"error" = "stale element reference" } }, out.writer.buffered());

    {
        server.enterIsolate(active);
        defer server.exitIsolate(active);
        const frame = active.session.currentFrame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.compileAndRun(
            "setTimeout(() => { location.href = \"data:text/html,<p id='late_navigation_target'>new</p>\"; }, 1)",
            null,
        );
    }
    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"implicit\":100}", &out.writer));
    out.clearRetainingCapacity();
    try testing.expectEqual(
        .not_found,
        try handle(
            server,
            request_allocator,
            .POST,
            find_path,
            "{\"using\":\"css selector\",\"value\":\"#late_navigation_target\"}",
            &out.writer,
        ),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "no such element" } }, out.writer.buffered());

    {
        server.enterIsolate(active);
        defer server.exitIsolate(active);
        const frame = active.session.currentFrame().?;
        var scope: lp.js.Local.Scope = undefined;
        frame.js.localScope(&scope);
        defer scope.deinit();
        _ = try scope.local.compileAndRun("setTimeout(() => { while (true) {} }, 1)", null);
    }
    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, timeouts_path, "{\"implicit\":50}", &out.writer));
    out.clearRetainingCapacity();
    try testing.expectEqual(
        .not_found,
        try handle(
            server,
            request_allocator,
            .POST,
            find_path,
            "{\"using\":\"css selector\",\"value\":\"#never\"}",
            &out.writer,
        ),
    );
    try testing.expectJson(.{ .value = .{ .@"error" = "no such element" } }, out.writer.buffered());

    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .DELETE, delete_path, "", &out.writer));
}

test "WebDriver: capabilities support version constraints and valid prompt handlers" {
    try std.testing.expect(browserVersionMatches(">=0.9.0 <2.0.0", "1.0.0-dev"));
    try std.testing.expect(browserVersionMatches("1.2.0", "1.2"));
    try std.testing.expect(!browserVersionMatches(">=1.0.0", "1.0.0-dev"));
    try std.testing.expect(!browserVersionMatches(">=not-a-version", "1.0.0-dev"));

    inline for (.{
        "dismiss",
        "accept",
        "dismiss and notify",
        "accept and notify",
        "ignore",
    }) |handler| try std.testing.expect(isPromptHandler(handler));
}

test "WebDriver: proxy endpoints reject invalid hosts and ports" {
    try std.testing.expect(validProxyEndpoint("httpProxy", "proxy.example:8080"));
    try std.testing.expect(validProxyEndpoint("sslProxy", "user:pass@proxy.example"));
    try std.testing.expect(!validProxyEndpoint("httpProxy", "proxy.example:99999"));
    try std.testing.expect(!validProxyEndpoint("socksProxy", "not a host"));
}

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;
