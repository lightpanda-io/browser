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
pub const Headers = Http.Headers;
const Notification = @import("../notification.zig").Notification;

const c = Http.c;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

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

// count of active requests
active: usize,

// curl has 2 APIs: easy and multi. Multi is like a combination of some I/O block
// (e.g. epoll) and a bunch of pools. You add/remove easys to the multiple and
// then poll the multi.
multi: *c.CURLM,

// Our easy handles. Although the multi contains buffer pools and connections
// pools, re-using the easys is still recommended. This acts as our own pool
// of easys.
handles: Handles,

// Use to generate the next request ID
next_request_id: u64 = 0,

// When handles has no more available easys, requests get queued.
queue: RequestQueue,

// Memory pool for Queue nodes.
queue_node_pool: std.heap.MemoryPool(RequestQueue.Node),

// The main app allocator
allocator: Allocator,

// Once we have a handle/easy to process a request with, we create a Transfer
// which contains the Request as well as any state we need to process the
// request. These wil come and go with each request.
transfer_pool: std.heap.MemoryPool(Transfer),

// see ScriptManager.blockingGet
blocking: Handle,

// To notify registered subscribers of events, the browser sets/nulls this for us.
notification: ?*Notification = null,

// The only place this is meant to be used is in `makeRequest` BEFORE `perform`
// is called. It is used to generate our Cookie header. It can be used for other
// purposes, but keep in mind that, while single-threaded, calls like makeRequest
// can result in makeRequest being re-called (from a doneCallback).
arena: ArenaAllocator,

// only needed for CDP which can change the proxy and then restore it. When
// restoring, this originally-configured value is what it goes to.
http_proxy: ?[:0]const u8 = null,

const RequestQueue = std.DoublyLinkedList(Request);

pub fn init(allocator: Allocator, ca_blob: ?c.curl_blob, opts: Http.Opts) !*Client {
    var transfer_pool = std.heap.MemoryPool(Transfer).init(allocator);
    errdefer transfer_pool.deinit();

    var queue_node_pool = std.heap.MemoryPool(RequestQueue.Node).init(allocator);
    errdefer queue_node_pool.deinit();

    const client = try allocator.create(Client);
    errdefer allocator.destroy(client);

    const multi = c.curl_multi_init() orelse return error.FailedToInitializeMulti;
    errdefer _ = c.curl_multi_cleanup(multi);

    try errorMCheck(c.curl_multi_setopt(multi, c.CURLMOPT_MAX_HOST_CONNECTIONS, @as(c_long, opts.max_host_open)));

    var handles = try Handles.init(allocator, client, ca_blob, &opts);
    errdefer handles.deinit(allocator);

    var blocking = try Handle.init(client, ca_blob, &opts);
    errdefer blocking.deinit();

    client.* = .{
        .queue = .{},
        .active = 0,
        .multi = multi,
        .handles = handles,
        .blocking = blocking,
        .allocator = allocator,
        .http_proxy = opts.http_proxy,
        .transfer_pool = transfer_pool,
        .queue_node_pool = queue_node_pool,
        .arena = ArenaAllocator.init(allocator),
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
    self.arena.deinit();
    self.allocator.destroy(self);
}

pub fn abort(self: *Client) void {
    while (self.handles.in_use.first) |node| {
        var transfer = Transfer.fromEasy(node.data.conn.easy) catch |err| {
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
        if (handles.hasAvailable() == false) {
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
    var req_copy = req; // We need it mutable

    if (req_copy.id == null) { // If the ID has already been set that means the request was previously intercepted
        req_copy.id = self.next_request_id;
        self.next_request_id += 1;
        if (self.notification) |notification| {
            notification.dispatch(.http_request_start, &.{ .request = &req_copy });

            var wait_for_interception = false;
            notification.dispatch(.http_request_intercept, &.{ .request = &req_copy, .wait_for_interception = &wait_for_interception });
            if (wait_for_interception) return; // The user is send an invitation to intercept this request.
        }
    }

    if (self.handles.getFreeHandle()) |handle| {
        return self.makeRequest(handle, req_copy);
    }

    const node = try self.queue_node_pool.create();
    node.data = req_copy;
    self.queue.append(node);
}

// See ScriptManager.blockingGet
pub fn blockingRequest(self: *Client, req: Request) !void {
    return self.makeRequest(&self.blocking, req);
}

// Restrictive since it'll only work if there are no inflight requests. In some
// cases, the libcurl documentation is clear that changing settings while a
// connection is inflight is undefined. It doesn't say anything about CURLOPT_PROXY,
// but better to be safe than sorry.
// For now, this restriction is ok, since it's only called by CDP on
// createBrowserContext, at which point, if we do have an active connection,
// that's probably a bug (a previous abort failed?). But if we need to call this
// at any point in time, it could be worth digging into libcurl to see if this
// can be changed at any point in the easy's lifecycle.
pub fn changeProxy(self: *Client, proxy: [:0]const u8) !void {
    try self.ensureNoActiveConnection();

    for (self.handles.handles) |h| {
        try errorCheck(c.curl_easy_setopt(h.conn.easy, c.CURLOPT_PROXY, proxy.ptr));
    }
    try errorCheck(c.curl_easy_setopt(self.blocking.conn.easy, c.CURLOPT_PROXY, proxy.ptr));
}

// Same restriction as changeProxy. Should be ok since this is only called on
// BrowserContext deinit.
pub fn restoreOriginalProxy(self: *Client) !void {
    try self.ensureNoActiveConnection();

    const proxy = if (self.http_proxy) |p| p.ptr else null;
    for (self.handles.handles) |h| {
        try errorCheck(c.curl_easy_setopt(h.conn.easy, c.CURLOPT_PROXY, proxy));
    }
    try errorCheck(c.curl_easy_setopt(self.blocking.conn.easy, c.CURLOPT_PROXY, proxy));
}

fn makeRequest(self: *Client, handle: *Handle, req: Request) !void {
    const conn = handle.conn;
    const easy = conn.easy;

    // we need this for cookies
    const uri = std.Uri.parse(req.url) catch |err| {
        self.handles.release(handle);
        log.warn(.http, "invalid url", .{ .err = err, .url = req.url });
        return;
    };

    var header_list = req.headers;
    {
        errdefer self.handles.release(handle);
        try conn.setMethod(req.method);
        try conn.setURL(req.url);

        if (req.body) |b| {
            try conn.setBody(b);
        }

        // { // TODO move up to `fn request()`
        //     const aa = self.arena.allocator();
        //     var arr: std.ArrayListUnmanaged(u8) = .{};
        //     try req.cookie.forRequest(&uri, arr.writer(aa));

        //     if (arr.items.len > 0) {
        //         try arr.append(aa, 0); //null terminate

        //         // copies the value
        //         header_list = c.curl_slist_append(header_list, @ptrCast(arr.items.ptr));
        //         defer _ = self.arena.reset(.{ .retain_with_limit = 2048 });
        //     }
        // }

        try conn.secretHeaders(&header_list); // Add headers that must be hidden from intercepts
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, header_list.headers));
    }

    {
        errdefer self.handles.release(handle);

        const transfer = try self.transfer_pool.create();
        transfer.* = .{
            .id = 0,
            .uri = uri,
            .req = req,
            .ctx = req.ctx,
            .handle = handle,
            ._request_header_list = header_list.headers,
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

    var messages_count: c_int = 0;
    while (c.curl_multi_info_read(multi, &messages_count)) |msg_| {
        const msg: *c.CURLMsg = @ptrCast(msg_);
        // This is the only possible mesage type from CURL for now.
        std.debug.assert(msg.msg == c.CURLMSG_DONE);

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
}

fn endTransfer(self: *Client, transfer: *Transfer) void {
    const handle = transfer.handle;

    transfer.deinit();
    self.transfer_pool.destroy(transfer);

    errorMCheck(c.curl_multi_remove_handle(self.multi, handle.conn.easy)) catch |err| {
        log.fatal(.http, "Failed to remove handle", .{ .err = err });
    };

    self.handles.release(handle);
    self.active -= 1;
}

fn ensureNoActiveConnection(self: *const Client) !void {
    if (self.active > 0) {
        return error.InflightConnection;
    }
}

const Handles = struct {
    handles: []Handle,
    in_use: HandleList,
    available: HandleList,

    const HandleList = std.DoublyLinkedList(*Handle);

    // pointer to opts is not stable, don't hold a reference to it!
    fn init(allocator: Allocator, client: *Client, ca_blob: ?c.curl_blob, opts: *const Http.Opts) !Handles {
        const count = if (opts.max_concurrent == 0) 1 else opts.max_concurrent;

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

    fn hasAvailable(self: *const Handles) bool {
        return self.available.first != null;
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
        // client.blocking is a handle without a node, it doesn't exist in
        // either the in_use or available lists.
        const node = &(handle.node orelse return);

        self.in_use.remove(node);
        node.prev = null;
        node.next = null;
        self.available.append(node);
    }
};

// wraps a c.CURL (an easy handle)
const Handle = struct {
    client: *Client,
    conn: Http.Connection,
    node: ?Handles.HandleList.Node,

    // pointer to opts is not stable, don't hold a reference to it!
    fn init(client: *Client, ca_blob: ?c.curl_blob, opts: *const Http.Opts) !Handle {
        const conn = try Http.Connection.init(ca_blob, opts);
        errdefer conn.deinit();

        const easy = conn.easy;

        // callbacks
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HEADERDATA, easy));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HEADERFUNCTION, Transfer.headerCallback));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, easy));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, Transfer.dataCallback));

        return .{
            .conn = conn,
            .node = null,
            .client = client,
        };
    }

    fn deinit(self: *const Handle) void {
        self.conn.deinit();
    }
};

pub const RequestCookie = struct {
    is_http: bool,
    is_navigation: bool,
    origin: *const std.Uri,
    jar: *@import("../browser/storage/cookie.zig").Jar,

    fn forRequest(self: *const RequestCookie, uri: *const std.Uri, writer: anytype) !void {
        return self.jar.forRequest(uri, writer, .{
            .is_http = self.is_http,
            .is_navigation = self.is_navigation,
            .origin_uri = self.origin,
            .prefix = "Cookie: ",
        });
    }
};

pub const Request = struct {
    id: ?u64 = null,
    method: Method,
    url: [:0]const u8,
    headers: Headers,
    body: ?[]const u8 = null,
    cookie: RequestCookie,

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
    uri: std.Uri, // used for setting/getting the cookie

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

        var hdr = &transfer.response_header.?;

        if (hdr._content_type_len == 0) {
            const CONTENT_TYPE_LEN = "content-type:".len;
            if (header.len > CONTENT_TYPE_LEN) {
                if (std.ascii.eqlIgnoreCase(header[0..CONTENT_TYPE_LEN], "content-type:")) {
                    const value = std.mem.trimLeft(u8, header[CONTENT_TYPE_LEN..], " ");
                    const len = @min(value.len, hdr._content_type.len);
                    hdr._content_type_len = len;
                    @memcpy(hdr._content_type[0..len], value[0..len]);
                }
            }
        }

        {
            const SET_COOKIE_LEN = "set-cookie:".len;
            if (header.len > SET_COOKIE_LEN) {
                if (std.ascii.eqlIgnoreCase(header[0..SET_COOKIE_LEN], "set-cookie:")) {
                    const value = std.mem.trimLeft(u8, header[SET_COOKIE_LEN..], " ");
                    transfer.req.cookie.jar.populateFromResponse(&transfer.uri, value) catch |err| {
                        log.err(.http, "set cookie", .{ .err = err, .req = transfer });
                    };
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

    fn dataCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) callconv(.c) usize {
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

    // pub because Page.printWaitAnalysis uses it
    pub fn fromEasy(easy: *c.CURL) !*Transfer {
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
