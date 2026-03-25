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

const std = @import("std");
const crypto = @import("../sys/libcrypto.zig");

const Http = @import("../network/http.zig");

const WebBotAuth = @This();

pkey: *crypto.EVP_PKEY,
keyid: []const u8,
directory_url: [:0]const u8,

pub const Config = struct {
    key_file: []const u8,
    keyid: []const u8,
    domain: []const u8,
};

fn parsePemPrivateKey(pem: []const u8) !*crypto.EVP_PKEY {
    const begin = "-----BEGIN PRIVATE KEY-----";
    const end = "-----END PRIVATE KEY-----";
    const start_idx = std.mem.indexOf(u8, pem, begin) orelse return error.InvalidPem;
    const end_idx = std.mem.indexOf(u8, pem, end) orelse return error.InvalidPem;

    const b64 = std.mem.trim(u8, pem[start_idx + begin.len .. end_idx], &std.ascii.whitespace);

    // decode base64 into 48-byte DER buffer
    var der: [48]u8 = undefined;
    try std.base64.standard.Decoder.decode(der[0..48], b64);

    // Ed25519 PKCS#8 structure always places the 32-byte raw private key at offset 16.
    const key_bytes = der[16..48];

    const pkey = crypto.EVP_PKEY_new_raw_private_key(crypto.EVP_PKEY_ED25519, null, key_bytes.ptr, 32);
    return pkey orelse error.InvalidKey;
}

fn signEd25519(pkey: *crypto.EVP_PKEY, message: []const u8, out: *[64]u8) !void {
    const ctx = crypto.EVP_MD_CTX_new() orelse return error.OutOfMemory;
    defer crypto.EVP_MD_CTX_free(ctx);

    if (crypto.EVP_DigestSignInit(ctx, null, null, null, pkey) != 1)
        return error.SignInit;

    var sig_len: usize = 64;
    if (crypto.EVP_DigestSign(ctx, out.ptr, &sig_len, message.ptr, message.len) != 1)
        return error.SignFailed;
}

pub fn fromConfig(allocator: std.mem.Allocator, config: *const Config) !WebBotAuth {
    const pem = try std.fs.cwd().readFileAlloc(allocator, config.key_file, 1024 * 4);
    defer allocator.free(pem);

    const pkey = try parsePemPrivateKey(pem);
    errdefer crypto.EVP_PKEY_free(pkey);

    const directory_url = try std.fmt.allocPrintSentinel(
        allocator,
        "https://{s}/.well-known/http-message-signatures-directory",
        .{config.domain},
        0,
    );
    errdefer allocator.free(directory_url);

    return .{
        .pkey = pkey,
        // Owned by the Config so it's okay.
        .keyid = config.keyid,
        .directory_url = directory_url,
    };
}

pub fn signRequest(
    self: *const WebBotAuth,
    allocator: std.mem.Allocator,
    headers: *Http.Headers,
    authority: []const u8,
) !void {
    const now = std.time.timestamp();
    const expires = now + 60;

    // build the signature-input value (without the sig1= label)
    const sig_input_value = try std.fmt.allocPrint(
        allocator,
        "(\"@authority\" \"signature-agent\");created={d};expires={d};keyid=\"{s}\";alg=\"ed25519\";tag=\"web-bot-auth\"",
        .{ now, expires, self.keyid },
    );
    defer allocator.free(sig_input_value);

    // build the canonical string to sign
    const canonical = try std.fmt.allocPrint(
        allocator,
        "\"@authority\": {s}\n\"signature-agent\": \"{s}\"\n\"@signature-params\": {s}",
        .{ authority, self.directory_url, sig_input_value },
    );
    defer allocator.free(canonical);

    // sign it
    var sig: [64]u8 = undefined;
    try signEd25519(self.pkey, canonical, &sig);

    // base64 encode
    const encoded_len = std.base64.standard.Encoder.calcSize(sig.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, &sig);

    // build the 3 headers and add them
    const sig_agent = try std.fmt.allocPrintSentinel(
        allocator,
        "Signature-Agent: \"{s}\"",
        .{self.directory_url},
        0,
    );
    defer allocator.free(sig_agent);

    const sig_input = try std.fmt.allocPrintSentinel(
        allocator,
        "Signature-Input: sig1={s}",
        .{sig_input_value},
        0,
    );
    defer allocator.free(sig_input);

    const signature = try std.fmt.allocPrintSentinel(
        allocator,
        "Signature: sig1=:{s}:",
        .{encoded},
        0,
    );
    defer allocator.free(signature);

    try headers.add(sig_agent);
    try headers.add(sig_input);
    try headers.add(signature);
}

pub fn deinit(self: WebBotAuth, allocator: std.mem.Allocator) void {
    crypto.EVP_PKEY_free(self.pkey);
    allocator.free(self.directory_url);
}

test "parsePemPrivateKey: valid Ed25519 PKCS#8 PEM" {
    const pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEIBuCRBIEFNtXcMBsyOOkFBFTJcEWTkbgSwKExhOjKFHT
        \\-----END PRIVATE KEY-----
        \\
    ;

    const pkey = try parsePemPrivateKey(pem);
    defer crypto.EVP_PKEY_free(pkey);
}

test "parsePemPrivateKey: missing BEGIN marker returns error" {
    const bad_pem = "-----END PRIVATE KEY-----\n";
    try std.testing.expectError(error.InvalidPem, parsePemPrivateKey(bad_pem));
}

test "parsePemPrivateKey: missing END marker returns error" {
    const bad_pem = "-----BEGIN PRIVATE KEY-----\nMC4CAQA=\n";
    try std.testing.expectError(error.InvalidPem, parsePemPrivateKey(bad_pem));
}

test "signEd25519: signature length is always 64 bytes" {
    const pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEIBuCRBIEFNtXcMBsyOOkFBFTJcEWTkbgSwKExhOjKFHT
        \\-----END PRIVATE KEY-----
        \\
    ;
    const pkey = try parsePemPrivateKey(pem);
    defer crypto.EVP_PKEY_free(pkey);

    var sig: [64]u8 = @splat(0);
    try signEd25519(pkey, "hello world", &sig);

    var all_zero = true;
    for (sig) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
}

test "signEd25519: same key + message produces same signature (deterministic)" {
    const pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEIBuCRBIEFNtXcMBsyOOkFBFTJcEWTkbgSwKExhOjKFHT
        \\-----END PRIVATE KEY-----
        \\
    ;
    const pkey = try parsePemPrivateKey(pem);
    defer crypto.EVP_PKEY_free(pkey);

    var sig1: [64]u8 = undefined;
    var sig2: [64]u8 = undefined;
    try signEd25519(pkey, "deterministic test", &sig1);
    try signEd25519(pkey, "deterministic test", &sig2);

    try std.testing.expectEqualSlices(u8, &sig1, &sig2);
}

test "signEd25519: same key + diff message produces different signature (deterministic)" {
    const pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEIBuCRBIEFNtXcMBsyOOkFBFTJcEWTkbgSwKExhOjKFHT
        \\-----END PRIVATE KEY-----
        \\
    ;
    const pkey = try parsePemPrivateKey(pem);
    defer crypto.EVP_PKEY_free(pkey);

    var sig1: [64]u8 = undefined;
    var sig2: [64]u8 = undefined;
    try signEd25519(pkey, "msg 1", &sig1);
    try signEd25519(pkey, "msg 2", &sig2);

    try std.testing.expect(!std.mem.eql(u8, &sig1, &sig2));
}

test "signRequest: adds headers with correct names" {
    const allocator = std.testing.allocator;

    const pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEIBuCRBIEFNtXcMBsyOOkFBFTJcEWTkbgSwKExhOjKFHT
        \\-----END PRIVATE KEY-----
        \\
    ;
    const pkey = try parsePemPrivateKey(pem);

    const directory_url = try allocator.dupeZ(
        u8,
        "https://example.com/.well-known/http-message-signatures-directory",
    );

    var auth = WebBotAuth{
        .pkey = pkey,
        .keyid = "test-key-id",
        .directory_url = directory_url,
    };
    defer auth.deinit(allocator);

    var headers = try Http.Headers.init("User-Agent: Test-Agent");
    defer headers.deinit();

    try auth.signRequest(allocator, &headers, "example.com");

    var it = headers.iterator();
    var found_sig_agent = false;
    var found_sig_input = false;
    var found_signature = false;
    var count: usize = 0;

    while (it.next()) |h| {
        count += 1;
        if (std.ascii.eqlIgnoreCase(h.name, "Signature-Agent")) found_sig_agent = true;
        if (std.ascii.eqlIgnoreCase(h.name, "Signature-Input")) found_sig_input = true;
        if (std.ascii.eqlIgnoreCase(h.name, "Signature")) found_signature = true;
    }

    try std.testing.expect(count >= 3);
    try std.testing.expect(found_sig_agent);
    try std.testing.expect(found_sig_input);
    try std.testing.expect(found_signature);
}
