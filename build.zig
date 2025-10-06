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
const builtin = @import("builtin");

const Build = std.Build;

/// Do not rename this constant. It is scanned by some scripts to determine
/// which zig version to install.
const recommended_zig_version = "0.15.1";

pub fn build(b: *Build) !void {
    switch (comptime builtin.zig_version.order(std.SemanticVersion.parse(recommended_zig_version) catch unreachable)) {
        .eq => {},
        .lt => {
            @compileError("The minimum version of Zig required to compile is '" ++ recommended_zig_version ++ "', found '" ++ builtin.zig_version_string ++ "'.");
        },
        .gt => {
            std.debug.print(
                "WARNING: Recommended Zig version '{s}', but found '{s}', build may fail...\n\n",
                .{ recommended_zig_version, builtin.zig_version_string },
            );
        },
    }

    var opts = b.addOptions();
    opts.addOption(
        []const u8,
        "git_commit",
        b.option([]const u8, "git_commit", "Current git commit") orelse "dev",
    );

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // We're still using llvm because the new x86 backend seems to crash
    // with v8. This can be reproduced in zig-v8-fork.

    const lightpanda_module = b.addModule("lightpanda", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    try addDependencies(b, lightpanda_module, opts);

    {
        // browser
        // -------

        // compile and install
        const exe = b.addExecutable(.{
            .name = "lightpanda",
            .use_llvm = true,
            .root_module = lightpanda_module,
        });
        b.installArtifact(exe);

        // run
        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        // step
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    {
        // tests
        // ----

        // compile
        const tests = b.addTest(.{
            .root_module = lightpanda_module,
            .use_llvm = true,
            .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
        });

        const run_tests = b.addRunArtifact(tests);
        if (b.args) |args| {
            run_tests.addArgs(args);
        }

        // step
        const tests_step = b.step("test", "Run unit tests");
        tests_step.dependOn(&run_tests.step);
    }

    {
        // wpt
        // -----
        const wpt_module = b.createModule(.{
            .root_source_file = b.path("src/main_wpt.zig"),
            .target = target,
            .optimize = optimize,
        });
        try addDependencies(b, wpt_module, opts);

        // compile and install
        const wpt = b.addExecutable(.{
            .name = "lightpanda-wpt",
            .use_llvm = true,
            .root_module = wpt_module,
        });

        // run
        const wpt_cmd = b.addRunArtifact(wpt);
        if (b.args) |args| {
            wpt_cmd.addArgs(args);
        }
        // step
        const wpt_step = b.step("wpt", "WPT tests");
        wpt_step.dependOn(&wpt_cmd.step);
    }

    {
        // get v8
        // -------
        const v8 = b.dependency("v8", .{ .target = target, .optimize = optimize });
        const get_v8 = b.addRunArtifact(v8.artifact("get-v8"));
        const get_step = b.step("get-v8", "Get v8");
        get_step.dependOn(&get_v8.step);
    }

    {
        // build v8
        // -------
        const v8 = b.dependency("v8", .{ .target = target, .optimize = optimize });
        const build_v8 = b.addRunArtifact(v8.artifact("build-v8"));
        const build_step = b.step("build-v8", "Build v8");
        build_step.dependOn(&build_v8.step);
    }
}

fn addDependencies(b: *Build, mod: *Build.Module, opts: *Build.Step.Options) !void {
    try moduleNetSurf(b, mod);
    mod.addImport("build_config", opts.createModule());

    const target = mod.resolved_target.?;
    const dep_opts = .{
        .target = target,
        .optimize = mod.optimize.?,
    };

    mod.addIncludePath(b.path("vendor/lightpanda"));

    {
        // v8
        const v8_opts = b.addOptions();
        v8_opts.addOption(bool, "inspector_subtype", false);

        const v8_mod = b.dependency("v8", dep_opts).module("v8");
        v8_mod.addOptions("default_exports", v8_opts);
        mod.addImport("v8", v8_mod);

        const release_dir = if (mod.optimize.? == .Debug) "debug" else "release";
        const os = switch (target.result.os.tag) {
            .linux => "linux",
            .macos => "macos",
            else => return error.UnsupportedPlatform,
        };
        var lib_path = try std.fmt.allocPrint(
            mod.owner.allocator,
            "v8/out/{s}/{s}/obj/zig/libc_v8.a",
            .{ os, release_dir },
        );
        std.fs.cwd().access(lib_path, .{}) catch {
            // legacy path
            lib_path = try std.fmt.allocPrint(
                mod.owner.allocator,
                "v8/out/{s}/obj/zig/libc_v8.a",
                .{release_dir},
            );
        };
        mod.addObjectFile(mod.owner.path(lib_path));

        switch (target.result.os.tag) {
            .macos => {
                // v8 has a dependency, abseil-cpp, which, on Mac, uses CoreFoundation
                mod.addSystemFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });
                mod.linkFramework("CoreFoundation", .{});
            },
            else => {},
        }
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
            mod.addCMacro("USE_MBEDTLS", "1");
            mod.addCMacro("USE_THREADS_POSIX", "1");
            mod.addCMacro("USE_UNIX_SOCKETS", "1");
        }

        try buildZlib(b, mod);
        try buildBrotli(b, mod);
        try buildMbedtls(b, mod);
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

fn moduleNetSurf(b: *Build, mod: *Build.Module) !void {
    const target = mod.resolved_target.?;
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;

    // iconv
    const libiconv_lib_path = try std.fmt.allocPrint(
        b.allocator,
        "vendor/libiconv/out/{s}-{s}/lib/libiconv.a",
        .{ @tagName(os), @tagName(arch) },
    );
    const libiconv_include_path = try std.fmt.allocPrint(
        b.allocator,
        "vendor/libiconv/out/{s}-{s}/lib/libiconv.a",
        .{ @tagName(os), @tagName(arch) },
    );
    mod.addObjectFile(b.path(libiconv_lib_path));
    mod.addIncludePath(b.path(libiconv_include_path));

    {
        // mimalloc
        const mimalloc = "vendor/mimalloc";
        const lib_path = try std.fmt.allocPrint(
            b.allocator,
            mimalloc ++ "/out/{s}-{s}/lib/libmimalloc.a",
            .{ @tagName(os), @tagName(arch) },
        );
        mod.addObjectFile(b.path(lib_path));
        mod.addIncludePath(b.path(mimalloc ++ "/include"));
    }

    // netsurf libs
    const ns = "vendor/netsurf";
    const ns_include_path = try std.fmt.allocPrint(
        b.allocator,
        ns ++ "/out/{s}-{s}/include",
        .{ @tagName(os), @tagName(arch) },
    );
    mod.addIncludePath(b.path(ns_include_path));

    const libs: [4][]const u8 = .{
        "libdom",
        "libhubbub",
        "libparserutils",
        "libwapcaplet",
    };
    inline for (libs) |lib| {
        const ns_lib_path = try std.fmt.allocPrint(
            b.allocator,
            ns ++ "/out/{s}-{s}/lib/" ++ lib ++ ".a",
            .{ @tagName(os), @tagName(arch) },
        );
        mod.addObjectFile(b.path(ns_lib_path));
        mod.addIncludePath(b.path(ns ++ "/" ++ lib ++ "/src"));
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

fn buildMbedtls(b: *Build, m: *Build.Module) !void {
    const mbedtls = b.addLibrary(.{
        .name = "mbedtls",
        .root_module = m,
    });

    const root = "vendor/mbedtls/";
    mbedtls.addIncludePath(b.path(root ++ "include"));
    mbedtls.addIncludePath(b.path(root ++ "library"));

    mbedtls.addCSourceFiles(.{ .flags = &.{}, .files = &.{
        root ++ "library/aes.c",
        root ++ "library/aesni.c",
        root ++ "library/aesce.c",
        root ++ "library/aria.c",
        root ++ "library/asn1parse.c",
        root ++ "library/asn1write.c",
        root ++ "library/base64.c",
        root ++ "library/bignum.c",
        root ++ "library/bignum_core.c",
        root ++ "library/bignum_mod.c",
        root ++ "library/bignum_mod_raw.c",
        root ++ "library/camellia.c",
        root ++ "library/ccm.c",
        root ++ "library/chacha20.c",
        root ++ "library/chachapoly.c",
        root ++ "library/cipher.c",
        root ++ "library/cipher_wrap.c",
        root ++ "library/constant_time.c",
        root ++ "library/cmac.c",
        root ++ "library/ctr_drbg.c",
        root ++ "library/des.c",
        root ++ "library/dhm.c",
        root ++ "library/ecdh.c",
        root ++ "library/ecdsa.c",
        root ++ "library/ecjpake.c",
        root ++ "library/ecp.c",
        root ++ "library/ecp_curves.c",
        root ++ "library/entropy.c",
        root ++ "library/entropy_poll.c",
        root ++ "library/error.c",
        root ++ "library/gcm.c",
        root ++ "library/hkdf.c",
        root ++ "library/hmac_drbg.c",
        root ++ "library/lmots.c",
        root ++ "library/lms.c",
        root ++ "library/md.c",
        root ++ "library/md5.c",
        root ++ "library/memory_buffer_alloc.c",
        root ++ "library/nist_kw.c",
        root ++ "library/oid.c",
        root ++ "library/padlock.c",
        root ++ "library/pem.c",
        root ++ "library/pk.c",
        root ++ "library/pk_ecc.c",
        root ++ "library/pk_wrap.c",
        root ++ "library/pkcs12.c",
        root ++ "library/pkcs5.c",
        root ++ "library/pkparse.c",
        root ++ "library/pkwrite.c",
        root ++ "library/platform.c",
        root ++ "library/platform_util.c",
        root ++ "library/poly1305.c",
        root ++ "library/psa_crypto.c",
        root ++ "library/psa_crypto_aead.c",
        root ++ "library/psa_crypto_cipher.c",
        root ++ "library/psa_crypto_client.c",
        root ++ "library/psa_crypto_ffdh.c",
        root ++ "library/psa_crypto_driver_wrappers_no_static.c",
        root ++ "library/psa_crypto_ecp.c",
        root ++ "library/psa_crypto_hash.c",
        root ++ "library/psa_crypto_mac.c",
        root ++ "library/psa_crypto_pake.c",
        root ++ "library/psa_crypto_rsa.c",
        root ++ "library/psa_crypto_se.c",
        root ++ "library/psa_crypto_slot_management.c",
        root ++ "library/psa_crypto_storage.c",
        root ++ "library/psa_its_file.c",
        root ++ "library/psa_util.c",
        root ++ "library/ripemd160.c",
        root ++ "library/rsa.c",
        root ++ "library/rsa_alt_helpers.c",
        root ++ "library/sha1.c",
        root ++ "library/sha3.c",
        root ++ "library/sha256.c",
        root ++ "library/sha512.c",
        root ++ "library/threading.c",
        root ++ "library/timing.c",
        root ++ "library/version.c",
        root ++ "library/version_features.c",
        root ++ "library/pkcs7.c",
        root ++ "library/x509.c",
        root ++ "library/x509_create.c",
        root ++ "library/x509_crl.c",
        root ++ "library/x509_crt.c",
        root ++ "library/x509_csr.c",
        root ++ "library/x509write.c",
        root ++ "library/x509write_crt.c",
        root ++ "library/x509write_csr.c",
        root ++ "library/debug.c",
        root ++ "library/mps_reader.c",
        root ++ "library/mps_trace.c",
        root ++ "library/net_sockets.c",
        root ++ "library/ssl_cache.c",
        root ++ "library/ssl_ciphersuites.c",
        root ++ "library/ssl_client.c",
        root ++ "library/ssl_cookie.c",
        root ++ "library/ssl_debug_helpers_generated.c",
        root ++ "library/ssl_msg.c",
        root ++ "library/ssl_ticket.c",
        root ++ "library/ssl_tls.c",
        root ++ "library/ssl_tls12_client.c",
        root ++ "library/ssl_tls12_server.c",
        root ++ "library/ssl_tls13_keys.c",
        root ++ "library/ssl_tls13_server.c",
        root ++ "library/ssl_tls13_client.c",
        root ++ "library/ssl_tls13_generic.c",
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
            root ++ "lib/vtls/mbedtls.c",
            root ++ "lib/vtls/mbedtls_threadlock.c",
            root ++ "lib/vtls/vtls.c",
            root ++ "lib/vtls/vtls_scache.c",
            root ++ "lib/vtls/x509asn1.c",
        },
    });
}
