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
const builtin = @import("builtin");

const lightpanda_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;
const min_zig_version = std.SemanticVersion.parse(@import("build.zig.zon").minimum_zig_version) catch unreachable;

const Build = blk: {
    if (builtin.zig_version.order(min_zig_version) == .lt) {
        @compileError(std.fmt.comptimePrint(
            \\Zig version is too old:
            \\  current Zig version: {f}
            \\  minimum Zig version: {f}
        , .{ builtin.zig_version, min_zig_version }));
    }
    break :blk std.Build;
};

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const requested_target = b.standardTargetOptions(.{});

    const enable_tsan = b.option(bool, "tsan", "Enable Thread Sanitizer") orelse false;
    const enable_asan = b.option(bool, "asan", "Enable Address Sanitizer") orelse false;
    const enable_csan = b.option(std.zig.SanitizeC, "csan", "Enable C Sanitizers");

    const prebuilt_v8_path_option = b.option([]const u8, "prebuilt_v8_path", "Path to a prebuilt libc_v8.a or libc_v8.so");

    const dev_fast = b.option(bool, "dev_fast", "Linux debug builds: shared V8 + self-hosted backend. Implies -Dshared_v8, -Duse_llvm=false and a bundled-CRT target") orelse
        (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64 and
            optimize == .Debug and requested_target.query.isNative() and
            !enable_tsan and !enable_asan and
            (prebuilt_v8_path_option == null or std.mem.endsWith(u8, prebuilt_v8_path_option.?, ".so")));

    if (dev_fast) {
        if (builtin.os.tag != .linux) {
            std.debug.print("-Ddev_fast is Linux-only (host is {s})\n", .{@tagName(builtin.os.tag)});
            return error.DevFastUnsupportedHost;
        }
        if (optimize != .Debug) {
            std.debug.print("-Ddev_fast is Debug-only (optimize is {s})\n", .{@tagName(optimize)});
            return error.DevFastRequiresDebug;
        }
        if (!requested_target.query.isNative()) {
            std.debug.print("-Ddev_fast builds for the host; drop -Dtarget/-Dcpu\n", .{});
            return error.DevFastRequiresNativeTarget;
        }
    }

    const target = if (dev_fast) b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
        // Explicit version => bundled CRT, https://codeberg.org/ziglang/zig/issues/31272
        .glibc_version = devFastGlibcVersion(b),
    }) else requested_target;

    // Without an explicit -Dprebuilt_v8_path, pick up whatever `make
    // download-v8` cached rather than building V8 from source.
    const prebuilt_v8_path = prebuilt_v8_path_option orelse if (enable_tsan or enable_asan) null else findPrebuiltV8(b, target, dev_fast);
    const snapshot_path = b.option([]const u8, "snapshot_path", "Path to v8 snapshot");
    const wpt_extensions = b.option(bool, "wpt_extensions", "Extend WebAPI with WPT driver behavior") orelse false;
    const shared_v8 = b.option(bool, "shared_v8", "Link V8 as a shared library") orelse (dev_fast or (prebuilt_v8_path != null and std.mem.endsWith(u8, prebuilt_v8_path.?, ".so")));
    const use_llvm = b.option(bool, "use_llvm", "Use the LLVM backend") orelse !dev_fast;
    // Hot-code layout for the Linux release artifacts, see orderfile/README.md.
    // Opt-in (CI passes it): it needs LLD and costs link time on every build.
    const orderfile = b.option([]const u8, "orderfile", "Linker script packing hot sections, e.g. orderfile/lightpanda.ld (Linux/LLD release builds)");

    const version = resolveVersion(b);
    std.debug.print("Lightpanda {f}\n", .{version});

    const version_string = b.fmt("{f}", .{version});
    const version_encoded = std.mem.replaceOwned(u8, b.allocator, version_string, "+", "%2B") catch @panic("OOM");

    var opts = b.addOptions();
    opts.addOption([]const u8, "version", version_string);
    opts.addOption([]const u8, "version_encoded", version_encoded);
    opts.addOption(?[]const u8, "snapshot_path", snapshot_path);
    opts.addOption(bool, "wpt_extensions", wpt_extensions);

    const lightpanda_module = b.addModule("lightpanda", .{
        .root_source_file = b.path("src/lightpanda.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = enable_csan,
        .sanitize_thread = enable_tsan,
    });
    lightpanda_module.addImport("lightpanda", lightpanda_module); // allow circular "lightpanda" import
    lightpanda_module.addImport("build_config", opts.createModule());

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
    b.default_step.dependOn(fmt_step);

    // With an orderfile, the prebuilt V8 archive is rewritten so its hot
    // functions' sections can be addressed by the linker script.
    const v8_archive: ?Build.LazyPath = if (prebuilt_v8_path) |path| .{ .cwd_relative = path } else null;
    const v8_for_link = if (orderfile != null and v8_archive != null and !shared_v8) markHotSections(b, v8_archive.?) else v8_archive;
    linkV8(b, lightpanda_module, enable_asan, enable_tsan, v8_for_link, shared_v8);
    linkCurl(b, lightpanda_module, enable_tsan, orderfile != null);
    linkRust(b, lightpanda_module);
    linkZenai(b, lightpanda_module);
    linkIsocline(b, lightpanda_module);
    linkSqlite(b, lightpanda_module, enable_csan, enable_tsan, orderfile != null);

    // Check compilation
    const check = b.step("check", "Check if lightpanda compiles");

    const check_lib = b.addLibrary(.{
        .name = "lightpanda_check",
        .root_module = lightpanda_module,
    });
    check.dependOn(&check_lib.step);

    // Extras (snapshot_creator) are off the default install to
    // avoid paying for three exe compiles on every edit. Build explicitly
    // with `zig build extras`.
    const extras_step = b.step("extras", "Build snapshot_creator");

    const exe_config: ExeConfig = .{
        .check = check,
        .lightpanda_module = lightpanda_module,
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
        .orderfile = orderfile,
        .sanitize_c = enable_csan,
        .sanitize_thread = enable_tsan,
    };

    {
        // browser
        const exe = addExe(b, exe_config, "lightpanda", "lightpanda_exe_check", "src/main.zig");
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        const version_info_step = b.step("version", "Print the resolved version information");
        const version_info_run = b.addRunArtifact(exe);
        version_info_run.addArg("version");
        version_info_step.dependOn(&version_info_run.step);
    }

    {
        // snapshot creator
        const exe = addExe(b, exe_config, "lightpanda-snapshot-creator", "snapshot_creator_check", "src/main_snapshot_creator.zig");
        extras_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("snapshot_creator", "Generate a v8 snapshot");
        run_step.dependOn(&run_cmd.step);
    }

    {
        // skills generator
        const exe = addExe(b, exe_config, "lightpanda-skills", "skills_check", "src/main_skills.zig");

        const run_cmd = b.addRunArtifact(exe);
        const out_dir = run_cmd.addOutputDirectoryArg("skills");
        const install = b.addInstallDirectory(.{
            .source_dir = out_dir,
            .install_dir = .prefix,
            .install_subdir = "skills",
        });
        const skills_step = b.step("skills", "Generate LLM skill docs (zig-out/skills/<name>/SKILL.md)");
        skills_step.dependOn(&install.step);
    }

    {
        // test
        const tests = b.addTest(.{
            .root_module = lightpanda_module,
            .use_llvm = use_llvm,
            .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
        });
        const run_tests = b.addRunArtifact(tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_tests.step);
    }
}

const ExeConfig = struct {
    check: *Build.Step,
    lightpanda_module: *Build.Module,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
    orderfile: ?[]const u8,
    sanitize_c: ?std.zig.SanitizeC,
    sanitize_thread: bool,
};

fn addExe(b: *Build, config: ExeConfig, name: []const u8, check_name: []const u8, root_source_file: []const u8) *Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .use_llvm = config.use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = config.target,
            .optimize = config.optimize,
            .sanitize_c = config.sanitize_c,
            .sanitize_thread = config.sanitize_thread,
            .imports = &.{
                .{ .name = "lightpanda", .module = config.lightpanda_module },
            },
        }),
    });

    if (config.orderfile) |path| {
        // Per-function/per-datum sections exist only so the orderfile script
        // can place individual hot functions; the self-hosted backend used by
        // Debug builds does not support them on the C libraries, so they are
        // gated on the orderfile being set (release/LLVM only).
        exe.link_function_sections = true;
        exe.link_data_sections = true;
        exe.linker_script = .{ .cwd_relative = path };
    }

    const exe_check = b.addLibrary(.{
        .name = check_name,
        .root_module = exe.root_module,
    });
    config.check.dependOn(&exe_check.step);

    return exe;
}

fn devFastGlibcVersion(b: *Build) std.SemanticVersion {
    const host = b.graph.host.result.os.version_range.linux.glibc;
    const newest_known: std.SemanticVersion = .{ .major = 2, .minor = 43, .patch = 0 };
    return if (host.order(newest_known) == .gt) newest_known else host;
}

/// Looks for the prebuilt V8 that `make download-v8` caches. The cache
/// path is keyed on the zig-v8 release tag, read from the install action so
/// it cannot drift from CI (the Makefile reads the same source of truth).
fn findPrebuiltV8(b: *Build, target: Build.ResolvedTarget, dev_fast: bool) ?[]const u8 {
    const io = b.graph.io;
    const action = std.Io.Dir.cwd().readFileAlloc(
        io,
        b.pathFromRoot(".github/actions/install/action.yml"),
        b.allocator,
        .limited(64 * 1024),
    ) catch return null;

    const tag = actionDefault(action, "zig-v8:") orelse return null;
    if (tag.len == 0) {
        return null;
    }

    const cache_dir = b.pathFromRoot(".lp-cache");
    // The .so must keep the name the exe's DT_NEEDED records; the archive
    // name encodes V8 version, os and arch.
    const path = if (dev_fast)
        b.pathJoin(&.{ cache_dir, "prebuilt-v8", tag, "libc_v8.so" })
    else blk: {
        const version = actionDefault(action, "v8:") orelse return null;
        break :blk b.pathJoin(&.{ cache_dir, "prebuilt-v8", tag, b.fmt("libc_v8_{s}_{s}_{s}.a", .{
            version,
            @tagName(target.result.os.tag),
            @tagName(target.result.cpu.arch),
        }) });
    };
    std.Io.Dir.cwd().access(io, path, .{}) catch {
        std.debug.print("No prebuilt V8 at {s}; using the V8 source-build path. `make download-v8` fetches the prebuilt.\n", .{path});
        return null;
    };
    std.debug.print("Using prebuilt V8: {s}\n", .{path});
    return path;
}

/// Returns the quoted `default:` value of a top-level `key` in the install
/// action's yaml.
fn actionDefault(action: []const u8, key: []const u8) ?[]const u8 {
    var in_key = false;
    var lines = std.mem.splitScalar(u8, action, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "  ") and !std.mem.startsWith(u8, line, "   ")) {
            in_key = std.mem.eql(u8, std.mem.trimEnd(u8, line[2..], " \r"), key);
            continue;
        }
        if (!in_key) continue;
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.mem.startsWith(u8, trimmed, "default:")) {
            var it = std.mem.splitScalar(u8, trimmed, '\'');
            _ = it.next();
            if (it.next()) |value| return value;
            break;
        }
    }
    std.debug.print("Can't parse the `{s} default:` value from .github/actions/install/action.yml; prebuilt V8 discovery skipped.\n", .{key});
    return null;
}

/// Renames the hot V8 functions' sections (`.text` -> `.text.hot.<sym>`, see
/// orderfile/mark_hot_sections.zig) so the orderfile script can gather them.
fn markHotSections(b: *Build, archive: Build.LazyPath) Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "mark_hot_sections",
        .root_module = b.createModule(.{
            .root_source_file = b.path("orderfile/mark_hot_sections.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(archive);
    run.addFileArg(b.path("orderfile/v8.txt"));
    return run.addOutputFileArg("libc_v8.a");
}

/// Per-function/per-datum sections let the -Dorderfile linker script place
/// individual hot functions. Only enabled for orderfile (release/LLVM) builds:
/// the self-hosted backend used by Debug builds fails to link the C libraries
/// with them.
fn sectionize(lib: *Build.Step.Compile, enabled: bool) *Build.Step.Compile {
    if (enabled) {
        lib.link_function_sections = true;
        lib.link_data_sections = true;
    }
    return lib;
}

fn linkV8(
    b: *Build,
    mod: *Build.Module,
    is_asan: bool,
    is_tsan: bool,
    prebuilt_v8_path: ?Build.LazyPath,
    shared_v8: bool,
) void {
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
        .shared_v8 = shared_v8,
    });
    mod.addImport("v8", dep.module("v8"));
}

fn linkRust(b: *Build, mod: *Build.Module) void {
    const is_debug = mod.optimize.? == .Debug;

    // One cargo workspace, one staticlib (src/rust/Cargo.toml explains why).
    const exec_cargo = b.addSystemCommand(&.{
        "cargo",           "build",
        "--profile",       if (is_debug) "dev" else "release",
        "--features",      if (is_debug) "memstats" else "",
        "--manifest-path", "src/rust/ffi/Cargo.toml",
    });

    addDirInputs(b, exec_cargo, "src/rust", "target") catch |err| {
        std.debug.panic("walk src/rust: {t}", .{err});
    };

    // Cargo reports progress on stderr; left uncaptured, Zig prints it as a
    // "failed command: ..." diagnostic on a successful build. A non-zero exit
    // still surfaces the captured output.
    _ = exec_cargo.captureStdErr(.{});

    // don't let cargo's progress report (sent to stderr) cause Zig's build to
    // print a 'failed command: ...' message. (non-zero status still outputs the error)
    _ = exec_cargo.captureStdErr(.{});

    // TODO: We can prefer `--artifact-dir` once it become stable.
    const out_dir = exec_cargo.addPrefixedOutputDirectoryArg("--target-dir=", "rust");

    const rust_step = b.step("rust", "Build the Rust staticlib (requires cargo)");
    rust_step.dependOn(&exec_cargo.step);

    const obj = out_dir.path(b, if (is_debug) "debug" else "release").path(b, "liblightpanda_ffi.a");
    mod.addObjectFile(obj);
}

/// Registers every file under `root` (relative to the build root) as an
/// input of `run`, skipping the `skip_dir` subtree at any depth.
fn addDirInputs(b: *Build, run: *Build.Step.Run, root: []const u8, skip_dir: []const u8) !void {
    const io = b.graph.io;
    var dir = try b.build_root.handle.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => if (std.mem.eql(u8, entry.basename, skip_dir)) walker.leave(io),
            .file => run.addFileInput(b.path(b.pathJoin(&.{ root, entry.path }))),
            else => {},
        }
    }
}

fn linkSqlite(b: *Build, mod: *Build.Module, enable_csan: ?std.zig.SanitizeC, is_tsan: bool, section: bool) void {
    const dep = b.dependency("sqlite3", .{
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
    });

    const lib = sectionize(dep.artifact("sqlite3"), section);
    lib.root_module.sanitize_c = enable_csan;
    lib.root_module.sanitize_thread = is_tsan;

    const macros = [_]struct { []const u8, []const u8 }{
        .{ "SQLITE_DEFAULT_FILE_PERMISSIONS", "0600" },
        .{ "SQLITE_DEFAULT_MEMSTATUS", "0" },
        .{ "SQLITE_DEFAULT_WAL_SYNCHRONOUS", "1" },
        .{ "SQLITE_DQS", "0" },
        .{ "SQLITE_ENABLE_API_ARMOR", "1" },
        .{ "SQLITE_ENABLE_UNLOCK_NOTIFY", "1" },
        .{ "SQLITE_TEMP_STORE", "3" },
        .{ "SQLITE_THREADSAFE", "1" },
        .{ "SQLITE_UNTESTABLE", "1" },
        .{ "SQLITE_USE_ALLOCA", "1" },
        .{ "SQLITE_OMIT_AUTHORIZATION", "1" },
        .{ "SQLITE_OMIT_AUTOMATIC_INDEX", "1" },
        .{ "SQLITE_OMIT_AUTORESET", "1" },
        .{ "SQLITE_OMIT_AUTOVACUUM", "1" },
        .{ "SQLITE_OMIT_BETWEEN_OPTIMIZATION", "1" },
        .{ "SQLITE_OMIT_CASE_SENSITIVE_LIKE_PRAGMA", "1" },
        .{ "SQLITE_OMIT_COMPLETE", "1" },
        .{ "SQLITE_OMIT_DECLTYPE", "1" },
        .{ "SQLITE_OMIT_DEPRECATED", "1" },
        .{ "SQLITE_OMIT_DESERIALIZE", "1" },
        .{ "SQLITE_OMIT_GET_TABLE", "1" },
        .{ "SQLITE_OMIT_INCRBLOB", "1" },
        .{ "SQLITE_OMIT_JSON", "1" },
        .{ "SQLITE_OMIT_LIKE_OPTIMIZATION", "1" },
        .{ "SQLITE_OMIT_LOAD_EXTENSION", "1" },
        .{ "SQLITE_OMIT_PROGRESS_CALLBACK", "1" },
        .{ "SQLITE_OMIT_SHARED_CACHE", "1" },
        .{ "SQLITE_OMIT_TCL_VARIABLE", "1" },
        .{ "SQLITE_OMIT_TEMPDB", "1" },
        .{ "SQLITE_OMIT_TRACE", "1" },
        .{ "SQLITE_OMIT_UTF16", "1" },
        .{ "SQLITE_OMIT_XFER_OPT", "1" },
    };
    for (macros) |m| {
        lib.root_module.addCMacro(m[0], m[1]);
    }

    mod.linkLibrary(lib);

    const translate_c = b.addTranslateC(.{
        .root_source_file = lib.getEmittedIncludeTree().path(b, "sqlite3.h"),
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
    });
    mod.addImport("sqlite3", translate_c.createModule());
}

fn linkCurl(b: *Build, mod: *Build.Module, is_tsan: bool, section: bool) void {
    const target = mod.resolved_target.?;

    const curl = buildCurl(b, target, mod.optimize.?, is_tsan, section);
    mod.linkLibrary(curl);

    const dep = b.dependency("curl", .{});
    const translate_c = b.addTranslateC(.{
        .root_source_file = dep.path("include/curl/curl.h"),
        .target = target,
        .optimize = mod.optimize.?,
    });
    translate_c.addIncludePath(dep.path("include"));
    mod.addImport("curl", translate_c.createModule());

    const zlib = buildZlib(b, target, mod.optimize.?, is_tsan, section);
    curl.root_module.linkLibrary(zlib);

    const brotli = buildBrotli(b, target, mod.optimize.?, is_tsan, section);
    for (brotli) |lib| curl.root_module.linkLibrary(lib);

    const nghttp2 = buildNghttp2(b, target, mod.optimize.?, is_tsan, section);
    curl.root_module.linkLibrary(nghttp2);

    const boringssl = buildBoringSsl(b, target, mod.optimize.?, section);
    for (boringssl) |lib| curl.root_module.linkLibrary(lib);

    if (target.result.os.tag == .macos) {
        // needed for proxying on mac
        const framework_path = if (b.sysroot) |sysroot|
            b.pathJoin(&.{ sysroot, "System/Library/Frameworks" })
        else if (b.graph.environ_map.get("SDKROOT")) |sdk_root|
            b.pathJoin(&.{ sdk_root, "System/Library/Frameworks" })
        else
            "/System/Library/Frameworks";
        mod.addSystemFrameworkPath(.{ .cwd_relative = framework_path });
        mod.linkFramework("CoreFoundation", .{});
        mod.linkFramework("SystemConfiguration", .{});
    }
}

fn cLibModule(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, is_tsan: bool) *Build.Module {
    return b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = is_tsan,
    });
}

fn buildZlib(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, is_tsan: bool, section: bool) *Build.Step.Compile {
    const dep = b.dependency("zlib", .{});

    const mod = cLibModule(b, target, optimize, is_tsan);
    const lib = sectionize(b.addLibrary(.{ .name = "z", .root_module = mod }), section);
    lib.installHeadersDirectory(dep.path(""), "", .{});
    mod.addCSourceFiles(.{
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

fn buildBrotli(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, is_tsan: bool, section: bool) [3]*Build.Step.Compile {
    const dep = b.dependency("brotli", .{});

    const mod = cLibModule(b, target, optimize, is_tsan);
    mod.addIncludePath(dep.path("c/include"));

    const brotlicmn = sectionize(b.addLibrary(.{ .name = "brotlicommon", .root_module = mod }), section);
    const brotlidec = sectionize(b.addLibrary(.{ .name = "brotlidec", .root_module = mod }), section);
    const brotlienc = sectionize(b.addLibrary(.{ .name = "brotlienc", .root_module = mod }), section);

    brotlicmn.installHeadersDirectory(dep.path("c/include/brotli"), "brotli", .{});
    mod.addCSourceFiles(.{
        .root = dep.path("c/common"),
        .files = &.{
            "transform.c",  "shared_dictionary.c", "platform.c",
            "dictionary.c", "context.c",           "constants.c",
        },
    });
    mod.addCSourceFiles(.{
        .root = dep.path("c/dec"),
        .files = &.{
            "bit_reader.c", "decode.c", "huffman.c",
            "prefix.c",     "state.c",  "static_init.c",
        },
    });
    mod.addCSourceFiles(.{
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

fn buildBoringSsl(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, section: bool) [2]*Build.Step.Compile {
    const dep = b.dependency("boringssl-zig", .{
        .target = target,
        .optimize = optimize,
        .force_pic = true,
    });

    const ssl = sectionize(dep.artifact("ssl"), section);
    ssl.bundle_ubsan_rt = false;

    const crypto = sectionize(dep.artifact("crypto"), section);
    crypto.bundle_ubsan_rt = false;

    return .{ ssl, crypto };
}

fn buildNghttp2(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, is_tsan: bool, section: bool) *Build.Step.Compile {
    const dep = b.dependency("nghttp2", .{});

    const mod = cLibModule(b, target, optimize, is_tsan);
    mod.addIncludePath(dep.path("lib/includes"));

    const config = b.addConfigHeader(.{
        .include_path = "nghttp2ver.h",
        .style = .{ .cmake = dep.path("lib/includes/nghttp2/nghttp2ver.h.in") },
    }, .{
        .PACKAGE_VERSION = "1.68.90",
        .PACKAGE_VERSION_NUM = 0x016890,
    });
    mod.addConfigHeader(config);

    const lib = sectionize(b.addLibrary(.{ .name = "nghttp2", .root_module = mod }), section);

    lib.installConfigHeader(config);
    lib.installHeadersDirectory(dep.path("lib/includes/nghttp2"), "nghttp2", .{});
    mod.addCSourceFiles(.{
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
    is_tsan: bool,
    section: bool,
) *Build.Step.Compile {
    const dep = b.dependency("curl", .{});

    const mod = cLibModule(b, target, optimize, is_tsan);
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
            return b2.fmt("#define SIZEOF_{s} {d}", .{ name, target2.result.cTypeByteSize(ctype) });
        }
    }.it;

    const config = .{
        .HAVE_LIBZ = true,
        .HAVE_BROTLI = true,
        .USE_NGHTTP2 = true,

        .USE_OPENSSL = true,
        .OPENSSL_IS_BORINGSSL = true,
        .CURL_BORINGSSL_VERSION = null,
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
        .CURL_DISABLE_WEBSOCKETS = false, // Enable WebSocket support

        .ssize_t = null,
        ._FILE_OFFSET_BITS = 64,

        .USE_IPV6 = true,
        // IDN is handled before libcurl (HttpClient calls URL.ensureHostAscii,
        // backed by rust-url), so libcurl always receives an ASCII host and
        // does not link libidn2.
        .HAVE_LIBIDN2 = false,
        .HAVE_IDN2_H = false,
        .CURL_OS = switch (os) {
            .linux => if (is_android) "\"android\"" else "\"linux\"",
            else => b.fmt("\"{s}\"", .{@tagName(os)}),
        },

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
        .CURL_PATCHSTAMP = null,
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
        .HAVE_THREADS_POSIX = !is_windows,
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
        .USE_RESOLV_THREADED = !is_windows,

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

    const lib = sectionize(b.addLibrary(.{ .name = "curl", .root_module = mod }), section);
    mod.addConfigHeader(curl_config);
    lib.installHeadersDirectory(dep.path("include/curl"), "curl", .{});
    mod.addCSourceFiles(.{
        .root = dep.path("lib"),
        .flags = &.{
            "-D_GNU_SOURCE",
            "-DHAVE_CONFIG_H",
            "-DCURL_STATICLIB",
            "-DBUILDING_LIBCURL",
        },
        .files = &.{
            // You can include all files from lib, libcurl uses #ifdef-guards to exclude code for disabled functions
            "cf-dns.c",            "dnscache.c",            "protocol.c",          "curlx/strdup.c",
            "thrdpool.c",          "thrdqueue.c",           "altsvc.c",            "amigaos.c",
            "asyn-ares.c",         "asyn-base.c",           "asyn-thrdd.c",        "bufq.c",
            "bufref.c",            "cf-h1-proxy.c",         "cf-h2-proxy.c",       "cf-haproxy.c",
            "cf-https-connect.c",  "cf-ip-happy.c",         "cf-socket.c",         "cfilters.c",
            "conncache.c",         "connect.c",             "content_encoding.c",  "cookie.c",
            "cshutdn.c",           "curl_addrinfo.c",       "curl_endian.c",       "curl_fnmatch.c",
            "curl_fopen.c",        "curl_get_line.c",       "curl_gethostname.c",  "curl_gssapi.c",
            "curl_memrchr.c",      "curl_ntlm_core.c",      "curl_range.c",        "curl_sasl.c",
            "curl_sha512_256.c",   "curl_share.c",          "curl_sspi.c",         "curl_threads.c",
            "curl_trc.c",          "curlx/base64.c",        "curlx/dynbuf.c",      "curlx/fopen.c",
            "curlx/inet_ntop.c",   "curlx/inet_pton.c",     "curlx/multibyte.c",   "curlx/nonblock.c",
            "curlx/strcopy.c",     "curlx/strerr.c",        "curlx/strparse.c",    "curlx/timediff.c",
            "curlx/timeval.c",     "curlx/version_win32.c", "curlx/wait.c",        "curlx/warnless.c",
            "curlx/winapi.c",      "cw-out.c",              "cw-pause.c",          "dict.c",
            "dllmain.c",           "doh.c",                 "dynhds.c",            "easy.c",
            "easygetopt.c",        "easyoptions.c",         "escape.c",            "fake_addrinfo.c",
            "file.c",              "fileinfo.c",            "formdata.c",          "ftp.c",
            "ftplistparser.c",     "getenv.c",              "getinfo.c",           "gopher.c",
            "hash.c",              "headers.c",             "hmac.c",              "hostip.c",
            "hostip4.c",           "hostip6.c",             "hsts.c",              "http.c",
            "http1.c",             "http2.c",               "http_aws_sigv4.c",    "http_chunks.c",
            "http_digest.c",       "http_negotiate.c",      "http_ntlm.c",         "http_proxy.c",
            "httpsrr.c",           "idn.c",                 "if2ip.c",             "imap.c",
            "ldap.c",              "llist.c",               "macos.c",             "md4.c",
            "md5.c",               "memdebug.c",            "mime.c",              "mprintf.c",
            "mqtt.c",              "multi.c",               "multi_ev.c",          "multi_ntfy.c",
            "netrc.c",             "noproxy.c",             "openldap.c",          "parsedate.c",
            "pingpong.c",          "pop3.c",                "progress.c",          "psl.c",
            "rand.c",              "ratelimit.c",           "request.c",           "rtsp.c",
            "select.c",            "sendf.c",               "setopt.c",            "sha256.c",
            "slist.c",             "smb.c",                 "smtp.c",              "socketpair.c",
            "socks.c",             "socks_gssapi.c",        "socks_sspi.c",        "splay.c",
            "strcase.c",           "strequal.c",            "strerror.c",          "system_win32.c",
            "telnet.c",            "tftp.c",                "transfer.c",          "uint-bset.c",
            "uint-hash.c",         "uint-spbset.c",         "uint-table.c",        "url.c",
            "urlapi.c",            "vauth/cleartext.c",     "vauth/cram.c",        "vauth/digest.c",
            "vauth/digest_sspi.c", "vauth/gsasl.c",         "vauth/krb5_gssapi.c", "vauth/krb5_sspi.c",
            "vauth/ntlm.c",        "vauth/ntlm_sspi.c",     "vauth/oauth2.c",      "vauth/spnego_gssapi.c",
            "vauth/spnego_sspi.c", "vauth/vauth.c",         "version.c",           "vquic/curl_ngtcp2.c",
            "vquic/curl_quiche.c", "vquic/vquic-tls.c",     "vquic/vquic.c",       "vssh/libssh.c",
            "vssh/libssh2.c",      "vssh/vssh.c",           "vtls/apple.c",        "vtls/cipher_suite.c",
            "vtls/gtls.c",         "vtls/hostcheck.c",      "vtls/keylog.c",       "vtls/mbedtls.c",
            "vtls/openssl.c",      "vtls/rustls.c",         "vtls/schannel.c",     "vtls/schannel_verify.c",
            "vtls/vtls.c",         "vtls/vtls_scache.c",    "vtls/vtls_spack.c",   "vtls/wolfssl.c",
            "vtls/x509asn1.c",     "ws.c",
        },
    });

    return lib;
}

fn linkZenai(b: *Build, mod: *Build.Module) void {
    const dep = b.dependency("zenai", .{});
    mod.addImport("zenai", dep.module("zenai"));
}

fn linkIsocline(b: *Build, mod: *Build.Module) void {
    const dep = b.dependency("isocline", .{});
    mod.addIncludePath(dep.path("include"));
    mod.addCSourceFile(.{
        .file = dep.path("src/isocline.c"),
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = dep.path("include/isocline.h"),
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
    });
    mod.addImport("isocline", translate_c.createModule());
}

/// Resolves the semantic version of the build.
///
/// The base version is read from `build.zig.zon`. This can be overridden
/// using the `-Dversion` command-line flag:
/// - If the flag contains a full semantic version (e.g., `1.2.3`), it replaces
///   the base version entirely.
/// - If the flag contains a simple string (e.g., `nightly`), it replaces only
///   the pre-release tag of the base version (e.g., `1.0.0-dev` -> `1.0.0-nightly`).
///
/// For versions that have a pre-release tag and no explicit build metadata,
/// this function automatically enriches the version with the git commit count
/// and short hash (e.g., `1.0.0-dev.5243+dbe45229`).
fn resolveVersion(b: *std.Build) std.SemanticVersion {
    const opt_version = b.option([]const u8, "version", "Override the version of this build");

    const version = if (opt_version) |v|
        std.SemanticVersion.parse(v) catch blk: {
            var fallback = lightpanda_version;
            fallback.pre = v;
            break :blk fallback;
        }
    else
        lightpanda_version;

    if (version.pre == null or version.build != null) return version;

    const git_hash_raw = runGit(b, &.{ "rev-parse", "--short", "HEAD" }) catch return version;
    const commit_hash = std.mem.trim(u8, git_hash_raw, " \n\r");

    const git_count_raw = runGit(b, &.{ "rev-list", "--count", "HEAD" }) catch return version;
    const commit_count = std.mem.trim(u8, git_count_raw, " \n\r");

    return .{
        .major = version.major,
        .minor = version.minor,
        .patch = version.patch,
        .pre = b.fmt("{s}.{s}", .{ version.pre.?, commit_count }),
        .build = commit_hash,
    };
}

fn runGit(b: *std.Build, args: []const []const u8) ![]const u8 {
    var code: u8 = undefined;
    const command = try std.mem.concat(b.allocator, []const u8, &.{
        &.{ "git", "-C", b.pathFromRoot(".") },
        args,
    });
    return b.runAllowFail(command, &code, .ignore);
}
