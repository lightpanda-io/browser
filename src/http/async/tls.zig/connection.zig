const std = @import("std");
const assert = std.debug.assert;

const proto = @import("protocol.zig");
const record = @import("record.zig");
const cipher = @import("cipher.zig");
const Cipher = cipher.Cipher;

const async_io = @import("../std/http/Client.zig");
const Cbk = async_io.Cbk;
const Ctx = async_io.Ctx;

pub fn connection(stream: anytype) Connection(@TypeOf(stream)) {
    return .{
        .stream = stream,
        .rec_rdr = record.reader(stream),
    };
}

pub fn Connection(comptime Stream: type) type {
    return struct {
        stream: Stream, // underlying stream
        rec_rdr: record.Reader(Stream),
        cipher: Cipher = undefined,

        max_encrypt_seq: u64 = std.math.maxInt(u64) - 1,
        key_update_requested: bool = false,

        read_buf: []const u8 = "",
        received_close_notify: bool = false,

        const Self = @This();

        /// Encrypts and writes single tls record to the stream.
        fn writeRecord(c: *Self, content_type: proto.ContentType, bytes: []const u8) !void {
            assert(bytes.len <= cipher.max_cleartext_len);
            var write_buf: [cipher.max_ciphertext_record_len]u8 = undefined;
            // If key update is requested send key update message and update
            // my encryption keys.
            if (c.cipher.encryptSeq() >= c.max_encrypt_seq or @atomicLoad(bool, &c.key_update_requested, .monotonic)) {
                @atomicStore(bool, &c.key_update_requested, false, .monotonic);

                // If the request_update field is set to "update_requested",
                // then the receiver MUST send a KeyUpdate of its own with
                // request_update set to "update_not_requested" prior to sending
                // its next Application Data record. This mechanism allows
                // either side to force an update to the entire connection, but
                // causes an implementation which receives multiple KeyUpdates
                // while it is silent to respond with a single update.
                //
                // rfc: https://datatracker.ietf.org/doc/html/rfc8446#autoid-57
                const key_update = &record.handshakeHeader(.key_update, 1) ++ [_]u8{0};
                const rec = try c.cipher.encrypt(&write_buf, .handshake, key_update);
                try c.stream.writeAll(rec);
                try c.cipher.keyUpdateEncrypt();
            }
            const rec = try c.cipher.encrypt(&write_buf, content_type, bytes);
            try c.stream.writeAll(rec);
        }

        fn writeAlert(c: *Self, err: anyerror) !void {
            const cleartext = proto.alertFromError(err);
            var buf: [128]u8 = undefined;
            const ciphertext = try c.cipher.encrypt(&buf, .alert, &cleartext);
            c.stream.writeAll(ciphertext) catch {};
        }

        /// Returns next record of cleartext data.
        /// Can be used in iterator like loop without memcpy to another buffer:
        ///   while (try client.next()) |buf| { ... }
        pub fn next(c: *Self) ReadError!?[]const u8 {
            const content_type, const data = c.nextRecord() catch |err| {
                try c.writeAlert(err);
                return err;
            } orelse return null;
            if (content_type != .application_data) return error.TlsUnexpectedMessage;
            return data;
        }

        fn nextRecord(c: *Self) ReadError!?struct { proto.ContentType, []const u8 } {
            if (c.eof()) return null;
            while (true) {
                const content_type, const cleartext = try c.rec_rdr.nextDecrypt(&c.cipher) orelse return null;

                switch (content_type) {
                    .application_data => {},
                    .handshake => {
                        const handshake_type: proto.Handshake = @enumFromInt(cleartext[0]);
                        switch (handshake_type) {
                            // skip new session ticket and read next record
                            .new_session_ticket => continue,
                            .key_update => {
                                if (cleartext.len != 5) return error.TlsDecodeError;
                                // rfc: Upon receiving a KeyUpdate, the receiver MUST
                                // update its receiving keys.
                                try c.cipher.keyUpdateDecrypt();
                                const key: proto.KeyUpdateRequest = @enumFromInt(cleartext[4]);
                                switch (key) {
                                    .update_requested => {
                                        @atomicStore(bool, &c.key_update_requested, true, .monotonic);
                                    },
                                    .update_not_requested => {},
                                    else => return error.TlsIllegalParameter,
                                }
                                // this record is handled read next
                                continue;
                            },
                            else => {},
                        }
                    },
                    .alert => {
                        if (cleartext.len < 2) return error.TlsUnexpectedMessage;
                        try proto.Alert.parse(cleartext[0..2].*).toError();
                        // server side clean shutdown
                        c.received_close_notify = true;
                        return null;
                    },
                    else => return error.TlsUnexpectedMessage,
                }
                return .{ content_type, cleartext };
            }
        }

        pub fn eof(c: *Self) bool {
            return c.received_close_notify and c.read_buf.len == 0;
        }

        pub fn close(c: *Self) !void {
            if (c.received_close_notify) return;
            try c.writeRecord(.alert, &proto.Alert.closeNotify());
        }

        // read, write interface

        pub const ReadError = Stream.ReadError || proto.Alert.Error ||
            error{
            TlsBadVersion,
            TlsUnexpectedMessage,
            TlsRecordOverflow,
            TlsDecryptError,
            TlsDecodeError,
            TlsBadRecordMac,
            TlsIllegalParameter,
            BufferOverflow,
        };
        pub const WriteError = Stream.WriteError ||
            error{
            BufferOverflow,
            TlsUnexpectedMessage,
        };

        pub const Reader = std.io.Reader(*Self, ReadError, read);
        pub const Writer = std.io.Writer(*Self, WriteError, write);

        pub fn reader(c: *Self) Reader {
            return .{ .context = c };
        }

        pub fn writer(c: *Self) Writer {
            return .{ .context = c };
        }

        /// Encrypts cleartext and writes it to the underlying stream as single
        /// tls record. Max single tls record payload length is 1<<14 (16K)
        /// bytes.
        pub fn write(c: *Self, bytes: []const u8) WriteError!usize {
            const n = @min(bytes.len, cipher.max_cleartext_len);
            try c.writeRecord(.application_data, bytes[0..n]);
            return n;
        }

        /// Encrypts cleartext and writes it to the underlying stream. If needed
        /// splits cleartext into multiple tls record.
        pub fn writeAll(c: *Self, bytes: []const u8) WriteError!void {
            var index: usize = 0;
            while (index < bytes.len) {
                index += try c.write(bytes[index..]);
            }
        }

        pub fn read(c: *Self, buffer: []u8) ReadError!usize {
            if (c.read_buf.len == 0) {
                c.read_buf = try c.next() orelse return 0;
            }
            const n = @min(c.read_buf.len, buffer.len);
            @memcpy(buffer[0..n], c.read_buf[0..n]);
            c.read_buf = c.read_buf[n..];
            return n;
        }

        /// Returns the number of bytes read. If the number read is smaller than
        /// `buffer.len`, it means the stream reached the end.
        pub fn readAll(c: *Self, buffer: []u8) ReadError!usize {
            return c.readAtLeast(buffer, buffer.len);
        }

        /// Returns the number of bytes read, calling the underlying read function
        /// the minimal number of times until the buffer has at least `len` bytes
        /// filled. If the number read is less than `len` it means the stream
        /// reached the end.
        pub fn readAtLeast(c: *Self, buffer: []u8, len: usize) ReadError!usize {
            assert(len <= buffer.len);
            var index: usize = 0;
            while (index < len) {
                const amt = try c.read(buffer[index..]);
                if (amt == 0) break;
                index += amt;
            }
            return index;
        }

        /// Returns the number of bytes read. If the number read is less than
        /// the space provided it means the stream reached the end.
        pub fn readv(c: *Self, iovecs: []std.posix.iovec) !usize {
            var vp: VecPut = .{ .iovecs = iovecs };
            while (true) {
                if (c.read_buf.len == 0) {
                    c.read_buf = try c.next() orelse break;
                }
                const n = vp.put(c.read_buf);
                const read_buf_len = c.read_buf.len;
                c.read_buf = c.read_buf[n..];
                if ((n < read_buf_len) or
                    (n == read_buf_len and !c.rec_rdr.hasMore()))
                    break;
            }
            return vp.total;
        }

        fn onWriteAll(ctx: *Ctx, res: anyerror!void) anyerror!void {
            res catch |err| return ctx.pop(err);

            if (ctx._tls_write_bytes.len - ctx._tls_write_index > 0) {
                const rec = ctx.conn().tls_client.prepareRecord(ctx.stream(), ctx) catch |err| return ctx.pop(err);
                return ctx.stream().async_writeAll(rec, ctx, onWriteAll) catch |err| return ctx.pop(err);
            }

            return ctx.pop({});
        }

        pub fn async_writeAll(c: *Self, stream: anytype, bytes: []const u8, ctx: *Ctx, comptime cbk: Cbk) !void {
            assert(bytes.len <= cipher.max_cleartext_len);

            ctx._tls_write_bytes = bytes;
            ctx._tls_write_index = 0;
            const rec = try c.prepareRecord(stream, ctx);

            try ctx.push(cbk);
            return stream.async_writeAll(rec, ctx, onWriteAll);
        }

        fn prepareRecord(c: *Self, stream: anytype, ctx: *Ctx) ![]const u8 {
            const len = @min(ctx._tls_write_bytes.len - ctx._tls_write_index, cipher.max_cleartext_len);

            // If key update is requested send key update message and update
            // my encryption keys.
            if (c.cipher.encryptSeq() >= c.max_encrypt_seq or @atomicLoad(bool, &c.key_update_requested, .monotonic)) {
                @atomicStore(bool, &c.key_update_requested, false, .monotonic);

                // If the request_update field is set to "update_requested",
                // then the receiver MUST send a KeyUpdate of its own with
                // request_update set to "update_not_requested" prior to sending
                // its next Application Data record. This mechanism allows
                // either side to force an update to the entire connection, but
                // causes an implementation which receives multiple KeyUpdates
                // while it is silent to respond with a single update.
                //
                // rfc: https://datatracker.ietf.org/doc/html/rfc8446#autoid-57
                const key_update = &record.handshakeHeader(.key_update, 1) ++ [_]u8{0};
                const rec = try c.cipher.encrypt(&ctx._tls_write_buf, .handshake, key_update);
                try stream.writeAll(rec); // TODO async
                try c.cipher.keyUpdateEncrypt();
            }

            defer ctx._tls_write_index += len;
            return c.cipher.encrypt(&ctx._tls_write_buf, .application_data, ctx._tls_write_bytes[ctx._tls_write_index..len]);
        }

        fn onReadv(ctx: *Ctx, res: anyerror!void) anyerror!void {
            res catch |err| return ctx.pop(err);

            if (ctx._tls_read_buf == null) {
                // end of read
                ctx.setLen(ctx._vp.total);
                return ctx.pop({});
            }

            while (true) {
                const n = ctx._vp.put(ctx._tls_read_buf.?);
                const read_buf_len = ctx._tls_read_buf.?.len;
                const c = ctx.conn().tls_client;

                if (read_buf_len == 0) {
                    // read another buffer
                    return c.async_next(ctx.stream(), ctx, onReadv) catch |err| return ctx.pop(err);
                }

                ctx._tls_read_buf = ctx._tls_read_buf.?[n..];

                if ((n < read_buf_len) or (n == read_buf_len and !c.rec_rdr.hasMore())) {
                    // end of read
                    ctx.setLen(ctx._vp.total);
                    return ctx.pop({});
                }
            }
        }

        pub fn async_readv(c: *Self, stream: anytype, iovecs: []std.posix.iovec, ctx: *Ctx, comptime cbk: Cbk) !void {
            try ctx.push(cbk);
            ctx._vp = .{ .iovecs = iovecs };

            return c.async_next(stream, ctx, onReadv);
        }

        fn onNext(ctx: *Ctx, res: anyerror!void) anyerror!void {
            res catch |err| {
                ctx.conn().tls_client.writeAlert(err) catch |e| std.log.err("onNext: write alert: {any}", .{e}); // TODO async
                return ctx.pop(err);
            };

            if (ctx._tls_read_content_type != .application_data) {
                return ctx.pop(error.TlsUnexpectedMessage);
            }

            return ctx.pop({});
        }

        pub fn async_next(c: *Self, stream: anytype, ctx: *Ctx, comptime cbk: Cbk) !void {
            try ctx.push(cbk);

            return c.async_next_decrypt(stream, ctx, onNext);
        }

        pub fn onNextDecrypt(ctx: *Ctx, res: anyerror!void) anyerror!void {
            res catch |err| return ctx.pop(err);

            const c = ctx.conn().tls_client;
            // TOOD not sure if this works in my async case...
            if (c.eof()) {
                ctx._tls_read_buf = null;
                return ctx.pop({});
            }

            const content_type = ctx._tls_read_content_type;

            switch (content_type) {
                .application_data => {},
                .handshake => {
                    const handshake_type: proto.Handshake = @enumFromInt(ctx._tls_read_buf.?[0]);
                    switch (handshake_type) {
                        // skip new session ticket and read next record
                        .new_session_ticket => return c.async_next_record(ctx.stream(), ctx, onNextDecrypt) catch |err| return ctx.pop(err),
                        .key_update => {
                            if (ctx._tls_read_buf.?.len != 5) return ctx.pop(error.TlsDecodeError);
                            // rfc: Upon receiving a KeyUpdate, the receiver MUST
                            // update its receiving keys.
                            try c.cipher.keyUpdateDecrypt();
                            const key: proto.KeyUpdateRequest = @enumFromInt(ctx._tls_read_buf.?[4]);
                            switch (key) {
                                .update_requested => {
                                    @atomicStore(bool, &c.key_update_requested, true, .monotonic);
                                },
                                .update_not_requested => {},
                                else => return ctx.pop(error.TlsIllegalParameter),
                            }
                            // this record is handled read next
                            c.async_next_record(ctx.stream(), ctx, onNextDecrypt) catch |err| return ctx.pop(err);
                        },
                        else => {},
                    }
                },
                .alert => {
                    if (ctx._tls_read_buf.?.len < 2) return ctx.pop(error.TlsUnexpectedMessage);
                    try proto.Alert.parse(ctx._tls_read_buf.?[0..2].*).toError();
                    // server side clean shutdown
                    c.received_close_notify = true;
                    ctx._tls_read_buf = null;
                    return ctx.pop({});
                },
                else => return ctx.pop(error.TlsUnexpectedMessage),
            }

            return ctx.pop({});
        }

        pub fn async_next_decrypt(c: *Self, stream: anytype, ctx: *Ctx, comptime cbk: Cbk) !void {
            try ctx.push(cbk);

            return c.async_next_record(stream, ctx, onNextDecrypt) catch |err| return ctx.pop(err);
        }

        pub fn onNextRecord(ctx: *Ctx, res: anyerror!void) anyerror!void {
            res catch |err| return ctx.pop(err);

            const rec = ctx._tls_read_record orelse {
                ctx._tls_read_buf = null;
                return ctx.pop({});
            };

            if (rec.protocol_version != .tls_1_2) return error.TlsBadVersion;

            const c = ctx.conn().tls_client;
            const cph = &c.cipher;

            ctx._tls_read_content_type, ctx._tls_read_buf = cph.decrypt(
                // Reuse reader buffer for cleartext. `rec.header` and
                // `rec.payload`(ciphertext) are also pointing somewhere in
                // this buffer. Decrypter is first reading then writing a
                // block, cleartext has less length then ciphertext,
                // cleartext starts from the beginning of the buffer, so
                // ciphertext is always ahead of cleartext.
                c.rec_rdr.buffer[0..c.rec_rdr.start],
                rec,
            ) catch |err| return ctx.pop(err);

            return ctx.pop({});
        }

        pub fn async_next_record(c: *Self, stream: anytype, ctx: *Ctx, comptime cbk: Cbk) !void {
            try ctx.push(cbk);

            return c.async_reader_next(stream, ctx, onNextRecord);
        }

        pub fn onReaderNext(ctx: *Ctx, res: anyerror!void) anyerror!void {
            res catch |err| return ctx.pop(err);

            const c = ctx.conn().tls_client;

            const n = ctx.len();
            if (n == 0) {
                ctx._tls_read_record = null;
                return ctx.pop({});
            }
            c.rec_rdr.end += n;

            return c.readNext(ctx);
        }

        pub fn readNext(c: *Self, ctx: *Ctx) anyerror!void {
            const buffer = c.rec_rdr.buffer[c.rec_rdr.start..c.rec_rdr.end];
            // If we have 5 bytes header.
            if (buffer.len >= record.header_len) {
                const record_header = buffer[0..record.header_len];
                const payload_len = std.mem.readInt(u16, record_header[3..5], .big);
                if (payload_len > cipher.max_ciphertext_len)
                    return error.TlsRecordOverflow;
                const record_len = record.header_len + payload_len;
                // If we have whole record
                if (buffer.len >= record_len) {
                    c.rec_rdr.start += record_len;
                    ctx._tls_read_record = record.Record.init(buffer[0..record_len]);
                    return ctx.pop({});
                }
            }
            { // Move dirty part to the start of the buffer.
                const n = c.rec_rdr.end - c.rec_rdr.start;
                if (n > 0 and c.rec_rdr.start > 0) {
                    if (c.rec_rdr.start > n) {
                        @memcpy(c.rec_rdr.buffer[0..n], c.rec_rdr.buffer[c.rec_rdr.start..][0..n]);
                    } else {
                        std.mem.copyForwards(u8, c.rec_rdr.buffer[0..n], c.rec_rdr.buffer[c.rec_rdr.start..][0..n]);
                    }
                }
                c.rec_rdr.start = 0;
                c.rec_rdr.end = n;
            }
            // Read more from inner_reader.
            return ctx.stream()
                .async_read(c.rec_rdr.buffer[c.rec_rdr.end..], ctx, onReaderNext) catch |err| return ctx.pop(err);
        }

        pub fn async_reader_next(c: *Self, _: anytype, ctx: *Ctx, comptime cbk: Cbk) !void {
            try ctx.push(cbk);
            return c.readNext(ctx);
        }
    };
}

const testing = std.testing;
const data12 = @import("testdata/tls12.zig");
const testu = @import("testu.zig");

test "encrypt decrypt" {
    var output_buf: [1024]u8 = undefined;
    const stream = testu.Stream.init(&(data12.server_pong ** 3), &output_buf);
    var conn: Connection(@TypeOf(stream)) = .{ .stream = stream, .rec_rdr = record.reader(stream) };
    conn.cipher = try Cipher.initTls12(.ECDHE_RSA_WITH_AES_128_CBC_SHA, &data12.key_material, .client);
    conn.cipher.ECDHE_RSA_WITH_AES_128_CBC_SHA.rnd = testu.random(0); // use fixed rng

    conn.stream.output.reset();
    { // encrypt verify data from example
        _ = testu.random(0x40); // sets iv to 40, 41, ... 4f
        try conn.writeRecord(.handshake, &data12.client_finished);
        try testing.expectEqualSlices(u8, &data12.verify_data_encrypted_msg, conn.stream.output.getWritten());
    }

    conn.stream.output.reset();
    { // encrypt ping
        const cleartext = "ping";
        _ = testu.random(0); // sets iv to 00, 01, ... 0f
        //conn.encrypt_seq = 1;

        try conn.writeAll(cleartext);
        try testing.expectEqualSlices(u8, &data12.encrypted_ping_msg, conn.stream.output.getWritten());
    }
    { // decrypt server pong message
        conn.cipher.ECDHE_RSA_WITH_AES_128_CBC_SHA.decrypt_seq = 1;
        try testing.expectEqualStrings("pong", (try conn.next()).?);
    }
    { // test reader interface
        conn.cipher.ECDHE_RSA_WITH_AES_128_CBC_SHA.decrypt_seq = 1;
        var rdr = conn.reader();
        var buffer: [4]u8 = undefined;
        const n = try rdr.readAll(&buffer);
        try testing.expectEqualStrings("pong", buffer[0..n]);
    }
    { // test readv interface
        conn.cipher.ECDHE_RSA_WITH_AES_128_CBC_SHA.decrypt_seq = 1;
        var buffer: [9]u8 = undefined;
        var iovecs = [_]std.posix.iovec{
            .{ .base = &buffer, .len = 3 },
            .{ .base = buffer[3..], .len = 3 },
            .{ .base = buffer[6..], .len = 3 },
        };
        const n = try conn.readv(iovecs[0..]);
        try testing.expectEqual(4, n);
        try testing.expectEqualStrings("pong", buffer[0..n]);
    }
}

// Copied from: https://github.com/ziglang/zig/blob/455899668b620dfda40252501c748c0a983555bd/lib/std/crypto/tls/Client.zig#L1354
/// Abstraction for sending multiple byte buffers to a slice of iovecs.
pub const VecPut = struct {
    iovecs: []const std.posix.iovec,
    idx: usize = 0,
    off: usize = 0,
    total: usize = 0,

    /// Returns the amount actually put which is always equal to bytes.len
    /// unless the vectors ran out of space.
    pub fn put(vp: *VecPut, bytes: []const u8) usize {
        if (vp.idx >= vp.iovecs.len) return 0;
        var bytes_i: usize = 0;
        while (true) {
            const v = vp.iovecs[vp.idx];
            const dest = v.base[vp.off..v.len];
            const src = bytes[bytes_i..][0..@min(dest.len, bytes.len - bytes_i)];
            @memcpy(dest[0..src.len], src);
            bytes_i += src.len;
            vp.off += src.len;
            if (vp.off >= v.len) {
                vp.off = 0;
                vp.idx += 1;
                if (vp.idx >= vp.iovecs.len) {
                    vp.total += bytes_i;
                    return bytes_i;
                }
            }
            if (bytes_i >= bytes.len) {
                vp.total += bytes_i;
                return bytes_i;
            }
        }
    }
};

test "client/server connection" {
    const BufReaderWriter = struct {
        buf: []u8,
        wp: usize = 0,
        rp: usize = 0,

        const Self = @This();

        pub fn write(self: *Self, bytes: []const u8) !usize {
            if (self.wp == self.buf.len) return error.NoSpaceLeft;

            const n = @min(bytes.len, self.buf.len - self.wp);
            @memcpy(self.buf[self.wp..][0..n], bytes[0..n]);
            self.wp += n;
            return n;
        }

        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            var n: usize = 0;
            while (n < bytes.len) {
                n += try self.write(bytes[n..]);
            }
        }

        pub fn read(self: *Self, bytes: []u8) !usize {
            const n = @min(bytes.len, self.wp - self.rp);
            if (n == 0) return 0;
            @memcpy(bytes[0..n], self.buf[self.rp..][0..n]);
            self.rp += n;
            if (self.rp == self.wp) {
                self.wp = 0;
                self.rp = 0;
            }
            return n;
        }
    };

    const TestStream = struct {
        inner_stream: *BufReaderWriter,
        const Self = @This();
        pub const ReadError = error{};
        pub const WriteError = error{NoSpaceLeft};
        pub fn read(self: *Self, bytes: []u8) !usize {
            return try self.inner_stream.read(bytes);
        }
        pub fn writeAll(self: *Self, bytes: []const u8) !void {
            return try self.inner_stream.writeAll(bytes);
        }
    };

    const buf_len = 32 * 1024;
    const tls_records_in_buf = (std.math.divCeil(comptime_int, buf_len, cipher.max_cleartext_len) catch unreachable);
    const overhead: usize = tls_records_in_buf * @import("cipher.zig").encrypt_overhead_tls_13;
    var buf: [buf_len + overhead]u8 = undefined;
    var inner_stream = BufReaderWriter{ .buf = &buf };

    const cipher_client, const cipher_server = brk: {
        const Transcript = @import("transcript.zig").Transcript;
        const CipherSuite = @import("cipher.zig").CipherSuite;
        const cipher_suite: CipherSuite = .AES_256_GCM_SHA384;

        var rnd: [128]u8 = undefined;
        std.crypto.random.bytes(&rnd);
        const secret = Transcript.Secret{
            .client = rnd[0..64],
            .server = rnd[64..],
        };

        break :brk .{
            try Cipher.initTls13(cipher_suite, secret, .client),
            try Cipher.initTls13(cipher_suite, secret, .server),
        };
    };

    var conn1 = connection(TestStream{ .inner_stream = &inner_stream });
    conn1.cipher = cipher_client;

    var conn2 = connection(TestStream{ .inner_stream = &inner_stream });
    conn2.cipher = cipher_server;

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    var send_buf: [buf_len]u8 = undefined;
    var recv_buf: [buf_len]u8 = undefined;
    random.bytes(&send_buf); // fill send buffer with random bytes

    for (0..16) |_| {
        const n = buf_len; //random.uintLessThan(usize, buf_len);

        const sent = send_buf[0..n];
        try conn1.writeAll(sent);
        const r = try conn2.readAll(&recv_buf);
        const received = recv_buf[0..r];

        try testing.expectEqual(n, r);
        try testing.expectEqualSlices(u8, sent, received);
    }
}
