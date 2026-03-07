const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const RectCommand = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    color: Color,
};

pub const TextCommand = struct {
    x: i32,
    y: i32,
    width: i32,
    font_size: i32 = 16,
    color: Color,
    underline: bool = false,
    text: []u8,
};

pub const LinkRegion = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    url: []u8,
};

pub const ImageCommand = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    url: []u8,
    alt: []u8,
};

pub const Command = union(enum) {
    fill_rect: RectCommand,
    stroke_rect: RectCommand,
    text: TextCommand,
    image: ImageCommand,

    fn cloneOwned(self: Command, allocator: std.mem.Allocator) !Command {
        return switch (self) {
            .fill_rect => |rect| .{ .fill_rect = rect },
            .stroke_rect => |rect| .{ .stroke_rect = rect },
            .text => |text| .{ .text = .{
                .x = text.x,
                .y = text.y,
                .width = text.width,
                .font_size = text.font_size,
                .color = text.color,
                .underline = text.underline,
                .text = try allocator.dupe(u8, text.text),
            } },
            .image => |image| .{ .image = .{
                .x = image.x,
                .y = image.y,
                .width = image.width,
                .height = image.height,
                .url = try allocator.dupe(u8, image.url),
                .alt = try allocator.dupe(u8, image.alt),
            } },
        };
    }

    fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |text| allocator.free(text.text),
            .image => |image| {
                allocator.free(image.url);
                allocator.free(image.alt);
            },
            else => {},
        }
    }
};

pub const DisplayList = @This();

commands: std.ArrayListUnmanaged(Command) = .{},
link_regions: std.ArrayListUnmanaged(LinkRegion) = .{},
content_height: i32 = 0,
layout_scale: i32 = 100,
page_margin: i32 = 0,

pub fn deinit(self: *DisplayList, allocator: std.mem.Allocator) void {
    for (self.commands.items) |*command| {
        command.deinit(allocator);
    }
    self.commands.deinit(allocator);
    for (self.link_regions.items) |region| {
        allocator.free(region.url);
    }
    self.link_regions.deinit(allocator);
    self.* = .{};
}

pub fn cloneOwned(self: *const DisplayList, allocator: std.mem.Allocator) !DisplayList {
    var copy = DisplayList{
        .content_height = self.content_height,
        .layout_scale = self.layout_scale,
        .page_margin = self.page_margin,
    };
    errdefer copy.deinit(allocator);

    try copy.commands.ensureTotalCapacity(allocator, self.commands.items.len);
    for (self.commands.items) |command| {
        try copy.commands.append(allocator, try command.cloneOwned(allocator));
    }
    try copy.link_regions.ensureTotalCapacity(allocator, self.link_regions.items.len);
    for (self.link_regions.items) |region| {
        try copy.link_regions.append(allocator, .{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
            .url = try allocator.dupe(u8, region.url),
        });
    }
    return copy;
}

pub fn addFillRect(self: *DisplayList, allocator: std.mem.Allocator, rect: RectCommand) !void {
    try self.commands.append(allocator, .{ .fill_rect = rect });
    self.content_height = @max(self.content_height, rect.y + rect.height);
}

pub fn addStrokeRect(self: *DisplayList, allocator: std.mem.Allocator, rect: RectCommand) !void {
    try self.commands.append(allocator, .{ .stroke_rect = rect });
    self.content_height = @max(self.content_height, rect.y + rect.height);
}

pub fn addText(self: *DisplayList, allocator: std.mem.Allocator, text: TextCommand) !void {
    try self.commands.append(allocator, .{ .text = .{
        .x = text.x,
        .y = text.y,
        .width = text.width,
        .font_size = text.font_size,
        .color = text.color,
        .underline = text.underline,
        .text = try allocator.dupe(u8, text.text),
    } });
    self.content_height = @max(self.content_height, text.y + text.font_size + 8);
}

pub fn addImage(self: *DisplayList, allocator: std.mem.Allocator, image: ImageCommand) !void {
    try self.commands.append(allocator, .{ .image = .{
        .x = image.x,
        .y = image.y,
        .width = image.width,
        .height = image.height,
        .url = try allocator.dupe(u8, image.url),
        .alt = try allocator.dupe(u8, image.alt),
    } });
    self.content_height = @max(self.content_height, image.y + image.height);
}

pub fn addLinkRegion(self: *DisplayList, allocator: std.mem.Allocator, region: LinkRegion) !void {
    try self.link_regions.append(allocator, .{
        .x = region.x,
        .y = region.y,
        .width = region.width,
        .height = region.height,
        .url = try allocator.dupe(u8, region.url),
    });
    self.content_height = @max(self.content_height, region.y + region.height);
}

pub fn hashInto(self: *const DisplayList, hasher: anytype) void {
    hasher.update(std.mem.asBytes(&self.content_height));
    hasher.update(std.mem.asBytes(&self.layout_scale));
    hasher.update(std.mem.asBytes(&self.page_margin));

    for (self.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| {
                hasher.update("fill_rect");
                hasher.update(std.mem.asBytes(&rect.x));
                hasher.update(std.mem.asBytes(&rect.y));
                hasher.update(std.mem.asBytes(&rect.width));
                hasher.update(std.mem.asBytes(&rect.height));
                hasher.update(std.mem.asBytes(&rect.color));
            },
            .stroke_rect => |rect| {
                hasher.update("stroke_rect");
                hasher.update(std.mem.asBytes(&rect.x));
                hasher.update(std.mem.asBytes(&rect.y));
                hasher.update(std.mem.asBytes(&rect.width));
                hasher.update(std.mem.asBytes(&rect.height));
                hasher.update(std.mem.asBytes(&rect.color));
            },
            .text => |text| {
                hasher.update("text");
                hasher.update(std.mem.asBytes(&text.x));
                hasher.update(std.mem.asBytes(&text.y));
                hasher.update(std.mem.asBytes(&text.width));
                hasher.update(std.mem.asBytes(&text.font_size));
                hasher.update(std.mem.asBytes(&text.color));
                hasher.update(std.mem.asBytes(&text.underline));
                hasher.update(text.text);
            },
            .image => |image| {
                hasher.update("image");
                hasher.update(std.mem.asBytes(&image.x));
                hasher.update(std.mem.asBytes(&image.y));
                hasher.update(std.mem.asBytes(&image.width));
                hasher.update(std.mem.asBytes(&image.height));
                hasher.update(image.url);
                hasher.update(image.alt);
            },
        }
    }

    for (self.link_regions.items) |region| {
        hasher.update("link_region");
        hasher.update(std.mem.asBytes(&region.x));
        hasher.update(std.mem.asBytes(&region.y));
        hasher.update(std.mem.asBytes(&region.width));
        hasher.update(std.mem.asBytes(&region.height));
        hasher.update(region.url);
    }
}
