const std = @import("std");

const jsruntime_path = "vendor/jsruntime-lib/";
const jsruntime = @import("vendor/jsruntime-lib/build.zig");
const jsruntime_pkgs = jsruntime.packages(jsruntime_path);

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const options = try jsruntime.buildOptions(b);

    // browser
    // -------

    // compile and install
    const exe = b.addExecutable("browsercore", "src/main.zig");
    try common(exe, mode, target, options);
    exe.install();

    // run
    const run_cmd = exe.run();
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
    const shell = b.addExecutable("browsercore-shell", "src/main_shell.zig");
    try common(shell, mode, target, options);
    try jsruntime_pkgs.add_shell(shell, mode);
    // do not install shell binary
    shell.install();

    // run
    const shell_cmd = shell.run();
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
    const exe_tests = b.addTest("src/run_tests.zig");
    try common(exe_tests, mode, target, options);

    // step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

fn common(
    step: *std.build.LibExeObjStep,
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,
    options: jsruntime.Options,
) !void {
    step.setTarget(target);
    step.setBuildMode(mode);
    try jsruntime_pkgs.add(step, mode, options);
    linkLexbor(step);
}

fn linkLexbor(step: *std.build.LibExeObjStep) void {
    // cmake . -DLEXBOR_BUILD_SHARED=OFF
    const lib_path = "vendor/lexbor/liblexbor_static.a";
    step.addObjectFile(lib_path);
    step.addIncludePath("vendor/lexbor/source");
}
