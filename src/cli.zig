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
const lp = @import("lightpanda");
const log = lp.log;

/// Comptime CLI builder that generates a tagged union parser from a
/// declarative command recipe. Each command becomes a union variant whose
/// payload is a struct with one field per option.
///
/// ## Command descriptor fields
///
///   - `name: []const u8` — canonical command name on the command line.
///   - `options: tuple` — tuple of option descriptors (see below). Use `.{}`
///     for none.
///   - `shared_options: tuple` (optional) — extra options merged into this
///     command. Useful for common flags shared across commands.
///   - `positional: struct` (optional) — a single positional argument with
///     `.name` and `.type`. Type must be an optional pointer-to-u8 slice
///     (e.g. `?[:0]const u8`). Positionals can appear anywhere in argv and
///     must be provided; a missing positional returns `error.MissingArgument`.
///
/// ## Option descriptor fields
///
///   - `name: []const u8` — snake_case field name. Both `--snake_case` and
///     `--kebab-case` are accepted on the command line.
///   - `type` — the Zig type of the parsed value (see supported types below).
///   - `default` (optional) — compile-time default when the flag is absent.
///     Rules vary by type; see the defaults section below.
///   - `multiple: bool` (optional) — when `true`, the field becomes a
///     `std.ArrayList(type)` and each occurrence appends. Not supported for
///     `bool` or packed-struct options.
///   - `validator: fn` (optional) — custom parse function that replaces the
///     built-in type switch. See the validator section below.
///
/// ## Supported types and their defaults
///
///   - `bool` — presence flips the field to the opposite of its `default`
///     (so a flag with `default = true` acts as a disable switch). Defaults
///     to `false` when no `default` is given. `?bool` is not allowed.
///   - Integers (`u8`, `u16`, `u31`, `usize`, etc.) — parsed with
///     `std.fmt.parseInt`. Requires `default` unless wrapped in `?`.
///   - `[]const u8`, `[:0]const u8` (and mutable variants) — string slices
///     duped from argv. Sentinel is preserved. Requires `default` unless `?`.
///   - Enums — parsed via `std.meta.stringToEnum`. Returns
///     `error.UnknownArgument` on a bad value. Requires `default` unless `?`.
///   - Packed structs of `bool` fields — parsed from a comma-separated list
///     (e.g. `--strip-mode js,css`). The literal `"full"` sets every field.
///     Unknown names return `error.UnknownArgument`. Requires `default`.
///     `multiple` is not supported.
///   - Optional types default to `null` when `default` is omitted.
///
/// ## Validators
///
/// A `validator` is a custom parse function that takes over argument
/// consumption for an option. Its signature depends on whether `multiple`
/// is set:
///
///   - Single: `fn (Allocator, *ArgIterator) !T` — returns the parsed value.
///   - Multiple: `fn (Allocator, *ArgIterator, *std.ArrayList(T)) !void` —
///     appends directly into the list.
///
/// When a validator is present, the built-in type switch is skipped entirely.
/// The validator owns advancing the iterator and is free to peek ahead.
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
///         .options = .{
///             .{ .name = "host", .type = []const u8, .default = "127.0.0.1" },
///             .{ .name = "port", .type = u16, .default = 9222 },
///         },
///         .shared_options = CommonOptions,
///     },
///     .{
///         .name = "fetch",
///         .positional = .{ .name = "url", .type = ?[:0]const u8 },
///         .options = .{
///             .{ .name = "dump", .type = ?DumpFormat, .validator = dumpValidator },
///             .{ .name = "strip_mode", .type = StripMode, .default = .{} },
///             .{ .name = "wait_until", .type = ?WaitUntil },
///             .{ .name = "extra_header", .type = []const u8, .multiple = true },
///         },
///         .shared_options = CommonOptions,
///     },
///     .{ .name = "version", .options = .{} },
///     .{ .name = "help", .options = .{} },
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

            const cmd_str: []const u8 = args.next() orelse "serve";
            inline for (commands) |command| {
                // Match a command.
                if (std.mem.eql(u8, cmd_str, command.name)) {
                    return .{ exec_name, try parseCommand(allocator, command, &args) };
                }
            }

            // Last resort, try sniffing.
            const command_enum = try sniffCommand(cmd_str);

            // `help` takes no arguments; short-circuit so the sniffed flag
            // isn't re-parsed as an unknown option.
            if (command_enum == .help) {
                return .{ exec_name, .{ .help = .{} } };
            }

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
                "--strip-mode",
                "--strip_mode",
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
                "--port",
                "--timeout",
            }) |heuristic| {
                if (std.mem.eql(u8, cmd_str, heuristic)) {
                    return .serve;
                }
            }

            // Legacy `--help` flag maps to the `help` command.
            if (std.mem.eql(u8, cmd_str, "--help")) {
                return .help;
            }

            return error.UnknownCommand;
        }

        /// Returns the type for validator function.
        pub fn ValidatorFn(comptime T: type, comptime is_multiple: bool) type {
            if (is_multiple) {
                return *const fn (Allocator, *std.process.ArgIterator, *std.ArrayList(T)) anyerror!void;
            }

            return *const fn (Allocator, *std.process.ArgIterator) anyerror!T;
        }

        /// Turns a snake_case string to kebab-case in comptime.
        fn toKebabCase(comptime str: []const u8) [str.len]u8 {
            var output: [str.len]u8 = str[0..str.len].*;
            for (&output) |*c| if (c.* == '_') {
                c.* = '-';
            };
            return output;
        }

        fn parseValue(
            allocator: Allocator,
            args: *std.process.ArgIterator,
            /// Pointer to field; *T.
            target: anytype,
            /// `Option` doesn't have a concrete type; this field expects:
            /// ```zig
            /// Option{
            ///     .name = "option_name",
            ///     .type = T,
            ///     .multiple = ?bool,
            ///     .validator = ?ValidatorFn(T, is_multiple),
            /// };
            /// ```
            option: anytype,
        ) !void {
            const kebab_cased = "--" ++ comptime toKebabCase(option.name);

            const OptionType = @TypeOf(option);
            const is_multiple = @hasField(OptionType, "multiple") and option.multiple;
            const has_validator = @hasField(OptionType, "validator");

            // Prefer validator for parsing if provided.
            if (has_validator) {
                const validator = option.validator;
                if (is_multiple) {
                    // Pass the list.
                    try @call(.auto, validator, .{ allocator, args, target });
                } else {
                    // Receive the value from return.
                    const v = try @call(.auto, validator, .{ allocator, args });
                    target.* = v;
                }

                return;
            }

            // Extract type info.
            const T = option.type;
            const option_info = blk: {
                const info = @typeInfo(T);
                // If wrapped in optional, prefer the child type.
                if (info == .optional) break :blk @typeInfo(info.optional.child);
                break :blk info;
            };

            // Parse by type.
            return switch (option_info) {
                .int => |int| {
                    const Int = std.meta.Int(int.signedness, int.bits);

                    const str = args.next() orelse return error.MissingArgument;
                    const v = std.fmt.parseInt(Int, str, 10) catch |err| {
                        switch (err) {
                            error.Overflow => log.fatal(.app, "range overflow", .{ .arg = kebab_cased, .value = str }),
                            error.InvalidCharacter => log.fatal(.app, "invalid character", .{ .arg = kebab_cased, .value = str }),
                        }
                        return error.InvalidArgument;
                    };

                    if (is_multiple) {
                        // Push to ArrayList.
                        try target.append(allocator, v);
                    } else {
                        target.* = v;
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
                        try target.append(allocator, v);
                    } else {
                        target.* = v;
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
                        const Int = _struct.backing_integer orelse @compileError("packed struct must provide a backing integer");
                        target.* = @bitCast(@as(Int, std.math.maxInt(Int)));
                    } else {
                        // Parse given args.
                        var it = std.mem.tokenizeScalar(u8, str, ',');
                        outer: while (it.next()) |part| {
                            const trimmed = std.mem.trim(u8, part, &std.ascii.whitespace);

                            inline for (_struct.fields) |f| {
                                lp.assert(f.type == bool, "all fields of packed struct must be boolean", .{
                                    .option = option.name,
                                    .field = f.name,
                                });

                                if (std.mem.eql(u8, trimmed, @as([]const u8, f.name))) {
                                    @field(target, f.name) = true;
                                    continue :outer;
                                }
                            }

                            // Invalid option choice.
                            log.fatal(.app, "invalid option choice", .{ .arg = kebab_cased, .value = trimmed });
                            return error.InvalidArgument;
                        }
                    }
                },
                .@"enum" => {
                    const E = switch (@typeInfo(T)) {
                        .optional => |optional| optional.child,
                        inline else => T,
                    };

                    const str = args.next() orelse return error.MissingArgument;
                    const v = std.meta.stringToEnum(E, str) orelse {
                        log.fatal(.app, "invalid option choice", .{ .arg = kebab_cased, .value = str });
                        return error.InvalidArgument;
                    };

                    if (is_multiple) {
                        try target.append(allocator, v);
                    } else {
                        target.* = v;
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
                    target.* = !default;
                },
                else => unreachable,
            };
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
                    // We allow both `--my-option` and `--my_option` variants;
                    // assuming given `option` struct prefer snake_case for `name`.
                    // Match an option.
                    if (std.mem.eql(u8, option_name, "--" ++ option.name) or
                        std.mem.eql(u8, option_name, "--" ++ comptime toKebabCase(option.name)))
                    {
                        try parseValue(allocator, args, &@field(c, option.name), option);
                        continue :iter_args;
                    }

                    const is_multiple = @hasField(@TypeOf(option), "multiple") and option.multiple;
                    // Parse for variants if there are.
                    const has_variants = @hasField(@TypeOf(option), "variants");
                    if (has_variants) {
                        inline for (option.variants) |variant| {
                            if (std.mem.eql(u8, option_name, "--" ++ variant.name) or
                                std.mem.eql(u8, option_name, "--" ++ comptime toKebabCase(variant.name)))
                            {
                                const opts = blk: {
                                    if (@hasField(@TypeOf(variant), "validator")) {
                                        break :blk .{
                                            .name = variant.name,
                                            .type = option.type,
                                            .multiple = is_multiple,
                                            .validator = variant.validator,
                                        };
                                    }

                                    break :blk .{ .name = variant.name, .type = option.type, .multiple = is_multiple };
                                };

                                try parseValue(allocator, args, &@field(c, option.name), opts);
                                continue :iter_args;
                            }
                        }
                    }
                }

                // Encountered an option we don't know of.
                if (std.mem.startsWith(u8, option_name, "--")) {
                    log.fatal(.app, "unknown argument", .{ .mode = command.name, .arg = option_name });
                    return error.UnknownOption;
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
                    log.fatal(.app, "unknown argument", .{ .mode = command.name, .arg = option_name });
                    return error.UnknownOption;
                }
            }

            // A non-optional positional that is still null after parsing is missing.
            if (comptime @hasField(@TypeOf(command), "positional")) {
                const is_optional = @typeInfo(command.positional.type) == .optional;
                if (!is_optional and @field(c, command.positional.name) == null) {
                    return error.MissingArgument;
                }
            }

            return @unionInit(Union, command.name, c);
        }
    };
}
