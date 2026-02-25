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
        mod.addImport("build_config", opts.createModule());

        try linkV8(b, mod, enable_asan, enable_tsan, prebuilt_v8_path);
        try linkCurl(b, mod);
        try linkHtml5Ever(b, mod);

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

fn linkV8(
    b: *Build,
    mod: *Build.Module,
    is_asan: bool,
    is_tsan: bool,
    prebuilt_v8_path: ?[]const u8,
) !void {
    const target = mod.resolved_target.?;

    const dep = b.dependency("v8", .{
        .target = target,
        .optimize = mod.optimize.?,
        .is_asan = is_asan,
        .is_tsan = is_tsan,
        .inspector_subtype = false,
        .v8_enable_sandbox = is_tsan,
        .cache_root = b.pathFromRoot(".lp-cache"),
        .prebuilt_v8_path = prebuilt_v8_path,
    });
    mod.addImport("v8", dep.module("v8"));
}

fn linkHtml5Ever(b: *Build, mod: *Build.Module) !void {
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

    const html5ever_obj = switch (mod.optimize.?) {
        .Debug => b.getInstallPath(.prefix, "html5ever/debug/liblitefetch_html5ever.a"),
        // Release builds.
        else => b.getInstallPath(.prefix, "html5ever/release/liblitefetch_html5ever.a"),
    };

    mod.addObjectFile(.{ .cwd_relative = html5ever_obj });
}

fn linkCurl(b: *Build, mod: *Build.Module) !void {
    const target = mod.resolved_target.?;

    const curl = buildCurl(b, target, mod.optimize.?);
    mod.linkLibrary(curl);

    const zlib = buildZlib(b, target, mod.optimize.?);
    curl.root_module.linkLibrary(zlib);

    const brotli = buildBrotli(b, target, mod.optimize.?);
    for (brotli) |lib| curl.root_module.linkLibrary(lib);

    const nghttp2 = buildNghttp2(b, target, mod.optimize.?);
    curl.root_module.linkLibrary(nghttp2);

    const boringssl = buildBoringSsl(b, target, mod.optimize.?);
    for (boringssl) |lib| curl.root_module.linkLibrary(lib);

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

fn buildZlib(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Step.Compile {
    const dep = b.dependency("zlib", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{ .name = "z", .root_module = mod });
    lib.installHeadersDirectory(dep.path(""), "", .{});
    lib.addCSourceFiles(.{
        .root = dep.path(""),
        .flags = &.{
            "-DHAVE_SYS_TYPES_H",
            "-DHAVE_STDINT_H",
            "-DHAVE_STDDEF_H",
            "-DHAVE_UNISTD_H",
        },
        .files = &.{
            "adler32.c", "compress.c", "crc32.c",
            "deflate.c", "gzclose.c",  "gzlib.c",
            "gzread.c",  "gzwrite.c",  "infback.c",
            "inffast.c", "inflate.c",  "inftrees.c",
            "trees.c",   "uncompr.c",  "zutil.c",
        },
    });

    return lib;
}

fn buildBrotli(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) [3]*Build.Step.Compile {
    const dep = b.dependency("brotli", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(dep.path("c/include"));

    const brotlicmn = b.addLibrary(.{ .name = "brotlicommon", .root_module = mod });
    const brotlidec = b.addLibrary(.{ .name = "brotlidec", .root_module = mod });
    const brotlienc = b.addLibrary(.{ .name = "brotlienc", .root_module = mod });

    brotlicmn.installHeadersDirectory(dep.path("c/include/brotli"), "brotli", .{});
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

    return .{ brotlicmn, brotlidec, brotlienc };
}

fn buildBoringSsl(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) [2]*Build.Step.Compile {
    const dep = b.dependency("boringssl-zig", .{
        .target = target,
        .optimize = optimize,
        .force_pic = true,
    });

    const ssl = dep.artifact("ssl");
    ssl.bundle_ubsan_rt = false;

    const crypto = dep.artifact("crypto");
    crypto.bundle_ubsan_rt = false;

    return .{ ssl, crypto };
}

fn buildNghttp2(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Build.Step.Compile {
    const dep = b.dependency("nghttp2", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(dep.path("lib/includes"));

    const config = b.addConfigHeader(.{
        .include_path = "nghttp2ver.h",
        .style = .{ .cmake = dep.path("lib/includes/nghttp2/nghttp2ver.h.in") },
    }, .{
        .PACKAGE_VERSION = "1.68.90",
        .PACKAGE_VERSION_NUM = 0x016890,
    });
    mod.addConfigHeader(config);

    const lib = b.addLibrary(.{ .name = "nghttp2", .root_module = mod });

    lib.installConfigHeader(config);
    lib.installHeadersDirectory(dep.path("lib/includes/nghttp2"), "nghttp2", .{});
    lib.addCSourceFiles(.{
        .root = dep.path("lib"),
        .flags = &.{
            "-DNGHTTP2_STATICLIB",
            "-DHAVE_TIME_H",
            "-DHAVE_ARPA_INET_H",
            "-DHAVE_NETINET_IN_H",
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

    return lib;
}

fn buildCurl(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Build.Step.Compile {
    const dep = b.dependency("curl", .{});

    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(dep.path("lib"));
    mod.addIncludePath(dep.path("include"));

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

    const lib = b.addLibrary(.{ .name = "curl", .root_module = mod });
    lib.addCSourceFiles(.{
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

    lib.installHeadersDirectory(dep.path("include/curl"), "curl", .{});
    return lib;
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
