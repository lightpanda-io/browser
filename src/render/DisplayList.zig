const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

pub const ClipRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const RectCommand = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32 = 0,
    corner_radius: i32 = 0,
    clip_rect: ?ClipRect = null,
    opacity: u8 = 255,
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
    clip_rect: ?ClipRect = null,
    opacity: u8 = 255,
    color: Color,
    letter_spacing: i32 = 0,
    word_spacing: i32 = 0,
    underline: bool = false,
    nowrap: bool = false,
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
    pub const invalid_command_index = std.math.maxInt(usize);

    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32 = 0,
    dom_path: []u16 = &.{},
    command_start: usize = invalid_command_index,
    command_end: usize = invalid_command_index,

    pub fn hasCommandSpan(self: *const ControlRegion, command_count: usize) bool {
        if (self.command_start == invalid_command_index or self.command_end == invalid_command_index) {
            return false;
        }
        return self.command_start <= self.command_end and self.command_end <= command_count;
    }

    pub fn clearCommandSpan(self: *ControlRegion) void {
        self.command_start = invalid_command_index;
        self.command_end = invalid_command_index;
    }
};

pub const ImageCommand = struct {
    pub const DrawMode = enum(u8) {
        fit,
        background,
    };

    pub const ObjectFitMode = enum(u8) {
        fill,
        contain,
        cover,
        none,
        scale_down,
    };

    pub const BackgroundPositionMode = enum(u8) {
        offset,
        center,
        far,
        percent,
    };

    pub const BackgroundSizeMode = enum(u8) {
        natural,
        explicit,
        contain,
        cover,
    };

    pub const BackgroundSizeComponentMode = enum(u8) {
        auto,
        px,
        percent,
    };

    x: i32,
    y: i32,
    width: i32,
    height: i32,
    z_index: i32 = 0,
    clip_rect: ?ClipRect = null,
    draw_mode: DrawMode = .fit,
    object_fit: ObjectFitMode = .fill,
    object_position_x_mode: BackgroundPositionMode = .center,
    object_position_y_mode: BackgroundPositionMode = .center,
    object_position_x_percent_bp: i32 = 0,
    object_position_y_percent_bp: i32 = 0,
    object_position_x_offset: i32 = 0,
    object_position_y_offset: i32 = 0,
    background_offset_x: i32 = 0,
    background_offset_y: i32 = 0,
    background_position_x_mode: BackgroundPositionMode = .offset,
    background_position_y_mode: BackgroundPositionMode = .offset,
    background_position_x_percent_bp: i32 = 0,
    background_position_y_percent_bp: i32 = 0,
    background_size_mode: BackgroundSizeMode = .natural,
    background_size_width_mode: BackgroundSizeComponentMode = .auto,
    background_size_height_mode: BackgroundSizeComponentMode = .auto,
    background_size_width: i32 = 0,
    background_size_height: i32 = 0,
    background_size_width_percent_bp: i32 = 0,
    background_size_height_percent_bp: i32 = 0,
    repeat_x: bool = false,
    repeat_y: bool = false,
    opacity: u8 = 255,
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
    clip_rect: ?ClipRect = null,
    pixel_width: u32,
    pixel_height: u32,
    pixels: []u8,
    opacity: u8 = 255,
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
                .clip_rect = text.clip_rect,
                .opacity = text.opacity,
                .color = text.color,
                .letter_spacing = text.letter_spacing,
                .word_spacing = text.word_spacing,
                .underline = text.underline,
                .nowrap = text.nowrap,
                .text = try allocator.dupe(u8, text.text),
            } },
            .image => |image| .{ .image = .{
                .x = image.x,
                .y = image.y,
                .width = image.width,
                .height = image.height,
                .z_index = image.z_index,
                .clip_rect = image.clip_rect,
                .draw_mode = image.draw_mode,
                .object_fit = image.object_fit,
                .object_position_x_mode = image.object_position_x_mode,
                .object_position_y_mode = image.object_position_y_mode,
                .object_position_x_percent_bp = image.object_position_x_percent_bp,
                .object_position_y_percent_bp = image.object_position_y_percent_bp,
                .object_position_x_offset = image.object_position_x_offset,
                .object_position_y_offset = image.object_position_y_offset,
                .background_offset_x = image.background_offset_x,
                .background_offset_y = image.background_offset_y,
                .background_position_x_mode = image.background_position_x_mode,
                .background_position_y_mode = image.background_position_y_mode,
                .background_position_x_percent_bp = image.background_position_x_percent_bp,
                .background_position_y_percent_bp = image.background_position_y_percent_bp,
                .background_size_mode = image.background_size_mode,
                .background_size_width_mode = image.background_size_width_mode,
                .background_size_height_mode = image.background_size_height_mode,
                .background_size_width = image.background_size_width,
                .background_size_height = image.background_size_height,
                .background_size_width_percent_bp = image.background_size_width_percent_bp,
                .background_size_height_percent_bp = image.background_size_height_percent_bp,
                .repeat_x = image.repeat_x,
                .repeat_y = image.repeat_y,
                .opacity = image.opacity,
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
                .clip_rect = canvas.clip_rect,
                .pixel_width = canvas.pixel_width,
                .pixel_height = canvas.pixel_height,
                .pixels = try allocator.dupe(u8, canvas.pixels),
                .opacity = canvas.opacity,
            } },
        };
    }

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
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
            .command_start = region.command_start,
            .command_end = region.command_end,
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
        .clip_rect = text.clip_rect,
        .opacity = text.opacity,
        .color = text.color,
        .letter_spacing = text.letter_spacing,
        .word_spacing = text.word_spacing,
        .underline = text.underline,
        .nowrap = text.nowrap,
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
        .clip_rect = image.clip_rect,
        .draw_mode = image.draw_mode,
        .object_fit = image.object_fit,
        .object_position_x_mode = image.object_position_x_mode,
        .object_position_y_mode = image.object_position_y_mode,
        .object_position_x_percent_bp = image.object_position_x_percent_bp,
        .object_position_y_percent_bp = image.object_position_y_percent_bp,
        .object_position_x_offset = image.object_position_x_offset,
        .object_position_y_offset = image.object_position_y_offset,
        .background_offset_x = image.background_offset_x,
        .background_offset_y = image.background_offset_y,
        .background_position_x_mode = image.background_position_x_mode,
        .background_position_y_mode = image.background_position_y_mode,
        .background_position_x_percent_bp = image.background_position_x_percent_bp,
        .background_position_y_percent_bp = image.background_position_y_percent_bp,
        .background_size_mode = image.background_size_mode,
        .background_size_width_mode = image.background_size_width_mode,
        .background_size_height_mode = image.background_size_height_mode,
        .background_size_width = image.background_size_width,
        .background_size_height = image.background_size_height,
        .background_size_width_percent_bp = image.background_size_width_percent_bp,
        .background_size_height_percent_bp = image.background_size_height_percent_bp,
        .repeat_x = image.repeat_x,
        .repeat_y = image.repeat_y,
        .opacity = image.opacity,
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
    try self.commands.append(allocator, .{ .canvas = .{
        .x = canvas.x,
        .y = canvas.y,
        .width = canvas.width,
        .height = canvas.height,
        .z_index = canvas.z_index,
        .clip_rect = canvas.clip_rect,
        .pixel_width = canvas.pixel_width,
        .pixel_height = canvas.pixel_height,
        .pixels = canvas.pixels,
        .opacity = canvas.opacity,
    } });
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
        .command_start = region.command_start,
        .command_end = region.command_end,
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
                hasher.update(std.mem.asBytes(&rect.clip_rect));
                hasher.update(std.mem.asBytes(&rect.opacity));
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
                hasher.update(std.mem.asBytes(&rect.clip_rect));
                hasher.update(std.mem.asBytes(&rect.opacity));
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
                hasher.update(std.mem.asBytes(&text.clip_rect));
                hasher.update(std.mem.asBytes(&text.opacity));
                hasher.update(std.mem.asBytes(&text.color));
                hasher.update(std.mem.asBytes(&text.letter_spacing));
                hasher.update(std.mem.asBytes(&text.word_spacing));
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
                hasher.update(std.mem.asBytes(&image.clip_rect));
                hasher.update(std.mem.asBytes(&image.draw_mode));
                hasher.update(std.mem.asBytes(&image.object_fit));
                hasher.update(std.mem.asBytes(&image.object_position_x_mode));
                hasher.update(std.mem.asBytes(&image.object_position_y_mode));
                hasher.update(std.mem.asBytes(&image.object_position_x_percent_bp));
                hasher.update(std.mem.asBytes(&image.object_position_y_percent_bp));
                hasher.update(std.mem.asBytes(&image.object_position_x_offset));
                hasher.update(std.mem.asBytes(&image.object_position_y_offset));
                hasher.update(std.mem.asBytes(&image.background_offset_x));
                hasher.update(std.mem.asBytes(&image.background_offset_y));
                hasher.update(std.mem.asBytes(&image.background_position_x_mode));
                hasher.update(std.mem.asBytes(&image.background_position_y_mode));
                hasher.update(std.mem.asBytes(&image.background_position_x_percent_bp));
                hasher.update(std.mem.asBytes(&image.background_position_y_percent_bp));
                hasher.update(std.mem.asBytes(&image.background_size_mode));
                hasher.update(std.mem.asBytes(&image.background_size_width_mode));
                hasher.update(std.mem.asBytes(&image.background_size_height_mode));
                hasher.update(std.mem.asBytes(&image.background_size_width));
                hasher.update(std.mem.asBytes(&image.background_size_height));
                hasher.update(std.mem.asBytes(&image.background_size_width_percent_bp));
                hasher.update(std.mem.asBytes(&image.background_size_height_percent_bp));
                hasher.update(std.mem.asBytes(&image.repeat_x));
                hasher.update(std.mem.asBytes(&image.repeat_y));
                hasher.update(std.mem.asBytes(&image.opacity));
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
                hasher.update(std.mem.asBytes(&canvas.clip_rect));
                hasher.update(std.mem.asBytes(&canvas.pixel_width));
                hasher.update(std.mem.asBytes(&canvas.pixel_height));
                hasher.update(std.mem.asBytes(&canvas.opacity));
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

pub fn recomputeContentHeight(self: *DisplayList) void {
    self.content_height = 0;

    for (self.commands.items) |command| {
        switch (command) {
            .fill_rect => |rect| self.content_height = @max(self.content_height, clippedCommandBottom(rect.y, rect.height, rect.clip_rect)),
            .stroke_rect => |rect| self.content_height = @max(self.content_height, clippedCommandBottom(rect.y, rect.height, rect.clip_rect)),
            .text => |text| self.content_height = @max(self.content_height, clippedCommandBottom(text.y, @max(text.height, text.font_size + 8), text.clip_rect)),
            .image => |image| self.content_height = @max(self.content_height, clippedCommandBottom(image.y, image.height, image.clip_rect)),
            .canvas => |canvas| self.content_height = @max(self.content_height, clippedCommandBottom(canvas.y, canvas.height, canvas.clip_rect)),
        }
    }

    for (self.link_regions.items) |region| {
        self.content_height = @max(self.content_height, region.y + region.height);
    }
    for (self.control_regions.items) |region| {
        self.content_height = @max(self.content_height, region.y + region.height);
    }
}

fn clippedCommandBottom(y: i32, height: i32, clip_rect: ?ClipRect) i32 {
    const command_bottom = y + height;
    if (clip_rect) |clip| {
        return @min(command_bottom, clip.y + clip.height);
    }
    return command_bottom;
}

test "hashInto ignores control command span metadata" {
    var list_a = DisplayList{};
    defer list_a.deinit(std.testing.allocator);
    try list_a.addControlRegion(std.testing.allocator, .{
        .x = 10,
        .y = 20,
        .width = 120,
        .height = 32,
        .z_index = 4,
        .dom_path = @constCast(&[_]u16{ 0, 3, 2 }),
        .command_start = 1,
        .command_end = 4,
    });

    var list_b = DisplayList{};
    defer list_b.deinit(std.testing.allocator);
    try list_b.addControlRegion(std.testing.allocator, .{
        .x = 10,
        .y = 20,
        .width = 120,
        .height = 32,
        .z_index = 4,
        .dom_path = @constCast(&[_]u16{ 0, 3, 2 }),
        .command_start = 40,
        .command_end = 44,
    });

    var hasher_a = std.hash.Wyhash.init(0);
    list_a.hashInto(&hasher_a);
    var hasher_b = std.hash.Wyhash.init(0);
    list_b.hashInto(&hasher_b);

    try std.testing.expectEqual(hasher_a.final(), hasher_b.final());
}
