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

const jsruntime_path = "vendor/zig-js-runtime/";
const jsruntime = @import("vendor/zig-js-runtime/build.zig");
const jsruntime_pkgs = jsruntime.packages(jsruntime_path);

/// Do not rename this constant. It is scanned by some scripts to determine
/// which zig version to install.
const recommended_zig_version = jsruntime.recommended_zig_version;

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

    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});

    const options = jsruntime.buildOptions(b);

    // browser
    // -------

    // compile and install
    const exe = b.addExecutable(.{
        .name = "lightpanda",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = mode,
    });
    try common(b, exe, options);
    b.installArtifact(exe);

    // run
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // step
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // shell
    // -----

    // compile and install
    const shell = b.addExecutable(.{
        .name = "lightpanda-shell",
        .root_source_file = b.path("src/main_shell.zig"),
        .target = target,
        .optimize = mode,
    });
    try common(b, shell, options);
    try jsruntime_pkgs.add_shell(shell);

    // run
    const shell_cmd = b.addRunArtifact(shell);
    if (b.args) |args| {
        shell_cmd.addArgs(args);
    }

    // step
    const shell_step = b.step("shell", "Run JS shell");
    shell_step.dependOn(&shell_cmd.step);

    // test
    // ----

    // compile
    const tests = b.addTest(.{
        .root_source_file = b.path("src/main_tests.zig"),
        .test_runner = b.path("src/main_tests.zig"),
        .target = target,
        .optimize = mode,
    });
    try common(b, tests, options);

    // add jsruntime pretty deps
    tests.root_module.addAnonymousImport("pretty", .{
        .root_source_file = b.path("vendor/zig-js-runtime/src/pretty.zig"),
    });

    const run_tests = b.addRunArtifact(tests);
    if (b.args) |args| {
        run_tests.addArgs(args);
    }

    // step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // unittest
    // ----

    // compile
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .test_runner = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = mode,
    });
    try common(b, unit_tests, options);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    if (b.args) |args| {
        run_unit_tests.addArgs(args);
    }

    // step
    const unit_test_step = b.step("unittest", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // wpt
    // -----

    // compile and install
    const wpt = b.addExecutable(.{
        .name = "lightpanda-wpt",
        .root_source_file = b.path("src/main_wpt.zig"),
        .target = target,
        .optimize = mode,
    });
    try common(b, wpt, options);

    // run
    const wpt_cmd = b.addRunArtifact(wpt);
    if (b.args) |args| {
        wpt_cmd.addArgs(args);
    }
    // step
    const wpt_step = b.step("wpt", "WPT tests");
    wpt_step.dependOn(&wpt_cmd.step);
}

fn common(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    options: jsruntime.Options,
) !void {
    const target = step.root_module.resolved_target.?;
    const jsruntimemod = try jsruntime_pkgs.module(
        b,
        options,
        step.root_module.optimize.?,
        target,
    );
    step.root_module.addImport("jsruntime", jsruntimemod);

    const netsurf = try moduleNetSurf(b, target);
    netsurf.addImport("jsruntime", jsruntimemod);
    step.root_module.addImport("netsurf", netsurf);

    const asyncio = b.addModule("asyncio", .{
        .root_source_file = b.path("vendor/zig-async-io/src/lib.zig"),
    });
    step.root_module.addImport("asyncio", asyncio);

    const tlsmod = b.addModule("tls", .{
        .root_source_file = b.path("vendor/tls.zig/src/main.zig"),
    });
    step.root_module.addImport("tls", tlsmod);

    const wsmod = b.addModule("websocket", .{
        .root_source_file = b.path("vendor/websocket.zig/src/websocket.zig"),
    });
    step.root_module.addImport("websocket", wsmod);
}

fn moduleNetSurf(b: *std.Build, target: std.Build.ResolvedTarget) !*std.Build.Module {
    const mod = b.addModule("netsurf", .{
        .root_source_file = b.path("src/netsurf/netsurf.zig"),
        .target = target,
    });

    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;

    // iconv
    const libiconv_lib_path = try std.fmt.allocPrint(
        mod.owner.allocator,
        "vendor/libiconv/out/{s}-{s}/lib/libiconv.a",
        .{ @tagName(os), @tagName(arch) },
    );
    const libiconv_include_path = try std.fmt.allocPrint(
        mod.owner.allocator,
        "vendor/libiconv/out/{s}-{s}/lib/libiconv.a",
        .{ @tagName(os), @tagName(arch) },
    );
    mod.addObjectFile(b.path(libiconv_lib_path));
    mod.addIncludePath(b.path(libiconv_include_path));

    // mimalloc
    mod.addImport("mimalloc", (try moduleMimalloc(b, target)));

    // netsurf libs
    const ns = "vendor/netsurf";
    const ns_include_path = try std.fmt.allocPrint(
        mod.owner.allocator,
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
            mod.owner.allocator,
            ns ++ "/out/{s}-{s}/lib/" ++ lib ++ ".a",
            .{ @tagName(os), @tagName(arch) },
        );
        mod.addObjectFile(b.path(ns_lib_path));
        mod.addIncludePath(b.path(ns ++ "/" ++ lib ++ "/src"));
    }

    return mod;
}

fn moduleMimalloc(b: *std.Build, target: std.Build.ResolvedTarget) !*std.Build.Module {
    const mod = b.addModule("mimalloc", .{
        .root_source_file = b.path("src/mimalloc/mimalloc.zig"),
        .target = target,
    });

    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;

    const mimalloc = "vendor/mimalloc";
    const lib_path = try std.fmt.allocPrint(
        mod.owner.allocator,
        mimalloc ++ "/out/{s}-{s}/lib/libmimalloc.a",
        .{ @tagName(os), @tagName(arch) },
    );
    mod.addObjectFile(b.path(lib_path));
    mod.addIncludePath(b.path(mimalloc ++ "/include"));

    return mod;
}
