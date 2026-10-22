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
const lp = @import("lightpanda");
const crypto = @import("../sys/libcrypto.zig");

const ArenaPool = @import("../ArenaPool.zig");
const Transfer = @import("HttpClient.zig").Transfer;

const WebBotAuth = @This();

pkey: *crypto.EVP_PKEY,
keyid: []const u8,
signature_agent: [:0]const u8,

pub const Config = struct {
    key_file: []const u8,
    keyid: []const u8,
    domain: []const u8,
};

fn parsePemPrivateKey(pem: []const u8) !*crypto.EVP_PKEY {
    const begin = "-----BEGIN PRIVATE KEY-----";
    const end = "-----END PRIVATE KEY-----";
    const start_idx = std.mem.find(u8, pem, begin) orelse return error.InvalidPem;
    const end_idx = std.mem.find(u8, pem, end) orelse return error.InvalidPem;

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
    const pem = try std.Io.Dir.cwd().readFileAlloc(lp.io, config.key_file, allocator, .limited(1024 * 4));
    defer allocator.free(pem);

    const pkey = try parsePemPrivateKey(pem);
    errdefer crypto.EVP_PKEY_free(pkey);

    const signature_agent = try allocator.printSentinel(
        "\"https://{s}\"",
        .{config.domain},
        0,
    );
    errdefer allocator.free(signature_agent);

    return .{
        .pkey = pkey,
        // Owned by the Config so it's okay.
        .keyid = config.keyid,
        .signature_agent = signature_agent,
    };
}

pub fn signRequest(
    self: *const WebBotAuth,
    transfer: *Transfer,
    authority: []const u8,
) !void {
    const arena = transfer.arena.allocator();
    const now = lp.datetime.timestamp(.real);
    const expires = now + 60;

    // Use fresh system entropy for every request, including redirect hops.
    var nonce_bytes: [64]u8 = undefined;
    try lp.io.randomSecure(&nonce_bytes);
    // Match Cloudflare's reference signer: standard padded base64.
    var nonce_encoded: [std.base64.standard.Encoder.calcSize(nonce_bytes.len)]u8 = undefined;
    const nonce = std.base64.standard.Encoder.encode(&nonce_encoded, &nonce_bytes);

    // build the signature-input value (without the sig1= label)
    const sig_input_value = try arena.print(
        "(\"@authority\" \"signature-agent\");created={d};expires={d};keyid=\"{s}\";alg=\"ed25519\";nonce=\"{s}\";tag=\"web-bot-auth\"",
        .{ now, expires, self.keyid, nonce },
    );

    // build the canonical string to sign
    const canonical = try arena.print(
        "\"@authority\": {s}\n\"signature-agent\": {s}\n\"@signature-params\": {s}",
        .{ authority, self.signature_agent, sig_input_value },
    );

    // sign it
    var sig: [64]u8 = undefined;
    try signEd25519(self.pkey, canonical, &sig);

    // base64 encode
    const encoded_len = std.base64.standard.Encoder.calcSize(sig.len);
    const encoded = try arena.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, &sig);

    try transfer.setHeader("Signature-Agent", self.signature_agent, .{});
    try transfer.setHeader("Signature-Input", try arena.print("sig1={s}", .{sig_input_value}), .{});
    try transfer.setHeader("Signature", try arena.print("sig1=:{s}:", .{encoded}), .{});
}

pub fn deinit(self: WebBotAuth, allocator: std.mem.Allocator) void {
    crypto.EVP_PKEY_free(self.pkey);
    allocator.free(self.signature_agent);
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

test "signRequest: origin, fresh nonces and verifiable signatures" {
    const allocator = std.testing.allocator;

    // Published Ed25519 test key from RFC 8037, Appendix A.1.
    const pem =
        \\-----BEGIN PRIVATE KEY-----
        \\MC4CAQAwBQYDK2VwBCIEIJ1hsZ3v/VpguoRK9JLsLMREScVpezJpGXA7rAMcrn9g
        \\-----END PRIVATE KEY-----
        \\
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(lp.io, .{ .sub_path = "key.pem", .data = pem });
    const key_file = try tmp.dir.realPathFileAlloc(lp.io, "key.pem", allocator);
    defer allocator.free(key_file);

    const auth = try WebBotAuth.fromConfig(allocator, &.{
        .key_file = key_file,
        .keyid = "test-key-id",
        .domain = "example.com",
    });
    defer auth.deinit(allocator);
    try std.testing.expectEqualStrings("\"https://example.com\"", auth.signature_agent);

    var pool = ArenaPool.init(allocator, .{});
    defer pool.deinit();
    const arena = try pool.acquire(.small, "test");
    defer arena.release();

    var transfer = Transfer{
        .arena = arena,
        .owner = null,
        .req = .{
            .method = .GET,
            .url = "https://example.com/",
            .origin = null,
            .credentials_mode = .omit,
            .request_mode = .no_cors,
            .resource_type = .document,
            .shutdown_callback = @import("HttpClient.zig").noopShutdown,
        },
        .client = undefined,
        .id = 1,
        .start_time = 0,
    };

    try auth.signRequest(&transfer, "example.com");
    const first_nonce = try testSignedRequest(&transfer, "example.com");
    const first_signature = transfer.req_headers.items[2].value;

    // Even the same authority and timestamps must produce a fresh signature.
    try auth.signRequest(&transfer, "example.com");
    const second_nonce = try testSignedRequest(&transfer, "example.com");
    const second_signature = transfer.req_headers.items[2].value;
    try std.testing.expect(!std.mem.eql(u8, first_nonce, second_nonce));
    try std.testing.expect(!std.mem.eql(u8, first_signature, second_signature));

    // Re-signing a transfer replaces the headers and covers the new authority.
    try auth.signRequest(&transfer, "localhost:8989");
    const third_nonce = try testSignedRequest(&transfer, "localhost:8989");
    try std.testing.expect(!std.mem.eql(u8, second_nonce, third_nonce));
    try std.testing.expectError(error.SignatureVerificationFailed, testSignedRequest(&transfer, "example.com"));
}

fn testSignedRequest(transfer: *const Transfer, authority: []const u8) ![]const u8 {
    const headers = transfer.req_headers.items;
    try std.testing.expectEqual(3, headers.len);
    try std.testing.expectEqualStrings("Signature-Agent", headers[0].name);
    try std.testing.expectEqualStrings("\"https://example.com\"", headers[0].value);
    try std.testing.expectEqualStrings("Signature-Input", headers[1].name);
    const input = headers[1].value;
    try std.testing.expect(std.mem.startsWith(u8, input, "sig1=(\"@authority\" \"signature-agent\");created="));
    const nonce_start = (std.mem.find(u8, input, ";nonce=\"") orelse return error.MissingNonce) + ";nonce=\"".len;
    const nonce_end = std.mem.findPos(u8, input, nonce_start, "\"") orelse return error.MissingNonce;
    const nonce = input[nonce_start..nonce_end];
    try std.testing.expectEqual(88, nonce.len);
    try std.testing.expect(std.mem.endsWith(u8, nonce, "=="));
    try std.testing.expectEqualStrings("\";tag=\"web-bot-auth\"", input[nonce_end..]);
    try std.testing.expectEqual(64, try std.base64.standard.Decoder.calcSizeForSlice(nonce));
    var nonce_bytes: [64]u8 = undefined;
    try std.base64.standard.Decoder.decode(&nonce_bytes, nonce);
    var nonce_encoded: [88]u8 = undefined;
    try std.testing.expectEqualStrings(nonce, std.base64.standard.Encoder.encode(&nonce_encoded, &nonce_bytes));

    var params = std.mem.splitScalar(u8, input, ';');
    _ = params.next();
    const created_param = params.next().?;
    const expires_param = params.next().?;
    try std.testing.expect(std.mem.startsWith(u8, created_param, "created="));
    try std.testing.expect(std.mem.startsWith(u8, expires_param, "expires="));
    const created = try std.fmt.parseInt(i64, created_param["created=".len..], 10);
    const expires = try std.fmt.parseInt(i64, expires_param["expires=".len..], 10);
    try std.testing.expectEqual(created + 60, expires);
    try std.testing.expectEqualStrings("keyid=\"test-key-id\"", params.next().?);
    try std.testing.expectEqualStrings("alg=\"ed25519\"", params.next().?);

    try std.testing.expectEqualStrings("Signature", headers[2].name);
    try std.testing.expect(std.mem.startsWith(u8, headers[2].value, "sig1=:"));
    try std.testing.expect(std.mem.endsWith(u8, headers[2].value, ":"));
    const encoded_signature = headers[2].value["sig1=:".len .. headers[2].value.len - 1];
    try std.testing.expectEqual(64, try std.base64.standard.Decoder.calcSizeForSlice(encoded_signature));
    var signature_bytes: [64]u8 = undefined;
    try std.base64.standard.Decoder.decode(&signature_bytes, encoded_signature);

    // Reconstruct RFC 9421's signature base from the actual header values.
    // Verify independently of the libcrypto signing implementation.
    const canonical = try std.testing.allocator.print(
        "\"@authority\": {s}\n\"signature-agent\": {s}\n\"@signature-params\": {s}",
        .{ authority, headers[0].value, input["sig1=".len..] },
    );
    defer std.testing.allocator.free(canonical);
    var public_key_bytes: [32]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&public_key_bytes, "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo");
    const Ed25519 = std.crypto.sign.Ed25519;
    const public_key = try Ed25519.PublicKey.fromBytes(public_key_bytes);
    try Ed25519.Signature.fromBytes(signature_bytes).verify(canonical, public_key);
    return nonce;
}
