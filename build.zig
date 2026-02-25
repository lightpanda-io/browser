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
    const is_debug = if (mod.optimize.? == .Debug) true else false;

    const exec_cargo = b.addSystemCommand(&.{
        "cargo",           "build",
        "--profile",       if (is_debug) "dev" else "release",
        "--manifest-path", "src/html5ever/Cargo.toml",
    });

    // TODO: We can prefer `--artifact-dir` once it become stable.
    const out_dir = exec_cargo.addPrefixedOutputDirectoryArg("--target-dir=", "html5ever");

    const html5ever_step = b.step("html5ever", "Install html5ever dependency (requires cargo)");
    html5ever_step.dependOn(&exec_cargo.step);

    const obj = out_dir.path(b, if (is_debug) "debug" else "release").path(b, "liblitefetch_html5ever.a");
    mod.addObjectFile(obj);
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

    const os = target.result.os.tag;
    const abi = target.result.abi;

    const is_gnu = abi.isGnu();
    const is_ios = os == .ios;
    const is_android = abi.isAndroid();
    const is_linux = os == .linux;
    const is_darwin = os.isDarwin();
    const is_windows = os == .windows;
    const is_netbsd = os == .netbsd;
    const is_openbsd = os == .openbsd;
    const is_freebsd = os == .freebsd;

    const byte_size = struct {
        fn it(b2: *std.Build, target2: Build.ResolvedTarget, name: []const u8, comptime ctype: std.Target.CType) []const u8 {
            const size = target2.result.cTypeByteSize(ctype);
            return std.fmt.allocPrint(b2.allocator, "#define SIZEOF_{s} {d}", .{ name, size }) catch @panic("OOM");
        }
    }.it;

    const config = .{
        .HAVE_LIBZ = true,
        .HAVE_BROTLI = true,
        .USE_NGHTTP2 = true,

        .USE_OPENSSL = true,
        .OPENSSL_IS_BORINGSSL = true,
        .CURL_CA_PATH = null,
        .CURL_CA_BUNDLE = null,
        .CURL_CA_FALLBACK = false,
        .CURL_CA_SEARCH_SAFE = false,
        .CURL_DEFAULT_SSL_BACKEND = "openssl",

        .CURL_DISABLE_AWS = true,
        .CURL_DISABLE_DICT = true,
        .CURL_DISABLE_DOH = true,
        .CURL_DISABLE_FILE = true,
        .CURL_DISABLE_FTP = true,
        .CURL_DISABLE_GOPHER = true,
        .CURL_DISABLE_KERBEROS_AUTH = true,
        .CURL_DISABLE_IMAP = true,
        .CURL_DISABLE_IPFS = true,
        .CURL_DISABLE_LDAP = true,
        .CURL_DISABLE_LDAPS = true,
        .CURL_DISABLE_MQTT = true,
        .CURL_DISABLE_NTLM = true,
        .CURL_DISABLE_PROGRESS_METER = true,
        .CURL_DISABLE_POP3 = true,
        .CURL_DISABLE_RTSP = true,
        .CURL_DISABLE_SMB = true,
        .CURL_DISABLE_SMTP = true,
        .CURL_DISABLE_TELNET = true,
        .CURL_DISABLE_TFTP = true,

        .ssize_t = null,
        ._FILE_OFFSET_BITS = 64,

        .USE_IPV6 = true,
        .CURL_OS = switch (os) {
            .linux => if (is_android) "\"android\"" else "\"linux\"",
            else => std.fmt.allocPrint(b.allocator, "\"{s}\"", .{@tagName(os)}) catch @panic("OOM"),
        },

        // Adjusts the sizes of variables
        .SIZEOF_INT_CODE = byte_size(b, target, "INT", .int),
        .SIZEOF_LONG_CODE = byte_size(b, target, "LONG", .long),
        .SIZEOF_LONG_LONG_CODE = byte_size(b, target, "LONG_LONG", .longlong),

        .SIZEOF_OFF_T_CODE = byte_size(b, target, "OFF_T", .longlong),
        .SIZEOF_CURL_OFF_T_CODE = byte_size(b, target, "CURL_OFF_T", .longlong),
        .SIZEOF_CURL_SOCKET_T_CODE = byte_size(b, target, "CURL_SOCKET_T", .int),

        .SIZEOF_SIZE_T_CODE = byte_size(b, target, "SIZE_T", .longlong),
        .SIZEOF_TIME_T_CODE = byte_size(b, target, "TIME_T", .longlong),

        // headers availability
        .HAVE_ARPA_INET_H = !is_windows,
        .HAVE_DIRENT_H = true,
        .HAVE_FCNTL_H = true,
        .HAVE_IFADDRS_H = !is_windows,
        .HAVE_IO_H = is_windows,
        .HAVE_LIBGEN_H = true,
        .HAVE_LINUX_TCP_H = is_linux and is_gnu,
        .HAVE_LOCALE_H = true,
        .HAVE_NETDB_H = !is_windows,
        .HAVE_NETINET_IN6_H = is_android,
        .HAVE_NETINET_IN_H = !is_windows,
        .HAVE_NETINET_TCP_H = !is_windows,
        .HAVE_NETINET_UDP_H = !is_windows,
        .HAVE_NET_IF_H = !is_windows,
        .HAVE_POLL_H = !is_windows,
        .HAVE_PWD_H = !is_windows,
        .HAVE_STDATOMIC_H = true,
        .HAVE_STDBOOL_H = true,
        .HAVE_STDDEF_H = true,
        .HAVE_STDINT_H = true,
        .HAVE_STRINGS_H = true,
        .HAVE_STROPTS_H = false,
        .HAVE_SYS_EVENTFD_H = is_linux or is_freebsd or is_netbsd,
        .HAVE_SYS_FILIO_H = !is_linux and !is_windows,
        .HAVE_SYS_IOCTL_H = !is_windows,
        .HAVE_SYS_PARAM_H = true,
        .HAVE_SYS_POLL_H = !is_windows,
        .HAVE_SYS_RESOURCE_H = !is_windows,
        .HAVE_SYS_SELECT_H = !is_windows,
        .HAVE_SYS_SOCKIO_H = !is_linux and !is_windows,
        .HAVE_SYS_TYPES_H = true,
        .HAVE_SYS_UN_H = !is_windows,
        .HAVE_SYS_UTIME_H = is_windows,
        .HAVE_TERMIOS_H = !is_windows,
        .HAVE_TERMIO_H = is_linux,
        .HAVE_UNISTD_H = true,
        .HAVE_UTIME_H = true,
        .STDC_HEADERS = true,

        // general environment
        .CURL_KRB5_VERSION = null,
        .HAVE_ALARM = !is_windows,
        .HAVE_ARC4RANDOM = is_android,
        .HAVE_ATOMIC = true,
        .HAVE_BOOL_T = true,
        .HAVE_BUILTIN_AVAILABLE = true,
        .HAVE_CLOCK_GETTIME_MONOTONIC = !is_darwin and !is_windows,
        .HAVE_CLOCK_GETTIME_MONOTONIC_RAW = is_linux,
        .HAVE_FILE_OFFSET_BITS = true,
        .HAVE_GETEUID = !is_windows,
        .HAVE_GETPPID = !is_windows,
        .HAVE_GETTIMEOFDAY = true,
        .HAVE_GLIBC_STRERROR_R = is_gnu,
        .HAVE_GMTIME_R = !is_windows,
        .HAVE_LOCALTIME_R = !is_windows,
        .HAVE_LONGLONG = !is_windows,
        .HAVE_MACH_ABSOLUTE_TIME = is_darwin,
        .HAVE_MEMRCHR = !is_darwin and !is_windows,
        .HAVE_POSIX_STRERROR_R = !is_gnu and !is_windows,
        .HAVE_PTHREAD_H = !is_windows,
        .HAVE_SETLOCALE = true,
        .HAVE_SETRLIMIT = !is_windows,
        .HAVE_SIGACTION = !is_windows,
        .HAVE_SIGINTERRUPT = !is_windows,
        .HAVE_SIGNAL = true,
        .HAVE_SIGSETJMP = !is_windows,
        .HAVE_SIZEOF_SA_FAMILY_T = false,
        .HAVE_SIZEOF_SUSECONDS_T = false,
        .HAVE_SNPRINTF = true,
        .HAVE_STRCASECMP = !is_windows,
        .HAVE_STRCMPI = false,
        .HAVE_STRDUP = true,
        .HAVE_STRERROR_R = !is_windows,
        .HAVE_STRICMP = false,
        .HAVE_STRUCT_TIMEVAL = true,
        .HAVE_TIME_T_UNSIGNED = false,
        .HAVE_UTIME = true,
        .HAVE_UTIMES = !is_windows,
        .HAVE_WRITABLE_ARGV = !is_windows,
        .HAVE__SETMODE = is_windows,
        .USE_THREADS_POSIX = !is_windows,

        // filesystem, network
        .HAVE_ACCEPT4 = is_linux or is_freebsd or is_netbsd or is_openbsd,
        .HAVE_BASENAME = true,
        .HAVE_CLOSESOCKET = is_windows,
        .HAVE_DECL_FSEEKO = !is_windows,
        .HAVE_EVENTFD = is_linux or is_freebsd or is_netbsd,
        .HAVE_FCNTL = !is_windows,
        .HAVE_FCNTL_O_NONBLOCK = !is_windows,
        .HAVE_FNMATCH = !is_windows,
        .HAVE_FREEADDRINFO = true,
        .HAVE_FSEEKO = !is_windows,
        .HAVE_FSETXATTR = is_darwin or is_linux or is_netbsd,
        .HAVE_FSETXATTR_5 = is_linux or is_netbsd,
        .HAVE_FSETXATTR_6 = is_darwin,
        .HAVE_FTRUNCATE = true,
        .HAVE_GETADDRINFO = true,
        .HAVE_GETADDRINFO_THREADSAFE = is_linux or is_freebsd or is_netbsd,
        .HAVE_GETHOSTBYNAME_R = is_linux or is_freebsd,
        .HAVE_GETHOSTBYNAME_R_3 = false,
        .HAVE_GETHOSTBYNAME_R_3_REENTRANT = false,
        .HAVE_GETHOSTBYNAME_R_5 = false,
        .HAVE_GETHOSTBYNAME_R_5_REENTRANT = false,
        .HAVE_GETHOSTBYNAME_R_6 = is_linux,
        .HAVE_GETHOSTBYNAME_R_6_REENTRANT = is_linux,
        .HAVE_GETHOSTNAME = true,
        .HAVE_GETIFADDRS = if (is_windows) false else !is_android or target.result.os.versionRange().linux.android >= 24,
        .HAVE_GETPASS_R = is_netbsd,
        .HAVE_GETPEERNAME = true,
        .HAVE_GETPWUID = !is_windows,
        .HAVE_GETPWUID_R = !is_windows,
        .HAVE_GETRLIMIT = !is_windows,
        .HAVE_GETSOCKNAME = true,
        .HAVE_IF_NAMETOINDEX = !is_windows,
        .HAVE_INET_NTOP = !is_windows,
        .HAVE_INET_PTON = !is_windows,
        .HAVE_IOCTLSOCKET = is_windows,
        .HAVE_IOCTLSOCKET_CAMEL = false,
        .HAVE_IOCTLSOCKET_CAMEL_FIONBIO = false,
        .HAVE_IOCTLSOCKET_FIONBIO = is_windows,
        .HAVE_IOCTL_FIONBIO = !is_windows,
        .HAVE_IOCTL_SIOCGIFADDR = !is_windows,
        .HAVE_MSG_NOSIGNAL = !is_windows,
        .HAVE_OPENDIR = true,
        .HAVE_PIPE = !is_windows,
        .HAVE_PIPE2 = is_linux or is_freebsd or is_netbsd or is_openbsd,
        .HAVE_POLL = !is_windows,
        .HAVE_REALPATH = !is_windows,
        .HAVE_RECV = true,
        .HAVE_SA_FAMILY_T = !is_windows,
        .HAVE_SCHED_YIELD = !is_windows,
        .HAVE_SELECT = true,
        .HAVE_SEND = true,
        .HAVE_SENDMMSG = !is_darwin and !is_windows,
        .HAVE_SENDMSG = !is_windows,
        .HAVE_SETMODE = !is_linux,
        .HAVE_SETSOCKOPT_SO_NONBLOCK = false,
        .HAVE_SOCKADDR_IN6_SIN6_ADDR = !is_windows,
        .HAVE_SOCKADDR_IN6_SIN6_SCOPE_ID = true,
        .HAVE_SOCKET = true,
        .HAVE_SOCKETPAIR = !is_windows,
        .HAVE_STRUCT_SOCKADDR_STORAGE = true,
        .HAVE_SUSECONDS_T = is_android or is_ios,
        .USE_UNIX_SOCKETS = !is_windows,
    };

    const curl_config = b.addConfigHeader(.{
        .include_path = "curl_config.h",
        .style = .{ .cmake = dep.path("lib/curl_config-cmake.h.in") },
    }, .{
        .CURL_EXTERN_SYMBOL = "__attribute__ ((__visibility__ (\"default\"))",
    });
    curl_config.addValues(config);

    const lib = b.addLibrary(.{ .name = "curl", .root_module = mod });
    lib.addConfigHeader(curl_config);
    lib.installHeadersDirectory(dep.path("include/curl"), "curl", .{});
    lib.addCSourceFiles(.{
        .root = dep.path("lib"),
        .flags = &.{
            "-D_GNU_SOURCE",
            "-DHAVE_CONFIG_H",
            "-DCURL_STATICLIB",
            "-DBUILDING_LIBCURL",
        },
        .files = &.{
            // You can include all files from lib, libcurl uses an #ifdef-guards to exclude code for disabled functions
            "altsvc.c",              "amigaos.c",              "asyn-ares.c",
            "asyn-base.c",           "asyn-thrdd.c",           "bufq.c",
            "bufref.c",              "cf-h1-proxy.c",          "cf-h2-proxy.c",
            "cf-haproxy.c",          "cf-https-connect.c",     "cf-ip-happy.c",
            "cf-socket.c",           "cfilters.c",             "conncache.c",
            "connect.c",             "content_encoding.c",     "cookie.c",
            "cshutdn.c",             "curl_addrinfo.c",        "curl_endian.c",
            "curl_fnmatch.c",        "curl_fopen.c",           "curl_get_line.c",
            "curl_gethostname.c",    "curl_gssapi.c",          "curl_memrchr.c",
            "curl_ntlm_core.c",      "curl_range.c",           "curl_rtmp.c",
            "curl_sasl.c",           "curl_sha512_256.c",      "curl_share.c",
            "curl_sspi.c",           "curl_threads.c",         "curl_trc.c",
            "curlx/base64.c",        "curlx/dynbuf.c",         "curlx/fopen.c",
            "curlx/inet_ntop.c",     "curlx/inet_pton.c",      "curlx/multibyte.c",
            "curlx/nonblock.c",      "curlx/strcopy.c",        "curlx/strerr.c",
            "curlx/strparse.c",      "curlx/timediff.c",       "curlx/timeval.c",
            "curlx/version_win32.c", "curlx/wait.c",           "curlx/warnless.c",
            "curlx/winapi.c",        "cw-out.c",               "cw-pause.c",
            "dict.c",                "dllmain.c",              "doh.c",
            "dynhds.c",              "easy.c",                 "easygetopt.c",
            "easyoptions.c",         "escape.c",               "fake_addrinfo.c",
            "file.c",                "fileinfo.c",             "formdata.c",
            "ftp.c",                 "ftplistparser.c",        "getenv.c",
            "getinfo.c",             "gopher.c",               "hash.c",
            "headers.c",             "hmac.c",                 "hostip.c",
            "hostip4.c",             "hostip6.c",              "hsts.c",
            "http.c",                "http1.c",                "http2.c",
            "http_aws_sigv4.c",      "http_chunks.c",          "http_digest.c",
            "http_negotiate.c",      "http_ntlm.c",            "http_proxy.c",
            "httpsrr.c",             "idn.c",                  "if2ip.c",
            "imap.c",                "ldap.c",                 "llist.c",
            "macos.c",               "md4.c",                  "md5.c",
            "memdebug.c",            "mime.c",                 "mprintf.c",
            "mqtt.c",                "multi.c",                "multi_ev.c",
            "multi_ntfy.c",          "netrc.c",                "noproxy.c",
            "openldap.c",            "parsedate.c",            "pingpong.c",
            "pop3.c",                "progress.c",             "psl.c",
            "rand.c",                "ratelimit.c",            "request.c",
            "rtsp.c",                "select.c",               "sendf.c",
            "setopt.c",              "sha256.c",               "slist.c",
            "smb.c",                 "smtp.c",                 "socketpair.c",
            "socks.c",               "socks_gssapi.c",         "socks_sspi.c",
            "splay.c",               "strcase.c",              "strdup.c",
            "strequal.c",            "strerror.c",             "system_win32.c",
            "telnet.c",              "tftp.c",                 "transfer.c",
            "uint-bset.c",           "uint-hash.c",            "uint-spbset.c",
            "uint-table.c",          "url.c",                  "urlapi.c",
            "vauth/cleartext.c",     "vauth/cram.c",           "vauth/digest.c",
            "vauth/digest_sspi.c",   "vauth/gsasl.c",          "vauth/krb5_gssapi.c",
            "vauth/krb5_sspi.c",     "vauth/ntlm.c",           "vauth/ntlm_sspi.c",
            "vauth/oauth2.c",        "vauth/spnego_gssapi.c",  "vauth/spnego_sspi.c",
            "vauth/vauth.c",         "version.c",              "vquic/curl_ngtcp2.c",
            "vquic/curl_osslq.c",    "vquic/curl_quiche.c",    "vquic/vquic-tls.c",
            "vquic/vquic.c",         "vssh/libssh.c",          "vssh/libssh2.c",
            "vssh/vssh.c",           "vtls/apple.c",           "vtls/cipher_suite.c",
            "vtls/gtls.c",           "vtls/hostcheck.c",       "vtls/keylog.c",
            "vtls/mbedtls.c",        "vtls/openssl.c",         "vtls/rustls.c",
            "vtls/schannel.c",       "vtls/schannel_verify.c", "vtls/vtls.c",
            "vtls/vtls_scache.c",    "vtls/vtls_spack.c",      "vtls/wolfssl.c",
            "vtls/x509asn1.c",       "ws.c",
        },
    });

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
