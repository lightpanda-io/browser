// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

//! Shell completion scripts for `lightpanda completion <shell>`, generated
//! from the CLI recipe (flags, accepted values, paths) and help.zon
//! (descriptions), so they can't drift from the parser.

const std = @import("std");
const Writer = std.Io.Writer;

const cli = @import("cli.zig");
const Config = @import("Config.zig");
const Help = @import("help.zon");

const Shell = Config.Shell;
const Values = cli.Completion.Values;

const commands = Config.Commands.completion_spec;

/// Each command's help.zon text, in `commands` order.
const help_texts = blk: {
    var texts: [commands.len][]const u8 = undefined;
    for (commands, &texts) |command, *text| text.* = @field(Help, command.name);
    const frozen = texts;
    break :blk &frozen;
};

const command_names = blk: {
    var names: [commands.len][]const u8 = undefined;
    for (commands, &names) |command, *name| name.* = command.name;
    const frozen = names;
    break :blk &frozen;
};

pub fn write(w: *Writer, shell: Shell, exec_name: []const u8) !void {
    return switch (shell) {
        .bash => writeBash(w, exec_name),
        .fish => writeFish(w, exec_name),
        .zsh => writeZsh(w, exec_name),
    };
}

fn writeFish(w: *Writer, exec_name: []const u8) !void {
    try w.print("complete -c {s} -f\n", .{exec_name});
    for (commands) |command| {
        try w.print("complete -c {s} -n __fish_use_subcommand -a {s} -d '", .{ exec_name, command.name });
        try writeText(w, commandSummary(command.name), exec_name, .fish);
        try w.writeAll("'\n");
    }

    for (commands, help_texts) |command, help_text| {
        const condition = "complete -c {s} -n '__fish_seen_subcommand_from {s}'";
        if (command.positional) |positional| switch (positional.values) {
            .none, .any => {},
            .path => try w.print(condition ++ " -F\n", .{ exec_name, command.name }),
            .one_of, .list_of => |values| {
                try w.print(condition ++ " -a '", .{ exec_name, command.name });
                try writeJoined(w, values);
                try w.writeAll("'\n");
            },
        };
        for (command.flags) |flag| {
            try w.print(condition ++ " -l {s}", .{ exec_name, command.name, flag.name[2..] });
            if (flag.short) |short| try w.print(" -s {c}", .{short});
            switch (flag.values) {
                .none => {},
                .any => try w.writeAll(" -x"),
                .path => try w.writeAll(" -r -F"),
                .one_of, .list_of => |values| {
                    try w.writeAll(" -x -a '");
                    try writeJoined(w, values);
                    try w.writeAll("'");
                },
            }
            try w.writeAll(" -d '");
            try writeText(w, describe(help_text, flag.name), exec_name, .fish);
            try w.writeAll("'\n");
        }
    }
}

fn writeBash(w: *Writer, exec_name: []const u8) !void {
    try w.print(
        \\_{f}() {{
        \\    local cur prev cmd i
        \\    cur="${{COMP_WORDS[COMP_CWORD]}}"
        \\    prev="${{COMP_WORDS[COMP_CWORD-1]}}"
        \\    cmd=""
        \\    for ((i = 1; i < COMP_CWORD; i++)); do
        \\        case "${{COMP_WORDS[i]}}" in
        \\            -*) ;;
        \\            *) cmd="${{COMP_WORDS[i]}}"; break ;;
        \\        esac
        \\    done
        \\
        \\    if [[ -z $cmd ]]; then
        \\        COMPREPLY=($(compgen -W "
    , .{Ident{ .name = exec_name }});
    try writeJoined(w, command_names);
    try w.writeAll(
        \\" -- "$cur"))
        \\        return
        \\    fi
        \\
        \\    case "$cmd" in
        \\
    );

    for (commands) |command| {
        try w.print("        {s})\n            case \"$prev\" in\n", .{command.name});
        for (command.flags) |flag| {
            if (flag.values == .none) continue;
            try w.print("                {s}", .{flag.name});
            if (flag.short) |short| try w.print("|-{c}", .{short});
            try w.writeAll(") ");
            try writeBashAction(w, flag.values);
            try w.writeAll("return ;;\n");
        }
        try w.writeAll("            esac\n            if [[ $cur == -* ]]; then\n                COMPREPLY=($(compgen -W \"");
        for (command.flags, 0..) |flag, i| {
            if (i > 0) try w.writeAll(" ");
            try w.writeAll(flag.name);
            if (flag.short) |short| try w.print(" -{c}", .{short});
        }
        try w.writeAll("\" -- \"$cur\"))\n");
        if (command.positional) |positional| if (positional.values != .any) {
            try w.writeAll("            else\n                ");
            try writeBashAction(w, positional.values);
            try w.writeAll("\n");
        };
        try w.writeAll("            fi\n            ;;\n");
    }

    try w.print("    esac\n}}\ncomplete -F _{f} {s}\n", .{ Ident{ .name = exec_name }, exec_name });
}

fn writeBashAction(w: *Writer, values: Values) !void {
    switch (values) {
        .none, .any => {},
        .path => try w.writeAll("compopt -o filenames 2>/dev/null; mapfile -t COMPREPLY < <(compgen -f -- \"$cur\"); "),
        .one_of => |one_of| {
            try w.writeAll("COMPREPLY=($(compgen -W \"");
            try writeJoined(w, one_of);
            try w.writeAll("\" -- \"$cur\")); ");
        },
        .list_of => |list_of| {
            // Complete the item after the last comma.
            try w.writeAll("COMPREPLY=($(compgen -P \"${cur%\"${cur##*,}\"}\" -W \"");
            try writeJoined(w, list_of);
            try w.writeAll("\" -- \"${cur##*,}\")); ");
        },
    }
}

fn writeZsh(w: *Writer, exec_name: []const u8) !void {
    const ident: Ident = .{ .name = exec_name };
    try w.print(
        \\#compdef {s}
        \\
        \\_{f}() {{
        \\    local curcontext="$curcontext" state line
        \\    typeset -A opt_args
        \\    _arguments -C '1: :->command' '*:: :->args'
        \\    case $state in
        \\        command)
        \\            local -a commands=(
        \\
    , .{ exec_name, ident });
    for (commands) |command| {
        try w.print("                '{s}:", .{command.name});
        try writeText(w, commandSummary(command.name), exec_name, .zsh);
        try w.writeAll("'\n");
    }
    try w.writeAll(
        \\            )
        \\            _describe -t commands command commands
        \\            ;;
        \\        args)
        \\            case $words[1] in
        \\
    );

    for (commands, help_texts) |command, help_text| {
        try w.print("                {s})\n                    _arguments -s", .{command.name});
        for (command.flags) |flag| {
            const description = describe(help_text, flag.name);
            try writeZshFlag(w, flag.name, flag.values, description, exec_name);
            if (flag.short) |short| {
                try writeZshFlag(w, &.{ '-', short }, flag.values, description, exec_name);
            }
        }
        if (command.positional) |positional| {
            try w.print(" \\\n                        '{s}", .{if (positional.multiple) "*" else "1"});
            try writeZshAction(w, positional.name, positional.values);
            try w.writeAll("'");
        }
        try w.writeAll("\n                    ;;\n");
    }

    try w.print(
        \\            esac
        \\            ;;
        \\    esac
        \\}}
        \\
        \\if [ "$funcstack[1]" = "_{f}" ]; then
        \\    _{f} "$@"
        \\else
        \\    compdef _{f} {s}
        \\fi
        \\
    , .{ ident, ident, ident, exec_name });
}

fn writeZshFlag(w: *Writer, name: []const u8, values: Values, description: []const u8, exec_name: []const u8) !void {
    // Every flag is repeatable: `multiple` ones collect, the rest keep the last.
    try w.print(" \\\n                        '*{s}[", .{name});
    try writeText(w, description, exec_name, .zsh);
    try w.writeAll("]");
    try writeZshAction(w, std.mem.trimStart(u8, name, "-"), values);
    try w.writeAll("'");
}

fn writeZshAction(w: *Writer, message: []const u8, values: Values) !void {
    switch (values) {
        .none => {},
        .any => try w.print(":{s}: ", .{message}),
        .path => try w.print(":{s}:_files", .{message}),
        .one_of => |one_of| {
            try w.print(":{s}:(", .{message});
            try writeJoined(w, one_of);
            try w.writeAll(")");
        },
        .list_of => |list_of| {
            try w.print(":{s}:_values -s , {s} ", .{ message, message });
            try writeJoined(w, list_of);
        },
    }
}

fn writeJoined(w: *Writer, items: []const []const u8) !void {
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeAll(" ");
        try w.writeAll(item);
    }
}

/// An exec name as a shell function name, which can't hold `-` or `.`.
const Ident = struct {
    name: []const u8,

    pub fn format(self: Ident, w: *Writer) Writer.Error!void {
        for (self.name) |c| try w.writeByte(if (std.ascii.isAlphanumeric(c)) c else '_');
    }
};

/// Writes help.zon text into a single-quoted string: `{0s}` becomes the exec
/// name and each line break with its indentation a single space. zsh also
/// needs `[]` escaped, as descriptions sit inside `--flag[description]`.
fn writeText(w: *Writer, text: []const u8, exec_name: []const u8, comptime quoting: enum { fish, zsh }) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (std.mem.startsWith(u8, text[i..], "{0s}")) {
            try w.writeAll(exec_name);
            i += 3;
            continue;
        }
        const c = text[i];
        if (c == '\n') {
            while (i + 1 < text.len and text[i + 1] == ' ') i += 1;
            try w.writeByte(' ');
            continue;
        }
        switch (quoting) {
            .fish => switch (c) {
                '\\', '\'' => try w.print("\\{c}", .{c}),
                else => try w.writeByte(c),
            },
            .zsh => switch (c) {
                '\'' => try w.writeAll("'\\''"),
                '[', ']' => try w.print("\\{c}", .{c}),
                else => try w.writeByte(c),
            },
        }
    }
}

fn commandSummary(name: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, Help.general, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len == line.len) continue;
        if (!std.mem.startsWith(u8, trimmed, name)) continue;
        const rest = trimmed[name.len..];
        if (rest.len == 0 or rest[0] != ' ') continue;
        return std.mem.trim(u8, rest, " ");
    }
    return "";
}

/// The first sentence of the flag's description, from the command's own help
/// or else the common options. It can span lines, as written in help.zon.
fn describe(help_text: []const u8, flag: []const u8) []const u8 {
    return findDescription(help_text, flag) orelse findDescription(Help.common_options, flag) orelse "";
}

fn findDescription(text: []const u8, flag: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "  -")) continue;
        var tokens = std.mem.tokenizeAny(u8, line, " ,");
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, flag)) return firstSentence(lines.rest());
        }
    }
    return null;
}

/// `text` starts with the indented description lines that follow a flag.
fn firstSentence(text: []const u8) []const u8 {
    var end: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (trimmed.len == line.len or
            std.mem.startsWith(u8, trimmed, "Defaults") or
            std.mem.startsWith(u8, trimmed, "Allowed values") or
            std.mem.startsWith(u8, trimmed, "e.g.")) break;
        end = lines.index orelse text.len;
    }
    const body = std.mem.trim(u8, text[0..end], " \n");
    return body[0 .. sentenceEnd(body) orelse std.mem.trimEnd(u8, body, ".").len];
}

/// Index of the period closing the first sentence, skipping `e.g.`/`i.e.`.
fn sentenceEnd(text: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '.')) |dot| : (i = dot + 1) {
        if (dot + 1 < text.len and text[dot + 1] != ' ' and text[dot + 1] != '\n') continue;
        if (std.mem.endsWith(u8, text[0..dot], "e.g") or std.mem.endsWith(u8, text[0..dot], "i.e")) continue;
        return dot;
    }
    return null;
}

test "completion: every flag is documented" {
    for (commands, help_texts) |command, help_text| {
        for (command.flags) |flag| {
            if (describe(help_text, flag.name).len == 0) {
                std.debug.print("{s} {s} has no entry in help.zon\n", .{ command.name, flag.name });
                return error.Undocumented;
            }
        }
        try std.testing.expect(commandSummary(command.name).len > 0);
    }
}

test "completion: describe" {
    try std.testing.expectEqualStrings("Path to a file to load cookies from (read-only)", describe(Help.fetch, "--cookie"));
    // e.g. doesn't end the sentence.
    try std.testing.expectEqualStrings("The host to advertise, e.g. in the /json/version response", describe(Help.serve, "--advertise-host"));
    // Found in the common options.
    try std.testing.expectEqualStrings("The log level", describe(Help.serve, "--log-level"));
    try std.testing.expectEqualStrings("", describe(Help.serve, "--nope"));
}

test "completion: fish" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, .fish, "lp");
    const script = out.written();

    const expected = [_][]const u8{
        "complete -c lp -n __fish_use_subcommand -a fetch -d 'fetches the specified URL'\n",
        "complete -c lp -n '__fish_seen_subcommand_from fetch' -l with-base -d ",
        "complete -c lp -n '__fish_seen_subcommand_from fetch' -l cookie -r -F -d ",
        "complete -c lp -n '__fish_seen_subcommand_from fetch' -l dump -x -a 'html markdown ",
        "complete -c lp -n '__fish_seen_subcommand_from agent' -l attach -s a -r -F -d ",
        "complete -c lp -n '__fish_seen_subcommand_from run' -F\n",
        "complete -c lp -n '__fish_seen_subcommand_from completion' -a 'bash fish zsh'\n",
        "complete -c lp -n '__fish_seen_subcommand_from help' -a 'serve fetch ",
    };
    for (expected) |line| {
        if (std.mem.indexOf(u8, script, line) == null) {
            std.debug.print("missing: {s}\n", .{line});
            return error.MissingLine;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, script, "disable-workers") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "{0s}") == null);
}

test "completion: bash and zsh" {
    inline for (.{ Shell.bash, Shell.zsh }) |shell| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try write(&out.writer, shell, "light-panda");
        const script = out.written();
        try std.testing.expect(std.mem.indexOf(u8, script, "_light_panda()") != null);
        try std.testing.expect(std.mem.indexOf(u8, script, "--load-resources") != null);
    }
}
