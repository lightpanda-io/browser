// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const js = @import("js.zig");
const v8 = js.v8;

const Platform = @This();
handle: *v8.Platform,

pub const Options = struct {
    v8_flags: ?[]const u8 = null,
    // BCP 47 tag; becomes ICU's default locale (Intl, toLocaleString).
    locale: ?[]const u8 = null,
    // IANA id; becomes ICU's default time zone. Null keeps the host zone.
    timezone: ?[]const u8 = null,
};

/// ICU reads LC_ALL and TZ lazily on first use, so the environment must be
/// set here, before InitializeICU and before the platform starts its thread
/// pool (setenv is not safe once other threads may call getenv).
pub fn init(opts: Options) !Platform {
    if (opts.v8_flags) |flags| {
        v8.v8__V8__SetFlagsFromString(flags.ptr, flags.len);
    }

    if (opts.locale) |tag| {
        var buf: [32]u8 = undefined;
        _ = setenv("LC_ALL", posixLocaleId(&buf, tag), 1);
    }
    if (opts.timezone) |id| {
        var buf: [128]u8 = undefined;
        const value = std.fmt.bufPrintZ(&buf, "{s}", .{id}) catch return error.TimezoneTooLong;
        _ = setenv("TZ", value, 1);
    }

    if (v8.v8__V8__InitializeICU() == false) {
        return error.FailedToInitializeICU;
    }
    // 0 - threadpool size, 0 == let v8 decide
    // 1 - idle_task_support, 1 == enabled
    const handle = v8.v8__Platform__NewDefaultPlatform(0, 1).?;
    v8.v8__V8__InitializePlatform(handle);
    v8.v8__V8__Initialize();
    return .{ .handle = handle };
}

pub fn deinit(self: Platform) void {
    _ = v8.v8__V8__Dispose();
    v8.v8__V8__DisposePlatform();
    v8.v8__Platform__DELETE(self.handle);
}

/// `language[_REGION].UTF-8`, the POSIX id ICU parses from LC_ALL. The region
/// is the first 2-letter or 3-digit subtag, so a script subtag is skipped.
/// The tag is assumed valid per Config.validateLocale (language <= 3 bytes).
pub fn posixLocaleId(buf: *[32]u8, tag: []const u8) [:0]const u8 {
    var it = std.mem.splitScalar(u8, tag, '-');
    var language_buf: [3]u8 = undefined;
    const language = std.ascii.lowerString(&language_buf, it.next().?);

    while (it.next()) |subtag| {
        const is_alpha2 = subtag.len == 2 and std.ascii.isAlphabetic(subtag[0]) and std.ascii.isAlphabetic(subtag[1]);
        const is_digit3 = subtag.len == 3 and std.ascii.isDigit(subtag[0]) and std.ascii.isDigit(subtag[1]) and std.ascii.isDigit(subtag[2]);
        if (is_alpha2 or is_digit3) {
            var region_buf: [3]u8 = undefined;
            const region = std.ascii.upperString(&region_buf, subtag);
            return std.fmt.bufPrintZ(buf, "{s}_{s}.UTF-8", .{ language, region }) catch unreachable;
        }
    }
    return std.fmt.bufPrintZ(buf, "{s}.UTF-8", .{language}) catch unreachable;
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, override: c_int) c_int;

test "Platform: posixLocaleId" {
    const cases = [_]struct { tag: []const u8, expected: []const u8 }{
        .{ .tag = "en-US", .expected = "en_US.UTF-8" },
        .{ .tag = "de-DE", .expected = "de_DE.UTF-8" },
        .{ .tag = "en", .expected = "en.UTF-8" },
        .{ .tag = "zh-Hant-TW", .expected = "zh_TW.UTF-8" },
        .{ .tag = "es-419", .expected = "es_419.UTF-8" },
        .{ .tag = "PT-br", .expected = "pt_BR.UTF-8" },
        .{ .tag = "de-DE-1996", .expected = "de_DE.UTF-8" },
    };
    for (cases) |case| {
        var buf: [32]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, posixLocaleId(&buf, case.tag));
    }
}
