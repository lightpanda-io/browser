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

/// How the executables of this build are compiled and linked.
pub const Link = struct {
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: bool,
    sanitize_c: ?std.zig.SanitizeC,
    sanitize_thread: bool,
};

/// An executable with per-function/per-datum sections, laid out by `script`
/// (none: the input-order layout the profile is taken from). The sections
/// exist only so the script can place individual hot functions; the
/// self-hosted backend used by Debug builds does not support them on the C
/// libraries, so this is release/LLVM only.
pub fn addExe(b: *Build, link: Link, name: []const u8, root_module: *Build.Module, script: ?Build.LazyPath) *Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .use_llvm = link.use_llvm,
        .root_module = root_module,
    });
    exe.link_function_sections = true;
    exe.link_data_sections = true;
    if (script) |s| exe.setLinkerScript(s);
    return exe;
}

/// Renames the hot V8 functions' sections (`.text` -> `.text.hot.<sym>`, see
/// orderfile/mark_hot_sections.zig) so the orderfile script can gather them.
pub fn markHotSections(b: *Build, archive: Build.LazyPath) Build.LazyPath {
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

/// `zig build orderfile`: regenerates orderfile/lightpanda.ld and v8.txt from
/// a profile of the CDP bench, see orderfile/README.md. The bench needs root,
/// a ../demo checkout and node; the build args are those of the release
/// build, -Dorderfile included (it sections the C libraries).
pub fn addStep(b: *Build, link: Link, root_module: *Build.Module, v8_archive: ?Build.LazyPath, orderfile_path: ?[]const u8) void {
    const step = b.step("orderfile", "Regenerate orderfile/lightpanda.ld and v8.txt from a profile of the CDP bench (Linux release build with -Dorderfile; needs root, ../demo and node)");
    if (orderfile_path == null) {
        step.dependOn(&b.addFail("zig build orderfile needs the release build args, -Dorderfile=orderfile/lightpanda.ld included").step);
        return;
    }
    const v8 = v8_archive orelse {
        step.dependOn(&b.addFail("zig build orderfile needs the prebuilt V8 archive (make download-v8)").step);
        return;
    };
    if (link.target.result.os.tag != .linux) {
        step.dependOn(&b.addFail("zig build orderfile is Linux-only (the profile is of a Linux ELF)").step);
        return;
    }

    // The unordered binary. Profiling the layout the current profile produces
    // would keep every stale entry hot by neighbourhood (orderfile/README.md).
    // Named like the release exe: the patterns are scoped to its object's
    // file name.
    const unordered = addExe(b, link, "lightpanda", root_module, null);
    // Zig leaves the compilation's object next to the exe in its cache
    // directory; the linker script scopes the Zig patterns to it.
    const zcu = unordered.getEmittedBin().dirname().path(b, "lightpanda_zcu.o");

    const profile = b.addSystemCommand(&.{"bash"});
    profile.addFileArg(b.path("orderfile/tools/profile.sh"));
    profile.addFileArg(unordered.getEmittedBin());
    const hot = profile.addOutputDirectoryArg("profile");
    profile.has_side_effects = true;

    const gen = b.addSystemCommand(&.{"python3"});
    gen.addFileArg(b.path("orderfile/tools/gen_order.py"));
    gen.addFileArg(hot.path(b, "hot.text"));
    gen.addFileArg(hot.path(b, "hot.rodata"));
    const ld = gen.addOutputFileArg("lightpanda.ld");
    gen.addArg("--v8");
    gen.addFileArg(v8);
    const v8_txt = gen.addOutputFileArg("v8.txt");
    gen.addArg("--stats");
    const stats = gen.addOutputFileArg("gen_order.stats");
    // libc++, libunwind and compiler_rt come from Zig's global cache; the
    // script only needs their members' names, which every copy shares.
    gen.addArg("--zig-cache");
    gen.addArg(b.pathJoin(&.{ b.graph.global_cache_root.path.?, "o" }));
    gen.addFileArg(zcu);
    for (linkInputs(b, root_module)) |input| gen.addFileArg(input);

    // Does it link? The script is an input of the whole compilation, so this
    // is a second compile of the Zig code (the dependencies are cached).
    const ordered = addExe(b, link, "lightpanda", root_module, ld);
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

/// The objects and archives an executable rooted at `root` links,
/// transitively: what its link line lists apart from what Zig supplies itself.
fn linkInputs(b: *Build, root: *Build.Module) []const Build.LazyPath {
    var inputs: std.ArrayList(Build.LazyPath) = .empty;
    var seen: std.AutoHashMapUnmanaged(*Build.Module, void) = .empty;
    collectLinkInputs(b, root, &inputs, &seen);
    return inputs.items;
}

fn collectLinkInputs(b: *Build, mod: *Build.Module, inputs: *std.ArrayList(Build.LazyPath), seen: *std.AutoHashMapUnmanaged(*Build.Module, void)) void {
    if (seen.contains(mod)) return;
    seen.put(b.allocator, mod, {}) catch @panic("OOM");
    for (mod.link_objects.items) |link_object| switch (link_object) {
        .static_path => |path| inputs.append(b.allocator, path) catch @panic("OOM"),
        .other_step => |other| {
            inputs.append(b.allocator, other.getEmittedBin()) catch @panic("OOM");
            collectLinkInputs(b, other.root_module, inputs, seen);
        },
        else => {},
    };
    for (mod.import_table.values()) |import| collectLinkInputs(b, import, inputs, seen);
}
