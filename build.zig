const std = @import("std");

const builtin = @import("builtin");

const jsruntime_path = "vendor/jsruntime-lib/";
const jsruntime = @import("vendor/jsruntime-lib/build.zig");
const jsruntime_pkgs = jsruntime.packages(jsruntime_path);

/// Do not rename this constant. It is scanned by some scripts to determine
/// which zig version to install.
const recommended_zig_version = jsruntime.recommended_zig_version;

pub fn build(b: *std.build.Builder) !void {
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

    const options = try jsruntime.buildOptions(b);

    // browser
    // -------

    // compile and install
    const exe = b.addExecutable(.{
        .name = "browsercore",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    try common(exe, options);
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
        .name = "browsercore-shell",
        .root_source_file = .{ .path = "src/main_shell.zig" },
        .target = target,
        .optimize = mode,
    });
    try common(shell, options);
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
        .root_source_file = .{ .path = "src/run_tests.zig" },
        .test_runner = "src/test_runner.zig",
        .single_threaded = true,
    });
    try common(tests, options);

    // add jsruntime pretty deps
    const pretty = tests.step.owner.createModule(.{
        .source_file = .{ .path = "vendor/jsruntime-lib/src/pretty.zig" },
    });
    tests.addModule("pretty", pretty);

    const run_tests = b.addRunArtifact(tests);
    if (b.args) |args| {
        run_tests.addArgs(args);
    }

    // step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // wpt
    // -----

    // compile and install
    const wpt = b.addExecutable(.{
        .name = "browsercore-wpt",
        .root_source_file = .{ .path = "src/main_wpt.zig" },
        .target = target,
        .optimize = mode,
    });
    try common(wpt, options);
    b.installArtifact(wpt);

    // run
    const wpt_cmd = b.addRunArtifact(wpt);
    if (b.args) |args| {
        wpt_cmd.addArgs(args);
    }
    // step
    const wpt_step = b.step("wpt", "WPT tests");
    wpt_step.dependOn(&wpt_cmd.step);

    // get
    // -----

    // compile and install
    const get = b.addExecutable(.{
        .name = "browsercore-get",
        .root_source_file = .{ .path = "src/main_get.zig" },
        .target = target,
        .optimize = mode,
    });
    try common(get, options);
    b.installArtifact(get);

    // run
    const get_cmd = b.addRunArtifact(get);
    if (b.args) |args| {
        get_cmd.addArgs(args);
    }
    // step
    const get_step = b.step("get", "request URL");
    get_step.dependOn(&get_cmd.step);
}

fn common(
    step: *std.Build.Step.Compile,
    options: jsruntime.Options,
) !void {
    try jsruntime_pkgs.add(step, options);
    linkNetSurf(step);

    // link mimalloc
    step.addObjectFile(.{ .path = "vendor/mimalloc/out/libmimalloc.a" });
    step.addIncludePath(.{ .path = "vendor/mimalloc/include" });
}

fn linkNetSurf(step: *std.build.LibExeObjStep) void {

    // iconv
    step.addObjectFile(.{ .path = "vendor/libiconv/lib/libiconv.a" });
    step.addIncludePath(.{ .path = "vendor/libiconv/include" });

    // netsurf libs
    const ns = "vendor/netsurf";
    const libs: [4][]const u8 = .{
        "libdom",
        "libhubbub",
        "libparserutils",
        "libwapcaplet",
    };
    inline for (libs) |lib| {
        step.addObjectFile(.{ .path = ns ++ "/lib/" ++ lib ++ ".a" });
        step.addIncludePath(.{ .path = ns ++ "/" ++ lib ++ "/src" });
    }
    step.addIncludePath(.{ .path = ns ++ "/include" });
}
