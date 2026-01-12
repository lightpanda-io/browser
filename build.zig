// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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

const Build = std.Build;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const manifest = Manifest.init(b);

    const git_commit = b.option([]const u8, "git_commit", "Current git commit");
    const prebuilt_v8_path = b.option([]const u8, "prebuilt_v8_path", "Path to prebuilt libc_v8.a");
    const snapshot_path = b.option([]const u8, "snapshot_path", "Path to v8 snapshot");

    var opts = b.addOptions();
    opts.addOption([]const u8, "version", manifest.version);
    opts.addOption([]const u8, "git_commit", git_commit orelse "dev");
    opts.addOption(?[]const u8, "snapshot_path", snapshot_path);

    const enable_tsan = b.option(bool, "tsan", "Enable Thread Sanitizer");
    const enable_csan = b.option(std.zig.SanitizeC, "csan", "Enable C Sanitizers");

    const lightpanda_module = blk: {
        const mod = b.addModule("lightpanda", .{
            .root_source_file = b.path("src/lightpanda.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .sanitize_c = enable_csan,
            .sanitize_thread = enable_tsan,
        });
        mod.addImport("lightpanda", mod); // allow circular "lightpanda" import

        try addDependencies(b, mod, opts, prebuilt_v8_path);

        break :blk mod;
    };

    {
        // browser
        const exe = b.addExecutable(.{
            .name = "lightpanda",
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_c = enable_csan,
                .sanitize_thread = enable_tsan,
                .imports = &.{
                    .{ .name = "lightpanda", .module = lightpanda_module },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        // snapshot creator
        const exe = b.addExecutable(.{
            .name = "lightpanda-snapshot-creator",
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_snapshot_creator.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "lightpanda", .module = lightpanda_module },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("snapshot_creator", "Generate a v8 snapshot");
        run_step.dependOn(&run_cmd.step);
    }

    {
        // test
        const tests = b.addTest(.{
            .root_module = lightpanda_module,
            .use_llvm = true,
            .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
        });
        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_tests.step);
    }

    {
        // browser
        const exe = b.addExecutable(.{
            .name = "legacy_test",
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_legacy_test.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_c = enable_csan,
                .sanitize_thread = enable_tsan,
                .imports = &.{
                    .{ .name = "lightpanda", .module = lightpanda_module },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("legacy_test", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        // wpt
        const exe = b.addExecutable(.{
            .name = "lightpanda-wpt",
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_wpt.zig"),
                .target = target,
                .optimize = optimize,
                .sanitize_c = enable_csan,
                .sanitize_thread = enable_tsan,
                .imports = &.{
                    .{ .name = "lightpanda", .module = lightpanda_module },
                },
            }),
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("wpt", "Run WPT tests");
        run_step.dependOn(&run_cmd.step);
    }
}

fn addDependencies(b: *Build, mod: *Build.Module, opts: *Build.Step.Options, prebuilt_v8_path: ?[]const u8) !void {
    mod.addImport("build_config", opts.createModule());

    const target = mod.resolved_target.?;
    const dep_opts = .{
        .target = target,
        .optimize = mod.optimize.?,
        .prebuilt_v8_path = prebuilt_v8_path,
        .cache_root = b.pathFromRoot(".lp-cache"),
    };

    mod.addIncludePath(b.path("vendor/lightpanda"));

    {
        // html5ever

        // Build step to install html5ever dependency.
        const html5ever_argv = blk: {
            const argv: []const []const u8 = &.{
                "cargo",
                "build",
                // Seems cargo can figure out required paths out of Cargo.toml.
                "--manifest-path",
                "src/html5ever/Cargo.toml",
                // TODO: We can prefer `--artifact-dir` once it become stable.
                "--target-dir",
                b.getInstallPath(.prefix, "html5ever"),
                // This must be the last argument.
                "--release",
            };

            break :blk switch (mod.optimize.?) {
                // Prefer dev build on debug option.
                .Debug => argv[0 .. argv.len - 1],
                else => argv,
            };
        };
        const html5ever_exec_cargo = b.addSystemCommand(html5ever_argv);
        const html5ever_step = b.step("html5ever", "Install html5ever dependency (requires cargo)");
        html5ever_step.dependOn(&html5ever_exec_cargo.step);
        opts.step.dependOn(html5ever_step);

        const html5ever_obj = switch (mod.optimize.?) {
            .Debug => b.getInstallPath(.prefix, "html5ever/debug/liblitefetch_html5ever.a"),
            // Release builds.
            else => b.getInstallPath(.prefix, "html5ever/release/liblitefetch_html5ever.a"),
        };

        mod.addObjectFile(.{ .cwd_relative = html5ever_obj });
    }

    {
        // v8
        const v8_opts = b.addOptions();
        v8_opts.addOption(bool, "inspector_subtype", false);

        const v8_mod = b.dependency("v8", dep_opts).module("v8");
        v8_mod.addOptions("default_exports", v8_opts);
        mod.addImport("v8", v8_mod);
    }

    {
        //curl
        {
            const is_linux = target.result.os.tag == .linux;
            if (is_linux) {
                mod.addCMacro("HAVE_LINUX_TCP_H", "1");
                mod.addCMacro("HAVE_MSG_NOSIGNAL", "1");
                mod.addCMacro("HAVE_GETHOSTBYNAME_R", "1");
            }
            mod.addCMacro("_FILE_OFFSET_BITS", "64");
            mod.addCMacro("BUILDING_LIBCURL", "1");
            mod.addCMacro("CURL_DISABLE_AWS", "1");
            mod.addCMacro("CURL_DISABLE_DICT", "1");
            mod.addCMacro("CURL_DISABLE_DOH", "1");
            mod.addCMacro("CURL_DISABLE_FILE", "1");
            mod.addCMacro("CURL_DISABLE_FTP", "1");
            mod.addCMacro("CURL_DISABLE_GOPHER", "1");
            mod.addCMacro("CURL_DISABLE_KERBEROS", "1");
            mod.addCMacro("CURL_DISABLE_IMAP", "1");
            mod.addCMacro("CURL_DISABLE_IPFS", "1");
            mod.addCMacro("CURL_DISABLE_LDAP", "1");
            mod.addCMacro("CURL_DISABLE_LDAPS", "1");
            mod.addCMacro("CURL_DISABLE_MQTT", "1");
            mod.addCMacro("CURL_DISABLE_NTLM", "1");
            mod.addCMacro("CURL_DISABLE_PROGRESS_METER", "1");
            mod.addCMacro("CURL_DISABLE_POP3", "1");
            mod.addCMacro("CURL_DISABLE_RTSP", "1");
            mod.addCMacro("CURL_DISABLE_SMB", "1");
            mod.addCMacro("CURL_DISABLE_SMTP", "1");
            mod.addCMacro("CURL_DISABLE_TELNET", "1");
            mod.addCMacro("CURL_DISABLE_TFTP", "1");
            mod.addCMacro("CURL_EXTERN_SYMBOL", "__attribute__ ((__visibility__ (\"default\"))");
            mod.addCMacro("CURL_OS", if (is_linux) "\"Linux\"" else "\"mac\"");
            mod.addCMacro("CURL_STATICLIB", "1");
            mod.addCMacro("ENABLE_IPV6", "1");
            mod.addCMacro("HAVE_ALARM", "1");
            mod.addCMacro("HAVE_ALLOCA_H", "1");
            mod.addCMacro("HAVE_ARPA_INET_H", "1");
            mod.addCMacro("HAVE_ARPA_TFTP_H", "1");
            mod.addCMacro("HAVE_ASSERT_H", "1");
            mod.addCMacro("HAVE_BASENAME", "1");
            mod.addCMacro("HAVE_BOOL_T", "1");
            mod.addCMacro("HAVE_BROTLI", "1");
            mod.addCMacro("HAVE_BUILTIN_AVAILABLE", "1");
            mod.addCMacro("HAVE_CLOCK_GETTIME_MONOTONIC", "1");
            mod.addCMacro("HAVE_DLFCN_H", "1");
            mod.addCMacro("HAVE_ERRNO_H", "1");
            mod.addCMacro("HAVE_FCNTL", "1");
            mod.addCMacro("HAVE_FCNTL_H", "1");
            mod.addCMacro("HAVE_FCNTL_O_NONBLOCK", "1");
            mod.addCMacro("HAVE_FREEADDRINFO", "1");
            mod.addCMacro("HAVE_FSETXATTR", "1");
            mod.addCMacro("HAVE_FSETXATTR_5", "1");
            mod.addCMacro("HAVE_FTRUNCATE", "1");
            mod.addCMacro("HAVE_GETADDRINFO", "1");
            mod.addCMacro("HAVE_GETEUID", "1");
            mod.addCMacro("HAVE_GETHOSTBYNAME", "1");
            mod.addCMacro("HAVE_GETHOSTBYNAME_R_6", "1");
            mod.addCMacro("HAVE_GETHOSTNAME", "1");
            mod.addCMacro("HAVE_GETPEERNAME", "1");
            mod.addCMacro("HAVE_GETPPID", "1");
            mod.addCMacro("HAVE_GETPPID", "1");
            mod.addCMacro("HAVE_GETPROTOBYNAME", "1");
            mod.addCMacro("HAVE_GETPWUID", "1");
            mod.addCMacro("HAVE_GETPWUID_R", "1");
            mod.addCMacro("HAVE_GETRLIMIT", "1");
            mod.addCMacro("HAVE_GETSOCKNAME", "1");
            mod.addCMacro("HAVE_GETTIMEOFDAY", "1");
            mod.addCMacro("HAVE_GMTIME_R", "1");
            mod.addCMacro("HAVE_IDN2_H", "1");
            mod.addCMacro("HAVE_IF_NAMETOINDEX", "1");
            mod.addCMacro("HAVE_IFADDRS_H", "1");
            mod.addCMacro("HAVE_INET_ADDR", "1");
            mod.addCMacro("HAVE_INET_PTON", "1");
            mod.addCMacro("HAVE_INTTYPES_H", "1");
            mod.addCMacro("HAVE_IOCTL", "1");
            mod.addCMacro("HAVE_IOCTL_FIONBIO", "1");
            mod.addCMacro("HAVE_IOCTL_SIOCGIFADDR", "1");
            mod.addCMacro("HAVE_LDAP_URL_PARSE", "1");
            mod.addCMacro("HAVE_LIBGEN_H", "1");
            mod.addCMacro("HAVE_LIBZ", "1");
            mod.addCMacro("HAVE_LL", "1");
            mod.addCMacro("HAVE_LOCALE_H", "1");
            mod.addCMacro("HAVE_LOCALTIME_R", "1");
            mod.addCMacro("HAVE_LONGLONG", "1");
            mod.addCMacro("HAVE_MALLOC_H", "1");
            mod.addCMacro("HAVE_MEMORY_H", "1");
            mod.addCMacro("HAVE_NET_IF_H", "1");
            mod.addCMacro("HAVE_NETDB_H", "1");
            mod.addCMacro("HAVE_NETINET_IN_H", "1");
            mod.addCMacro("HAVE_NETINET_TCP_H", "1");
            mod.addCMacro("HAVE_PIPE", "1");
            mod.addCMacro("HAVE_POLL", "1");
            mod.addCMacro("HAVE_POLL_FINE", "1");
            mod.addCMacro("HAVE_POLL_H", "1");
            mod.addCMacro("HAVE_POSIX_STRERROR_R", "1");
            mod.addCMacro("HAVE_PTHREAD_H", "1");
            mod.addCMacro("HAVE_PWD_H", "1");
            mod.addCMacro("HAVE_RECV", "1");
            mod.addCMacro("HAVE_SA_FAMILY_T", "1");
            mod.addCMacro("HAVE_SELECT", "1");
            mod.addCMacro("HAVE_SEND", "1");
            mod.addCMacro("HAVE_SETJMP_H", "1");
            mod.addCMacro("HAVE_SETLOCALE", "1");
            mod.addCMacro("HAVE_SETRLIMIT", "1");
            mod.addCMacro("HAVE_SETSOCKOPT", "1");
            mod.addCMacro("HAVE_SIGACTION", "1");
            mod.addCMacro("HAVE_SIGINTERRUPT", "1");
            mod.addCMacro("HAVE_SIGNAL", "1");
            mod.addCMacro("HAVE_SIGNAL_H", "1");
            mod.addCMacro("HAVE_SIGSETJMP", "1");
            mod.addCMacro("HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID", "1");
            mod.addCMacro("HAVE_SOCKET", "1");
            mod.addCMacro("HAVE_STDBOOL_H", "1");
            mod.addCMacro("HAVE_STDINT_H", "1");
            mod.addCMacro("HAVE_STDIO_H", "1");
            mod.addCMacro("HAVE_STDLIB_H", "1");
            mod.addCMacro("HAVE_STRCASECMP", "1");
            mod.addCMacro("HAVE_STRDUP", "1");
            mod.addCMacro("HAVE_STRERROR_R", "1");
            mod.addCMacro("HAVE_STRING_H", "1");
            mod.addCMacro("HAVE_STRINGS_H", "1");
            mod.addCMacro("HAVE_STRSTR", "1");
            mod.addCMacro("HAVE_STRTOK_R", "1");
            mod.addCMacro("HAVE_STRTOLL", "1");
            mod.addCMacro("HAVE_STRUCT_SOCKADDR_STORAGE", "1");
            mod.addCMacro("HAVE_STRUCT_TIMEVAL", "1");
            mod.addCMacro("HAVE_SYS_IOCTL_H", "1");
            mod.addCMacro("HAVE_SYS_PARAM_H", "1");
            mod.addCMacro("HAVE_SYS_POLL_H", "1");
            mod.addCMacro("HAVE_SYS_RESOURCE_H", "1");
            mod.addCMacro("HAVE_SYS_SELECT_H", "1");
            mod.addCMacro("HAVE_SYS_SOCKET_H", "1");
            mod.addCMacro("HAVE_SYS_STAT_H", "1");
            mod.addCMacro("HAVE_SYS_TIME_H", "1");
            mod.addCMacro("HAVE_SYS_TYPES_H", "1");
            mod.addCMacro("HAVE_SYS_UIO_H", "1");
            mod.addCMacro("HAVE_SYS_UN_H", "1");
            mod.addCMacro("HAVE_TERMIO_H", "1");
            mod.addCMacro("HAVE_TERMIOS_H", "1");
            mod.addCMacro("HAVE_TIME_H", "1");
            mod.addCMacro("HAVE_UNAME", "1");
            mod.addCMacro("HAVE_UNISTD_H", "1");
            mod.addCMacro("HAVE_UTIME", "1");
            mod.addCMacro("HAVE_UTIME_H", "1");
            mod.addCMacro("HAVE_UTIMES", "1");
            mod.addCMacro("HAVE_VARIADIC_MACROS_C99", "1");
            mod.addCMacro("HAVE_VARIADIC_MACROS_GCC", "1");
            mod.addCMacro("HAVE_ZLIB_H", "1");
            mod.addCMacro("RANDOM_FILE", "\"/dev/urandom\"");
            mod.addCMacro("RECV_TYPE_ARG1", "int");
            mod.addCMacro("RECV_TYPE_ARG2", "void *");
            mod.addCMacro("RECV_TYPE_ARG3", "size_t");
            mod.addCMacro("RECV_TYPE_ARG4", "int");
            mod.addCMacro("RECV_TYPE_RETV", "ssize_t");
            mod.addCMacro("SEND_QUAL_ARG2", "const");
            mod.addCMacro("SEND_TYPE_ARG1", "int");
            mod.addCMacro("SEND_TYPE_ARG2", "void *");
            mod.addCMacro("SEND_TYPE_ARG3", "size_t");
            mod.addCMacro("SEND_TYPE_ARG4", "int");
            mod.addCMacro("SEND_TYPE_RETV", "ssize_t");
            mod.addCMacro("SIZEOF_CURL_OFF_T", "8");
            mod.addCMacro("SIZEOF_INT", "4");
            mod.addCMacro("SIZEOF_LONG", "8");
            mod.addCMacro("SIZEOF_OFF_T", "8");
            mod.addCMacro("SIZEOF_SHORT", "2");
            mod.addCMacro("SIZEOF_SIZE_T", "8");
            mod.addCMacro("SIZEOF_TIME_T", "8");
            mod.addCMacro("STDC_HEADERS", "1");
            mod.addCMacro("TIME_WITH_SYS_TIME", "1");
            mod.addCMacro("USE_NGHTTP2", "1");
            mod.addCMacro("USE_OPENSSL", "1");
            mod.addCMacro("OPENSSL_IS_BORINGSSL", "1");
            mod.addCMacro("USE_THREADS_POSIX", "1");
            mod.addCMacro("USE_UNIX_SOCKETS", "1");
        }

        try buildZlib(b, mod);
        try buildBrotli(b, mod);
        const boringssl_dep = b.dependency("boringssl-zig", .{
            .target = target,
            .optimize = mod.optimize.?,
            .force_pic = true,
        });

        const ssl = boringssl_dep.artifact("ssl");
        ssl.bundle_ubsan_rt = false;
        const crypto = boringssl_dep.artifact("crypto");
        crypto.bundle_ubsan_rt = false;

        mod.linkLibrary(ssl);
        mod.linkLibrary(crypto);
        try buildNghttp2(b, mod);
        try buildCurl(b, mod);

        switch (target.result.os.tag) {
            .macos => {
                // needed for proxying on mac
                mod.addSystemFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });
                mod.linkFramework("CoreFoundation", .{});
                mod.linkFramework("SystemConfiguration", .{});
            },
            else => {},
        }
    }
}

fn buildZlib(b: *Build, m: *Build.Module) !void {
    const zlib = b.addLibrary(.{
        .name = "zlib",
        .root_module = m,
    });

    const root = "vendor/zlib/";
    zlib.installHeader(b.path(root ++ "zlib.h"), "zlib.h");
    zlib.installHeader(b.path(root ++ "zconf.h"), "zconf.h");
    zlib.addCSourceFiles(.{ .flags = &.{
        "-DHAVE_SYS_TYPES_H",
        "-DHAVE_STDINT_H",
        "-DHAVE_STDDEF_H",
    }, .files = &.{
        root ++ "adler32.c",
        root ++ "compress.c",
        root ++ "crc32.c",
        root ++ "deflate.c",
        root ++ "gzclose.c",
        root ++ "gzlib.c",
        root ++ "gzread.c",
        root ++ "gzwrite.c",
        root ++ "inflate.c",
        root ++ "infback.c",
        root ++ "inftrees.c",
        root ++ "inffast.c",
        root ++ "trees.c",
        root ++ "uncompr.c",
        root ++ "zutil.c",
    } });
}

fn buildBrotli(b: *Build, m: *Build.Module) !void {
    const brotli = b.addLibrary(.{
        .name = "brotli",
        .root_module = m,
    });

    const root = "vendor/brotli/c/";
    brotli.addIncludePath(b.path(root ++ "include"));
    brotli.addCSourceFiles(.{ .flags = &.{}, .files = &.{
        root ++ "common/constants.c",
        root ++ "common/context.c",
        root ++ "common/dictionary.c",
        root ++ "common/platform.c",
        root ++ "common/shared_dictionary.c",
        root ++ "common/transform.c",
        root ++ "dec/bit_reader.c",
        root ++ "dec/decode.c",
        root ++ "dec/huffman.c",
        root ++ "dec/prefix.c",
        root ++ "dec/state.c",
        root ++ "dec/static_init.c",
    } });
}

fn buildNghttp2(b: *Build, m: *Build.Module) !void {
    const nghttp2 = b.addLibrary(.{
        .name = "nghttp2",
        .root_module = m,
    });

    const root = "vendor/nghttp2/";
    nghttp2.addIncludePath(b.path(root ++ "lib"));
    nghttp2.addIncludePath(b.path(root ++ "lib/includes"));
    nghttp2.addCSourceFiles(.{ .flags = &.{
        "-DNGHTTP2_STATICLIB",
        "-DHAVE_NETINET_IN",
        "-DHAVE_TIME_H",
    }, .files = &.{
        root ++ "lib/sfparse.c",
        root ++ "lib/nghttp2_alpn.c",
        root ++ "lib/nghttp2_buf.c",
        root ++ "lib/nghttp2_callbacks.c",
        root ++ "lib/nghttp2_debug.c",
        root ++ "lib/nghttp2_extpri.c",
        root ++ "lib/nghttp2_frame.c",
        root ++ "lib/nghttp2_hd.c",
        root ++ "lib/nghttp2_hd_huffman.c",
        root ++ "lib/nghttp2_hd_huffman_data.c",
        root ++ "lib/nghttp2_helper.c",
        root ++ "lib/nghttp2_http.c",
        root ++ "lib/nghttp2_map.c",
        root ++ "lib/nghttp2_mem.c",
        root ++ "lib/nghttp2_option.c",
        root ++ "lib/nghttp2_outbound_item.c",
        root ++ "lib/nghttp2_pq.c",
        root ++ "lib/nghttp2_priority_spec.c",
        root ++ "lib/nghttp2_queue.c",
        root ++ "lib/nghttp2_rcbuf.c",
        root ++ "lib/nghttp2_session.c",
        root ++ "lib/nghttp2_stream.c",
        root ++ "lib/nghttp2_submit.c",
        root ++ "lib/nghttp2_version.c",
        root ++ "lib/nghttp2_ratelim.c",
        root ++ "lib/nghttp2_time.c",
    } });
}

fn buildCurl(b: *Build, m: *Build.Module) !void {
    const curl = b.addLibrary(.{
        .name = "curl",
        .root_module = m,
    });

    const root = "vendor/curl/";

    curl.addIncludePath(b.path(root ++ "lib"));
    curl.addIncludePath(b.path(root ++ "include"));
    curl.addIncludePath(b.path("vendor/zlib"));

    curl.addCSourceFiles(.{
        .flags = &.{},
        .files = &.{
            root ++ "lib/altsvc.c",
            root ++ "lib/amigaos.c",
            root ++ "lib/asyn-ares.c",
            root ++ "lib/asyn-base.c",
            root ++ "lib/asyn-thrdd.c",
            root ++ "lib/bufq.c",
            root ++ "lib/bufref.c",
            root ++ "lib/cf-h1-proxy.c",
            root ++ "lib/cf-h2-proxy.c",
            root ++ "lib/cf-haproxy.c",
            root ++ "lib/cf-https-connect.c",
            root ++ "lib/cf-socket.c",
            root ++ "lib/cfilters.c",
            root ++ "lib/conncache.c",
            root ++ "lib/connect.c",
            root ++ "lib/content_encoding.c",
            root ++ "lib/cookie.c",
            root ++ "lib/cshutdn.c",
            root ++ "lib/curl_addrinfo.c",
            root ++ "lib/curl_des.c",
            root ++ "lib/curl_endian.c",
            root ++ "lib/curl_fnmatch.c",
            root ++ "lib/curl_get_line.c",
            root ++ "lib/curl_gethostname.c",
            root ++ "lib/curl_gssapi.c",
            root ++ "lib/curl_memrchr.c",
            root ++ "lib/curl_ntlm_core.c",
            root ++ "lib/curl_range.c",
            root ++ "lib/curl_rtmp.c",
            root ++ "lib/curl_sasl.c",
            root ++ "lib/curl_sha512_256.c",
            root ++ "lib/curl_sspi.c",
            root ++ "lib/curl_threads.c",
            root ++ "lib/curl_trc.c",
            root ++ "lib/cw-out.c",
            root ++ "lib/cw-pause.c",
            root ++ "lib/dict.c",
            root ++ "lib/doh.c",
            root ++ "lib/dynhds.c",
            root ++ "lib/easy.c",
            root ++ "lib/easygetopt.c",
            root ++ "lib/easyoptions.c",
            root ++ "lib/escape.c",
            root ++ "lib/fake_addrinfo.c",
            root ++ "lib/file.c",
            root ++ "lib/fileinfo.c",
            root ++ "lib/fopen.c",
            root ++ "lib/formdata.c",
            root ++ "lib/ftp.c",
            root ++ "lib/ftplistparser.c",
            root ++ "lib/getenv.c",
            root ++ "lib/getinfo.c",
            root ++ "lib/gopher.c",
            root ++ "lib/hash.c",
            root ++ "lib/headers.c",
            root ++ "lib/hmac.c",
            root ++ "lib/hostip.c",
            root ++ "lib/hostip4.c",
            root ++ "lib/hostip6.c",
            root ++ "lib/hsts.c",
            root ++ "lib/http.c",
            root ++ "lib/http1.c",
            root ++ "lib/http2.c",
            root ++ "lib/http_aws_sigv4.c",
            root ++ "lib/http_chunks.c",
            root ++ "lib/http_digest.c",
            root ++ "lib/http_negotiate.c",
            root ++ "lib/http_ntlm.c",
            root ++ "lib/http_proxy.c",
            root ++ "lib/httpsrr.c",
            root ++ "lib/idn.c",
            root ++ "lib/if2ip.c",
            root ++ "lib/imap.c",
            root ++ "lib/krb5.c",
            root ++ "lib/ldap.c",
            root ++ "lib/llist.c",
            root ++ "lib/macos.c",
            root ++ "lib/md4.c",
            root ++ "lib/md5.c",
            root ++ "lib/memdebug.c",
            root ++ "lib/mime.c",
            root ++ "lib/mprintf.c",
            root ++ "lib/mqtt.c",
            root ++ "lib/multi.c",
            root ++ "lib/multi_ev.c",
            root ++ "lib/netrc.c",
            root ++ "lib/noproxy.c",
            root ++ "lib/openldap.c",
            root ++ "lib/parsedate.c",
            root ++ "lib/pingpong.c",
            root ++ "lib/pop3.c",
            root ++ "lib/progress.c",
            root ++ "lib/psl.c",
            root ++ "lib/rand.c",
            root ++ "lib/rename.c",
            root ++ "lib/request.c",
            root ++ "lib/rtsp.c",
            root ++ "lib/select.c",
            root ++ "lib/sendf.c",
            root ++ "lib/setopt.c",
            root ++ "lib/sha256.c",
            root ++ "lib/share.c",
            root ++ "lib/slist.c",
            root ++ "lib/smb.c",
            root ++ "lib/smtp.c",
            root ++ "lib/socketpair.c",
            root ++ "lib/socks.c",
            root ++ "lib/socks_gssapi.c",
            root ++ "lib/socks_sspi.c",
            root ++ "lib/speedcheck.c",
            root ++ "lib/splay.c",
            root ++ "lib/strcase.c",
            root ++ "lib/strdup.c",
            root ++ "lib/strequal.c",
            root ++ "lib/strerror.c",
            root ++ "lib/system_win32.c",
            root ++ "lib/telnet.c",
            root ++ "lib/tftp.c",
            root ++ "lib/transfer.c",
            root ++ "lib/uint-bset.c",
            root ++ "lib/uint-hash.c",
            root ++ "lib/uint-spbset.c",
            root ++ "lib/uint-table.c",
            root ++ "lib/url.c",
            root ++ "lib/urlapi.c",
            root ++ "lib/version.c",
            root ++ "lib/ws.c",
            root ++ "lib/curlx/base64.c",
            root ++ "lib/curlx/dynbuf.c",
            root ++ "lib/curlx/inet_ntop.c",
            root ++ "lib/curlx/nonblock.c",
            root ++ "lib/curlx/strparse.c",
            root ++ "lib/curlx/timediff.c",
            root ++ "lib/curlx/timeval.c",
            root ++ "lib/curlx/wait.c",
            root ++ "lib/curlx/warnless.c",
            root ++ "lib/vquic/curl_ngtcp2.c",
            root ++ "lib/vquic/curl_osslq.c",
            root ++ "lib/vquic/curl_quiche.c",
            root ++ "lib/vquic/vquic.c",
            root ++ "lib/vquic/vquic-tls.c",
            root ++ "lib/vauth/cleartext.c",
            root ++ "lib/vauth/cram.c",
            root ++ "lib/vauth/digest.c",
            root ++ "lib/vauth/digest_sspi.c",
            root ++ "lib/vauth/gsasl.c",
            root ++ "lib/vauth/krb5_gssapi.c",
            root ++ "lib/vauth/krb5_sspi.c",
            root ++ "lib/vauth/ntlm.c",
            root ++ "lib/vauth/ntlm_sspi.c",
            root ++ "lib/vauth/oauth2.c",
            root ++ "lib/vauth/spnego_gssapi.c",
            root ++ "lib/vauth/spnego_sspi.c",
            root ++ "lib/vauth/vauth.c",
            root ++ "lib/vtls/cipher_suite.c",
            root ++ "lib/vtls/openssl.c",
            root ++ "lib/vtls/hostcheck.c",
            root ++ "lib/vtls/keylog.c",
            root ++ "lib/vtls/vtls.c",
            root ++ "lib/vtls/vtls_scache.c",
            root ++ "lib/vtls/x509asn1.c",
        },
    });
}

const Manifest = struct {
    version: []const u8,
    minimum_zig_version: []const u8,

    fn init(b: *std.Build) Manifest {
        const input = @embedFile("build.zig.zon");

        var diagnostics: std.zon.parse.Diagnostics = .{};
        defer diagnostics.deinit(b.allocator);

        return std.zon.parse.fromSlice(Manifest, b.allocator, input, &diagnostics, .{
            .free_on_error = true,
            .ignore_unknown_fields = true,
        }) catch |err| {
            switch (err) {
                error.OutOfMemory => @panic("OOM"),
                error.ParseZon => {
                    std.debug.print("Parse diagnostics:\n{f}\n", .{diagnostics});
                    std.process.exit(1);
                },
            }
        };
    }
};
