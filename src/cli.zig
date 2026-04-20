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

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Comptime CLI builder that generates a tagged union parser from a
/// declarative command recipe. Each command becomes a union variant whose
/// payload is a struct with one field per option.
///
/// ## Command descriptor fields
///
///   - `name: []const u8` — canonical command name on the command line.
///   - `options: tuple` — tuple of option descriptors (see below). Use `.{}` for none.
///   - `aliases: tuple` (optional) — alternative names for the command.
///   - `shared_options: tuple` (optional) — extra options merged into this
///     command. Useful for common flags shared across commands.
///   - `positional: struct` (optional) — a single positional argument with
///     `.name` and `.type`. Type must be an optional pointer-to-u8 slice
///     (e.g. `?[:0]const u8`). Positionals can appear anywhere in argv.
///
/// ## Option descriptor fields
///
///   - `name: []const u8` — snake_case field name. Both `--snake_case` and
///     `--kebab-case` are accepted on the command line.
///   - `type` — the Zig type of the parsed value (see supported types below).
///   - `default` (optional) — compile-time default when the flag is absent.
///     Rules vary by type; see the defaults section below.
///   - `shortcuts: tuple` (optional) — single-character short flags. Each
///     shortcut is matched as `-X` on the command line.
///   - `multiple: bool` (optional) — when `true`, the field becomes a
///     `std.ArrayList(type)` and each occurrence appends.
///   - `validator: fn` (optional) — custom parse function that replaces the
///     built-in type switch. See the validator section below.
///
/// ## Supported types and their defaults
///
///   - `bool` — presence sets `true`; always defaults to `false`.
///     Specifying `default` is a compile error. `?bool` is not allowed.
///   - Integers (`u8`, `u16`, `u31`, `usize`, etc.) — parsed with
///     `std.fmt.parseInt`. Requires `default` unless wrapped in `?`.
///   - `[]const u8`, `[:0]const u8` (and mutable variants) — string slices,
///     duped from argv. Sentinel is preserved. Requires `default` unless `?`.
///   - Enums — parsed via `std.meta.stringToEnum`. Requires `default` unless `?`.
///   - Packed structs of `bool` fields — parsed from a comma-separated list
///     (e.g. `--strip js,css`). The literal `"all"` sets every field.
///     Requires `default`.
///   - Optional types default to `null` when `default` is omitted.
///
/// ## Validators
///
/// A `validator` is a custom parse function that takes over argument
/// consumption for an option. The expected signature depends on whether
/// `multiple` is set:
///
///   - Single: `fn (Allocator, *ArgIterator) !T` — returns the parsed value.
///   - Multiple: `fn (Allocator, *ArgIterator, *std.ArrayList(T)) !void` —
///     appends directly into the list.
///
/// When a validator is present, the built-in type switch is skipped entirely.
///
/// ## Example
///
/// ```zig
/// const StripMode = packed struct(u2) {
///     js: bool = false,
///     css: bool = false,
/// };
///
/// const WaitUntil = enum { load, domcontentloaded, networkidle };
///
/// const CommonOptions = .{
///     .{ .name = "verbose", .type = bool },
///     .{ .name = "log_level", .type = ?log.Level },
///     .{ .name = "timeout", .type = u31, .default = 30 },
/// };
///
/// const Cli = cli.Builder(.{
///     .{
///         .name = "serve",
///         .aliases = .{"s"},
///         .options = .{
///             .{ .name = "host", .shortcuts = .{"h"}, .type = []const u8, .default = "127.0.0.1" },
///             .{ .name = "port", .shortcuts = .{"p"}, .type = u16, .default = 9222 },
///         },
///         .shared_options = CommonOptions,
///     },
///     .{
///         .name = "fetch",
///         .positional = .{ .name = "url", .type = ?[:0]const u8 },
///         .options = .{
///             .{ .name = "dump", .type = ?DumpFormat, .validator = dumpValidator },
///             .{ .name = "strip", .type = StripMode, .default = .{} },
///             .{ .name = "wait_until", .type = ?WaitUntil },
///             .{ .name = "extra_header", .type = []const u8, .multiple = true },
///         },
///         .shared_options = CommonOptions,
///     },
///     .{ .name = "version", .options = .{} },
///     .{ .name = "help", .aliases = .{ "h", "?" }, .options = .{} },
/// });
///
/// const _, const cmd = try Cli.parse(arena);
/// switch (cmd) {
///     .serve => |opts| listen(opts.host, opts.port),
///     .fetch => |opts| fetch(opts.url.?, opts.dump),
///     .version => printVersion(),
///     .help => printHelp(),
/// }
/// ```
pub fn Builder(comptime commands: anytype) type {
    return struct {
        const Self = @This();

        /// Enum type for provided commands.
        pub const Enum = blk: {
            var enum_fields: [commands.len]std.builtin.Type.EnumField = undefined;
            for (commands, 0..) |command, i| {
                enum_fields[i] = .{ .name = command.name, .value = i };
            }

            break :blk @Type(.{
                .@"enum" = .{
                    .decls = &.{},
                    .fields = &enum_fields,
                    .is_exhaustive = true,
                    .tag_type = std.math.IntFittingRange(0, commands.len),
                },
            });
        };

        /// Creates an array of `StructField` out of given options.
        fn optionsToStructFields(comptime options: anytype) [options.len]std.builtin.Type.StructField {
            var fields: [options.len]std.builtin.Type.StructField = undefined;

            inline for (options, 0..) |option, j| {
                // Whether prefer `ArrayList` for the option.
                const is_multiple = @hasField(@TypeOf(option), "multiple") and option.multiple;
                // Whether option has a default value.
                const has_default = @hasField(@TypeOf(option), "default");

                const T = if (is_multiple) std.ArrayList(option.type) else option.type;

                const default = blk: {
                    if (is_multiple) {
                        // We currently don't allow default values for lists.
                        if (has_default) {
                            @compileError("`default` is not allowed for lists");
                        }
                        // Multiples are always initialized the same.
                        break :blk @as(*const anyopaque, @ptrCast(&@as(T, .{})));
                    }

                    switch (@typeInfo(option.type)) {
                        .optional => |optional| {
                            if (optional.child == bool) {
                                @compileError("?bool is not supported, prefer enum");
                            }

                            // If type is an optional type without default value, prefer null.
                            if (!has_default) {
                                break :blk @as(*const anyopaque, @ptrCast(&@as(T, null)));
                            }
                            // We have default value for an optional.
                            break :blk @as(*const anyopaque, @ptrCast(&@as(T, option.default)));
                        },
                        .bool => {
                            // Prefer `false` if no default.
                            const default = if (has_default) option.default else false;
                            break :blk @as(*const anyopaque, @ptrCast(&@as(T, default)));
                        },
                        inline else => {
                            if (!has_default) {
                                @compileError("option `" ++ option.name ++ "` is not optional type and has no default value");
                            }
                            break :blk @as(*const anyopaque, @ptrCast(&@as(T, option.default)));
                        },
                    }
                };

                fields[j] = .{
                    .name = option.name,
                    .type = T,
                    .default_value_ptr = default,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
                };
            }

            return fields;
        }

        /// Union type for provided commands.
        pub const Union = blk: {
            var union_fields: [commands.len]std.builtin.Type.UnionField = undefined;
            for (commands, 0..) |command, i| {
                const Command = @TypeOf(command);
                const options = command.options;

                const fields = optionsToStructFields(options) ++
                    (if (@hasField(Command, "shared_options"))
                        optionsToStructFields(command.shared_options)
                    else
                        .{}) ++
                    (if (@hasField(Command, "positional"))
                        [1]std.builtin.Type.StructField{
                            .{
                                .name = command.positional.name,
                                .type = command.positional.type,
                                .default_value_ptr = @ptrCast(&@as(command.positional.type, null)),
                                .is_comptime = false,
                                .alignment = @alignOf(command.positional.type),
                            },
                        }
                    else
                        .{});

                const T = @Type(.{
                    .@"struct" = .{
                        .decls = &.{},
                        .fields = &fields,
                        .is_tuple = false,
                        .layout = .auto,
                    },
                });

                union_fields[i] = .{ .name = command.name, .type = T, .alignment = @alignOf(T) };
            }

            break :blk @Type(.{
                .@"union" = .{
                    .decls = &.{},
                    .fields = &union_fields,
                    .layout = .auto,
                    .tag_type = Enum,
                },
            });
        };

        /// Parses executable name, command and options via single call.
        pub fn parse(allocator: Allocator) !struct { []const u8, Union } {
            var args = try std.process.argsWithAllocator(allocator);
            defer args.deinit();

            const exec_name = std.fs.path.basename(args.next().?);

            const cmd_str: []const u8 = args.next() orelse return error.MissingCommand;
            inline for (commands) |command| {
                // Match a command.
                if (std.mem.eql(u8, cmd_str, command.name)) {
                    return .{ exec_name, try parseCommand(allocator, command, &args) };
                }
            }

            // Last resort, try sniffing.
            const command_enum = try sniffCommand(cmd_str);
            // "cmd_str" wasn't a command but an option. We can't reset args, but
            // we can create a new one. Not great, but this fallback is temporary
            // as we transition to this command mode approach.
            args.deinit();
            args = try std.process.argsWithAllocator(allocator);
            // Skip the `exec_name`.
            _ = args.skip();

            inline for (commands) |command| {
                if (std.mem.eql(u8, @tagName(command_enum), command.name)) {
                    return .{ exec_name, try parseCommand(allocator, command, &args) };
                }
            }

            unreachable;
        }

        /// Try to sniff the command out of given option.
        /// Only exists for legacy reasons; hence hardcoded.
        fn sniffCommand(cmd_str: []const u8) error{UnknownCommand}!Enum {
            if (std.mem.startsWith(u8, cmd_str, "--") == false) {
                return .fetch;
            }

            // Fetch heuristics.
            inline for (.{
                "--dump",
                "--strip",
                "--with-base",
                "--with_base",
                "--with-frames",
                "--with_frames",
            }) |heuristic| {
                if (std.mem.eql(u8, cmd_str, heuristic)) {
                    return .fetch;
                }
            }

            // Serve heuristics.
            inline for (.{
                "--host",
                "-h",
                "-H",
                "--port",
                "-p",
                "-P",
                "--timeout",
            }) |heuristic| {
                if (std.mem.eql(u8, cmd_str, heuristic)) {
                    return .serve;
                }
            }

            return error.UnknownCommand;
        }

        /// Parses the command with its options.
        fn parseCommand(
            allocator: Allocator,
            command: anytype,
            args: *std.process.ArgIterator,
        ) !Union {
            const Command = @FieldType(Union, command.name);
            var c = Command{};

            const options = blk: {
                if (@hasField(@TypeOf(command), "shared_options")) {
                    break :blk command.options ++ command.shared_options;
                }

                break :blk command.options;
            };
            iter_args: while (args.next()) |option_name| {
                inline for (options) |option| {
                    // Match an option.
                    const match = blk: {
                        // We allow both `--my-option` and `--my_option` variants;
                        // assuming given `option` struct prefer snake_case for `name`.
                        const kebab_cased = comptime casing: {
                            var output: [option.name.len]u8 = undefined;
                            @memcpy(&output, option.name);
                            std.mem.replaceScalar(u8, &output, '_', '-');
                            break :casing output;
                        };

                        const match =
                            std.mem.eql(u8, option_name, "--" ++ option.name) or
                            std.mem.eql(u8, option_name, "--" ++ kebab_cased);
                        break :blk match;
                    };

                    if (match) {
                        const T = option.type;
                        const option_info = blk: {
                            const info = @typeInfo(T);
                            // If wrapped in optional, prefer the child type.
                            if (info == .optional) break :blk @typeInfo(info.optional.child);
                            break :blk info;
                        };

                        const is_multiple = @hasField(@TypeOf(option), "multiple") and option.multiple;
                        const has_validator = @hasField(@TypeOf(option), "validator");

                        // Prefer custom validator logic instead.
                        if (has_validator) {
                            const validator = option.validator;
                            if (is_multiple) {
                                // Pass the list.
                                try @call(.auto, validator, .{ allocator, args, &@field(c, option.name) });
                            } else {
                                // Receive the value from return.
                                const v = try @call(.auto, validator, .{ allocator, args });
                                @field(c, option.name) = v;
                            }
                        } else {
                            switch (option_info) {
                                .int => |int| {
                                    const Int = std.meta.Int(int.signedness, int.bits);
                                    const v = try std.fmt.parseInt(Int, args.next() orelse return error.MissingArgument, 10);

                                    if (is_multiple) {
                                        // Push to ArrayList.
                                        try @field(c, option.name).append(allocator, v);
                                    } else {
                                        @field(c, option.name) = v;
                                    }
                                },
                                .pointer => |pointer| {
                                    const not_u8_slice = pointer.child != u8 or pointer.size != .slice;
                                    if (not_u8_slice) {
                                        @compileError("Only []u8, []const u8, [:sentinel]u8 and [:sentinel]const u8 pointers are supported");
                                    }

                                    const v = blk: {
                                        const str = args.next() orelse return error.MissingArgument;

                                        // DupeZ branch.
                                        if (comptime pointer.sentinel()) |sentinel| {
                                            const buf = try allocator.alignedAlloc(u8, .fromByteUnits(pointer.alignment), str.len + 1);
                                            @memcpy(buf[0..str.len], str);
                                            buf[str.len] = sentinel;
                                            break :blk buf[0..str.len :sentinel];
                                        }

                                        // Dupe branch.
                                        const buf = try allocator.alignedAlloc(u8, .fromByteUnits(pointer.alignment), str.len);
                                        @memcpy(buf, str);
                                        break :blk buf;
                                    };

                                    if (is_multiple) {
                                        try @field(c, option.name).append(allocator, v);
                                    } else {
                                        @field(c, option.name) = v;
                                    }
                                },
                                .@"struct" => |_struct| {
                                    // Don't support multiple for structs for now.
                                    if (is_multiple) {
                                        @compileError("multiple option is not supported for structs");
                                    }

                                    const not_packed = _struct.layout != .@"packed";
                                    if (not_packed) {
                                        @compileError("only packed structs are allowed");
                                    }

                                    const str = args.next() orelse return error.MissingArgument;

                                    if (std.mem.eql(u8, str, "full")) {
                                        // "full" sets all the fields of packed struct.
                                        const Int = _struct.backing_integer.?;
                                        @field(c, option.name) = @bitCast(@as(Int, std.math.maxInt(Int)));
                                    } else {
                                        // Parse given args.
                                        var it = std.mem.splitScalar(u8, str, ',');
                                        outer: while (it.next()) |part| {
                                            const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);

                                            inline for (_struct.fields) |f| {
                                                std.debug.assert(f.type == bool);

                                                if (std.mem.eql(u8, trimmed, @as([]const u8, f.name))) {
                                                    @field(@field(c, option.name), f.name) = true;
                                                    continue :outer;
                                                }
                                            }
                                        }
                                    }
                                },
                                .@"enum" => {
                                    const E = switch (@typeInfo(T)) {
                                        .optional => |optional| optional.child,
                                        inline else => T,
                                    };

                                    const v = std.meta.stringToEnum(E, args.next() orelse return error.MissingArgument) orelse {
                                        return error.UnknownArgument;
                                    };

                                    if (is_multiple) {
                                        try @field(c, option.name).append(allocator, v);
                                    } else {
                                        @field(c, option.name) = v;
                                    }
                                },
                                .bool => {
                                    if (is_multiple) {
                                        @compileError("multiple option is not supported for booleans");
                                    }

                                    const default = blk: {
                                        if (@hasField(@TypeOf(option), "default")) {
                                            break :blk option.default;
                                        }
                                        break :blk false;
                                    };

                                    // Set opposite of the default.
                                    @field(c, option.name) = !default;
                                },

                                else => {},
                            }
                        }

                        continue :iter_args;
                    }
                }

                // Parse positional arg if provided; can be given out of order:
                //
                // lightpanda fetch --wait-ms 2_000 "https://lightpanda.io" --dump "html"
                // ---------------------------------^
                if (comptime @hasField(@TypeOf(command), "positional")) {
                    const positional = command.positional;

                    // Already given one.
                    if (@field(c, positional.name) != null) {
                        return error.TooManyPositionalArguments;
                    }

                    // The positional must be an optional type.
                    const info = @typeInfo(@typeInfo(positional.type).optional.child);

                    const str = @as([]const u8, option_name);
                    switch (info) {
                        .pointer => |pointer| {
                            const not_u8_slice = pointer.child != u8 or pointer.size != .slice;
                            if (not_u8_slice) {
                                @compileError("Only []u8, []const u8, [:sentinel]u8 and [:sentinel]const u8 pointers are supported");
                            }

                            const v = blk: {
                                // DupeZ branch.
                                if (comptime pointer.sentinel()) |sentinel| {
                                    const buf = try allocator.alignedAlloc(u8, .fromByteUnits(pointer.alignment), str.len + 1);
                                    @memcpy(buf[0..str.len], str);
                                    buf[str.len] = sentinel;
                                    break :blk buf[0..str.len :sentinel];
                                }

                                // Dupe branch.
                                const buf = try allocator.alignedAlloc(u8, .fromByteUnits(pointer.alignment), str.len);
                                @memcpy(buf, str);
                                break :blk buf;
                            };

                            @field(c, positional.name) = v;
                        },
                        inline else => @compileError("not supported"),
                    }
                } else {
                    // An option we don't know of.
                    return error.UnknownOption;
                }
            }

            // Parsing is complete and positional is null.
            const positional_is_null = @hasField(@TypeOf(command), "positional") and @field(c, command.positional.name) == null;
            if (positional_is_null) {
                return error.MissingArgument;
            }

            return @unionInit(Union, command.name, c);
        }
    };
}
