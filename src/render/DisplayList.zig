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
    z_index: i32 = 0,
    corner_radius: i32 = 0,
    color: Color,
};

pub const TextCommand = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32 = 0,
    z_index: i32 = 0,
    font_size: i32 = 16,
    font_family: []u8 = &.{},
    font_weight: i32 = 400,
    italic: bool = false,
    color: Color,
    underline: bool = false,
    text: []u8,
};

pub const LinkRegion = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32 = 0,
    url: []u8,
    dom_path: []u16 = &.{},
    download_filename: []u8 = &.{},
    open_in_new_tab: bool = false,
    target_name: []u8 = &.{},
};

pub const ControlRegion = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32 = 0,
    dom_path: []u16 = &.{},
};

pub const ImageCommand = struct {
    pub const DrawMode = enum(u8) {
        fit,
        background,
    };

    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32 = 0,
    draw_mode: DrawMode = .fit,
    background_offset_x: i32 = 0,
    background_offset_y: i32 = 0,
    repeat_x: bool = false,
    repeat_y: bool = false,
    url: []u8,
    alt: []u8,
    request_include_credentials: bool = true,
    request_cookie_value: []u8 = &.{},
    request_referer_value: []u8 = &.{},
    request_authorization_value: []u8 = &.{},
};

pub const CanvasCommand = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32 = 0,
    pixel_width: u32,
    pixel_height: u32,
    pixels: []u8,
};

pub const FontFaceFormat = enum(u8) {
    unknown,
    truetype,
    opentype,
    woff,
    woff2,

    pub fn supportsWin32PrivateRegistration(self: FontFaceFormat) bool {
        return switch (self) {
            .truetype, .opentype, .woff, .woff2 => true,
            else => false,
        };
    }
};

pub const FontFaceResource = struct {
    family: []u8,
    format: FontFaceFormat = .unknown,
    bytes: []u8,
};

pub const Command = union(enum) {
    fill_rect: RectCommand,
    stroke_rect: RectCommand,
    text: TextCommand,
    image: ImageCommand,
    canvas: CanvasCommand,

    fn cloneOwned(self: Command, allocator: std.mem.Allocator) !Command {
        return switch (self) {
            .fill_rect => |rect| .{ .fill_rect = rect },
            .stroke_rect => |rect| .{ .stroke_rect = rect },
            .text => |text| .{ .text = .{
                .x = text.x,
                .y = text.y,
                .width = text.width,
                .height = text.height,
                .z_index = text.z_index,
                .font_size = text.font_size,
                .font_family = try allocator.dupe(u8, text.font_family),
                .font_weight = text.font_weight,
                .italic = text.italic,
                .color = text.color,
                .underline = text.underline,
                .text = try allocator.dupe(u8, text.text),
            } },
            .image => |image| .{ .image = .{
                .x = image.x,
                .y = image.y,
                .width = image.width,
                .height = image.height,
                .z_index = image.z_index,
                .draw_mode = image.draw_mode,
                .background_offset_x = image.background_offset_x,
                .background_offset_y = image.background_offset_y,
                .repeat_x = image.repeat_x,
                .repeat_y = image.repeat_y,
                .url = try allocator.dupe(u8, image.url),
                .alt = try allocator.dupe(u8, image.alt),
                .request_include_credentials = image.request_include_credentials,
                .request_cookie_value = try allocator.dupe(u8, image.request_cookie_value),
                .request_referer_value = try allocator.dupe(u8, image.request_referer_value),
                .request_authorization_value = try allocator.dupe(u8, image.request_authorization_value),
            } },
            .canvas => |canvas| .{ .canvas = .{
                .x = canvas.x,
                .y = canvas.y,
                .width = canvas.width,
                .height = canvas.height,
                .z_index = canvas.z_index,
                .pixel_width = canvas.pixel_width,
                .pixel_height = canvas.pixel_height,
                .pixels = try allocator.dupe(u8, canvas.pixels),
            } },
        };
    }

    fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |text| {
                allocator.free(text.font_family);
                allocator.free(text.text);
            },
            .image => |image| {
                allocator.free(image.url);
                allocator.free(image.alt);
                allocator.free(image.request_cookie_value);
                allocator.free(image.request_referer_value);
                allocator.free(image.request_authorization_value);
            },
            .canvas => |canvas| allocator.free(canvas.pixels),
            else => {},
        }
    }
};

pub const DisplayList = @This();

commands: std.ArrayListUnmanaged(Command) = .{},
link_regions: std.ArrayListUnmanaged(LinkRegion) = .{},
control_regions: std.ArrayListUnmanaged(ControlRegion) = .{},
font_faces: std.ArrayListUnmanaged(FontFaceResource) = .{},
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
        allocator.free(region.dom_path);
        allocator.free(region.download_filename);
        allocator.free(region.target_name);
    }
    self.link_regions.deinit(allocator);
    for (self.control_regions.items) |region| {
        allocator.free(region.dom_path);
    }
    self.control_regions.deinit(allocator);
    for (self.font_faces.items) |font_face| {
        allocator.free(font_face.family);
        allocator.free(font_face.bytes);
    }
    self.font_faces.deinit(allocator);
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
            .z_index = region.z_index,
            .url = try allocator.dupe(u8, region.url),
            .dom_path = try allocator.dupe(u16, region.dom_path),
            .download_filename = try allocator.dupe(u8, region.download_filename),
            .open_in_new_tab = region.open_in_new_tab,
            .target_name = try allocator.dupe(u8, region.target_name),
        });
    }
    try copy.control_regions.ensureTotalCapacity(allocator, self.control_regions.items.len);
    for (self.control_regions.items) |region| {
        try copy.control_regions.append(allocator, .{
            .x = region.x,
            .y = region.y,
            .width = region.width,
            .height = region.height,
            .z_index = region.z_index,
            .dom_path = try allocator.dupe(u16, region.dom_path),
        });
    }
    try copy.font_faces.ensureTotalCapacity(allocator, self.font_faces.items.len);
    for (self.font_faces.items) |font_face| {
        try copy.font_faces.append(allocator, .{
            .family = try allocator.dupe(u8, font_face.family),
            .format = font_face.format,
            .bytes = try allocator.dupe(u8, font_face.bytes),
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
        .height = text.height,
        .z_index = text.z_index,
        .font_size = text.font_size,
        .font_family = try allocator.dupe(u8, text.font_family),
        .font_weight = text.font_weight,
        .italic = text.italic,
        .color = text.color,
        .underline = text.underline,
        .text = try allocator.dupe(u8, text.text),
    } });
    self.content_height = @max(self.content_height, text.y + @max(text.height, text.font_size + 8));
}

pub fn addImage(self: *DisplayList, allocator: std.mem.Allocator, image: ImageCommand) !void {
    try self.commands.append(allocator, .{ .image = .{
        .x = image.x,
        .y = image.y,
        .width = image.width,
        .height = image.height,
        .z_index = image.z_index,
        .draw_mode = image.draw_mode,
        .background_offset_x = image.background_offset_x,
        .background_offset_y = image.background_offset_y,
        .repeat_x = image.repeat_x,
        .repeat_y = image.repeat_y,
        .url = try allocator.dupe(u8, image.url),
        .alt = try allocator.dupe(u8, image.alt),
        .request_include_credentials = image.request_include_credentials,
        .request_cookie_value = try allocator.dupe(u8, image.request_cookie_value),
        .request_referer_value = try allocator.dupe(u8, image.request_referer_value),
        .request_authorization_value = try allocator.dupe(u8, image.request_authorization_value),
    } });
    self.content_height = @max(self.content_height, image.y + image.height);
}

pub fn addCanvas(self: *DisplayList, allocator: std.mem.Allocator, canvas: CanvasCommand) !void {
    try self.commands.append(allocator, .{ .canvas = canvas });
    self.content_height = @max(self.content_height, canvas.y + canvas.height);
}

pub fn addLinkRegion(self: *DisplayList, allocator: std.mem.Allocator, region: LinkRegion) !void {
    try self.link_regions.append(allocator, .{
        .x = region.x,
        .y = region.y,
        .width = region.width,
        .height = region.height,
        .z_index = region.z_index,
        .url = try allocator.dupe(u8, region.url),
        .dom_path = try allocator.dupe(u16, region.dom_path),
        .download_filename = try allocator.dupe(u8, region.download_filename),
        .open_in_new_tab = region.open_in_new_tab,
        .target_name = try allocator.dupe(u8, region.target_name),
    });
    self.content_height = @max(self.content_height, region.y + region.height);
}

pub fn addControlRegion(self: *DisplayList, allocator: std.mem.Allocator, region: ControlRegion) !void {
    try self.control_regions.append(allocator, .{
        .x = region.x,
        .y = region.y,
        .width = region.width,
        .height = region.height,
        .z_index = region.z_index,
        .dom_path = try allocator.dupe(u16, region.dom_path),
    });
    self.content_height = @max(self.content_height, region.y + region.height);
}

pub fn addFontFace(self: *DisplayList, allocator: std.mem.Allocator, font_face: FontFaceResource) !void {
    try self.font_faces.append(allocator, .{
        .family = try allocator.dupe(u8, font_face.family),
        .format = font_face.format,
        .bytes = try allocator.dupe(u8, font_face.bytes),
    });
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
                hasher.update(std.mem.asBytes(&rect.z_index));
                hasher.update(std.mem.asBytes(&rect.corner_radius));
                hasher.update(std.mem.asBytes(&rect.color));
            },
            .stroke_rect => |rect| {
                hasher.update("stroke_rect");
                hasher.update(std.mem.asBytes(&rect.x));
                hasher.update(std.mem.asBytes(&rect.y));
                hasher.update(std.mem.asBytes(&rect.width));
                hasher.update(std.mem.asBytes(&rect.height));
                hasher.update(std.mem.asBytes(&rect.z_index));
                hasher.update(std.mem.asBytes(&rect.corner_radius));
                hasher.update(std.mem.asBytes(&rect.color));
            },
            .text => |text| {
                hasher.update("text");
                hasher.update(std.mem.asBytes(&text.x));
                hasher.update(std.mem.asBytes(&text.y));
                hasher.update(std.mem.asBytes(&text.width));
                hasher.update(std.mem.asBytes(&text.height));
                hasher.update(std.mem.asBytes(&text.z_index));
                hasher.update(std.mem.asBytes(&text.font_size));
                hasher.update(text.font_family);
                hasher.update(std.mem.asBytes(&text.font_weight));
                hasher.update(std.mem.asBytes(&text.italic));
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
                hasher.update(std.mem.asBytes(&image.z_index));
                hasher.update(std.mem.asBytes(&image.draw_mode));
                hasher.update(std.mem.asBytes(&image.background_offset_x));
                hasher.update(std.mem.asBytes(&image.background_offset_y));
                hasher.update(std.mem.asBytes(&image.repeat_x));
                hasher.update(std.mem.asBytes(&image.repeat_y));
                hasher.update(image.url);
                hasher.update(image.alt);
                hasher.update(std.mem.asBytes(&image.request_include_credentials));
                hasher.update(image.request_cookie_value);
                hasher.update(image.request_referer_value);
                hasher.update(image.request_authorization_value);
            },
            .canvas => |canvas| {
                hasher.update("canvas");
                hasher.update(std.mem.asBytes(&canvas.x));
                hasher.update(std.mem.asBytes(&canvas.y));
                hasher.update(std.mem.asBytes(&canvas.width));
                hasher.update(std.mem.asBytes(&canvas.height));
                hasher.update(std.mem.asBytes(&canvas.z_index));
                hasher.update(std.mem.asBytes(&canvas.pixel_width));
                hasher.update(std.mem.asBytes(&canvas.pixel_height));
                hasher.update(canvas.pixels);
            },
        }
    }

    for (self.link_regions.items) |region| {
        hasher.update("link_region");
        hasher.update(std.mem.asBytes(&region.x));
        hasher.update(std.mem.asBytes(&region.y));
        hasher.update(std.mem.asBytes(&region.width));
        hasher.update(std.mem.asBytes(&region.height));
        hasher.update(std.mem.asBytes(&region.z_index));
        hasher.update(region.url);
        hasher.update(std.mem.sliceAsBytes(region.dom_path));
        hasher.update(region.download_filename);
        hasher.update(std.mem.asBytes(&region.open_in_new_tab));
        hasher.update(region.target_name);
    }
    for (self.control_regions.items) |region| {
        hasher.update("control_region");
        hasher.update(std.mem.asBytes(&region.x));
        hasher.update(std.mem.asBytes(&region.y));
        hasher.update(std.mem.asBytes(&region.width));
        hasher.update(std.mem.asBytes(&region.height));
        hasher.update(std.mem.asBytes(&region.z_index));
        hasher.update(std.mem.sliceAsBytes(region.dom_path));
    }
    for (self.font_faces.items) |font_face| {
        hasher.update("font_face");
        hasher.update(font_face.family);
        hasher.update(std.mem.asBytes(&font_face.format));
        hasher.update(font_face.bytes);
    }
}
