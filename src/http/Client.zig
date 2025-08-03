// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const log = @import("../log.zig");
const builtin = @import("builtin");
const Http = @import("Http.zig");

const c = Http.c;

const Allocator = std.mem.Allocator;

const errorCheck = Http.errorCheck;
const errorMCheck = Http.errorMCheck;

pub const Method = Http.Method;

// This is loosely tied to a browser Page. Loading all the <scripts>, doing
// XHR requests, and loading imports all happens through here. Sine the app
// currently supports 1 browser and 1 page at-a-time, we only have 1 Client and
// re-use it from page to page. This allows us better re-use of the various
// buffers/caches (including keepalive connections) that libcurl has.
//
// The app has other secondary http needs, like telemetry. While we want to
// share some things (namely the ca blob, and maybe some configuration
// (TODO: ??? should proxy settings be global ???)), we're able to do call
// client.abort() to abort the transfers being made by a page, without impacting
// those other http requests.
pub const Client = @This();

active: usize,
multi: *c.CURLM,
handles: Handles,
queue: RequestQueue,
allocator: Allocator,
transfer_pool: std.heap.MemoryPool(Transfer),
queue_node_pool: std.heap.MemoryPool(RequestQueue.Node),
//@newhttp
http_proxy: ?std.Uri = null,
blocking: Handle,
blocking_active: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},

const RequestQueue = std.DoublyLinkedList(Request);

pub fn init(allocator: Allocator, ca_blob: c.curl_blob, opts: Http.Opts) !*Client {
    var transfer_pool = std.heap.MemoryPool(Transfer).init(allocator);
    errdefer transfer_pool.deinit();

    var queue_node_pool = std.heap.MemoryPool(RequestQueue.Node).init(allocator);
    errdefer queue_node_pool.deinit();

    const client = try allocator.create(Client);
    errdefer allocator.destroy(client);

    const multi = c.curl_multi_init() orelse return error.FailedToInitializeMulti;
    errdefer _ = c.curl_multi_cleanup(multi);

    var handles = try Handles.init(allocator, client, ca_blob, opts);
    errdefer handles.deinit(allocator);

    var blocking = try Handle.init(client, ca_blob, opts);
    errdefer blocking.deinit();

    client.* = .{
        .queue = .{},
        .active = 0,
        .multi = multi,
        .handles = handles,
        .blocking = blocking,
        .allocator = allocator,
        .transfer_pool = transfer_pool,
        .queue_node_pool = queue_node_pool,
    };

    return client;
}

pub fn deinit(self: *Client) void {
    self.abort();
    self.blocking.deinit();
    self.handles.deinit(self.allocator);

    _ = c.curl_multi_cleanup(self.multi);

    self.transfer_pool.deinit();
    self.queue_node_pool.deinit();
    self.allocator.destroy(self);
}

pub fn abort(self: *Client) void {
    while (self.handles.in_use.first) |node| {
        var transfer = Transfer.fromEasy(node.data.easy) catch |err| {
            log.err(.http, "get private info", .{ .err = err, .source = "abort" });
            continue;
        };
        transfer.req.error_callback(transfer.ctx, error.Abort);
        self.endTransfer(transfer);
    }
    std.debug.assert(self.active == 0);

    var n = self.queue.first;
    while (n) |node| {
        n = node.next;
        self.queue_node_pool.destroy(node);
    }
    self.queue = .{};

    // Maybe a bit of overkill
    // We can remove some (all?) of these once we're confident its right.
    std.debug.assert(self.handles.in_use.first == null);
    std.debug.assert(self.handles.available.len == self.handles.handles.len);
    if (builtin.mode == .Debug) {
        var running: c_int = undefined;
        std.debug.assert(c.curl_multi_perform(self.multi, &running) == c.CURLE_OK);
        std.debug.assert(running == 0);
    }
}

pub fn tick(self: *Client, timeout_ms: usize) !void {
    var handles = &self.handles;
    while (true) {
        if (handles.isEmpty()) {
            break;
        }
        const queue_node = self.queue.popFirst() orelse break;
        const req = queue_node.data;
        self.queue_node_pool.destroy(queue_node);

        // we know this exists, because we checked isEmpty() above
        const handle = handles.getFreeHandle().?;
        try self.makeRequest(handle, req);
    }

    try self.perform(@intCast(timeout_ms));
}

pub fn request(self: *Client, req: Request) !void {
    if (self.handles.getFreeHandle()) |handle| {
        return self.makeRequest(handle, req);
    }

    const node = try self.queue_node_pool.create();
    node.data = req;
    self.queue.append(node);
}

// See ScriptManager.blockingGet
pub fn blockingRequest(self: *Client, req: Request) !void {
    if (comptime builtin.mode == .Debug) {
        std.debug.assert(self.blocking_active == false);
        self.blocking_active = true;
    }
    defer if (comptime builtin.mode == .Debug) {
        self.blocking_active = false;
    };

    return self.makeRequest(&self.blocking, req);
}

fn makeRequest(self: *Client, handle: *Handle, req: Request) !void {
    const easy = handle.easy;

    const header_list = blk: {
        errdefer self.handles.release(handle);
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_URL, req.url.ptr));

        try Http.setMethod(easy, req.method);
        if (req.body) |b| {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, b.ptr));
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(b.len))));
        }

        var header_list = c.curl_slist_append(null, "User-Agent: Lightpanda/1.0");
        errdefer c.curl_slist_free_all(header_list);

        if (req.content_type) |ct| {
            header_list = c.curl_slist_append(header_list, ct);
        }

        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, header_list));

        break :blk header_list;
    };

    {
        errdefer self.handles.release(handle);

        const transfer = try self.transfer_pool.create();
        transfer.* = .{
            .id = 0,
            .req = req,
            .ctx = req.ctx,
            .handle = handle,
            ._request_header_list = header_list,
        };
        errdefer self.transfer_pool.destroy(transfer);
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PRIVATE, transfer));

        try errorMCheck(c.curl_multi_add_handle(self.multi, easy));
        if (req.start_callback) |cb| {
            cb(transfer) catch |err| {
                try errorMCheck(c.curl_multi_remove_handle(self.multi, easy));
                return err;
            };
        }
    }

    self.active += 1;
    return self.perform(0);
}

fn perform(self: *Client, timeout_ms: c_int) !void {
    const multi = self.multi;

    var running: c_int = undefined;
    try errorMCheck(c.curl_multi_perform(multi, &running));

    if (running > 0 and timeout_ms > 0) {
        try errorMCheck(c.curl_multi_poll(multi, null, 0, timeout_ms, null));
    }

    while (true) {
        var remaining: c_int = undefined;
        const msg: *c.CURLMsg = c.curl_multi_info_read(multi, &remaining) orelse break;
        if (msg.msg == c.CURLMSG_DONE) {
            const easy = msg.easy_handle.?;

            const transfer = try Transfer.fromEasy(easy);

            const ctx = transfer.ctx;
            const done_callback = transfer.req.done_callback;
            const error_callback = transfer.req.error_callback;

            // release it ASAP so that it's available; some done_callbacks
            // will load more resources.
            self.endTransfer(transfer);

            if (errorCheck(msg.data.result)) {
                done_callback(ctx) catch |err| {
                    // transfer isn't valid at this point, don't use it.
                    log.err(.http, "done_callback", .{ .err = err });
                    error_callback(ctx, err);
                };
            } else |err| {
                error_callback(ctx, err);
            }
        }

        if (remaining == 0) {
            break;
        }
    }
}

fn endTransfer(self: *Client, transfer: *Transfer) void {
    const handle = transfer.handle;

    transfer.deinit();
    self.transfer_pool.destroy(transfer);

    errorMCheck(c.curl_multi_remove_handle(self.multi, handle.easy)) catch |err| {
        log.fatal(.http, "Failed to abort", .{ .err = err });
    };

    self.handles.release(handle);
    self.active -= 1;
}

const Handles = struct {
    handles: []Handle,
    in_use: HandleList,
    available: HandleList,

    const HandleList = std.DoublyLinkedList(*Handle);

    fn init(allocator: Allocator, client: *Client, ca_blob: c.curl_blob, opts: Http.Opts) !Handles {
        const count = opts.max_concurrent_transfers;
        std.debug.assert(count > 0);

        const handles = try allocator.alloc(Handle, count);
        errdefer allocator.free(handles);

        var available: HandleList = .{};
        for (0..count) |i| {
            handles[i] = try Handle.init(client, ca_blob, opts);
            handles[i].node = .{ .data = &handles[i] };
            available.append(&handles[i].node.?);
        }

        return .{
            .in_use = .{},
            .handles = handles,
            .available = available,
        };
    }

    fn deinit(self: *Handles, allocator: Allocator) void {
        for (self.handles) |*h| {
            h.deinit();
        }
        allocator.free(self.handles);
    }

    fn isEmpty(self: *const Handles) bool {
        return self.available.first == null;
    }

    fn getFreeHandle(self: *Handles) ?*Handle {
        if (self.available.popFirst()) |node| {
            node.prev = null;
            node.next = null;
            self.in_use.append(node);
            return node.data;
        }
        return null;
    }

    fn release(self: *Handles, handle: *Handle) void {
        // client.blocking is a handle without a node, it doesn't exist in the
        // eitehr the in_use or available lists.
        const node = &(handle.node orelse return);

        self.in_use.remove(node);
        node.prev = null;
        node.next = null;
        self.available.append(node);
    }
};

// wraps a c.CURL (an easy handle)
const Handle = struct {
    easy: *c.CURL,
    client: *Client,
    node: ?Handles.HandleList.Node,

    fn init(client: *Client, ca_blob: c.curl_blob, opts: Http.Opts) !Handle {
        const easy = c.curl_easy_init() orelse return error.FailedToInitializeEasy;
        errdefer _ = c.curl_easy_cleanup(easy);

        // timeouts
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(opts.timeout_ms))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(opts.connect_timeout_ms))));

        // redirect behavior
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, @intCast(opts.max_redirects))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 2)));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_REDIR_PROTOCOLS_STR, "HTTP,HTTPS")); // remove FTP and FTPS from the default

        // callbacks
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HEADERDATA, easy));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HEADERFUNCTION, Transfer.headerCallback));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, easy));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, Transfer.bodyCallback));

        // tls
        if (opts.tls_verify_host) {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CAINFO_BLOB, ca_blob));
        } else {
            // Verify peer checks that the cert is signed by a CA, verify host makes sure the
            // cert contains the server name.
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0)));
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 0)));
        }

        // debug
        if (comptime Http.ENABLE_DEBUG) {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_VERBOSE, @as(c_long, 1)));
        }

        return .{
            .easy = easy,
            .node = null,
            .client = client,
        };
    }

    fn deinit(self: *const Handle) void {
        _ = c.curl_easy_cleanup(self.easy);
    }
};

pub const Request = struct {
    method: Method,
    url: [:0]const u8,
    body: ?[]const u8 = null,
    content_type: ?[:0]const u8 = null,

    // arbitrary data that can be associated with this request
    ctx: *anyopaque = undefined,

    start_callback: ?*const fn (req: *Transfer) anyerror!void = null,
    header_callback: ?*const fn (req: *Transfer, header: []const u8) anyerror!void = null,
    header_done_callback: *const fn (req: *Transfer) anyerror!void,
    data_callback: *const fn (req: *Transfer, data: []const u8) anyerror!void,
    done_callback: *const fn (ctx: *anyopaque) anyerror!void,
    error_callback: *const fn (ctx: *anyopaque, err: anyerror) void,
};

pub const Transfer = struct {
    id: usize,
    req: Request,
    ctx: *anyopaque,

    // We'll store the response header here
    response_header: ?Header = null,

    handle: *Handle,

    _redirecting: bool = false,
    // needs to be freed when we're done
    _request_header_list: ?*c.curl_slist = null,

    fn deinit(self: *Transfer) void {
        if (self._request_header_list) |list| {
            c.curl_slist_free_all(list);
        }
    }

    pub fn format(self: *const Transfer, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const req = self.req;
        return writer.print("[{d}] {s} {s}", .{ self.id, @tagName(req.method), req.url });
    }

    pub fn setBody(self: *Transfer, body: []const u8) !void {
        const easy = self.handle.easy;
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, body.ptr));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len))));
    }

    pub fn addHeader(self: *Transfer, value: [:0]const u8) !void {
        self._request_header_list = c.curl_slist_append(self._request_header_list, value);
    }

    pub fn abort(self: *Transfer) void {
        self.handle.client.endTransfer(self);
    }

    fn headerCallback(buffer: [*]const u8, header_count: usize, buf_len: usize, data: *anyopaque) callconv(.c) usize {
        // libcurl should only ever emit 1 header at a time
        std.debug.assert(header_count == 1);

        const easy: *c.CURL = @alignCast(@ptrCast(data));
        var transfer = fromEasy(easy) catch |err| {
            log.err(.http, "get private info", .{ .err = err, .source = "header callback" });
            return 0;
        };

        std.debug.assert(std.mem.endsWith(u8, buffer[0..buf_len], "\r\n"));

        const header = buffer[0 .. buf_len - 2];

        if (transfer.response_header == null) {
            if (buf_len < 13 or std.mem.startsWith(u8, header, "HTTP/") == false) {
                if (transfer._redirecting) {
                    return buf_len;
                }
                log.debug(.http, "invalid response line", .{ .line = header });
                return 0;
            }
            const version_start: usize = if (header[5] == '2') 7 else 9;
            const version_end = version_start + 3;

            // a bit silly, but it makes sure that we don't change the length check
            // above in a way that could break this.
            std.debug.assert(version_end < 13);

            const status = std.fmt.parseInt(u16, header[version_start..version_end], 10) catch {
                log.debug(.http, "invalid status code", .{ .line = header });
                return 0;
            };

            if (status >= 300 and status <= 399) {
                transfer._redirecting = true;
                return buf_len;
            }
            transfer._redirecting = false;

            var url: [*c]u8 = undefined;
            errorCheck(c.curl_easy_getinfo(easy, c.CURLINFO_EFFECTIVE_URL, &url)) catch |err| {
                log.err(.http, "failed to get URL", .{ .err = err });
                return 0;
            };

            transfer.response_header = .{
                .url = url,
                .status = status,
            };
            return buf_len;
        }

        const CONTENT_TYPE_LEN = "content-type:".len;

        var hdr = &transfer.response_header.?;
        if (hdr._content_type_len == 0) {
            if (buf_len > CONTENT_TYPE_LEN) {
                if (std.ascii.eqlIgnoreCase(header[0..CONTENT_TYPE_LEN], "content-type:")) {
                    const value = std.mem.trimLeft(u8, header[CONTENT_TYPE_LEN..], " ");
                    const len = @min(value.len, hdr._content_type.len);
                    hdr._content_type_len = len;
                    @memcpy(hdr._content_type[0..len], value[0..len]);
                }
            }
        }

        if (buf_len == 2) {
            transfer.req.header_done_callback(transfer) catch |err| {
                log.err(.http, "header_done_callback", .{ .err = err, .req = transfer });
                // returning < buf_len terminates the request
                return 0;
            };
        } else {
            if (transfer.req.header_callback) |cb| {
                cb(transfer, header) catch |err| {
                    log.err(.http, "header_callback", .{ .err = err, .req = transfer });
                    return 0;
                };
            }
        }
        return buf_len;
    }

    fn bodyCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) callconv(.c) usize {
        // libcurl should only ever emit 1 chunk at a time
        std.debug.assert(chunk_count == 1);

        const easy: *c.CURL = @alignCast(@ptrCast(data));
        var transfer = fromEasy(easy) catch |err| {
            log.err(.http, "get private info", .{ .err = err, .source = "body callback" });
            return c.CURL_WRITEFUNC_ERROR;
        };

        if (transfer._redirecting) {
            return chunk_len;
        }

        transfer.req.data_callback(transfer, buffer[0..chunk_len]) catch |err| {
            log.err(.http, "data_callback", .{ .err = err, .req = transfer });
            return c.CURL_WRITEFUNC_ERROR;
        };
        return chunk_len;
    }

    fn fromEasy(easy: *c.CURL) !*Transfer {
        var private: *anyopaque = undefined;
        try errorCheck(c.curl_easy_getinfo(easy, c.CURLINFO_PRIVATE, &private));
        return @alignCast(@ptrCast(private));
    }
};

pub const Header = struct {
    status: u16,
    url: [*c]const u8,
    _content_type_len: usize = 0,
    _content_type: [64]u8 = undefined,

    pub fn contentType(self: *Header) ?[]u8 {
        if (self._content_type_len == 0) {
            return null;
        }
        return self._content_type[0..self._content_type_len];
    }
};
