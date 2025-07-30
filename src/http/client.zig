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

pub const c = @cImport({
    @cInclude("curl/curl.h");
});

const ENABLE_DEBUG = false;

const std = @import("std");
const log = @import("../log.zig");
const builtin = @import("builtin");
const errors = @import("errors.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub fn init() !void {
    try errorCheck(c.curl_global_init(c.CURL_GLOBAL_SSL));
    if (comptime ENABLE_DEBUG) {
        std.debug.print("curl version: {s}\n\n", .{c.curl_version()});
    }
}

pub fn deinit() void {
    c.curl_global_cleanup();
}

pub const Client = struct {
    active: usize,
    multi: *c.CURLM,
    handles: Handles,
    queue: RequestQueue,
    allocator: Allocator,
    transfer_pool: std.heap.MemoryPool(Transfer),
    queue_node_pool: std.heap.MemoryPool(RequestQueue.Node),
    //@newhttp
    http_proxy: ?std.Uri = null,

    const RequestQueue = std.DoublyLinkedList(Request);

    const Opts = struct {
        timeout_ms: u31 = 0,
        max_redirects: u8 = 10,
        connect_timeout_ms: u31 = 5000,
        max_concurrent_transfers: u8 = 5,
    };
    pub fn init(allocator: Allocator, opts: Opts) !*Client {
        var transfer_pool = std.heap.MemoryPool(Transfer).init(allocator);
        errdefer transfer_pool.deinit();

        var queue_node_pool = std.heap.MemoryPool(RequestQueue.Node).init(allocator);
        errdefer queue_node_pool.deinit();

        const client = try allocator.create(Client);
        errdefer allocator.destroy(client);

        var handles = try Handles.init(allocator, client, opts);
        errdefer handles.deinit(allocator);

        const multi = c.curl_multi_init() orelse return error.FailedToInitializeMulti;
        errdefer _ = c.curl_multi_cleanup(multi);

        client.* = .{
            .queue = .{},
            .active = 0,
            .multi = multi,
            .handles = handles,
            .allocator = allocator,
            .transfer_pool = transfer_pool,
            .queue_node_pool = queue_node_pool,
        };
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.handles.deinit(self.allocator);
        _ = c.curl_multi_cleanup(self.multi);

        self.transfer_pool.deinit();
        self.queue_node_pool.deinit();
        self.allocator.destroy(self);
    }

    pub fn tick(self: *Client, timeout_ms: usize) !void {
        var handles = &self.handles.available;
        while (true) {
            if (handles.first == null) {
                break;
            }
            const queue_node = self.queue.popFirst() orelse break;

            defer self.queue_node_pool.destroy(queue_node);

            const handle = handles.popFirst().?.data;
            try self.makeRequest(handle, queue_node.data);
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

    fn makeRequest(self: *Client, handle: *Handle, req: Request) !void {
        const easy = handle.easy;

        const header_list = blk: {
            errdefer self.handles.release(handle);
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_URL, req.url.ptr));
            switch (req.method) {
                .GET => try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPGET, @as(c_long, 1))),
                .POST => try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HTTPPOST, @as(c_long, 1))),
                .PUT => try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CUSTOMREQUEST, "put")),
                .DELETE => try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CUSTOMREQUEST, "delete")),
                .HEAD => try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CUSTOMREQUEST, "head")),
                .OPTIONS => try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CUSTOMREQUEST, "options")),
            }

            const header_list = c.curl_slist_append(null, "User-Agent: Lightpanda/1.0");
            errdefer c.curl_slist_free_all(header_list);

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

        if (timeout_ms > 0) {
            try errorMCheck(c.curl_multi_poll(multi, null, 0, timeout_ms, null));
        }

        while (true) {
            var remaining: c_int = undefined;
            const msg: *c.CURLMsg = c.curl_multi_info_read(multi, &remaining) orelse break;
            if (msg.msg == c.CURLMSG_DONE) {
                self.active -= 1;
                const easy = msg.easy_handle.?;
                const transfer = try Transfer.fromEasy(easy);
                defer {
                    self.handles.release(transfer.handle);
                    transfer.deinit();
                    self.transfer_pool.destroy(transfer);
                }

                if (errorCheck(msg.data.result)) {
                    transfer.req.done_callback(transfer) catch |err| transfer.onError(err);
                } else |err| {
                    transfer.onError(err);
                }

                try errorMCheck(c.curl_multi_remove_handle(multi, easy));
            }

            if (remaining == 0) {
                break;
            }
        }
    }
};

const Handles = struct {
    handles: []Handle,
    available: FreeList,
    cert_arena: ArenaAllocator,

    const FreeList = std.DoublyLinkedList(*Handle);

    fn init(allocator: Allocator, client: *Client, opts: Client.Opts) !Handles {
        const count = opts.max_concurrent_transfers;
        std.debug.assert(count > 0);

        const handles = try allocator.alloc(Handle, count);
        errdefer allocator.free(handles);

        var initialized_count: usize = 0;
        errdefer cleanup(allocator, handles[0..initialized_count]);

        var cert_arena = ArenaAllocator.init(allocator);
        errdefer cert_arena.deinit();
        const ca_blob = try @import("ca_certs.zig").load(allocator, cert_arena.allocator());

        var available: FreeList = .{};
        for (0..count) |i| {
            const node = try allocator.create(FreeList.Node);
            errdefer allocator.destroy(node);

            handles[i] = .{
                .node = node,
                .client = client,
                .easy = undefined,
            };
            try handles[i].init(ca_blob, opts);
            initialized_count += 1;

            node.data = &handles[i];
            available.append(node);
         }

         return .{
            .handles = handles,
            .available = available,
            .cert_arena = cert_arena,
         };
    }

    fn deinit(self: *Handles, allocator: Allocator) void {
        cleanup(allocator, self.handles);
        allocator.free(self.handles);
        self.cert_arena.deinit();
    }

    // Done line this so that cleanup can be called from init with a partial state
    fn cleanup(allocator: Allocator, handles: []Handle) void {
        for (handles) |*h| {
            _ = c.curl_easy_cleanup(h.easy);
            allocator.destroy(h.node);
        }
    }

    fn getFreeHandle(self: *Handles) ?*Handle {
        if (self.available.popFirst()) |handle| {
            return handle.data;
        }
        return null;
    }

    fn release(self: *Handles, handle: *Handle) void {
        self.available.append(handle.node);
    }
};

// wraps a c.CURL (an easy handle), mostly to make it easier to keep a
// handle_pool and error_buffer associated with each easy handle
const Handle = struct {
    easy: *c.CURL,
    client: *Client,
    node: *Handles.FreeList.Node,
    error_buffer: [c.CURL_ERROR_SIZE:0]u8 = undefined,

    // Is called by Handles when already partially initialized. Done like this
    // so that we have a stable pointer to error_buffer.
    fn init(self: *Handle, ca_blob: c.curl_blob, opts: Client.Opts) !void {
        const easy = c.curl_easy_init() orelse return error.FailedToInitializeEasy;
        errdefer _ = c.curl_easy_cleanup(easy);

        self.easy = easy;

        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_ERRORBUFFER, &self.error_buffer));

        // timeouts
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(opts.timeout_ms))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, @intCast(opts.connect_timeout_ms))));

        // redirect behavior
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, @intCast(opts.max_redirects))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 2)));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_REDIR_PROTOCOLS_STR, "HTTP,HTTPS")); // remove FTP and FTPS from the default

        // callbacks
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HEADERDATA, self));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_HEADERFUNCTION, Transfer.headerCallback));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, self));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, Transfer.bodyCallback));

        // tls
        // try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 0)));
        // try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 0)));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_CAINFO_BLOB, ca_blob));

        // debug
        if (comptime ENABLE_DEBUG) {
            try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_VERBOSE, @as(c_long, 1)));
        }
    }
};

pub const Request = struct {
    method: Method,
    url: [:0]const u8,
    // arbitrary data that can be associated with this request
    ctx: *anyopaque = undefined,

    start_callback: ?*const fn(req: *Transfer) anyerror!void = null,
    header_callback: ?*const fn (req: *Transfer, header: []const u8) anyerror!void = null ,
    header_done_callback: *const fn (req: *Transfer) anyerror!void,
    data_callback: *const fn(req: *Transfer, data: []const u8) anyerror!void,
    done_callback: *const fn(req: *Transfer) anyerror!void,
    error_callback: *const fn(req: *Transfer, err: anyerror) void,
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
        return writer.print("[{d}] {s} {s}", .{self.id, @tagName(req.method), req.url});
    }

    fn onError(self: *Transfer, err: anyerror) void {
        self.req.error_callback(self, err);
    }

    pub fn setBody(self: *Transfer, body: []const u8) !void {
        const easy = self.handle.easy;
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(body.len))));
        try errorCheck(c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, body.ptr));
    }

    pub fn addHeader(self: *Transfer, value: [:0]const u8) !void {
        self._request_header_list = c.curl_slist_append(self._request_header_list, value);
    }

    pub fn abort(self: *Transfer) void {
        var client = self.handle.client;
        errorMCheck(c.curl_multi_remove_handle(client.multi, self.handle.easy)) catch |err| {
            log.err(.http, "Failed to abort", .{.err = err});
        };
        client.active -= 1;
        self.deinit();
    }

    fn headerCallback(buffer: [*]const u8, header_count: usize, buf_len: usize, data: *anyopaque) callconv(.c) usize {
        // libcurl should only ever emit 1 header at a time
        std.debug.assert(header_count == 1);

        const handle: *Handle = @alignCast(@ptrCast(data));
        var transfer = fromEasy(handle.easy) catch |err| {
            log.err(.http, "retrive private info", .{.err = err});
            return 0;
        };

        std.debug.assert(std.mem.endsWith(u8, buffer[0..buf_len], "\r\n"));

        const header = buffer[0..buf_len - 2];

        if (transfer.response_header == null) {
            if (buf_len < 13 or std.mem.startsWith(u8, header, "HTTP/") == false) {
                if (transfer._redirecting) {
                    return buf_len;
                }
                transfer.onError(error.InvalidResponseLine);
                return 0;
            }
            const version_start: usize = if (header[5] == '2') 7 else 9;
            const version_end = version_start + 3;

            // a bit silly, but it makes sure that we don't change the length check
            // above in a way that could break this.
            std.debug.assert(version_end < 13);

            const status = std.fmt.parseInt(u16, header[version_start..version_end], 10) catch {
                transfer.onError(error.InvalidResponseStatus);
                return 0;
            };

            if (status >= 300 and status <= 399) {
                transfer._redirecting = true;
                return buf_len;
            }
            transfer._redirecting = false;

            var url: [*c]u8 = undefined;
            errorCheck(c.curl_easy_getinfo(handle.easy, c.CURLINFO_EFFECTIVE_URL, &url)) catch |err| {
                transfer.onError(err);
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
            transfer.req.header_done_callback(transfer) catch {
                // returning < buf_len terminates the request
                return 0;
            };
        } else {
            if (transfer.req.header_callback) |cb| {
                cb(transfer, header) catch return 0;
            }
        }
        return buf_len;
    }

    fn bodyCallback(buffer: [*]const u8, chunk_count: usize, chunk_len: usize, data: *anyopaque) callconv(.c) usize {
        // libcurl should only ever emit 1 chunk at a time
        std.debug.assert(chunk_count == 1);

        const handle: *Handle = @alignCast(@ptrCast(data));
        var transfer = fromEasy(handle.easy) catch |err| {
            log.err(.http, "retrive private info", .{.err = err});
            return c.CURL_WRITEFUNC_ERROR;
        };

        if (transfer._redirecting) {
            return chunk_len;
        }

        transfer.req.data_callback(transfer, buffer[0..chunk_len]) catch {
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

fn errorCheck(code: c.CURLcode) errors.Error!void {
    if (code == c.CURLE_OK) {
        return;
    }
    return errors.fromCode(code);
}

fn errorMCheck(code: c.CURLMcode) errors.Multi!void {
    if (code == c.CURLM_OK) {
        return;
    }
    if (code == c.CURLM_CALL_MULTI_PERFORM) {
        // should we can client.perform() here?
        // or just wait until the next time we naturally call it?
        return;
    }
    return errors.fromMCode(code);
}

pub const Method = enum {
    GET,
    PUT,
    POST,
    DELETE,
    HEAD,
    OPTIONS,
};

pub const ProxyType = enum {
    forward,
    connect,
};

pub const ProxyAuth = union(enum) {
    basic: struct { user_pass: []const u8 },
    bearer: struct { token: []const u8 },
};

