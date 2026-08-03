//! Minimal W3C WebDriver remote-end command router. The HTTP transport owns
//! framing; this module owns command routing and JSON response semantics.

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("lightpanda");

const Server = @import("Server.zig");

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
    get_timeouts,
    set_timeouts,
};

const Route = struct {
    command: Command,
    alternate: ?Command = null,
    session_id: ?[]const u8 = null,
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

    server.enterIsolate(session);
    defer server.exitIsolate(session);

    return switch (command) {
        .navigate => navigate(server, session, arena, body, out),
        .current_url => currentUrl(session, out),
        .get_timeouts => getTimeouts(server, out),
        .set_timeouts => setTimeouts(server, arena, body, out),
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
    if (!lp.URL.canParse(parsed.value.url, null)) {
        return sendError(out, .bad_request, "invalid argument", "Navigate To requires an absolute URL");
    }

    const result = lp.tools.gotoLiteral(
        session.session,
        &session.node_registry,
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
    const frame = session.session.currentFrame() orelse
        return sendError(out, .not_found, "no such window", "Current browsing context has no document");
    return sendValue(out, frame.url);
}

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
    if (std.mem.eql(u8, suffix, "/timeouts")) return .{
        .command = .get_timeouts,
        .alternate = .set_timeouts,
        .session_id = session_id,
    };
    return null;
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
        .status, .current_url, .get_timeouts => .GET,
        .new_session, .navigate, .set_timeouts => .POST,
        .delete_session => .DELETE,
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
    try testing.expectEqual(.ok, try handle(server, request_allocator, .POST, navigate_path, "{\"url\":\"data:text/html,<title>second</title>\"}", &out.writer));
    try testing.expectEqual(frame_id_before, active.session.primaryPage().?.frame_id);

    try active.session.cookie_jar.populateFromResponse("https://example.com/", "token=secret; Path=/");
    try testing.expectEqual(@as(usize, 1), active.session.cookie_jar.cookies.items.len);

    const delete_path = try std.fmt.allocPrint(testing.allocator, "/session/{s}", .{session_id});
    defer testing.allocator.free(delete_path);
    out.clearRetainingCapacity();
    try testing.expectEqual(.ok, try handle(server, request_allocator, .DELETE, delete_path, "", &out.writer));
    try testing.expectJson(.{ .value = null }, out.writer.buffered());

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
