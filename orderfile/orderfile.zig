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

//! The build side of the hot-code orderfile, see README.md: the sectioned
//! executables of -Dorderfile builds, the V8 archive rewrite and the
//! `orderfile` step that regenerates the profile.
const std = @import("std");
const Build = std.Build;

/// Per-function/per-datum sections let the linker script place individual
/// hot functions. Only enabled for orderfile (release/LLVM) builds: the
/// self-hosted backend used by Debug builds fails to link the C libraries
/// with them.
pub fn sectionize(compile: *Build.Step.Compile, enabled: bool) *Build.Step.Compile {
    if (enabled) {
        compile.link_function_sections = true;
        compile.link_data_sections = true;
    }
    return compile;
}

/// A sectioned executable laid out by `script`, or in input order without
/// one (the profile is taken from that layout).
fn addExe(b: *Build, name: []const u8, root_module: *Build.Module, use_llvm: bool, script: ?Build.LazyPath) *Build.Step.Compile {
    const exe = sectionize(b.addExecutable(.{
        .name = name,
        .use_llvm = use_llvm,
        .root_module = root_module,
    }), true);
    if (script) |s| exe.setLinkerScript(s);
    return exe;
}

/// One of the host tools in this directory.
fn tool(b: *Build, name: []const u8) *Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("orderfile/{s}.zig", .{name})),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
}

/// Renames the hot V8 functions' sections (`.text` -> `.text.hot.<sym>`, see
/// orderfile/mark_hot_sections.zig) so the orderfile script can gather them.
pub fn markHotSections(b: *Build, archive: Build.LazyPath) Build.LazyPath {
    const run = b.addRunArtifact(tool(b, "mark_hot_sections"));
    run.addFileArg(archive);
    run.addFileArg(b.path("orderfile/v8.txt"));
    return run.addOutputFileArg("libc_v8.a");
}

/// `zig build orderfile`: regenerates orderfile/lightpanda.ld and v8.txt from
/// a profile of the CDP bench, see orderfile/README.md. The bench needs root,
/// a ../demo checkout, node and go; the build args are those of the release
/// build, -Dorderfile included (it sections the C libraries).
pub fn addStep(b: *Build, root_module: *Build.Module, use_llvm: bool, v8_archive: ?Build.LazyPath, sectioned: bool) void {
    const step = b.step("orderfile", "Regenerate orderfile/lightpanda.ld and v8.txt from a profile of the CDP bench (Linux release build with -Dorderfile; needs root, ../demo and node)");
    const unmet: ?[]const u8 = if (!sectioned)
        "zig build orderfile needs the release build args, -Dorderfile=orderfile/lightpanda.ld included"
    else if (v8_archive == null)
        "zig build orderfile needs the prebuilt V8 archive (make download-v8)"
    else if (root_module.resolved_target.?.result.os.tag != .linux)
        "zig build orderfile is Linux-only (the profile is of a Linux ELF)"
    else
        null;
    if (unmet) |message| {
        step.dependOn(&b.addFail(message).step);
        return;
    }

    // The unordered binary. Profiling the layout the current profile produces
    // would keep every stale entry hot by neighbourhood (orderfile/README.md).
    // Named like the release exe: the patterns are scoped to its object's
    // file name.
    const unordered = addExe(b, "lightpanda", root_module, use_llvm, null);
    // Zig leaves the compilation's object next to the exe in its cache
    // directory; the linker script scopes the Zig patterns to it.
    const zcu = unordered.getEmittedBin().dirname().path(b, "lightpanda_zcu.o");

    const profile = b.addSystemCommand(&.{"bash"});
    profile.addFileArg(b.path("orderfile/profile.sh"));
    profile.addFileArg(unordered.getEmittedBin());
    profile.addFileArg(tool(b, "hotlist").getEmittedBin());
    const hot = profile.addOutputDirectoryArg("profile");
    profile.has_side_effects = true;
    profile.setCwd(b.path("."));

    const gen = b.addRunArtifact(tool(b, "gen_order"));
    gen.addFileArg(hot.path(b, "hot.text"));
    gen.addFileArg(hot.path(b, "hot.rodata"));
    const ld = gen.addOutputFileArg("lightpanda.ld");
    gen.addArg("--v8");
    gen.addFileArg(v8_archive.?);
    const v8_txt = gen.addOutputFileArg("v8.txt");
    const stats = gen.captureStdOut(.{ .basename = "gen_order.stats" });
    // libc++, libunwind and compiler_rt come from Zig's global cache; the
    // generator only needs their members' names, which every copy shares.
    gen.addArg("--zig-cache");
    gen.addArg(b.pathJoin(&.{ b.graph.global_cache_root.path.?, "o" }));
    gen.addFileArg(zcu);
    // The link inputs: every library the exe's module graph links and every
    // object file added to it (the Rust staticlib, the V8 archive). getGraph
    // caches, so this runs after the graph is complete.
    for (unordered.getCompileDependencies(false)) |compile| {
        if (compile != unordered) gen.addFileArg(compile.getEmittedBin());
        for (compile.root_module.getGraph().modules) |mod| {
            for (mod.link_objects.items) |link_object| switch (link_object) {
                .static_path => |path| gen.addFileArg(path),
                else => {},
            };
        }
    }

    // Does it link? The script is an input of the whole compilation, so this
    // is a second compile of the Zig code (the dependencies are cached).
    const ordered = addExe(b, "lightpanda", root_module, use_llvm, ld);
    const smoke = b.addRunArtifact(ordered);
    smoke.addArg("version");

    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(ld, "orderfile/lightpanda.ld");
    update.addCopyFileToSource(v8_txt, "orderfile/v8.txt");
    update.step.dependOn(&smoke.step);

    const report = b.addSystemCommand(&.{"cat"});
    report.addFileArg(hot.path(b, "result.txt"));
    report.addFileArg(stats);
    report.stdio = .inherit;
    report.step.dependOn(&update.step);
    step.dependOn(&report.step);

    // zig-out/orderfile/: the profile for CI to read and upload.
    step.dependOn(&b.addInstallDirectory(.{
        .source_dir = hot,
        .install_dir = .prefix,
        .install_subdir = "orderfile",
    }).step);
    step.dependOn(&b.addInstallFile(stats, "orderfile/gen_order.stats").step);
}
