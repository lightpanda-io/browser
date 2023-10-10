const std = @import("std");

const jsruntime_path = "vendor/jsruntime-lib/";
const jsruntime = @import("vendor/jsruntime-lib/build.zig");
const jsruntime_pkgs = jsruntime.packages(jsruntime_path);

pub fn build(b: *std.build.Builder) !void {
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
    run_cmd.step.dependOn(b.getInstallStep());
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
    // do not install shell binary
    b.installArtifact(shell);

    // run
    const shell_cmd = b.addRunArtifact(shell);
    shell_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        shell_cmd.addArgs(args);
    }

    // step
    const shell_step = b.step("shell", "Run JS shell");
    shell_step.dependOn(&shell_cmd.step);

    // test
    // ----

    // compile
    const tests = b.addTest(.{ .root_source_file = .{ .path = "src/run_tests.zig" } });
    try common(tests, options);
    tests.single_threaded = true;
    const run_tests = b.addRunArtifact(tests);

    // step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // wpt
    // -----

    // compile and install
    const wpt = b.addExecutable(.{
        .name = "browsercore-wpt",
        .root_source_file = .{ .path = "src/run_wpt.zig" },
        .target = target,
        .optimize = mode,
    });
    try common(wpt, options);
    b.installArtifact(wpt);

    // run
    const wpt_cmd = b.addRunArtifact(wpt);
    wpt_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        wpt_cmd.addArgs(args);
    }
    // step
    const wpt_step = b.step("wpt", "WPT tests");
    wpt_step.dependOn(&wpt_cmd.step);
}

fn common(
    step: *std.Build.CompileStep,
    options: jsruntime.Options,
) !void {
    try jsruntime_pkgs.add(step, options);
    linkLexbor(step);
    linkNetSurf(step);
}

fn linkLexbor(step: *std.build.LibExeObjStep) void {
    // cmake . -DLEXBOR_BUILD_SHARED=OFF
    const lib_path = "vendor/lexbor/liblexbor_static.a";
    step.addObjectFile(.{ .path = lib_path });
    step.addIncludePath(.{ .path = "vendor/lexbor-src/source" });
}

fn linkNetSurf(step: *std.build.LibExeObjStep) void {

    // iconv
    step.addObjectFile(.{ .path = "vendor/libiconv/lib/libiconv.a" });
    step.addIncludePath(.{ .path = "vendor/libiconv/include" });

    // netsurf libs
    const ns = "vendor/netsurf/";
    const libs: [4][]const u8 = .{
        "libdom",
        "libhubbub",
        "libparserutils",
        "libwapcaplet",
    };
    inline for (libs) |lib| {
        step.addObjectFile(.{ .path = ns ++ "/lib/" ++ lib ++ ".a" });
        step.addIncludePath(.{ .path = ns ++ lib ++ "/src" });
    }
    step.addIncludePath(.{ .path = ns ++ "/include" });

    // wrapper
    const flags = [_][]const u8{};
    const files: [1][]const u8 = .{ns ++ "wrapper/wrapper.c"};
    step.addCSourceFiles(&files, &flags);
    step.addIncludePath(.{ .path = ns ++ "wrapper" });
}
