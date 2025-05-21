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

/// Do not rename this constant. It is scanned by some scripts to determine
/// which zig version to install.
const recommended_zig_version = "0.14.0";

pub fn build(b: *std.Build) !void {
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

    opts.addOption(
        std.log.Level,
        "log_level",
        b.option(std.log.Level, "log_level", "The log level") orelse std.log.Level.info,
    );

    opts.addOption(
        bool,
        "log_unknown_properties",
        b.option(bool, "log_unknown_properties", "Log access to unknown properties") orelse false,
    );

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    {
        // browser
        // -------

        // compile and install
        const exe = b.addExecutable(.{
            .name = "lightpanda",
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
        });

        try common(b, opts, exe);
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

    {
        // tests
        // ----

        // compile
        const tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
            .target = target,
            .optimize = optimize,
        });
        try common(b, opts, tests);

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

        // compile and install
        const wpt = b.addExecutable(.{
            .name = "lightpanda-wpt",
            .root_source_file = b.path("src/main_wpt.zig"),
            .target = target,
            .optimize = optimize,
        });
        try common(b, opts, wpt);

        // run
        const wpt_cmd = b.addRunArtifact(wpt);
        if (b.args) |args| {
            wpt_cmd.addArgs(args);
        }
        // step
        const wpt_step = b.step("wpt", "WPT tests");
        wpt_step.dependOn(&wpt_cmd.step);
    }
}

fn common(b: *std.Build, opts: *std.Build.Step.Options, step: *std.Build.Step.Compile) !void {
    const mod = step.root_module;
    const target = mod.resolved_target.?;
    const optimize = mod.optimize.?;
    const dep_opts = .{ .target = target, .optimize = optimize };

    try moduleNetSurf(b, step, target);
    mod.addImport("tls", b.dependency("tls", dep_opts).module("tls"));
    mod.addImport("tigerbeetle-io", b.dependency("tigerbeetle_io", .{}).module("tigerbeetle_io"));

    {
        // v8
        const v8_opts = b.addOptions();
        v8_opts.addOption(bool, "inspector_subtype", false);

        const v8_mod = b.dependency("v8", dep_opts).module("v8");
        v8_mod.addOptions("default_exports", v8_opts);
        mod.addImport("v8", v8_mod);
    }

    const lib_path = try std.fmt.allocPrint(
        mod.owner.allocator,
        "v8/out/{s}/obj/zig/libc_v8.a",
        .{if (mod.optimize.? == .Debug) "debug" else "release"},
    );
    mod.link_libcpp = true;
    mod.addObjectFile(mod.owner.path(lib_path));

    switch (target.result.os.tag) {
        .macos => {
            // v8 has a dependency, abseil-cpp, which, on Mac, uses CoreFoundation
            mod.addSystemFrameworkPath(.{ .cwd_relative = "/System/Library/Frameworks" });
            mod.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }

    mod.addImport("build_config", opts.createModule());
    mod.addObjectFile(mod.owner.path(lib_path));
}

fn moduleNetSurf(b: *std.Build, step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) !void {
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
    step.addObjectFile(b.path(libiconv_lib_path));
    step.addIncludePath(b.path(libiconv_include_path));

    {
        // mimalloc
        const mimalloc = "vendor/mimalloc";
        const lib_path = try std.fmt.allocPrint(
            b.allocator,
            mimalloc ++ "/out/{s}-{s}/lib/libmimalloc.a",
            .{ @tagName(os), @tagName(arch) },
        );
        step.addObjectFile(b.path(lib_path));
        step.addIncludePath(b.path(mimalloc ++ "/include"));
    }

    // netsurf libs
    const ns = "vendor/netsurf";
    const ns_include_path = try std.fmt.allocPrint(
        b.allocator,
        ns ++ "/out/{s}-{s}/include",
        .{ @tagName(os), @tagName(arch) },
    );
    step.addIncludePath(b.path(ns_include_path));

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
        step.addObjectFile(b.path(ns_lib_path));
        step.addIncludePath(b.path(ns ++ "/" ++ lib ++ "/src"));
    }
}
