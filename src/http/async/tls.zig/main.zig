const std = @import("std");

pub const CipherSuite = @import("cipher.zig").CipherSuite;
pub const cipher_suites = @import("cipher.zig").cipher_suites;
pub const PrivateKey = @import("PrivateKey.zig");
pub const Connection = @import("connection.zig").Connection;
pub const ClientOptions = @import("handshake_client.zig").Options;
pub const ServerOptions = @import("handshake_server.zig").Options;
pub const key_log = @import("key_log.zig");
pub const proto = @import("protocol.zig");
pub const NamedGroup = proto.NamedGroup;
pub const Version = proto.Version;
const common = @import("handshake_common.zig");
pub const CertBundle = common.CertBundle;
pub const CertKeyPair = common.CertKeyPair;

pub const record = @import("record.zig");
const connection = @import("connection.zig").connection;
const max_ciphertext_record_len = @import("cipher.zig").max_ciphertext_record_len;
const HandshakeServer = @import("handshake_server.zig").Handshake;
const HandshakeClient = @import("handshake_client.zig").Handshake;

pub fn client(stream: anytype, opt: ClientOptions) !Connection(@TypeOf(stream)) {
    const Stream = @TypeOf(stream);
    var conn = connection(stream);
    var write_buf: [max_ciphertext_record_len]u8 = undefined;
    var h = HandshakeClient(Stream).init(&write_buf, &conn.rec_rdr);
    conn.cipher = try h.handshake(conn.stream, opt);
    return conn;
}

pub fn server(stream: anytype, opt: ServerOptions) !Connection(@TypeOf(stream)) {
    const Stream = @TypeOf(stream);
    var conn = connection(stream);
    var write_buf: [max_ciphertext_record_len]u8 = undefined;
    var h = HandshakeServer(Stream).init(&write_buf, &conn.rec_rdr);
    conn.cipher = try h.handshake(conn.stream, opt);
    return conn;
}

test {
    _ = @import("handshake_common.zig");
    _ = @import("handshake_server.zig");
    _ = @import("handshake_client.zig");

    _ = @import("connection.zig");
    _ = @import("cipher.zig");
    _ = @import("record.zig");
    _ = @import("transcript.zig");
    _ = @import("PrivateKey.zig");
}
