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

const log = lp.log;
const Config = lp.Config;
const Allocator = std.mem.Allocator;

const Certificates = @This();

store: *crypto.X509_STORE,

pub fn init(allocator: Allocator, config: *const Config) !Certificates {
    const store = blk: {
        const custom_store = config.customCertStore();
        if (config.tlsVerifyHost() == false) {
            if (custom_store != null) {
                log.warn(.app, "custom CA ignored", .{
                    .arg = "--ca-cert, --ca-path",
                    .reason = "TLS verification disabled",
                });
            }
            break :blk crypto.X509_STORE_new() orelse return error.FailedToCreateX509Store;
        }
        break :blk custom_store orelse try storeFromSystemCA(allocator);
    };

    return .{ .store = store };
}

pub fn deinit(self: Certificates) void {
    crypto.X509_STORE_free(self.store);
}

fn storeFromSystemCA(allocator: Allocator) !*crypto.X509_STORE {
    const store = crypto.X509_STORE_new() orelse return error.FailedToCreateX509Store;
    errdefer crypto.X509_STORE_free(store);

    var count: usize = 0;
    defer {
        if (count == 0) {
            log.warn(.app, "No certificates loaded", .{});
        }
    }

    switch (comptime @import("builtin").os.tag) {
        .linux, .openbsd, .netbsd, .freebsd => blk: {
            // Iterate over known directories; this may or may not succeed.
            const cwd = std.Io.Dir.cwd();
            inline for ([_][]const u8{
                "/etc/ssl/certs", // Debian/Ubuntu/Gentoo/Alpine, SUSE
                "/etc/pki/tls/certs", // Fedora/RHEL
            }) |dir_path| {
                count += try loadFromDirectory(allocator, store, cwd, dir_path);
                if (count > 0) break :blk;
            }

            // Iterate over known files.
            inline for ([_][*:0]const u8{
                "/etc/ssl/certs/ca-certificates.crt", // Debian/Ubuntu/Gentoo
                "/etc/pki/tls/certs/ca-bundle.crt", // Fedora/RHEL 6
                "/etc/ssl/ca-bundle.pem", // OpenSUSE
                "/etc/pki/tls/cacert.pem", // OpenELEC
                "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // CentOS/RHEL 7
                "/etc/ssl/cert.pem", // Alpine, *BSD
            }) |file| {
                if (crypto.X509_STORE_load_locations(store, file, null) == 1) {
                    count += 1;
                    break :blk;
                }
            }
        },
        else => {
            // Prefer stdlib's cert scanner.
            var bundle: std.crypto.Certificate.Bundle = .empty;
            try bundle.rescan(allocator, lp.io, std.Io.Clock.now(.real, lp.io));
            defer bundle.deinit(allocator);

            const bytes = bundle.bytes.items;
            var it = bundle.map.valueIterator();
            while (it.next()) |index| {
                // d2i_X509 reads the cert's own DER length header to find its end and
                // advances `ptr` past it, so we just hand it the rest of the buffer.
                var ptr: [*]const u8 = bytes.ptr + index.*;
                const x509 = crypto.d2i_X509(null, &ptr, @intCast(bytes.len - index.*)) orelse {
                    log.warn(.app, "Skipping unparseable system cert", .{});
                    continue;
                };
                defer crypto.X509_free(x509); // add_cert takes its own ref; drop ours.

                const result = crypto.X509_STORE_add_cert(store, x509);
                if (result != 1) {
                    log.warn(.app, "Failed to add X509 cert to store", .{});
                }
                count += 1;
            }
        },
    }

    return store;
}

fn loadFromDirectory(allocator: Allocator, store: *crypto.X509_STORE, cwd: std.Io.Dir, dir_path: []const u8) !usize {
    var count: usize = 0;
    var dir = cwd.openDir(lp.io, dir_path, .{ .iterate = true }) catch return count;
    defer dir.close(lp.io);

    var it = dir.iterate();
    while (it.next(lp.io) catch return count) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const path = try std.fs.path.joinZ(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);

        if (crypto.X509_STORE_load_locations(store, path, null) == 1) {
            count += 1;
        }
    }
    return count;
}
