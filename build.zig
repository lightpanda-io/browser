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

    const enable_tsan = b.option(bool, "tsan", "Enable Thread Sanitizer") orelse false;
    const enable_asan = b.option(bool, "asan", "Enable Address Sanitizer") orelse false;
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

        try addDependencies(b, mod, opts, enable_asan, enable_tsan, prebuilt_v8_path);

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

fn addDependencies(
    b: *Build,
    mod: *Build.Module,
    opts: *Build.Step.Options,
    is_asan: bool,
    is_tsan: bool,
    prebuilt_v8_path: ?[]const u8,
) !void {
    mod.addImport("build_config", opts.createModule());

    const target = mod.resolved_target.?;
    const dep_opts = .{
        .target = target,
        .optimize = mod.optimize.?,
        .cache_root = b.pathFromRoot(".lp-cache"),
        .prebuilt_v8_path = prebuilt_v8_path,
        .is_asan = is_asan,
        .is_tsan = is_tsan,
        .v8_enable_sandbox = is_tsan,
    };

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
        try buildZlib(b, mod);
        try buildBrotli(b, mod);
        try buildBoringSsl(b, mod);
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
    const dep = b.dependency("zlib", .{});

    const lib = b.addLibrary(.{ .name = "z", .root_module = m });

    lib.installHeadersDirectory(dep.path(""), "", .{});
    lib.addCSourceFiles(.{
        .root = dep.path(""),
        .flags = &.{
            "-DHAVE_SYS_TYPES_H",
            "-DHAVE_STDINT_H",
            "-DHAVE_STDDEF_H",
        },
        .files = &.{
            "adler32.c", "compress.c", "crc32.c",
            "deflate.c", "gzclose.c",  "gzlib.c",
            "gzread.c",  "gzwrite.c",  "infback.c",
            "inffast.c", "inflate.c",  "inftrees.c",
            "trees.c",   "uncompr.c",  "zutil.c",
        },
    });
}

fn buildBrotli(b: *Build, m: *Build.Module) !void {
    const dep = b.dependency("brotli", .{});

    const brotlicmn = b.addLibrary(.{ .name = "brotlicommon", .root_module = m });
    const brotlidec = b.addLibrary(.{ .name = "brotlidec", .root_module = m });
    const brotlienc = b.addLibrary(.{ .name = "brotlienc", .root_module = m });

    brotlicmn.addIncludePath(dep.path("c/include"));

    brotlicmn.addIncludePath(dep.path("c/include"));
    brotlidec.addIncludePath(dep.path("c/include"));
    brotlienc.addIncludePath(dep.path("c/include"));

    brotlicmn.addCSourceFiles(.{
        .root = dep.path("c/common"),
        .files = &.{
            "transform.c",  "shared_dictionary.c", "platform.c",
            "dictionary.c", "context.c",           "constants.c",
        },
    });
    brotlidec.addCSourceFiles(.{
        .root = dep.path("c/dec"),
        .files = &.{
            "bit_reader.c", "decode.c", "huffman.c",
            "prefix.c",     "state.c",  "static_init.c",
        },
    });
    brotlienc.addCSourceFiles(.{
        .root = dep.path("c/enc"),
        .files = &.{
            "backward_references.c",        "backward_references_hq.c", "bit_cost.c",
            "block_splitter.c",             "brotli_bit_stream.c",      "cluster.c",
            "command.c",                    "compound_dictionary.c",    "compress_fragment.c",
            "compress_fragment_two_pass.c", "dictionary_hash.c",        "encode.c",
            "encoder_dict.c",               "entropy_encode.c",         "fast_log.c",
            "histogram.c",                  "literal_cost.c",           "memory.c",
            "metablock.c",                  "static_dict.c",            "static_dict_lut.c",
            "static_init.c",                "utf8_util.c",
        },
    });
}

fn buildBoringSsl(b: *Build, m: *Build.Module) !void {
    const boringssl_dep = b.dependency("boringssl-zig", .{
        .force_pic = true,
        .optimize = m.optimize.?,
    });

    const ssl = boringssl_dep.artifact("ssl");
    ssl.bundle_ubsan_rt = false;

    const crypto = boringssl_dep.artifact("crypto");
    crypto.bundle_ubsan_rt = false;

    m.linkLibrary(ssl);
    m.linkLibrary(crypto);
}

fn buildNghttp2(b: *Build, m: *Build.Module) !void {
    const dep = b.dependency("nghttp2", .{});
    const lib = b.addLibrary(.{ .name = "nghttp2", .root_module = m });

    const config = b.addConfigHeader(.{
        .include_path = "nghttp2ver.h",
        .style = .{ .cmake = dep.path("lib/includes/nghttp2/nghttp2ver.h.in") },
    }, .{
        .PACKAGE_VERSION = "1.68.90",
        .PACKAGE_VERSION_NUM = 0x016890,
    });
    lib.addConfigHeader(config);

    lib.addIncludePath(dep.path("lib/includes"));
    lib.addCSourceFiles(.{
        .root = dep.path("lib"),
        .flags = &.{
            "-DNGHTTP2_STATICLIB",
            "-DHAVE_NETINET_IN",
            "-DHAVE_TIME_H",
        },
        .files = &.{
            "sfparse.c",                 "nghttp2_alpn.c",   "nghttp2_buf.c",
            "nghttp2_callbacks.c",       "nghttp2_debug.c",  "nghttp2_extpri.c",
            "nghttp2_frame.c",           "nghttp2_hd.c",     "nghttp2_hd_huffman.c",
            "nghttp2_hd_huffman_data.c", "nghttp2_helper.c", "nghttp2_http.c",
            "nghttp2_map.c",             "nghttp2_mem.c",    "nghttp2_option.c",
            "nghttp2_outbound_item.c",   "nghttp2_pq.c",     "nghttp2_priority_spec.c",
            "nghttp2_queue.c",           "nghttp2_rcbuf.c",  "nghttp2_session.c",
            "nghttp2_stream.c",          "nghttp2_submit.c", "nghttp2_version.c",
            "nghttp2_ratelim.c",         "nghttp2_time.c",
        },
    });
}

fn buildCurl(b: *Build, m: *Build.Module) !void {
    const target = m.resolved_target.?;

    const dep = b.dependency("curl", .{});
    const curl = b.addLibrary(.{ .name = "curl", .root_module = m });

    curl.addIncludePath(dep.path("lib"));
    curl.addIncludePath(dep.path("include"));

    const is_linux = target.result.os.tag == .linux;
    if (is_linux) {
        m.addCMacro("HAVE_LINUX_TCP_H", "1");
        m.addCMacro("HAVE_MSG_NOSIGNAL", "1");
        m.addCMacro("HAVE_GETHOSTBYNAME_R", "1");
    }
    m.addCMacro("_FILE_OFFSET_BITS", "64");
    m.addCMacro("BUILDING_LIBCURL", "1");
    m.addCMacro("CURL_DISABLE_AWS", "1");
    m.addCMacro("CURL_DISABLE_DICT", "1");
    m.addCMacro("CURL_DISABLE_DOH", "1");
    m.addCMacro("CURL_DISABLE_FILE", "1");
    m.addCMacro("CURL_DISABLE_FTP", "1");
    m.addCMacro("CURL_DISABLE_GOPHER", "1");
    m.addCMacro("CURL_DISABLE_KERBEROS", "1");
    m.addCMacro("CURL_DISABLE_IMAP", "1");
    m.addCMacro("CURL_DISABLE_IPFS", "1");
    m.addCMacro("CURL_DISABLE_LDAP", "1");
    m.addCMacro("CURL_DISABLE_LDAPS", "1");
    m.addCMacro("CURL_DISABLE_MQTT", "1");
    m.addCMacro("CURL_DISABLE_NTLM", "1");
    m.addCMacro("CURL_DISABLE_PROGRESS_METER", "1");
    m.addCMacro("CURL_DISABLE_POP3", "1");
    m.addCMacro("CURL_DISABLE_RTSP", "1");
    m.addCMacro("CURL_DISABLE_SMB", "1");
    m.addCMacro("CURL_DISABLE_SMTP", "1");
    m.addCMacro("CURL_DISABLE_TELNET", "1");
    m.addCMacro("CURL_DISABLE_TFTP", "1");
    m.addCMacro("CURL_EXTERN_SYMBOL", "__attribute__ ((__visibility__ (\"default\"))");
    m.addCMacro("CURL_OS", if (is_linux) "\"Linux\"" else "\"mac\"");
    m.addCMacro("CURL_STATICLIB", "1");
    m.addCMacro("ENABLE_IPV6", "1");
    m.addCMacro("HAVE_ALARM", "1");
    m.addCMacro("HAVE_ALLOCA_H", "1");
    m.addCMacro("HAVE_ARPA_INET_H", "1");
    m.addCMacro("HAVE_ARPA_TFTP_H", "1");
    m.addCMacro("HAVE_ASSERT_H", "1");
    m.addCMacro("HAVE_BASENAME", "1");
    m.addCMacro("HAVE_BOOL_T", "1");
    m.addCMacro("HAVE_BROTLI", "1");
    m.addCMacro("HAVE_BUILTIN_AVAILABLE", "1");
    m.addCMacro("HAVE_CLOCK_GETTIME_MONOTONIC", "1");
    m.addCMacro("HAVE_DLFCN_H", "1");
    m.addCMacro("HAVE_ERRNO_H", "1");
    m.addCMacro("HAVE_FCNTL", "1");
    m.addCMacro("HAVE_FCNTL_H", "1");
    m.addCMacro("HAVE_FCNTL_O_NONBLOCK", "1");
    m.addCMacro("HAVE_FREEADDRINFO", "1");
    m.addCMacro("HAVE_FSETXATTR", "1");
    m.addCMacro("HAVE_FSETXATTR_5", "1");
    m.addCMacro("HAVE_FTRUNCATE", "1");
    m.addCMacro("HAVE_GETADDRINFO", "1");
    m.addCMacro("HAVE_GETEUID", "1");
    m.addCMacro("HAVE_GETHOSTBYNAME", "1");
    m.addCMacro("HAVE_GETHOSTBYNAME_R_6", "1");
    m.addCMacro("HAVE_GETHOSTNAME", "1");
    m.addCMacro("HAVE_GETPEERNAME", "1");
    m.addCMacro("HAVE_GETPPID", "1");
    m.addCMacro("HAVE_GETPPID", "1");
    m.addCMacro("HAVE_GETPROTOBYNAME", "1");
    m.addCMacro("HAVE_GETPWUID", "1");
    m.addCMacro("HAVE_GETPWUID_R", "1");
    m.addCMacro("HAVE_GETRLIMIT", "1");
    m.addCMacro("HAVE_GETSOCKNAME", "1");
    m.addCMacro("HAVE_GETTIMEOFDAY", "1");
    m.addCMacro("HAVE_GMTIME_R", "1");
    m.addCMacro("HAVE_IDN2_H", "1");
    m.addCMacro("HAVE_IF_NAMETOINDEX", "1");
    m.addCMacro("HAVE_IFADDRS_H", "1");
    m.addCMacro("HAVE_INET_ADDR", "1");
    m.addCMacro("HAVE_INET_PTON", "1");
    m.addCMacro("HAVE_INTTYPES_H", "1");
    m.addCMacro("HAVE_IOCTL", "1");
    m.addCMacro("HAVE_IOCTL_FIONBIO", "1");
    m.addCMacro("HAVE_IOCTL_SIOCGIFADDR", "1");
    m.addCMacro("HAVE_LDAP_URL_PARSE", "1");
    m.addCMacro("HAVE_LIBGEN_H", "1");
    m.addCMacro("HAVE_LIBZ", "1");
    m.addCMacro("HAVE_LL", "1");
    m.addCMacro("HAVE_LOCALE_H", "1");
    m.addCMacro("HAVE_LOCALTIME_R", "1");
    m.addCMacro("HAVE_LONGLONG", "1");
    m.addCMacro("HAVE_MALLOC_H", "1");
    m.addCMacro("HAVE_MEMORY_H", "1");
    m.addCMacro("HAVE_NET_IF_H", "1");
    m.addCMacro("HAVE_NETDB_H", "1");
    m.addCMacro("HAVE_NETINET_IN_H", "1");
    m.addCMacro("HAVE_NETINET_TCP_H", "1");
    m.addCMacro("HAVE_PIPE", "1");
    m.addCMacro("HAVE_POLL", "1");
    m.addCMacro("HAVE_POLL_FINE", "1");
    m.addCMacro("HAVE_POLL_H", "1");
    m.addCMacro("HAVE_POSIX_STRERROR_R", "1");
    m.addCMacro("HAVE_PTHREAD_H", "1");
    m.addCMacro("HAVE_PWD_H", "1");
    m.addCMacro("HAVE_RECV", "1");
    m.addCMacro("HAVE_SA_FAMILY_T", "1");
    m.addCMacro("HAVE_SELECT", "1");
    m.addCMacro("HAVE_SEND", "1");
    m.addCMacro("HAVE_SETJMP_H", "1");
    m.addCMacro("HAVE_SETLOCALE", "1");
    m.addCMacro("HAVE_SETRLIMIT", "1");
    m.addCMacro("HAVE_SETSOCKOPT", "1");
    m.addCMacro("HAVE_SIGACTION", "1");
    m.addCMacro("HAVE_SIGINTERRUPT", "1");
    m.addCMacro("HAVE_SIGNAL", "1");
    m.addCMacro("HAVE_SIGNAL_H", "1");
    m.addCMacro("HAVE_SIGSETJMP", "1");
    m.addCMacro("HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID", "1");
    m.addCMacro("HAVE_SOCKET", "1");
    m.addCMacro("HAVE_STDBOOL_H", "1");
    m.addCMacro("HAVE_STDINT_H", "1");
    m.addCMacro("HAVE_STDIO_H", "1");
    m.addCMacro("HAVE_STDLIB_H", "1");
    m.addCMacro("HAVE_STRCASECMP", "1");
    m.addCMacro("HAVE_STRDUP", "1");
    m.addCMacro("HAVE_STRERROR_R", "1");
    m.addCMacro("HAVE_STRING_H", "1");
    m.addCMacro("HAVE_STRINGS_H", "1");
    m.addCMacro("HAVE_STRSTR", "1");
    m.addCMacro("HAVE_STRTOK_R", "1");
    m.addCMacro("HAVE_STRTOLL", "1");
    m.addCMacro("HAVE_STRUCT_SOCKADDR_STORAGE", "1");
    m.addCMacro("HAVE_STRUCT_TIMEVAL", "1");
    m.addCMacro("HAVE_SYS_IOCTL_H", "1");
    m.addCMacro("HAVE_SYS_PARAM_H", "1");
    m.addCMacro("HAVE_SYS_POLL_H", "1");
    m.addCMacro("HAVE_SYS_RESOURCE_H", "1");
    m.addCMacro("HAVE_SYS_SELECT_H", "1");
    m.addCMacro("HAVE_SYS_SOCKET_H", "1");
    m.addCMacro("HAVE_SYS_STAT_H", "1");
    m.addCMacro("HAVE_SYS_TIME_H", "1");
    m.addCMacro("HAVE_SYS_TYPES_H", "1");
    m.addCMacro("HAVE_SYS_UIO_H", "1");
    m.addCMacro("HAVE_SYS_UN_H", "1");
    m.addCMacro("HAVE_TERMIO_H", "1");
    m.addCMacro("HAVE_TERMIOS_H", "1");
    m.addCMacro("HAVE_TIME_H", "1");
    m.addCMacro("HAVE_UNAME", "1");
    m.addCMacro("HAVE_UNISTD_H", "1");
    m.addCMacro("HAVE_UTIME", "1");
    m.addCMacro("HAVE_UTIME_H", "1");
    m.addCMacro("HAVE_UTIMES", "1");
    m.addCMacro("HAVE_VARIADIC_MACROS_C99", "1");
    m.addCMacro("HAVE_VARIADIC_MACROS_GCC", "1");
    m.addCMacro("HAVE_ZLIB_H", "1");
    m.addCMacro("RANDOM_FILE", "\"/dev/urandom\"");
    m.addCMacro("RECV_TYPE_ARG1", "int");
    m.addCMacro("RECV_TYPE_ARG2", "void *");
    m.addCMacro("RECV_TYPE_ARG3", "size_t");
    m.addCMacro("RECV_TYPE_ARG4", "int");
    m.addCMacro("RECV_TYPE_RETV", "ssize_t");
    m.addCMacro("SEND_QUAL_ARG2", "const");
    m.addCMacro("SEND_TYPE_ARG1", "int");
    m.addCMacro("SEND_TYPE_ARG2", "void *");
    m.addCMacro("SEND_TYPE_ARG3", "size_t");
    m.addCMacro("SEND_TYPE_ARG4", "int");
    m.addCMacro("SEND_TYPE_RETV", "ssize_t");
    m.addCMacro("SIZEOF_CURL_OFF_T", "8");
    m.addCMacro("SIZEOF_INT", "4");
    m.addCMacro("SIZEOF_LONG", "8");
    m.addCMacro("SIZEOF_OFF_T", "8");
    m.addCMacro("SIZEOF_SHORT", "2");
    m.addCMacro("SIZEOF_SIZE_T", "8");
    m.addCMacro("SIZEOF_TIME_T", "8");
    m.addCMacro("STDC_HEADERS", "1");
    m.addCMacro("TIME_WITH_SYS_TIME", "1");
    m.addCMacro("USE_NGHTTP2", "1");
    m.addCMacro("USE_OPENSSL", "1");
    m.addCMacro("OPENSSL_IS_BORINGSSL", "1");
    m.addCMacro("USE_THREADS_POSIX", "1");
    m.addCMacro("USE_UNIX_SOCKETS", "1");

    curl.addCSourceFiles(.{
        .root = dep.path("lib"),
        .flags = &.{},
        .files = &.{
            // You can include all files from lib, libcurl uses an #ifdef-guards to exclude code for disabled functions
            "altsvc.c",              "amigaos.c",           "asyn-ares.c",
            "asyn-base.c",           "asyn-thrdd.c",        "bufq.c",
            "bufref.c",              "cf-h1-proxy.c",       "cf-h2-proxy.c",
            "cf-haproxy.c",          "cf-https-connect.c",  "cf-socket.c",
            "cfilters.c",            "conncache.c",         "connect.c",
            "content_encoding.c",    "cookie.c",            "cshutdn.c",
            "curl_addrinfo.c",       "curl_des.c",          "curl_endian.c",
            "curl_fnmatch.c",        "curl_get_line.c",     "curl_gethostname.c",
            "curl_gssapi.c",         "curl_memrchr.c",      "curl_ntlm_core.c",
            "curl_range.c",          "curl_rtmp.c",         "curl_sasl.c",
            "curl_sha512_256.c",     "curl_sspi.c",         "curl_threads.c",
            "curl_trc.c",            "curlx/base64.c",      "curlx/dynbuf.c",
            "curlx/inet_ntop.c",     "curlx/nonblock.c",    "curlx/strparse.c",
            "curlx/timediff.c",      "curlx/timeval.c",     "curlx/wait.c",
            "curlx/warnless.c",      "cw-out.c",            "cw-pause.c",
            "dict.c",                "doh.c",               "dynhds.c",
            "easy.c",                "easygetopt.c",        "easyoptions.c",
            "escape.c",              "fake_addrinfo.c",     "file.c",
            "fileinfo.c",            "fopen.c",             "formdata.c",
            "ftp.c",                 "ftplistparser.c",     "getenv.c",
            "getinfo.c",             "gopher.c",            "hash.c",
            "headers.c",             "hmac.c",              "hostip.c",
            "hostip4.c",             "hostip6.c",           "hsts.c",
            "http.c",                "http1.c",             "http2.c",
            "http_aws_sigv4.c",      "http_chunks.c",       "http_digest.c",
            "http_negotiate.c",      "http_ntlm.c",         "http_proxy.c",
            "httpsrr.c",             "idn.c",               "if2ip.c",
            "imap.c",                "krb5.c",              "ldap.c",
            "llist.c",               "macos.c",             "md4.c",
            "md5.c",                 "memdebug.c",          "mime.c",
            "mprintf.c",             "mqtt.c",              "multi.c",
            "multi_ev.c",            "netrc.c",             "noproxy.c",
            "openldap.c",            "parsedate.c",         "pingpong.c",
            "pop3.c",                "progress.c",          "psl.c",
            "rand.c",                "rename.c",            "request.c",
            "rtsp.c",                "select.c",            "sendf.c",
            "setopt.c",              "sha256.c",            "share.c",
            "slist.c",               "smb.c",               "smtp.c",
            "socketpair.c",          "socks.c",             "socks_gssapi.c",
            "socks_sspi.c",          "speedcheck.c",        "splay.c",
            "strcase.c",             "strdup.c",            "strequal.c",
            "strerror.c",            "system_win32.c",      "telnet.c",
            "tftp.c",                "transfer.c",          "uint-bset.c",
            "uint-hash.c",           "uint-spbset.c",       "uint-table.c",
            "url.c",                 "urlapi.c",            "vauth/cleartext.c",
            "vauth/cram.c",          "vauth/digest.c",      "vauth/digest_sspi.c",
            "vauth/gsasl.c",         "vauth/krb5_gssapi.c", "vauth/krb5_sspi.c",
            "vauth/ntlm.c",          "vauth/ntlm_sspi.c",   "vauth/oauth2.c",
            "vauth/spnego_gssapi.c", "vauth/spnego_sspi.c", "vauth/vauth.c",
            "version.c",             "vquic/curl_ngtcp2.c", "vquic/curl_osslq.c",
            "vquic/curl_quiche.c",   "vquic/vquic-tls.c",   "vquic/vquic.c",
            "vtls/cipher_suite.c",   "vtls/hostcheck.c",    "vtls/keylog.c",
            "vtls/openssl.c",        "vtls/vtls.c",         "vtls/vtls_scache.c",
            "vtls/x509asn1.c",       "ws.c",
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
