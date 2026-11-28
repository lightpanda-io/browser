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

//! Lightpanda Cloud: the agent and decision models through the Lightpanda
//! gateway, on the user's LIGHTPANDA_TOKEN. The gateway's `/v1/config` names
//! the protocol and route for each. `App` loads it once per process.

const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");

const log = lp.log;
const Route = zenai.gateway.Route;

const Cloud = @This();

arena: std.heap.ArenaAllocator,
gateway: zenai.gateway.Gateway,
config: Config,
/// The agent model's endpoint, or `error.UnsupportedProtocol` when this
/// version can't speak the agent route's protocol.
agent: error{UnsupportedProtocol}!zenai.provider.Endpoint,

pub const token_env_var_name = "LIGHTPANDA_TOKEN";
const gateway_url_env_var_name = "LIGHTPANDA_GATEWAY_URL";
const default_gateway_url = "https://llm.lightpanda.io";

/// Sent on every gateway call: the gateway counts traffic and decides
/// deprecation per version.
const version_headers = [_]std.http.Header{.{ .name = "X-Lightpanda-Version", .value = lp.build_config.version }};

/// Read by `describeError`.
const capture_headers = [_][]const u8{ "x-lightpanda-error", "x-lightpanda-resets-at" };

pub fn token() ?[:0]const u8 {
    const t = zenai.provider.envGet(lp.environ(), token_env_var_name) orelse return null;
    return if (t.len == 0) null else t;
}

pub fn gatewayUrl() []const u8 {
    const url = zenai.provider.envGet(lp.environ(), gateway_url_env_var_name) orelse return default_gateway_url;
    return std.mem.trimEnd(u8, url, "/");
}

/// `/v1/config`.
pub const Config = struct {
    agent: Route,
    decisions: Route,
    /// Set when the gateway will stop serving this version.
    deprecation: ?struct {
        /// When it stops, as the gateway words it.
        sunset: ?[]const u8 = null,
    } = null,
};

/// Null without LIGHTPANDA_TOKEN; `error.GatewayUnavailable` when neither the
/// gateway nor the cache in `app_dir` has a config (the cause is logged).
/// Warns when the gateway marks this version deprecated.
pub fn load(allocator: std.mem.Allocator, app_dir: ?[]const u8) zenai.gateway.ConfigError!?Cloud {
    const api_token = token() orelse return null;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const gateway: zenai.gateway.Gateway = .{
        .url = gatewayUrl(),
        .key = api_token,
        .extra_headers = &version_headers,
        .capture_headers = &capture_headers,
    };
    const config = try gateway.config(Config, lp.io, a, .{
        .path = "/v1/config",
        .cache_path = if (app_dir) |dir| try std.fs.path.join(a, &.{ dir, "lightpanda-gateway.json" }) else null,
    });
    if (config.deprecation) |d| {
        log.warn(.app, "lightpanda version deprecated", .{ .sunset = d.sunset orelse "soon", .hint = "update lightpanda" });
    }
    const agent: error{UnsupportedProtocol}!zenai.provider.Endpoint = agentEndpoint(a, gateway, config) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedProtocol => error.UnsupportedProtocol,
    };
    return .{ .arena = arena, .gateway = gateway, .config = config, .agent = agent };
}

pub fn deinit(self: *Cloud) void {
    self.arena.deinit();
}

/// Points `pool` at the gateway, over TYPESAFE_API_KEY too: the decisions
/// route, or with the provider forced to Gemini, whichever route speaks it.
/// Keeps the env keys when this version can't speak that route.
pub fn routeDecisions(self: *Cloud, pool: *zenai.decisions.Pool, provider_env_var_name: []const u8) !void {
    const forced = zenai.decisions.envForcedProvider(lp.environ(), provider_env_var_name) catch null;
    const route = decisionRoute(self.config, forced) orelse return;
    const credentials = self.gateway.decisionCredentials(self.arena.allocator(), route) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedProtocol => {
            log.warn(.app, "gateway decisions unsupported", .{ .protocol = route.protocol, .hint = "update lightpanda" });
            return;
        },
    };
    try pool.setCredentials(credentials);
}

/// The gateway serves its `default` alias unless the config names a model.
fn agentEndpoint(arena: std.mem.Allocator, gateway: zenai.gateway.Gateway, config: Config) zenai.gateway.RouteError!zenai.provider.Endpoint {
    var route = config.agent;
    if (route.model == null) route.model = "default";
    return gateway.endpoint(arena, route);
}

fn decisionRoute(config: Config, forced: ?zenai.decisions.Provider) ?Route {
    if (forced != .gemini) return config.decisions;
    for ([_]Route{ config.decisions, config.agent }) |r| {
        if (std.mem.eql(u8, r.protocol, "gemini")) return r;
    }
    return null;
}

/// What to tell the user about a failure the gateway itself reported, or
/// null when it came from the provider behind it.
pub fn describeError(buf: []u8, headers: zenai.http.CapturedHeaders) ?[]const u8 {
    const code = headers.get("x-lightpanda-error") orelse return null;
    const Code = enum { unauthorized, llm_not_enabled, model_not_allowed, rate_limited, quota_exceeded, upstream_rate_limited, route_removed };
    const known = std.meta.stringToEnum(Code, code) orelse return std.mem.print(buf, "Lightpanda gateway: {s}", .{code}) catch code;
    const used_up = "Lightpanda Cloud allowance used up";
    return switch (known) {
        .unauthorized => "Lightpanda rejected the token; check " ++ token_env_var_name,
        .llm_not_enabled => "model access is off for this Lightpanda token; turn it on in the Lightpanda console",
        .model_not_allowed => "Lightpanda Cloud doesn't serve this model; run /model default",
        .rate_limited => "too many requests to Lightpanda Cloud; wait a moment and retry",
        .quota_exceeded => if (headers.get("x-lightpanda-resets-at")) |at|
            std.mem.print(buf, used_up ++ "; it resets at {s}", .{at}) catch used_up
        else
            used_up,
        .upstream_rate_limited => "the model provider is rate-limiting Lightpanda Cloud (not your allowance); retry shortly",
        .route_removed => "Lightpanda Cloud no longer serves this version; update lightpanda",
    };
}

const testing = std.testing;

const test_gateway: zenai.gateway.Gateway = .{ .url = "https://gw", .key = "tok", .extra_headers = &version_headers };

const test_config: Config = .{
    .agent = .{ .protocol = "gemini", .path = "/gemini" },
    .decisions = .{ .protocol = "typesafe", .path = "/typesafe" },
};

test "Cloud.agentEndpoint: the client the gateway names, on its default alias" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const agent = try agentEndpoint(arena.allocator(), test_gateway, test_config);
    try testing.expectEqual(zenai.provider.Tag.gemini, agent.tag());
    try testing.expectEqualStrings("https://gw/gemini", agent.base_url.?);
    try testing.expectEqualStrings("default", agent.defaultModel());
    try testing.expectEqualStrings("X-Lightpanda-Version", agent.extra_headers[0].name);

    var unknown = test_config;
    unknown.agent.protocol = "lightpanda-v2";
    try testing.expectError(error.UnsupportedProtocol, agentEndpoint(arena.allocator(), test_gateway, unknown));
}

test "Cloud.decisionRoute: TypeSafe by default, a Gemini route when forced" {
    try testing.expectEqualStrings("/typesafe", decisionRoute(test_config, null).?.path);
    try testing.expectEqualStrings("/gemini", decisionRoute(test_config, .gemini).?.path);
    var no_gemini = test_config;
    no_gemini.agent.protocol = "anthropic";
    try testing.expectEqual(null, decisionRoute(no_gemini, .gemini));
}

fn captured(comptime pairs: []const std.http.Header) zenai.http.CapturedHeaders {
    return .{ .items = @constCast(pairs) };
}

test "Cloud.describeError: gateway codes get a message, provider errors don't" {
    var buf: [256]u8 = undefined;
    try testing.expectEqual(null, describeError(&buf, .{}));
    try testing.expectStringStartsWith(describeError(&buf, captured(&.{.{ .name = "x-lightpanda-error", .value = "llm_not_enabled" }})).?, "model access is off");
    try testing.expectEqualStrings(
        "Lightpanda Cloud allowance used up; it resets at 2026-12-01T00:00:00Z",
        describeError(&buf, captured(&.{
            .{ .name = "x-lightpanda-error", .value = "quota_exceeded" },
            .{ .name = "x-lightpanda-resets-at", .value = "2026-12-01T00:00:00Z" },
        })).?,
    );
    try testing.expectEqualStrings("Lightpanda gateway: brand_new_code", describeError(&buf, captured(&.{.{ .name = "x-lightpanda-error", .value = "brand_new_code" }})).?);
}
