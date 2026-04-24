const std = @import("std");
const log = @import("../log.zig");

const Page = @import("../browser/Page.zig");
const Config = @import("../Config.zig");
const AdFilter = @import("../network/AdFilter.zig");

pub const CosmeticFilter = struct {
    allocator: std.mem.Allocator,
    config: *const Config.AdblockConfig,
    ad_filter: ?*const AdFilter.AdFilter,
    selector_cache: std.StringArrayHashMap(bool),

    pub fn init(allocator: std.mem.Allocator, config: *const Config.AdblockConfig, ad_filter: ?*const AdFilter.AdFilter) !CosmeticFilter {
        return CosmeticFilter{
            .allocator = allocator,
            .config = config,
            .ad_filter = ad_filter,
            .selector_cache = std.StringArrayHashMap(bool).init(allocator),
        };
    }

    pub fn apply(filter: *CosmeticFilter, page: *Page) !void {
        if (!filter.config.enable) {
            return;
        }

        if (filter.ad_filter) |ad_filter| {
            if (try ad_filter.getCosmeticFilters(filter.allocator, page.url)) |cosmetics_json| {
                defer filter.allocator.free(cosmetics_json);
                try filter.injectStyles(page, cosmetics_json);
            }
        }

        try filter.injectDefaultRules(page);
        try filter.setupMutationObserver(page);
    }

    fn injectStyles(filter: *CosmeticFilter, page: *Page, cosmetics_json: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(filter.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        // Base64 encode the JSON to safely transport it into the JS context
        // without worrying about complex character escaping strings.
        const base64_encoder = std.base64.standard.Encoder;
        const encoded_len = base64_encoder.calcSize(cosmetics_json.len);
        const encoded_json = try arena_alloc.alloc(u8, encoded_len);
        _ = base64_encoder.encode(encoded_json, cosmetics_json);

        // Note: All literal JS braces must be double-escaped {{ }} when using std.fmt.allocPrint
        const script = try std.fmt.allocPrint(arena_alloc,
            \\(function() {{
            \\  try {{
            \\    const rules = JSON.parse(atob('{s}'));
            \\    if (rules && rules.hide_selectors) {{
            \\      rules.hide_selectors.forEach(function(selector) {{
            \\        try {{
            \\          document.querySelectorAll(selector).forEach(function(el) {{
            \\            el.style.cssText += ';display:none!important;visibility:hidden!important;';
            \\          }});
            \\        }} catch(e) {{}}
            \\      }});
            \\    }}
            \\  }} catch(e) {{
            \\    console.error("Adblock cosmetic parsing error", e);
            \\  }}
            \\}})();
        , .{encoded_json});

        try filter.execJS(page, script);
    }

    fn injectDefaultRules(filter: *CosmeticFilter, page: *Page) !void {
        if (filter.ad_filter == null) {
            // Note: Since no Zig interpolation is happening here (no std.fmt),
            // single braces `{}` are perfectly fine.
            const default_rules =
                \\(function() {
                \\  const adSelectors = [
                \\    '.ad', '.ads', '.advert', '.advertisement', '.banner', '.promo',
                \\    '.popup', '.modal', '.cookie-notice', '#cookie-law', '.tracking',
                \\    '.analytics', '.beacon', '.pixel', '.widget', '#header-ad',
                \\    '#footer-ad', '.sidebar-ad', '.inarticle-ad', '[id^="google_ads"]',
                \\    '[class^="adsbygoogle"]'
                \\  ];
                \\  adSelectors.forEach(function(selector) {
                \\    try {
                \\      document.querySelectorAll(selector).forEach(function(el) {
                \\        el.style.cssText += ';display:none!important;visibility:hidden!important;';
                \\      });
                \\    } catch(e) {}
                \\  });
                \\})();
            ;
            try filter.execJS(page, default_rules);
        }
    }

    fn setupMutationObserver(filter: *CosmeticFilter, page: *Page) !void {
        const observer_script =
            \\(function() {
            \\  if (window._adblockObserver) return;
            \\  window._adblockObserver = new MutationObserver(function(mutations) {
            \\    const adSelectors = [
            \\      '.ad', '.ads', '.advert', '.advertisement', '.banner', '.promo',
            \\      '.popup', '.modal', '.cookie-notice', '#cookie-law', '.tracking'
            \\    ];
            \\    mutations.forEach(function(mutation) {
            \\      mutation.addedNodes.forEach(function(node) {
            \\        if (node.nodeType === 1) {
            \\          adSelectors.forEach(function(selector) {
            \\            try {
            \\              node.matches(selector) && (node.style.cssText += ';display:none!important;');
            \\              node.querySelectorAll(selector).forEach(function(el) {
            \\                el.style.cssText += ';display:none!important;visibility:hidden!important;';
            \\              });
            \\            } catch(e) {}
            \\          });
            \\        }
            \\      });
            \\    });
            \\  });
            \\  window._adblockObserver.observe(document.body, { childList: true, subtree: true });
            \\})();
        ;
        try filter.execJS(page, observer_script);
    }

    fn execJS(filter: *CosmeticFilter, page: *Page, script: []const u8) !void {
        _ = filter;
        var ls: js.Local.Scope = undefined;
        page.js.localScope(&ls);
        defer ls.deinit();

        const entered = page.js.enter(&ls.handle_scope);
        defer entered.exit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        _ = ls.local.exec(script, "adblock-cosmetic-filter") catch |err| {
            const caught = try_catch.caughtOrError(filter.allocator, err);
            log.debug(.page, "cosmetic filter script error: {s}", .{caught});
        };
    }

    pub fn applyDynamicContent(filter: *CosmeticFilter, page: *Page) !void {
        try filter.injectDefaultRules(page);
    }

    pub fn deinit(filter: *CosmeticFilter) void {
        filter.selector_cache.deinit();
    }
};

const js = @import("js/js.zig");
