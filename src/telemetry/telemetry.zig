const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const uuidv4 = @import("../id.zig").uuidv4;

const log = lp.log;
const IID_FILE = "iid";
const Allocator = std.mem.Allocator;

pub fn isDisabled() bool {
    if (lp.IS_DEBUG or lp.IS_TEST) {
        return true;
    }

    return std.c.getenv("LIGHTPANDA_DISABLE_TELEMETRY") != null;
}

pub const Telemetry = TelemetryT(@import("lightpanda.zig"));

fn TelemetryT(comptime P: type) type {
    return struct {
        provider: *P,

        disabled: bool,

        const Self = @This();

        pub fn init(app: *App) !Self {
            const disabled = isDisabled();
            if (lp.IS_DEBUG == false and lp.IS_TEST == false) {
                log.info(.telemetry, "telemetry status", .{ .disabled = disabled });
            }

            const iid: ?[36]u8 = if (disabled) null else getOrCreateId(app.app_dir_path);

            const provider = try app.allocator.create(P);
            errdefer app.allocator.destroy(provider);

            try P.init(provider, app, iid);

            return .{
                .disabled = disabled,
                .provider = provider,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.provider.deinit();
            allocator.destroy(self.provider);
        }

        pub fn record(self: *Self, event: Event) void {
            if (self.disabled) {
                return;
            }
            self.provider.send(event) catch |err| {
                log.debug(.telemetry, "record error", .{ .err = err, .type = @tagName(std.meta.activeTag(event)) });
            };
        }

        /// `start_ms` is a `datetime.milliTimestamp(.awake)` taken before the call.
        pub fn recordTool(self: *Self, id: u8, source: Event.Tool.Source, outcome: Event.Tool.Outcome, start_ms: u64) void {
            if (self.disabled) {
                return;
            }
            const elapsed = lp.datetime.milliTimestamp(.awake) -| start_ms;
            self.record(.{ .tool = .{
                .id = id,
                .source = source,
                .outcome = outcome,
                .duration_ms = std.math.lossyCast(u32, elapsed),
            } });
        }

        pub fn llm_init(_: *Self, provider: [:0]const u8, model: ?[]const u8) Event.LLM {
            return Event.LLM.init(provider, model);
        }
    };
}

fn getOrCreateId(app_dir_path_: ?[]const u8) ?[36]u8 {
    const app_dir_path = app_dir_path_ orelse {
        var id: [36]u8 = undefined;
        uuidv4(&id);
        return id;
    };

    var buf: [37]u8 = undefined;
    var dir = std.Io.Dir.openDirAbsolute(lp.io, app_dir_path, .{}) catch |err| {
        log.warn(.telemetry, "data directory open error", .{ .path = app_dir_path, .err = err });
        return null;
    };
    defer dir.close(lp.io);

    const data = dir.readFile(lp.io, IID_FILE, &buf) catch |err| switch (err) {
        error.FileNotFound => &.{},
        else => {
            log.warn(.telemetry, "ID read error", .{ .path = app_dir_path, .err = err });
            return null;
        },
    };

    var id: [36]u8 = undefined;
    if (data.len == 36) {
        @memcpy(id[0..36], data);
        return id;
    }

    uuidv4(&id);
    dir.writeFile(lp.io, .{ .sub_path = IID_FILE, .data = &id }) catch |err| {
        log.warn(.telemetry, "ID write error", .{ .path = app_dir_path, .err = err });
        return null;
    };
    return id;
}

pub const Event = union(enum) {
    run: void,
    navigate: Navigate,
    buffer_overflow: BufferOverflow,
    llm: LLM,
    tool: Tool,
    mcp_client: McpClient,

    pub const Navigate = struct {
        tls: bool,
        context: Context,

        pub const Context = enum { page, iframe, popup };
    };

    /// The provider merges calls with the same id, source and outcome within
    /// one batch, so a sent row carries a count and a total duration.
    pub const Tool = struct {
        /// `browser.tools.Tool.telemetryId()`, or an MCP-only tool's pinned value
        /// (200+). 0 is a name that matched no tool.
        id: u8,
        source: Source,
        outcome: Outcome,
        count: u32 = 1,
        duration_ms: u32,

        pub const Source = enum { llm, user, script, mcp };

        pub const Outcome = enum {
            ok,
            is_error,
            frame_not_loaded,
            invalid_params,
            node_not_found,
            navigation_failed,
            navigation_timeout,
            cancelled,
            timeout,
            internal,
        };
    };

    /// The MCP client, from `clientInfo.name`. Values are wire ids: append,
    /// never renumber.
    pub const McpClient = enum(u8) {
        other = 0,
        claude_code = 1,
        claude = 2,
        cursor = 3,
        vscode = 4,
        codex = 5,
        gemini = 6,
        windsurf = 7,
        cline = 8,
        zed = 9,
        goose = 10,

        // Ordered: "claude-code" before "claude", "cursor" before the
        // "vscode" in Cursor's "cursor-vscode".
        const patterns = [_]struct { []const u8, McpClient }{
            .{ "claude-code", .claude_code },
            .{ "claude", .claude },
            .{ "cursor", .cursor },
            .{ "windsurf", .windsurf },
            .{ "visual studio code", .vscode },
            .{ "vscode", .vscode },
            .{ "codex", .codex },
            .{ "gemini", .gemini },
            .{ "cline", .cline },
            .{ "goose", .goose },
        };

        pub fn fromName(name: []const u8) McpClient {
            // Exact: "zed" is a common substring.
            if (std.ascii.eqlIgnoreCase(name, "zed")) return .zed;
            for (patterns) |p| {
                if (std.ascii.findIgnoreCase(name, p[0]) != null) return p[1];
            }
            return .other;
        }
    };

    const BufferOverflow = struct {
        dropped: u32,
    };

    const LLM = struct {
        provider: [:0]const u8,
        model: ?Model,

        const Model = struct {
            len: u8,
            buffer: [32]u8,

            pub fn wrap(_s: ?[]const u8) ?Model {
                if (_s == null) return null;

                const l = @min(_s.?.len, 32);
                var m: Model = .{
                    .len = l,
                    .buffer = undefined,
                };
                @memcpy(m.buffer[0..l], _s.?[0..l]);

                return m;
            }

            pub fn jsonStringify(self: *const Model, writer: anytype) !void {
                try writer.write(self.buffer[0..self.len]);
            }
        };

        pub fn init(provider: [:0]const u8, _model: ?[]const u8) LLM {
            return .{
                .provider = provider,
                .model = Model.wrap(_model),
            };
        }
    };
};

extern fn setenv(name: [*:0]u8, value: [*:0]u8, override: c_int) c_int;
extern fn unsetenv(name: [*:0]u8) c_int;

const testing = @import("../testing.zig");
test "telemetry: McpClient.fromName" {
    try testing.expectEqual(.claude_code, Event.McpClient.fromName("claude-code"));
    try testing.expectEqual(.claude, Event.McpClient.fromName("claude-ai"));
    try testing.expectEqual(.cursor, Event.McpClient.fromName("cursor-vscode"));
    try testing.expectEqual(.vscode, Event.McpClient.fromName("Visual Studio Code - Insiders"));
    try testing.expectEqual(.zed, Event.McpClient.fromName("Zed"));
    try testing.expectEqual(.other, Event.McpClient.fromName("customized-client"));
    try testing.expectEqual(.other, Event.McpClient.fromName(""));
}

test "telemetry: always disabled in debug builds" {
    // Must be disabled regardless of environment variable.
    _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"));
    try testing.expectEqual(true, isDisabled());

    _ = setenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"), @constCast(""), 0);
    defer _ = unsetenv(@constCast("LIGHTPANDA_DISABLE_TELEMETRY"));
    try testing.expectEqual(true, isDisabled());

    const FailingProvider = struct {
        fn init(_: *@This(), _: *App, _: ?[36]u8) !void {}
        fn deinit(_: *@This()) void {}
        pub fn send(_: *@This(), _: Event) !void {
            unreachable;
        }
    };

    var telemetry = try TelemetryT(FailingProvider).init(testing.test_app);
    defer telemetry.deinit(testing.test_app.allocator);
    telemetry.record(.{ .run = {} });
}

test "telemetry: getOrCreateId" {
    defer std.Io.Dir.cwd().deleteFile(testing.io, "/tmp/" ++ IID_FILE) catch {};

    std.Io.Dir.cwd().deleteFile(testing.io, "/tmp/" ++ IID_FILE) catch {};

    const id1 = getOrCreateId("/tmp/").?;
    const id2 = getOrCreateId("/tmp/").?;
    try testing.expectEqual(&id1, &id2);

    std.Io.Dir.cwd().deleteFile(testing.io, "/tmp/" ++ IID_FILE) catch {};
    const id3 = getOrCreateId("/tmp/").?;
    try testing.expectEqual(false, std.mem.eql(u8, &id1, &id3));

    const id4 = getOrCreateId(null).?;
    try testing.expectEqual(false, std.mem.eql(u8, &id1, &id4));
    try testing.expectEqual(false, std.mem.eql(u8, &id3, &id4));
}

test "telemetry: sends event to provider" {
    var telemetry = try TelemetryT(MockProvider).init(testing.test_app);
    defer telemetry.deinit(testing.test_app.allocator);
    telemetry.disabled = false;
    const mock = telemetry.provider;

    telemetry.record(.{ .buffer_overflow = .{ .dropped = 1 } });
    telemetry.record(.{ .buffer_overflow = .{ .dropped = 2 } });
    telemetry.record(.{ .buffer_overflow = .{ .dropped = 3 } });
    try testing.expectEqual(3, mock.events.items.len);

    for (mock.events.items, 0..) |event, i| {
        try testing.expectEqual(i + 1, event.buffer_overflow.dropped);
    }
}

const MockProvider = struct {
    allocator: Allocator,
    events: std.ArrayList(Event),

    fn init(self: *MockProvider, app: *App, _: ?[36]u8) !void {
        self.* = .{
            .events = .empty,
            .allocator = app.allocator,
        };
    }
    fn deinit(self: *MockProvider) void {
        self.events.deinit(self.allocator);
    }
    pub fn send(self: *MockProvider, event: Event) !void {
        try self.events.append(self.allocator, event);
    }
};
