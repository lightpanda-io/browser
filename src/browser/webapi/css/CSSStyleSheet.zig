const std = @import("std");
const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Element = @import("../Element.zig");
const Http = @import("../../../http/Http.zig");
const URL = @import("../URL.zig");
const CSSRuleList = @import("CSSRuleList.zig");
const CSSRule = @import("CSSRule.zig");
const CSSStyleDeclaration = @import("CSSStyleDeclaration.zig");
const RawURL = @import("../../URL.zig");

const CSSStyleSheet = @This();
const STYLESHEET_ACCEPT_HEADER: [:0]const u8 = "Accept: text/css,*/*;q=0.1";
const FONT_ACCEPT_HEADER: [:0]const u8 = "Accept: font/woff2,font/woff,font/ttf,font/otf,*/*;q=0.1";

_href: ?[]const u8 = null,
_title: []const u8 = "",
_disabled: bool = false,
_css_rules: ?*CSSRuleList = null,
_owner_rule: ?*CSSRule = null,
_owner_node: ?*Element = null,
_rules: []ParsedRule = &.{},
_font_faces: []ParsedFontFace = &.{},
_request_base_url: ?[:0]const u8 = null,
_request_referer_url: ?[:0]const u8 = null,
_request_include_credentials: bool = true,

const ParsedRule = struct {
    selector_text: []const u8,
    declarations_text: []const u8,
    rule: *CSSRule,
};

pub const FontFaceEntry = struct {
    pub const Format = enum(u8) {
        unknown,
        truetype,
        opentype,
        woff,
        woff2,
    };

    family: []const u8,
    source_url: ?[]const u8 = null,
    format: Format = .unknown,
    font_bytes: []const u8 = &.{},
    loaded: bool = false,
    rule: *CSSRule,
};
const ParsedFontFace = FontFaceEntry;

const ParsedFontSource = struct {
    url_specifier: []const u8,
    format_hint: FontFaceEntry.Format = .unknown,
};

pub fn init(page: *Page) !*CSSStyleSheet {
    return page._factory.create(CSSStyleSheet{});
}

pub fn initWithOwner(owner: *Element, page: *Page) !*CSSStyleSheet {
    return page._factory.create(CSSStyleSheet{ ._owner_node = owner });
}

pub fn getOwnerNode(self: *const CSSStyleSheet) ?*Element {
    return self._owner_node;
}

pub fn getHref(self: *const CSSStyleSheet) ?[]const u8 {
    return self._href;
}

pub fn getTitle(self: *const CSSStyleSheet) []const u8 {
    return self._title;
}

pub fn getDisabled(self: *const CSSStyleSheet) bool {
    return self._disabled;
}

pub fn setDisabled(self: *CSSStyleSheet, disabled: bool) void {
    self._disabled = disabled;
}

pub fn getCssRules(self: *CSSStyleSheet, page: *Page) !*CSSRuleList {
    if (self._css_rules) |rules| return rules;
    const rules = try CSSRuleList.init(page);
    self._css_rules = rules;
    try self.refreshRuleList(page);
    return rules;
}

pub fn getOwnerRule(self: *const CSSStyleSheet) ?*CSSRule {
    return self._owner_rule;
}

pub fn getFontFaces(self: *const CSSStyleSheet) []const FontFaceEntry {
    return self._font_faces;
}

pub fn insertRule(self: *CSSStyleSheet, rule: []const u8, index: u32, page: *Page) !u32 {
    _ = self;
    _ = rule;
    _ = index;
    _ = page;
    return 0;
}

pub fn deleteRule(self: *CSSStyleSheet, index: u32, page: *Page) !void {
    _ = self;
    _ = index;
    _ = page;
}

pub fn replace(self: *CSSStyleSheet, text: []const u8, page: *Page) !js.Promise {
    try self.replaceSync(text, page);
    return page.js.local.?.resolvePromise({});
}

pub fn replaceSync(self: *CSSStyleSheet, text: []const u8, page: *Page) !void {
    var parsed: std.ArrayList(ParsedRule) = .{};
    defer parsed.deinit(page.arena);
    var font_faces: std.ArrayList(ParsedFontFace) = .{};
    defer font_faces.deinit(page.arena);
    var scratch = std.heap.ArenaAllocator.init(page.arena);
    defer scratch.deinit();
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer visited.deinit(scratch.allocator());

    try self.appendParsedRulesFromText(
        &parsed,
        &font_faces,
        text,
        page,
        scratch.allocator(),
        &visited,
        self._request_base_url,
        self._request_referer_url,
        self._request_include_credentials,
    );

    self._rules = try page.arena.dupe(ParsedRule, parsed.items);
    self._font_faces = try page.arena.dupe(ParsedFontFace, font_faces.items);
    try self.refreshRuleList(page);
}

pub fn applyMatchingRules(self: *const CSSStyleSheet, element: *Element, decl: *CSSStyleDeclaration, page: *Page) !void {
    if (self._disabled) return;

    for (self._rules) |entry| {
        if (!(try element.matches(entry.selector_text, page))) {
            continue;
        }
        try decl.applyDeclarationsText(entry.declarations_text, page);
    }
}

fn refreshRuleList(self: *CSSStyleSheet, page: *Page) !void {
    const rules = if (self._css_rules) |rules| rules else return;
    var out: std.ArrayList(*CSSRule) = .{};
    defer out.deinit(page.arena);
    for (self._rules) |entry| {
        try out.append(page.arena, entry.rule);
    }
    for (self._font_faces) |entry| {
        try out.append(page.arena, entry.rule);
    }
    try rules.setRules(page, out.items);
}

const StylesheetFetchContext = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    finished: bool = false,
    failed: ?anyerror = null,
    status: u16 = 0,
};

fn appendParsedRulesFromText(
    self: *CSSStyleSheet,
    parsed: *std.ArrayList(ParsedRule),
    font_faces: *std.ArrayList(ParsedFontFace),
    text: []const u8,
    page: *Page,
    temp: std.mem.Allocator,
    visited: *std.StringHashMapUnmanaged(void),
    base_url: ?[:0]const u8,
    referer_url: ?[:0]const u8,
    include_credentials: bool,
) anyerror!void {
    var cursor: usize = 0;
    while (cursor < text.len) {
        const selector_start = skipWhitespaceAndComments(text, cursor);
        if (selector_start >= text.len) break;

        if (std.mem.startsWith(u8, text[selector_start..], "@import")) {
            const semicolon_index = std.mem.indexOfScalarPos(u8, text, selector_start, ';') orelse break;
            const import_text = std.mem.trim(u8, text[selector_start .. semicolon_index + 1], &std.ascii.whitespace);
            cursor = semicolon_index + 1;

            const import_specifier = parseImportSpecifier(import_text) orelse continue;
            try self.appendImportedRules(
                parsed,
                font_faces,
                import_specifier,
                page,
                temp,
                visited,
                base_url,
                referer_url,
                include_credentials,
            );
            continue;
        }

        if (text[selector_start] == '@') {
            const semicolon_index = std.mem.indexOfScalarPos(u8, text, selector_start, ';');
            const open_index = std.mem.indexOfScalarPos(u8, text, selector_start, '{');
            if (semicolon_index != null and (open_index == null or semicolon_index.? < open_index.?)) {
                cursor = semicolon_index.? + 1;
                continue;
            }
        }

        const open_index = std.mem.indexOfScalarPos(u8, text, selector_start, '{') orelse break;
        const close_index = findMatchingBrace(text, open_index) orelse break;
        cursor = close_index + 1;

        const selector_text = std.mem.trim(u8, text[selector_start..open_index], &std.ascii.whitespace);
        const declarations_text = std.mem.trim(u8, text[open_index + 1 .. close_index], &std.ascii.whitespace);
        if (selector_text.len == 0 or declarations_text.len == 0) continue;

        const rule_text = std.mem.trim(u8, text[selector_start .. close_index + 1], &std.ascii.whitespace);
        if (std.ascii.eqlIgnoreCase(selector_text, "@font-face")) {
            try self.appendFontFaceRule(
                font_faces,
                rule_text,
                declarations_text,
                page,
                temp,
                base_url,
                referer_url,
                include_credentials,
            );
            continue;
        }
        if (selector_text[0] == '@') continue;

        const rule = try CSSRule.init(.style, page);
        try rule.setCssText(rule_text, page);

        try parsed.append(page.arena, .{
            .selector_text = try page.dupeString(selector_text),
            .declarations_text = try page.dupeString(declarations_text),
            .rule = rule,
        });
    }
}

fn appendImportedRules(
    self: *CSSStyleSheet,
    parsed: *std.ArrayList(ParsedRule),
    font_faces: *std.ArrayList(ParsedFontFace),
    import_specifier: []const u8,
    page: *Page,
    temp: std.mem.Allocator,
    visited: *std.StringHashMapUnmanaged(void),
    base_url: ?[:0]const u8,
    referer_url: ?[:0]const u8,
    include_credentials: bool,
) anyerror!void {
    const current_base = base_url orelse return;
    const resolved_url = try URL.resolve(temp, current_base, import_specifier, .{ .encode = true, .always_dupe = true });
    const gop = try visited.getOrPut(temp, resolved_url);
    if (gop.found_existing) {
        return;
    }
    gop.key_ptr.* = resolved_url;

    const import_css = try fetchStylesheetText(page, temp, resolved_url, referer_url, include_credentials);
    try self.appendParsedRulesFromText(
        parsed,
        font_faces,
        import_css,
        page,
        temp,
        visited,
        resolved_url,
        resolved_url,
        include_credentials,
    );
}

fn fetchStylesheetText(
    page: *Page,
    temp: std.mem.Allocator,
    url: [:0]const u8,
    referer_url: ?[:0]const u8,
    include_credentials: bool,
) ![]const u8 {
    const request_url = try stylesheetRequestUrlForFetch(temp, url, include_credentials);
    const import_client = try page._session.browser.app.http.createClient(temp);
    defer import_client.deinit();

    var headers = try import_client.newHeaders();
    try headers.add(STYLESHEET_ACCEPT_HEADER);
    try page.headersForRequestWithPolicy(page.arena, request_url, &headers, .{
        .include_credentials = include_credentials,
        .referer_override_url = referer_url,
    });

    var ctx = StylesheetFetchContext{
        .allocator = temp,
        .buffer = .{},
    };
    defer ctx.buffer.deinit(temp);

    try import_client.request(.{
        .url = request_url,
        .ctx = &ctx,
        .method = .GET,
        .frame_id = page._frame_id,
        .headers = headers,
        .cookie_jar = if (include_credentials) page._session.cookie_jar else null,
        .resource_type = .stylesheet,
        .notification = page._session.notification,
        .header_callback = importedStylesheetHeaderCallback,
        .data_callback = importedStylesheetDataCallback,
        .done_callback = importedStylesheetDoneCallback,
        .error_callback = importedStylesheetErrorCallback,
    });

    while (!ctx.finished and ctx.failed == null) {
        _ = try import_client.tick(50);
    }
    if (ctx.failed) |err| return err;
    return try temp.dupe(u8, ctx.buffer.items);
}

fn appendFontFaceRule(
    self: *CSSStyleSheet,
    font_faces: *std.ArrayList(ParsedFontFace),
    rule_text: []const u8,
    declarations_text: []const u8,
    page: *Page,
    temp: std.mem.Allocator,
    base_url: ?[:0]const u8,
    referer_url: ?[:0]const u8,
    include_credentials: bool,
) !void {
    _ = self;
    const family_value = parseDeclarationValue(declarations_text, "font-family") orelse return;
    const family = parseCssStringLikeValue(family_value) orelse std.mem.trim(u8, family_value, &std.ascii.whitespace);
    if (family.len == 0) {
        return;
    }

    const rule = try CSSRule.init(.font_face, page);
    try rule.setCssText(rule_text, page);

    const src_value = parseDeclarationValue(declarations_text, "src");
    var source_url: ?[]const u8 = null;
    var loaded = true;
    var format: FontFaceEntry.Format = .unknown;
    var font_bytes: []const u8 = &.{};
    if (src_value) |raw_src| {
        if (base_url) |current_base| {
            const sources = try parseFontFaceSources(temp, raw_src);
            const selected_source = choosePreferredFontFaceSource(sources);
            if (selected_source) |source| {
                const resolved_url = try URL.resolve(temp, current_base, source.url_specifier, .{ .encode = true, .always_dupe = true });
                source_url = try page.dupeString(resolved_url);
                const fetch_result = fetchFontFaceSource(page, temp, resolved_url, source.format_hint, referer_url, include_credentials) catch FontFetchResult{};
                loaded = fetch_result.loaded;
                format = fetch_result.format;
                if (fetch_result.font_bytes.len > 0) {
                    font_bytes = try page.arena.dupe(u8, fetch_result.font_bytes);
                }
            }
        }
    }

    try font_faces.append(page.arena, .{
        .family = try page.dupeString(family),
        .source_url = source_url,
        .format = format,
        .font_bytes = font_bytes,
        .loaded = loaded,
        .rule = rule,
    });
}

const FontFetchContext = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    finished: bool = false,
    failed: ?anyerror = null,
    status: u16 = 0,
};

const FontFetchResult = struct {
    loaded: bool = false,
    format: FontFaceEntry.Format = .unknown,
    font_bytes: []const u8 = &.{},
};

fn fetchFontFaceSource(
    page: *Page,
    temp: std.mem.Allocator,
    url: [:0]const u8,
    format_hint: FontFaceEntry.Format,
    referer_url: ?[:0]const u8,
    include_credentials: bool,
) !FontFetchResult {
    const detected_format = detectFontFaceFormat(url);
    const format = if (format_hint != .unknown) format_hint else detected_format;
    const request_url = try stylesheetRequestUrlForFetch(temp, url, include_credentials);
    const font_client = try page._session.browser.app.http.createClient(temp);
    defer font_client.deinit();

    var headers = try font_client.newHeaders();
    try headers.add(FONT_ACCEPT_HEADER);
    try page.headersForRequestWithPolicy(page.arena, request_url, &headers, .{
        .include_credentials = include_credentials,
        .referer_override_url = referer_url,
    });

    var ctx = FontFetchContext{
        .allocator = temp,
        .buffer = .{},
    };
    defer ctx.buffer.deinit(temp);
    try font_client.request(.{
        .url = request_url,
        .ctx = &ctx,
        .method = .GET,
        .frame_id = page._frame_id,
        .headers = headers,
        .cookie_jar = if (include_credentials) page._session.cookie_jar else null,
        .resource_type = .font,
        .notification = page._session.notification,
        .header_callback = fontFetchHeaderCallback,
        .data_callback = fontFetchDataCallback,
        .done_callback = fontFetchDoneCallback,
        .error_callback = fontFetchErrorCallback,
    });

    while (!ctx.finished and ctx.failed == null) {
        _ = try font_client.tick(50);
    }
    if (ctx.failed != null) {
        return .{
            .loaded = false,
            .format = format,
        };
    }
    const loaded = ctx.status > 0 and ctx.status < 400;
    return .{
        .loaded = loaded,
        .format = format,
        .font_bytes = if (loaded and formatSupportsEmbeddedBytes(format))
            try temp.dupe(u8, ctx.buffer.items)
        else
            &.{},
    };
}

fn fontFetchHeaderCallback(transfer: *Http.Transfer) !bool {
    const ctx: *FontFetchContext = @ptrCast(@alignCast(transfer.ctx));
    const response_header = transfer.response_header orelse return true;
    ctx.status = response_header.status;
    if (response_header.status >= 400) {
        ctx.failed = error.BadStatusCode;
    }
    return true;
}

fn fontFetchDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const ctx: *FontFetchContext = @ptrCast(@alignCast(transfer.ctx));
    try ctx.buffer.appendSlice(ctx.allocator, data);
}

fn fontFetchDoneCallback(ctx_ptr: *anyopaque) !void {
    const ctx: *FontFetchContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.finished = true;
}

fn fontFetchErrorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
    const ctx: *FontFetchContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.failed = err;
}

fn importedStylesheetHeaderCallback(transfer: *Http.Transfer) !bool {
    const ctx: *StylesheetFetchContext = @ptrCast(@alignCast(transfer.ctx));
    const response_header = transfer.response_header orelse return true;
    ctx.status = response_header.status;
    if (response_header.status >= 400) {
        ctx.failed = error.BadStatusCode;
    }
    return true;
}

fn importedStylesheetDataCallback(transfer: *Http.Transfer, data: []const u8) !void {
    const ctx: *StylesheetFetchContext = @ptrCast(@alignCast(transfer.ctx));
    try ctx.buffer.appendSlice(ctx.allocator, data);
}

fn importedStylesheetDoneCallback(ctx_ptr: *anyopaque) !void {
    const ctx: *StylesheetFetchContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.finished = true;
}

fn importedStylesheetErrorCallback(ctx_ptr: *anyopaque, err: anyerror) void {
    const ctx: *StylesheetFetchContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.failed = err;
}

fn parseImportSpecifier(import_text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, import_text, "@import")) {
        return null;
    }

    var tail = std.mem.trim(u8, import_text["@import".len..], &std.ascii.whitespace);
    if (tail.len == 0) return null;
    if (tail[tail.len - 1] == ';') {
        tail = std.mem.trimRight(u8, tail[0 .. tail.len - 1], &std.ascii.whitespace);
    }
    if (tail.len == 0) return null;

    if (std.mem.startsWith(u8, tail, "url(")) {
        const close_index = std.mem.indexOfScalar(u8, tail, ')') orelse return null;
        var inner = std.mem.trim(u8, tail["url(".len..close_index], &std.ascii.whitespace);
        if (inner.len >= 2 and ((inner[0] == '"' and inner[inner.len - 1] == '"') or (inner[0] == '\'' and inner[inner.len - 1] == '\''))) {
            inner = inner[1 .. inner.len - 1];
        }
        return if (inner.len == 0) null else inner;
    }

    if (tail[0] == '"' or tail[0] == '\'') {
        const quote = tail[0];
        const end_index = std.mem.indexOfScalarPos(u8, tail, 1, quote) orelse return null;
        const inner = tail[1..end_index];
        return if (inner.len == 0) null else inner;
    }

    return null;
}

fn parseDeclarationValue(declarations_text: []const u8, property_name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, declarations_text, ';');
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        const colon_index = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..colon_index], &std.ascii.whitespace);
        if (!std.ascii.eqlIgnoreCase(name, property_name)) continue;
        return std.mem.trim(u8, trimmed[colon_index + 1 ..], &std.ascii.whitespace);
    }
    return null;
}

fn parseCssStringLikeValue(value: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
    if (trimmed.len < 2) return null;
    if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
        (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))
    {
        return trimmed[1 .. trimmed.len - 1];
    }
    return null;
}

fn parseFontFaceSources(allocator: std.mem.Allocator, src: []const u8) ![]ParsedFontSource {
    var out: std.ArrayList(ParsedFontSource) = .{};
    defer out.deinit(allocator);

    var cursor: usize = 0;
    while (cursor < src.len) {
        const url_index = std.mem.indexOfPos(u8, src, cursor, "url(") orelse break;
        const tail = src[url_index + 4 ..];
        const close_index = std.mem.indexOfScalar(u8, tail, ')') orelse break;
        var inner = std.mem.trim(u8, tail[0..close_index], &std.ascii.whitespace);
        if (inner.len >= 2 and ((inner[0] == '"' and inner[inner.len - 1] == '"') or
            (inner[0] == '\'' and inner[inner.len - 1] == '\'')))
        {
            inner = inner[1 .. inner.len - 1];
        }
        if (inner.len == 0) {
            cursor = url_index + 4 + close_index + 1;
            continue;
        }

        const after_url_index = url_index + 4 + close_index + 1;
        const next_url_index = std.mem.indexOfPos(u8, src, after_url_index, "url(") orelse src.len;
        const format_hint = parseFirstFontFaceFormatHint(src[after_url_index..next_url_index]);
        try out.append(allocator, .{
            .url_specifier = try allocator.dupe(u8, inner),
            .format_hint = format_hint,
        });
        cursor = next_url_index;
    }

    return try allocator.dupe(ParsedFontSource, out.items);
}

fn choosePreferredFontFaceSource(sources: []const ParsedFontSource) ?ParsedFontSource {
    for (sources) |source| {
        if (formatSupportsEmbeddedBytes(source.format_hint)) {
            return source;
        }
    }
    return if (sources.len > 0) sources[0] else null;
}

fn parseFirstFontFaceFormatHint(fragment: []const u8) FontFaceEntry.Format {
    const format_index = std.mem.indexOf(u8, fragment, "format(") orelse return .unknown;
    const tail = fragment[format_index + "format(".len ..];
    const close_index = std.mem.indexOfScalar(u8, tail, ')') orelse return .unknown;
    var inner = std.mem.trim(u8, tail[0..close_index], &std.ascii.whitespace);
    if (inner.len >= 2 and ((inner[0] == '"' and inner[inner.len - 1] == '"') or
        (inner[0] == '\'' and inner[inner.len - 1] == '\'')))
    {
        inner = inner[1 .. inner.len - 1];
    }
    if (std.ascii.eqlIgnoreCase(inner, "truetype") or std.ascii.eqlIgnoreCase(inner, "ttf")) {
        return .truetype;
    }
    if (std.ascii.eqlIgnoreCase(inner, "opentype") or std.ascii.eqlIgnoreCase(inner, "otf")) {
        return .opentype;
    }
    if (std.ascii.eqlIgnoreCase(inner, "woff")) {
        return .woff;
    }
    if (std.ascii.eqlIgnoreCase(inner, "woff2")) {
        return .woff2;
    }
    return .unknown;
}

fn detectFontFaceFormat(url: [:0]const u8) FontFaceEntry.Format {
    const pathname = RawURL.getPathname(url);
    const ext = std.fs.path.extension(pathname);
    if (ext.len == 0) {
        return .unknown;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".ttf")) {
        return .truetype;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".otf")) {
        return .opentype;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".woff")) {
        return .woff;
    }
    if (std.ascii.eqlIgnoreCase(ext, ".woff2")) {
        return .woff2;
    }
    return .unknown;
}

fn formatSupportsEmbeddedBytes(format: FontFaceEntry.Format) bool {
    return switch (format) {
        .truetype, .opentype, .woff, .woff2 => true,
        else => false,
    };
}

fn stylesheetRequestUrlForFetch(
    allocator: std.mem.Allocator,
    url: [:0]const u8,
    include_credentials: bool,
) ![:0]const u8 {
    if (include_credentials) {
        return try allocator.dupeZ(u8, url);
    }

    if (RawURL.getUsername(url).len == 0) {
        return try allocator.dupeZ(u8, url);
    }

    return try RawURL.buildUrl(
        allocator,
        RawURL.getProtocol(url),
        RawURL.getHost(url),
        RawURL.getPathname(url),
        RawURL.getSearch(url),
        RawURL.getHash(url),
    );
}

fn skipWhitespaceAndComments(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) {
        if (std.ascii.isWhitespace(text[i])) {
            i += 1;
            continue;
        }
        if (i + 1 < text.len and text[i] == '/' and text[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, text, i + 2, "*/") orelse return text.len;
            i = end + 2;
            continue;
        }
        break;
    }
    return i;
}

fn findMatchingBrace(text: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var i = open_index;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(CSSStyleSheet);

    pub const Meta = struct {
        pub const name = "CSSStyleSheet";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(CSSStyleSheet.init, .{});
    pub const ownerNode = bridge.accessor(CSSStyleSheet.getOwnerNode, null, .{ .null_as_undefined = true });
    pub const href = bridge.accessor(CSSStyleSheet.getHref, null, .{ .null_as_undefined = true });
    pub const title = bridge.accessor(CSSStyleSheet.getTitle, null, .{});
    pub const disabled = bridge.accessor(CSSStyleSheet.getDisabled, CSSStyleSheet.setDisabled, .{});
    pub const cssRules = bridge.accessor(CSSStyleSheet.getCssRules, null, .{});
    pub const ownerRule = bridge.accessor(CSSStyleSheet.getOwnerRule, null, .{});
    pub const insertRule = bridge.function(CSSStyleSheet.insertRule, .{});
    pub const deleteRule = bridge.function(CSSStyleSheet.deleteRule, .{});
    pub const replace = bridge.function(CSSStyleSheet.replace, .{});
    pub const replaceSync = bridge.function(CSSStyleSheet.replaceSync, .{});
};

test "parseDeclarationValue extracts font-face declarations" {
    const declarations =
        \\font-family: "Runner Font";
        \\src: url("font_face_test.woff2") format("woff2");
    ;
    try std.testing.expectEqualStrings("\"Runner Font\"", parseDeclarationValue(declarations, "font-family").?);
    try std.testing.expectEqualStrings("url(\"font_face_test.woff2\") format(\"woff2\")", parseDeclarationValue(declarations, "src").?);
}

test "parseFontFaceSources extracts multiple font sources and format hints" {
    const allocator = std.testing.allocator;
    const sources = try parseFontFaceSources(
        allocator,
        "local(\"Runner\"), url(\"font_face_test.woff2\") format(\"woff2\"), url('private_font_test.ttf') format('truetype')",
    );
    defer {
        for (sources) |source| {
            allocator.free(source.url_specifier);
        }
        allocator.free(sources);
    }

    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("font_face_test.woff2", sources[0].url_specifier);
    try std.testing.expectEqual(FontFaceEntry.Format.woff2, sources[0].format_hint);
    try std.testing.expectEqualStrings("private_font_test.ttf", sources[1].url_specifier);
    try std.testing.expectEqual(FontFaceEntry.Format.truetype, sources[1].format_hint);
}

test "choosePreferredFontFaceSource prefers renderable ttf or otf fallback" {
    const sources = [_]ParsedFontSource{
        .{ .url_specifier = "font_face_test.woff2", .format_hint = .woff2 },
        .{ .url_specifier = "private_font_test.ttf", .format_hint = .truetype },
    };
    const selected = choosePreferredFontFaceSource(sources[0..]).?;
    try std.testing.expectEqualStrings("private_font_test.ttf", selected.url_specifier);
    try std.testing.expectEqual(FontFaceEntry.Format.truetype, selected.format_hint);
}

test "choosePreferredFontFaceSource falls back to first source when only non-renderable formats exist" {
    const sources = [_]ParsedFontSource{
        .{ .url_specifier = "font_face_test.woff2", .format_hint = .woff2 },
        .{ .url_specifier = "font_face_test.woff", .format_hint = .woff },
    };
    const selected = choosePreferredFontFaceSource(sources[0..]).?;
    try std.testing.expectEqualStrings("font_face_test.woff2", selected.url_specifier);
    try std.testing.expectEqual(FontFaceEntry.Format.woff2, selected.format_hint);
}

test "parseFirstFontFaceFormatHint recognizes common hints" {
    try std.testing.expectEqual(FontFaceEntry.Format.truetype, parseFirstFontFaceFormatHint(" format('truetype'), local('Runner')"));
    try std.testing.expectEqual(FontFaceEntry.Format.opentype, parseFirstFontFaceFormatHint(" format(\"opentype\") "));
    try std.testing.expectEqual(FontFaceEntry.Format.woff, parseFirstFontFaceFormatHint(" format('woff') "));
    try std.testing.expectEqual(FontFaceEntry.Format.woff2, parseFirstFontFaceFormatHint(" format('woff2') "));
    try std.testing.expectEqual(FontFaceEntry.Format.unknown, parseFirstFontFaceFormatHint(" local('Runner') "));
}

test "detectFontFaceFormat recognizes supported font extensions" {
    try std.testing.expectEqual(FontFaceEntry.Format.truetype, detectFontFaceFormat("https://font.test/private_font_test.ttf"));
    try std.testing.expectEqual(FontFaceEntry.Format.opentype, detectFontFaceFormat("https://font.test/private_font_test.otf?x=1"));
    try std.testing.expectEqual(FontFaceEntry.Format.woff, detectFontFaceFormat("https://font.test/font.woff#frag"));
    try std.testing.expectEqual(FontFaceEntry.Format.woff2, detectFontFaceFormat("https://font.test/font.woff2"));
    try std.testing.expectEqual(FontFaceEntry.Format.unknown, detectFontFaceFormat("https://font.test/font.bin"));
}

test "formatSupportsEmbeddedBytes only retains ttf and otf bytes" {
    try std.testing.expect(formatSupportsEmbeddedBytes(.truetype));
    try std.testing.expect(formatSupportsEmbeddedBytes(.opentype));
    try std.testing.expect(formatSupportsEmbeddedBytes(.woff));
    try std.testing.expect(formatSupportsEmbeddedBytes(.woff2));
    try std.testing.expect(!formatSupportsEmbeddedBytes(.unknown));
}

const testing = @import("../../../testing.zig");
test "WebApi: CSSStyleSheet" {
    try testing.htmlRunner("css/stylesheet.html", .{});
}
