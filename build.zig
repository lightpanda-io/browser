const std = @import("std");

const jsruntime_path: []const u8 = "vendor/jsruntime-lib/";
const jsruntime_pkgs = @import("vendor/jsruntime-lib/build.zig").packages(jsruntime_path);

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // browser
    // -------

    // compile and install
    const exe = b.addExecutable("browsercore", "src/main.zig");
    try common(exe, mode, target);
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
    try common(shell, mode, target);
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
    try common(exe_tests, mode, target);

    // step
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}

fn common(
    step: *std.build.LibExeObjStep,
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,
) !void {
    step.setTarget(target);
    step.setBuildMode(mode);
    try jsruntime_pkgs.add(step, mode);
    linkLexbor(step);
}

fn linkLexbor(step: *std.build.LibExeObjStep) void {
    const lib_path = "../lexbor/liblexbor_static.a";
    step.addObjectFile(lib_path);
    step.addIncludePath("../lexbor/source");
}
