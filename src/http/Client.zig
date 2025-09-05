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
const Notification = @import("../notification.zig").Notification;
const CookieJar = @import("../browser/storage/storage.zig").CookieJar;

const urlStitch = @import("../url.zig").stitch;

const c = Http.c;
const posix = std.posix;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const errorCheck = Http.errorCheck;
const errorMCheck = Http.errorMCheck;

const Method = Http.Method;

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

// Count of active requests
active: usize,

// Count of intercepted requests. This is to help deal with intercepted requests.
// The client doesn't track intercepted transfers. If a request is intercepted,
// the client forgets about it and requires the interceptor to continue or abort
// it. That works well, except if we only rely on active, we might think there's
// no more network activity when, with interecepted requests, there might be more
// in the future. (We really only need this to properly emit a 'networkIdle' and
// 'networkAlmostIdle' Page.lifecycleEvent in CDP).
intercepted: usize,

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
queue: TransferQueue,

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

// only needed for CDP which can change the proxy and then restore it. When
// restoring, this originally-configured value is what it goes to.
http_proxy: ?[:0]const u8 = null,

// libcurl can monitor arbitrary sockets. Currently, we ever [maybe] want to
// monitor the CDP client socket, so we've done the simplest thing possible
// by having this single optional field
extra_socket: ?posix.socket_t = null,

const TransferQueue = std.DoublyLinkedList;

pub fn init(allocator: Allocator, ca_blob: ?c.curl_blob, opts: Http.Opts) !*Client {
    var transfer_pool = std.heap.MemoryPool(Transfer).init(allocator);
    errdefer transfer_pool.deinit();

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
        .intercepted = 0,
        .multi = multi,
        .handles = handles,
        .blocking = blocking,
        .allocator = allocator,
        .http_proxy = opts.http_proxy,
        .transfer_pool = transfer_pool,
    };

    return client;
}

pub fn deinit(self: *Client) void {
    self.abort();
    self.blocking.deinit();
    self.handles.deinit(self.allocator);

    _ = c.curl_multi_cleanup(self.multi);

    self.transfer_pool.deinit();
    self.allocator.destroy(self);
}

pub fn abort(self: *Client) void {
    while (self.handles.in_use.first) |node| {
        const handle: *Handle = @fieldParentPtr("node", node);
        var transfer = Transfer.fromEasy(handle.conn.easy) catch |err| {
            log.err(.http, "get private info", .{ .err = err, .source = "abort" });
            continue;
        };
        transfer.abort();
    }
    std.debug.assert(self.active == 0);

    var n = self.queue.first;
    while (n) |node| {
        n = node.next;
        const transfer: *Transfer = @fieldParentPtr("_node", node);
        self.transfer_pool.destroy(transfer);
    }
    self.queue = .{};

    // Maybe a bit of overkill
    // We can remove some (all?) of these once we're confident its right.
    std.debug.assert(self.handles.in_use.first == null);
    std.debug.assert(self.handles.available.len() == self.handles.handles.len);
    if (builtin.mode == .Debug) {
        var running: c_int = undefined;
        std.debug.assert(c.curl_multi_perform(self.multi, &running) == c.CURLE_OK);
        std.debug.assert(running == 0);
    }
}

pub fn tick(self: *Client, timeout_ms: i32) !PerformStatus {
    while (true) {
        if (self.handles.hasAvailable() == false) {
            break;
        }
        const queue_node = self.queue.popFirst() orelse break;
        const transfer: *Transfer = @fieldParentPtr("_node", queue_node);

        // we know this exists, because we checked isEmpty() above
        const handle = self.handles.getFreeHandle().?;
        try self.makeRequest(handle, transfer);
    }
    return self.perform(timeout_ms);
}

pub fn request(self: *Client, req: Request) !void {
    const transfer = try self.makeTransfer(req);

    if (self.notification) |notification| {
        notification.dispatch(.http_request_start, &.{ .transfer = transfer });

        var wait_for_interception = false;
        notification.dispatch(.http_request_intercept, &.{ .transfer = transfer, .wait_for_interception = &wait_for_interception });
        if (wait_for_interception) {
            self.intercepted += 1;
            if (builtin.mode == .Debug) {
                transfer._intercepted = true;
            }
            // The user is send an invitation to intercept this request.
            return;
        }
    }

    return self.process(transfer);
}

// Above, request will not process if there's an interception request. In such
// cases, the interecptor is expected to call resume to continue the transfer
// or transfer.abort() to abort it.
fn process(self: *Client, transfer: *Transfer) !void {
    if (self.handles.getFreeHandle()) |handle| {
        return self.makeRequest(handle, transfer);
    }

    self.queue.append(&transfer._node);
}

// For an intercepted request
pub fn continueTransfer(self: *Client, transfer: *Transfer) !void {
    if (builtin.mode == .Debug) {
        std.debug.assert(transfer._intercepted);
    }
    self.intercepted -= 1;
    return self.process(transfer);
}

// For an intercepted request
pub fn abortTransfer(self: *Client, transfer: *Transfer) void {
    if (builtin.mode == .Debug) {
        std.debug.assert(transfer._intercepted);
    }
    self.intercepted -= 1;
    transfer.abort();
}

// For an intercepted request
pub fn fulfillTransfer(self: *Client, transfer: *Transfer, status: u16, headers: []const Http.Header, body: ?[]const u8) !void {
    if (builtin.mode == .Debug) {
        std.debug.assert(transfer._intercepted);
    }
    self.intercepted -= 1;
    return transfer.fulfill(status, headers, body);
}

// See ScriptManager.blockingGet
pub fn blockingRequest(self: *Client, req: Request) !void {
    const transfer = try self.makeTransfer(req);
    return self.makeRequest(&self.blocking, transfer);
}

fn makeTransfer(self: *Client, req: Request) !*Transfer {
    errdefer req.headers.deinit();

    // we need this for cookies
    const uri = std.Uri.parse(req.url) catch |err| {
        log.warn(.http, "invalid url", .{ .err = err, .url = req.url });
        return err;
    };

    const transfer = try self.transfer_pool.create();
    errdefer self.transfer_pool.destroy(transfer);

    const id = self.next_request_id + 1;
    self.next_request_id = id;
    transfer.* = .{
        .arena = ArenaAllocator.init(self.allocator),
        .id = id,
        .uri = uri,
        .req = req,
        .ctx = req.ctx,
        .client = self,
    };
    return transfer;
}

fn requestFailed(self: *Client, transfer: *Transfer, err: anyerror) void {
    // this shouldn't happen, we'll crash in debug mode. But in release, we'll
    // just noop this state.
    std.debug.assert(transfer._notified_fail == false);
    if (transfer._notified_fail) {
        return;
    }

    transfer._notified_fail = true;

    if (self.notification) |notification| {
        notification.dispatch(.http_request_fail, &.{
            .transfer = transfer,
            .err = err,
        });
    }

    transfer.req.error_callback(transfer.ctx, err);
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

    for (self.handles.handles) |*h| {
        try errorCheck(c.curl_easy_setopt(h.conn.easy, c.CURLOPT_PROXY, proxy.ptr));
    }
    try errorCheck(c.curl_easy_setopt(self.blocking.conn.easy, c.CURLOPT_PROXY, proxy.ptr));
}

// Same restriction as changeProxy. Should be ok since this is only called on
// BrowserContext deinit.
pub fn restoreOriginalProxy(self: *Client) !void {
    try self.ensureNoActiveConnection();

    const proxy = if (self.http_proxy) |p| p.ptr else null;
    for (self.handles.handles) |*h| {
        try errorCheck(c.curl_easy_setopt(h.conn.easy, c.CURLOPT_PROXY, proxy));
    }
    try errorCheck(c.curl_easy_setopt(self.blocking.conn.easy, c.CURLOPT_PROXY, proxy));
}

fn makeRequest(self: *Client, handle: *Handle, transfer: *Transfer) !void {
    const conn = handle.conn;
    const easy = conn.easy;
    const req = &transfer.req;

    {
        transfer._handle = handle;
        errdefer transfer.deinit();

        try conn.setURL(req.url);
        try conn.setMethod(req.method);
        if (req.body) |b| {
            try conn.setBody(b);
        } else {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPGET, @as(c_long, 1)));
        }

        var header_list = req.headers;
        try conn.secretHeaders(&header_list); // Add headers that must be hidden from intercepts
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, header_list.headers));

        // Add cookies.
        if (header_list.cookies) |cookies| {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_COOKIE, cookies));
        }

        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PRIVATE, transfer));

        // add credentials
        if (req.credentials) |creds| {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_PROXYUSERPWD, creds.ptr));
        }
    }

    // Once soon as this is called, our "perform" loop is responsible for
    // cleaning things up. That's why the above code is in a block. If anything
    // fails BEFORE `curl_multi_add_handle` suceeds, the we still need to do
    // cleanup. But if things fail after `curl_multi_add_handle`, we expect
    // perfom to pickup the failure and cleanup.
    try errorMCheck(c.curl_multi_add_handle(self.multi, easy));

    if (req.start_callback) |cb| {
        cb(transfer) catch |err| {
            try errorMCheck(c.curl_multi_remove_handle(self.multi, easy));
            transfer.deinit();
            return err;
        };
    }

    self.active += 1;
    _ = try self.perform(0);
}

pub const PerformStatus = enum {
    extra_socket,
    normal,
};

fn perform(self: *Client, timeout_ms: c_int) !PerformStatus {
    const multi = self.multi;
    var running: c_int = undefined;
    try errorMCheck(c.curl_multi_perform(multi, &running));

    // We're potentially going to block for a while until we get data. Process
    // whatever messages we have waiting ahead of time.
    try self.processMessages();

    var status = PerformStatus.normal;
    if (self.extra_socket) |s| {
        var wait_fd = c.curl_waitfd{
            .fd = s,
            .events = c.CURL_WAIT_POLLIN,
            .revents = 0,
        };
        try errorMCheck(c.curl_multi_poll(multi, &wait_fd, 1, timeout_ms, null));
        if (wait_fd.revents != 0) {
            // the extra socket we passed in is ready, let's signal our caller
            status = .extra_socket;
        }
    } else if (running > 0) {
        try errorMCheck(c.curl_multi_poll(multi, null, 0, timeout_ms, null));
    }

    try self.processMessages();
    return status;
}

fn processMessages(self: *Client) !void {
    const multi = self.multi;
    var messages_count: c_int = 0;
    while (c.curl_multi_info_read(multi, &messages_count)) |msg_| {
        const msg: *c.CURLMsg = @ptrCast(msg_);
        // This is the only possible message type from CURL for now.
        std.debug.assert(msg.msg == c.CURLMSG_DONE);

        const easy = msg.easy_handle.?;
        const transfer = try Transfer.fromEasy(easy);

        // In case of auth challenge
        if (transfer._auth_challenge != null and transfer._tries < 10) { // TODO give a way to configure the number of auth retries.
            if (transfer.client.notification) |notification| {
                var wait_for_interception = false;
                notification.dispatch(.http_request_auth_required, &.{ .transfer = transfer, .wait_for_interception = &wait_for_interception });
                if (wait_for_interception) {
                    // the request is put on hold to be intercepted.
                    // In this case we ignore callbacks for now.
                    // Note: we don't deinit transfer on purpose: we want to keep
                    // using it for the following request.
                    self.endTransfer(transfer);
                    continue;
                }
            }
        }

        // release it ASAP so that it's available; some done_callbacks
        // will load more resources.
        self.endTransfer(transfer);

        defer transfer.deinit();

        if (errorCheck(msg.data.result)) {
            // In case of request w/o data, we need to call the header done
            // callback now.
            if (!transfer._header_done_called) {
                transfer.headerDoneCallback(easy) catch |err| {
                    log.err(.http, "header_done_callback", .{ .err = err });
                    self.requestFailed(transfer, err);
                    continue;
                };
            }
            transfer.req.done_callback(transfer.ctx) catch |err| {
                // transfer isn't valid at this point, don't use it.
                log.err(.http, "done_callback", .{ .err = err });
                self.requestFailed(transfer, err);
                continue;
            };

            if (transfer.client.notification) |notification| {
                notification.dispatch(.http_request_done, &.{
                    .transfer = transfer,
                });
            }
        } else |err| {
            self.requestFailed(transfer, err);
        }
    }
}

fn endTransfer(self: *Client, transfer: *Transfer) void {
    const handle = transfer._handle.?;

    errorMCheck(c.curl_multi_remove_handle(self.multi, handle.conn.easy)) catch |err| {
        log.fatal(.http, "Failed to remove handle", .{ .err = err });
    };

    self.handles.release(self, handle);
    transfer._handle = null;
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

    const HandleList = std.DoublyLinkedList;

    // pointer to opts is not stable, don't hold a reference to it!
    fn init(allocator: Allocator, client: *Client, ca_blob: ?c.curl_blob, opts: *const Http.Opts) !Handles {
        const count = if (opts.max_concurrent == 0) 1 else opts.max_concurrent;

        const handles = try allocator.alloc(Handle, count);
        errdefer allocator.free(handles);

        var available: HandleList = .{};
        for (0..count) |i| {
            handles[i] = try Handle.init(client, ca_blob, opts);
            available.append(&handles[i].node);
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
            return @as(*Handle, @fieldParentPtr("node", node));
        }
        return null;
    }

    fn release(self: *Handles, client: *Client, handle: *Handle) void {
        if (handle == &client.blocking) {
            // the handle we've reserved for blocking request doesn't participate
            // int he in_use/available pools
            return;
        }

        var node = &handle.node;
        self.in_use.remove(node);
        node.prev = null;
        node.next = null;
        self.available.append(node);
    }
};

// wraps a c.CURL (an easy handle)
pub const Handle = struct {
    client: *Client,
    conn: Http.Connection,
    node: Handles.HandleList.Node,

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
            .node = .{},
            .conn = conn,
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

    pub fn headersForRequest(self: *const RequestCookie, temp: Allocator, url: [:0]const u8, headers: *Http.Headers) !void {
        const uri = std.Uri.parse(url) catch |err| {
            log.warn(.http, "invalid url", .{ .err = err, .url = url });
            return error.InvalidUrl;
        };

        var arr: std.ArrayListUnmanaged(u8) = .{};
        try self.jar.forRequest(&uri, arr.writer(temp), .{
            .is_http = self.is_http,
            .is_navigation = self.is_navigation,
            .origin_uri = self.origin,
        });

        if (arr.items.len > 0) {
            try arr.append(temp, 0); //null terminate
            headers.cookies = @ptrCast(arr.items.ptr);
        }
    }
};

pub const Request = struct {
    method: Method,
    url: [:0]const u8,
    headers: Http.Headers,
    body: ?[]const u8 = null,
    cookie_jar: *CookieJar,
    resource_type: ResourceType,
    credentials: ?[:0]const u8 = null,

    // arbitrary data that can be associated with this request
    ctx: *anyopaque = undefined,

    start_callback: ?*const fn (transfer: *Transfer) anyerror!void = null,
    header_callback: *const fn (transfer: *Transfer) anyerror!void,
    data_callback: *const fn (transfer: *Transfer, data: []const u8) anyerror!void,
    done_callback: *const fn (ctx: *anyopaque) anyerror!void,
    error_callback: *const fn (ctx: *anyopaque, err: anyerror) void,

    const ResourceType = enum {
        document,
        xhr,
        script,
    };
};

pub const AuthChallenge = struct {
    status: u16,
    source: enum { server, proxy },
    scheme: enum { basic, digest },
    realm: []const u8,

    pub fn parse(status: u16, header: []const u8) !AuthChallenge {
        var ac: AuthChallenge = .{
            .status = status,
            .source = undefined,
            .realm = "TODO", // TODO parser and set realm
            .scheme = undefined,
        };

        const sep = std.mem.indexOfPos(u8, header, 0, ": ") orelse return error.InvalidHeader;
        const hname = header[0..sep];
        const hvalue = header[sep + 2 ..];

        if (std.ascii.eqlIgnoreCase("WWW-Authenticate", hname)) {
            ac.source = .server;
        } else if (std.ascii.eqlIgnoreCase("Proxy-Authenticate", hname)) {
            ac.source = .proxy;
        } else {
            return error.InvalidAuthChallenge;
        }

        const pos = std.mem.indexOfPos(u8, std.mem.trim(u8, hvalue, std.ascii.whitespace[0..]), 0, " ") orelse hvalue.len;
        const _scheme = hvalue[0..pos];
        if (std.ascii.eqlIgnoreCase(_scheme, "basic")) {
            ac.scheme = .basic;
        } else if (std.ascii.eqlIgnoreCase(_scheme, "digest")) {
            ac.scheme = .digest;
        } else {
            return error.UnknownAuthChallengeScheme;
        }

        return ac;
    }
};

pub const Transfer = struct {
    arena: ArenaAllocator,
    id: usize = 0,
    req: Request,
    uri: std.Uri, // used for setting/getting the cookie
    ctx: *anyopaque, // copied from req.ctx to make it easier for callback handlers
    client: *Client,
    // total bytes received in the response, including the response status line,
    // the headers, and the [encoded] body.
    bytes_received: usize = 0,

    // We'll store the response header here
    response_header: ?ResponseHeader = null,

    // track if the header callbacks done have been called.
    _header_done_called: bool = false,

    _notified_fail: bool = false,

    _handle: ?*Handle = null,

    _redirecting: bool = false,
    _auth_challenge: ?AuthChallenge = null,

    // number of times the transfer has been tried.
    // incremented by reset func.
    _tries: u8 = 0,

    // for when a Transfer is queued in the client.queue
    _node: std.DoublyLinkedList.Node = .{},
    _intercepted: if (builtin.mode == .Debug) bool else void = if (builtin.mode == .Debug) false else {},

    pub fn reset(self: *Transfer) void {
        self._redirecting = false;
        self._auth_challenge = null;
        self._notified_fail = false;
        self._header_done_called = false;
        self.response_header = null;
        self.bytes_received = 0;

        self._tries += 1;
    }

    fn deinit(self: *Transfer) void {
        self.req.headers.deinit();
        if (self._handle) |handle| {
            self.client.handles.release(self.client, handle);
        }
        self.arena.deinit();
        self.client.transfer_pool.destroy(self);
    }

    fn buildResponseHeader(self: *Transfer, easy: *c.CURL) !void {
        std.debug.assert(self.response_header == null);

        var url: [*c]u8 = undefined;
        try errorCheck(c.curl_easy_getinfo(easy, c.CURLINFO_EFFECTIVE_URL, &url));

        var status: c_long = undefined;
        if (self._auth_challenge) |_| {
            status = 407;
        } else {
            try errorCheck(c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status));
        }

        self.response_header = .{
            .url = url,
            .status = @intCast(status),
        };

        if (getResponseHeader(easy, "content-type", 0)) |ct| {
            var hdr = &self.response_header.?;
            const value = ct.value;
            const len = @min(value.len, ResponseHeader.MAX_CONTENT_TYPE_LEN);
            hdr._content_type_len = len;
            @memcpy(hdr._content_type[0..len], value[0..len]);
        }
    }

    pub fn format(self: *Transfer, writer: *std.Io.Writer) !void {
        const req = self.req;
        return writer.print("{s} {s}", .{ @tagName(req.method), req.url });
    }

    pub fn addHeader(self: *Transfer, value: [:0]const u8) !void {
        self._request_header_list = c.curl_slist_append(self._request_header_list, value);
    }

    pub fn updateURL(self: *Transfer, url: [:0]const u8) !void {
        // for cookies
        self.uri = try std.Uri.parse(url);

        // for the request itself
        self.req.url = url;
    }

    pub fn updateCredentials(self: *Transfer, userpwd: [:0]const u8) void {
        self.req.credentials = userpwd;
    }

    pub fn replaceRequestHeaders(self: *Transfer, allocator: Allocator, headers: []const Http.Header) !void {
        self.req.headers.deinit();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var new_headers = try Http.Headers.init();
        for (headers) |hdr| {
            // safe to re-use this buffer, because Headers.add because curl copies
            // the value we pass into curl_slist_append.
            defer buf.clearRetainingCapacity();
            try std.fmt.format(buf.writer(allocator), "{s}: {s}", .{ hdr.name, hdr.value });
            try buf.append(allocator, 0); // null terminated
            try new_headers.add(buf.items[0 .. buf.items.len - 1 :0]);
        }
        self.req.headers = new_headers;
    }

    pub fn abort(self: *Transfer) void {
        self.client.requestFailed(self, error.Abort);
        if (self._handle != null) {
            self.client.endTransfer(self);
        }
        self.deinit();
    }

    // abortAuthChallenge is called when an auth chanllenge interception is
    // abort. We don't call self.client.endTransfer here b/c it has been done
    // before interception process.
    pub fn abortAuthChallenge(self: *Transfer) void {
        self.client.requestFailed(self, error.AbortAuthChallenge);
        self.deinit();
    }

    // redirectionCookies manages cookies during redirections handled by Curl.
    // It sets the cookies from the current response to the cookie jar.
    // It also immediately sets cookies for the following request.
    fn redirectionCookies(transfer: *Transfer, easy: *c.CURL) !void {
        const req = &transfer.req;
        const arena = transfer.arena.allocator();

        // retrieve cookies from the redirect's response.
        var i: usize = 0;
        while (true) {
            const ct = getResponseHeader(easy, "set-cookie", i);
            if (ct == null) break;
            try req.cookie_jar.populateFromResponse(&transfer.uri, ct.?.value);
            i += 1;
            if (i >= ct.?.amount) break;
        }

        // set cookies for the following redirection's request.
        const hlocation = getResponseHeader(easy, "location", 0);
        if (hlocation == null) {
            return error.LocationNotFound;
        }

        var baseurl: [*c]u8 = undefined;
        try errorCheck(c.curl_easy_getinfo(easy, c.CURLINFO_EFFECTIVE_URL, &baseurl));

        const url = try urlStitch(arena, hlocation.?.value, std.mem.span(baseurl), .{});
        const uri = try std.Uri.parse(url);
        transfer.uri = uri;

        var cookies: std.ArrayListUnmanaged(u8) = .{};
        try req.cookie_jar.forRequest(&uri, cookies.writer(arena), .{
            .is_http = true,
            .origin_uri = &transfer.uri,
            // used to enforce samesite cookie rules
            .is_navigation = req.resource_type == .document,
        });
        try cookies.append(arena, 0); //null terminate
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_COOKIE, @as([*c]const u8, @ptrCast(cookies.items.ptr))));
    }

    // headerDoneCallback is called once the headers have been read.
    // It can be called either on dataCallback or once the request for those
    // w/o body.
    fn headerDoneCallback(transfer: *Transfer, easy: *c.CURL) !void {
        std.debug.assert(transfer._header_done_called == false);
        defer transfer._header_done_called = true;

        try transfer.buildResponseHeader(easy);

        if (getResponseHeader(easy, "content-type", 0)) |ct| {
            var hdr = &transfer.response_header.?;
            const value = ct.value;
            const len = @min(value.len, ResponseHeader.MAX_CONTENT_TYPE_LEN);
            hdr._content_type_len = len;
            @memcpy(hdr._content_type[0..len], value[0..len]);
        }

        var i: usize = 0;
        while (true) {
            const ct = getResponseHeader(easy, "set-cookie", i);
            if (ct == null) break;
            transfer.req.cookie_jar.populateFromResponse(&transfer.uri, ct.?.value) catch |err| {
                log.err(.http, "set cookie", .{ .err = err, .req = transfer });
                return err;
            };
            i += 1;
            if (i >= ct.?.amount) break;
        }

        transfer.req.header_callback(transfer) catch |err| {
            log.err(.http, "header_callback", .{ .err = err, .req = transfer });
            return err;
        };

        if (transfer.client.notification) |notification| {
            notification.dispatch(.http_response_header_done, &.{
                .transfer = transfer,
            });
        }
    }

    // headerCallback is called by curl on each request's header line read.
    fn headerCallback(buffer: [*]const u8, header_count: usize, buf_len: usize, data: *anyopaque) callconv(.c) usize {
        // libcurl should only ever emit 1 header at a time
        std.debug.assert(header_count == 1);

        const easy: *c.CURL = @ptrCast(@alignCast(data));
        var transfer = fromEasy(easy) catch |err| {
            log.err(.http, "get private info", .{ .err = err, .source = "header callback" });
            return 0;
        };

        std.debug.assert(std.mem.endsWith(u8, buffer[0..buf_len], "\r\n"));

        const header = buffer[0 .. buf_len - 2];

        // We need to parse the first line headers for each request b/c curl's
        // CURLINFO_RESPONSE_CODE returns the status code of the final request.
        // If a redirection or a proxy's CONNECT forbidden happens, we won't
        // get this intermediary status code.
        if (std.mem.startsWith(u8, header, "HTTP/")) {
            // Is it the first header line.
            if (buf_len < 13) {
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

            if (status == 401 or status == 407) {
                // The auth challenge must be parsed from a following
                // WWW-Authenticate or Proxy-Authenticate header.
                transfer._auth_challenge = .{
                    .status = status,
                    .source = undefined,
                    .scheme = undefined,
                    .realm = undefined,
                };
                return buf_len;
            }
            transfer._auth_challenge = null;

            transfer.bytes_received = buf_len;
            return buf_len;
        }

        if (transfer._redirecting == false and transfer._auth_challenge != null) {
            transfer.bytes_received += buf_len;
        }

        if (buf_len != 2) {
            if (transfer._auth_challenge != null) {
                // try to parse auth challenge.
                if (std.ascii.startsWithIgnoreCase(header, "WWW-Authenticate") or
                    std.ascii.startsWithIgnoreCase(header, "Proxy-Authenticate"))
                {
                    const ac = AuthChallenge.parse(
                        transfer._auth_challenge.?.status,
                        header,
                    ) catch |err| {
                        // We can't parse the auth challenge
                        log.err(.http, "parse auth challenge", .{ .err = err, .header = header });
                        // Should we cancel the request? I don't think so.
                        return buf_len;
                    };
                    transfer._auth_challenge = ac;
                }
            }
            return buf_len;
        }

        // Starting here, we get the last header line.

        if (transfer._redirecting) {
            // parse and set cookies for the redirection.
            redirectionCookies(transfer, easy) catch |err| {
                log.debug(.http, "redirection cookies", .{ .err = err });
                return 0;
            };
            return buf_len;
        }

        return buf_len;
    }

    fn dataCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) callconv(.c) usize {
        // libcurl should only ever emit 1 chunk at a time
        std.debug.assert(chunk_count == 1);

        const easy: *c.CURL = @ptrCast(@alignCast(data));
        var transfer = fromEasy(easy) catch |err| {
            log.err(.http, "get private info", .{ .err = err, .source = "body callback" });
            return c.CURL_WRITEFUNC_ERROR;
        };

        if (transfer._redirecting or transfer._auth_challenge != null) {
            return chunk_len;
        }

        if (!transfer._header_done_called) {
            transfer.headerDoneCallback(easy) catch |err| {
                log.err(.http, "header_done_callback", .{ .err = err, .req = transfer });
                return c.CURL_WRITEFUNC_ERROR;
            };
        }

        transfer.bytes_received += chunk_len;
        const chunk = buffer[0..chunk_len];
        transfer.req.data_callback(transfer, chunk) catch |err| {
            log.err(.http, "data_callback", .{ .err = err, .req = transfer });
            return c.CURL_WRITEFUNC_ERROR;
        };

        if (transfer.client.notification) |notification| {
            notification.dispatch(.http_response_data, &.{
                .data = chunk,
                .transfer = transfer,
            });
        }

        return chunk_len;
    }

    pub fn responseHeaderIterator(self: *Transfer) HeaderIterator {
        if (self._handle) |handle| {
            // If we have a handle, than this is a real curl request and we
            // iterate through the header that curl maintains.
            return .{ .curl = .{ .easy = handle.conn.easy } };
        }
        // If there's no handle, it either means this is being called before
        // the request is even being made (which would be a bug in the code)
        // or when a response was injected via transfer.fulfill. The injected
        // header should be iterated, since there is no handle/easy.
        return .{ .list = .{ .list = self.response_header.?._injected_headers } };
    }

    // pub because Page.printWaitAnalysis uses it
    pub fn fromEasy(easy: *c.CURL) !*Transfer {
        var private: *anyopaque = undefined;
        try errorCheck(c.curl_easy_getinfo(easy, c.CURLINFO_PRIVATE, &private));
        return @ptrCast(@alignCast(private));
    }

    pub fn fulfill(transfer: *Transfer, status: u16, headers: []const Http.Header, body: ?[]const u8) !void {
        if (transfer._handle != null) {
            // should never happen, should have been intercepted/paused, and then
            // either continued, aborted and fulfilled once.
            @branchHint(.unlikely);
            return error.RequestInProgress;
        }

        transfer._fulfill(status, headers, body) catch |err| {
            transfer.req.error_callback(transfer.req.ctx, err);
            return err;
        };
    }

    fn _fulfill(transfer: *Transfer, status: u16, headers: []const Http.Header, body: ?[]const u8) !void {
        const req = &transfer.req;
        if (req.start_callback) |cb| {
            try cb(transfer);
        }

        transfer.response_header = .{
            .status = status,
            .url = req.url,
            ._injected_headers = headers,
        };
        for (headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-type")) {
                const len = @min(hdr.value.len, ResponseHeader.MAX_CONTENT_TYPE_LEN);
                @memcpy(transfer.response_header.?._content_type[0..len], hdr.value[0..len]);
                transfer.response_header.?._content_type_len = len;
                break;
            }
        }

        try req.header_callback(transfer);

        if (body) |b| {
            try req.data_callback(transfer, b);
        }

        try req.done_callback(req.ctx);
    }

    // This function should be called during the dataCallback. Calling it after
    // such as in the doneCallback is guaranteed to return null.
    pub fn getContentLength(self: *const Transfer) ?u32 {
        const cl = self.getContentLengthRawValue() orelse return null;
        return std.fmt.parseInt(u32, cl, 10) catch null;
    }

    fn getContentLengthRawValue(self: *const Transfer) ?[]const u8 {
        if (self._handle) |handle| {
            // If we have a handle, than this is a normal request. We can get the
            // header value from the easy handle.
            const cl = getResponseHeader(handle.conn.easy, "content-length", 0) orelse return null;
            return cl.value;
        }

        // If we have no handle, then maybe this is being called after the
        // doneCallback. OR, maybe this is a "fulfilled" request. Let's check
        // the injected headers (if we have any).

        const rh = self.response_header orelse return null;
        for (rh._injected_headers) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-length")) {
                return hdr.value;
            }
        }

        return null;
    }
};

pub const ResponseHeader = struct {
    const MAX_CONTENT_TYPE_LEN = 64;

    status: u16,
    url: [*c]const u8,
    _content_type_len: usize = 0,
    _content_type: [MAX_CONTENT_TYPE_LEN]u8 = undefined,
    // this is normally an empty list, but if the response is being injected
    // than it'll be populated. It isn't meant to be used directly, but should
    // be used through the transfer.responseHeaderIterator() which abstracts
    // whether the headers are from a live curl easy handle, or injected.
    _injected_headers: []const Http.Header = &.{},

    pub fn contentType(self: *ResponseHeader) ?[]u8 {
        if (self._content_type_len == 0) {
            return null;
        }
        return self._content_type[0..self._content_type_len];
    }
};

// In normal cases, the header iterator comes from the curl linked list.
// But it's also possible to inject a response, via `transfer.fulfill`. In that
// case, the resposne headers are a list, []const Http.Header.
// This union, is an iterator that exposes the same API for either case.
const HeaderIterator = union(enum) {
    curl: CurlHeaderIterator,
    list: ListHeaderIterator,

    pub fn next(self: *HeaderIterator) ?Http.Header {
        switch (self.*) {
            inline else => |*it| return it.next(),
        }
    }

    const CurlHeaderIterator = struct {
        easy: *c.CURL,
        prev: ?*c.curl_header = null,

        pub fn next(self: *CurlHeaderIterator) ?Http.Header {
            const h = c.curl_easy_nextheader(self.easy, c.CURLH_HEADER, -1, self.prev) orelse return null;
            self.prev = h;

            const header = h.*;
            return .{
                .name = std.mem.span(header.name),
                .value = std.mem.span(header.value),
            };
        }
    };

    const ListHeaderIterator = struct {
        index: usize = 0,
        list: []const Http.Header,

        pub fn next(self: *ListHeaderIterator) ?Http.Header {
            const index = self.index;
            if (index == self.list.len) {
                return null;
            }
            self.index = index + 1;
            return self.list[index];
        }
    };
};

const CurlHeaderValue = struct {
    value: []const u8,
    amount: usize,
};

fn getResponseHeader(easy: *c.CURL, name: [:0]const u8, index: usize) ?CurlHeaderValue {
    var hdr: [*c]c.curl_header = null;
    const result = c.curl_easy_header(easy, name, index, c.CURLH_HEADER, -1, &hdr);
    if (result == c.CURLE_OK) {
        return .{
            .amount = hdr.*.amount,
            .value = std.mem.span(hdr.*.value),
        };
    }

    if (result == c.CURLE_FAILED_INIT) {
        // seems to be what it returns if the header isn't found
        return null;
    }
    log.err(.http, "get response header", .{
        .name = name,
        .err = @import("errors.zig").fromCode(result),
    });
    return null;
}
