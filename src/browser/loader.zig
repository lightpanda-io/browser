const std = @import("std");

const user_agent = "Lightpanda.io/1.0";

pub const Loader = struct {
    client: std.http.Client,

    pub const Response = struct {
        req: std.http.Request,

        pub fn deinit(self: *Response) void {
            self.req.deinit();
        }
    };

    pub fn init(allocator: std.mem.Allocator) Loader {
        return Loader{
            .client = std.http.Client{
                .allocator = allocator,
            },
        };
    }

    pub fn deinit(self: *Loader) void {
        self.client.deinit();
    }

    // the caller must deinit the FetchResult.
    pub fn fetch(self: *Loader, allocator: std.mem.Allocator, uri: std.Uri) !std.http.Client.FetchResult {
        var headers = try std.http.Headers.initList(allocator, &[_]std.http.Field{
            .{ .name = "User-Agent", .value = user_agent },
            .{ .name = "Accept", .value = "*/*" },
            .{ .name = "Accept-Language", .value = "en-US,en;q=0.5" },
        });
        defer headers.deinit();

        return try self.client.fetch(allocator, .{
            .location = .{ .uri = uri },
            .headers = headers,
            .payload = .none,
        });
    }
};

test "basic url fetch" {
    const alloc = std.testing.allocator;
    var loader = Loader.init(alloc);
    defer loader.deinit();

    var result = try loader.fetch(alloc, "https://en.wikipedia.org/wiki/Main_Page");
    defer result.deinit();

    try std.testing.expect(result.status == std.http.Status.ok);
}
