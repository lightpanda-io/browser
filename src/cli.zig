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
                const is_multiple = @hasField(@TypeOf(option), "multiple") and option.multiple;
                const T, const default = type_and_default: {
                    if (is_multiple) {
                        // We currently don't allow default values for lists.
                        if (@hasField(@TypeOf(option), "default")) unreachable;
                        // If `multiple` provided, prefer `ArrayList`.
                        const T = std.ArrayList(option.type);
                        break :type_and_default .{ T, &@as(T, .{}) };
                    }

                    const T = option.type;
                    break :type_and_default .{ T, &@as(T, option.default) };
                };

                fields[j] = .{
                    .name = option.name,
                    .type = T,
                    .default_value_ptr = @ptrCast(default),
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

                const T = @Type(.{
                    .@"struct" = .{
                        .decls = &.{},
                        .fields = &(optionsToStructFields(options) ++
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
                                .{})),
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

            // TODO: Return error.
            const cmd_str: []const u8 = args.next().?;
            inline for (commands) |command| {
                // Command name together with it's aliases.
                const with_aliases = blk: {
                    if (@hasField(@TypeOf(command), "aliases")) {
                        break :blk command.aliases ++ .{command.name};
                    }

                    break :blk .{command.name};
                };

                inline for (with_aliases) |name| {
                    if (std.mem.eql(u8, cmd_str, name)) {
                        return .{ exec_name, try parseCommand(allocator, command, &args) };
                    }
                }
            }

            // TODO: Unknown command.
            @panic("unknown command");
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
                    // assuming given `option` struct prefer snake_case for name.
                    const kebab_cased = comptime blk: {
                        var output: [option.name.len]u8 = undefined;
                        @memcpy(&output, option.name);
                        std.mem.replaceScalar(u8, &output, '_', '-');
                        break :blk output;
                    };

                    // Match an option.
                    if (std.mem.eql(u8, option_name, "--" ++ option.name) or
                        std.mem.eql(u8, option_name, "--" ++ kebab_cased))
                    {
                        const T = option.type;
                        const option_info = blk: {
                            const info = @typeInfo(T);
                            // If wrapped in optional, prefer the child type.
                            if (info == .optional) break :blk @typeInfo(info.optional.child);
                            break :blk info;
                        };

                        // TODO: Support multiples.
                        const is_multiple = @hasField(@TypeOf(option), "multiple") and option.multiple;

                        switch (option_info) {
                            .int => |int| {
                                const Int = std.meta.Int(int.signedness, int.bits);
                                // TODO: Return correct errors.
                                const v = try std.fmt.parseInt(Int, args.next().?, 10);

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

                                // TODO: Return error.
                                const str = args.next().?;

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

                                // TODO: Return error.
                                const str = args.next().?;

                                if (std.mem.eql(u8, str, "all")) {
                                    // "all" sets all the fields of packed struct.
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
                                if (is_multiple) {
                                    @compileError("multiple option is not supported for enums");
                                }

                                const E = switch (@typeInfo(T)) {
                                    .optional => |optional| optional.child,
                                    inline else => T,
                                };

                                // This type only, we peek ahead to check if there's a following arg.
                                // If there isn't, the default is set already.
                                var peek_args = args.*;
                                if (peek_args.next()) |next_arg| {
                                    const v = std.meta.stringToEnum(E, next_arg) orelse {
                                        return error.UnknownArgument;
                                    };
                                    // Discard.
                                    _ = args.next();

                                    @field(c, option.name) = v;
                                }
                            },
                            .bool => {
                                if (is_multiple) {
                                    @compileError("multiple option is not supported for booleans");
                                }

                                @field(c, option.name) = true;
                            },

                            else => {},
                        }

                        continue :iter_args;
                    }
                }

                // An option we don't know of.
                if (std.mem.startsWith(u8, option_name, "--")) {
                    return error.UnkownOption;
                }

                // Parse positional arg if provided; can be given out of order:
                //
                // lightpanda fetch --wait-ms 2_000 "https://lightpanda.io" --dump "html"
                // ---------------------------------^
                if (comptime @hasField(@TypeOf(command), "positional")) {
                    const positional = command.positional;

                    // Already given one.
                    if (@field(c, positional.name) != null) {
                        return error.TooManyPositionalArgs;
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
                }
            }

            return @unionInit(Union, command.name, c);
        }
    };
}
