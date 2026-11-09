// Copyright (C) 2026  Lightpanda (Selecy SAS)
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

//! A crawler that lives in the browser.
//!
//! The pages are loaded by the engine itself: there is no protocol between
//! the crawler and the pages, the links come from the DOM the engine built,
//! and the session is the engine's - one browser, one jar, one visitor.

const std = @import("std");
const lp = @import("lightpanda");

const Allocator = std.mem.Allocator;

const log = lp.log;

/// How far the crawl may go from its seeds.
pub const Scope = lp.Config.CrawlScope;

pub const Opts = struct {
    /// Where to start.
    seeds: []const [:0]const u8,
    /// How many pages to fetch, at most.
    max_pages: usize = 1000,
    /// How many browsers to run at the same time. Each has an isolate of its
    /// own, and its own session unless the process shares one.
    concurrency: usize = 1,
    /// How long to wait for a page before reading it.
    wait_until: lp.Config.WaitUntil = .load,
    wait_ms: u32 = 5_000,
    /// Where the records go. Standard output when null.
    output: ?[]const u8 = null,
    /// What to put in the record's content field: the page as HTML, or as
    /// markdown. Nothing when null.
    content: ?lp.Config.DumpFormat = null,
    /// How many bytes of content to keep, at most.
    max_content_bytes: ?u32 = null,
    /// How deep to go from the seeds. Nothing limits the depth when null.
    max_depth: ?u16 = null,
    /// Start a new session every this many pages, so the session's arena
    /// gives back the navigation history of the pages before it. 0 never
    /// recycles.
    recycle_every: usize = 100,
    /// How far the crawl may go from its seeds.
    scope: Scope = .host,
    /// Only the URLs that match one of these are followed.
    include: []const []const u8 = &.{},
    /// The URLs that match one of these are not followed.
    exclude: []const []const u8 = &.{},
};

/// A page the crawler fetched.
///
/// The shape is a row: flat, typed, and the same every time. It is what
/// the crawler writes to a file now, and what a database table would
/// hold later.
pub const Record = struct {
    /// Which crawl this page belongs to. Every row of a run carries the
    /// same one.
    crawl_id: []const u8 = "",
    /// When the page was fetched, in seconds since the epoch.
    fetched_at: i64 = 0,
    url: []const u8,
    final_url: ?[]const u8 = null,
    depth: u16 = 0,
    status: u16 = 0,
    title: []const u8 = "",
    /// The page itself, when the crawl was asked for it.
    content: ?[]const u8 = null,
    links: u32 = 0,
    ms: u64 = 0,
    timed_out: bool = false,
    /// The page was answered, but had nothing to crawl.
    skipped: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    bot_challenge: bool = false,
};

/// An id for this crawl: eight hex characters, so the rows of two crawls
/// can be told apart once they are in the same table.
fn crawlId(allocator: Allocator) ![]const u8 {
    // The clock at the start of the crawl, mixed. Two crawls do not start
    // in the same microsecond.
    var hash: u64 = @bitCast(lp.datetime.DateTime.now().unix(.microseconds));
    hash ^= hash >> 30;
    hash *%= 0xBF58476D1CE4E5B9;
    hash ^= hash >> 27;
    hash *%= 0x94D049BB133111EB;
    hash ^= hash >> 31;
    return allocator.print("{x:0>8}", .{hash & 0xffffffff});
}

/// Crawl the web from the seeds, writing one record per page.
pub fn run(app: *lp.App, opts: Opts) !void {
    const allocator = app.allocator;

    var frontier = Frontier.init(allocator, opts.max_pages, opts.scope, opts.max_depth);
    defer frontier.deinit();

    // The crawl stays on the seeds' hosts, unless it is told otherwise.
    for (opts.seeds) |seed| {
        const host = try allocator.dupe(u8, hostOf(seed));
        try frontier.hosts.append(allocator, host);
    }

    // The patterns that say which URLs to follow, compiled once.
    for (opts.include) |pattern| {
        const re = app.regex_context.compile(pattern, .{ .unicode = true }, null) catch |err| {
            log.fatal(.app, "crawl include", .{ .err = err, .pattern = pattern });
            return err;
        };
        try frontier.includes.append(allocator, re);
    }
    for (opts.exclude) |pattern| {
        const re = app.regex_context.compile(pattern, .{ .unicode = true }, null) catch |err| {
            log.fatal(.app, "crawl exclude", .{ .err = err, .pattern = pattern });
            return err;
        };
        try frontier.excludes.append(allocator, re);
    }

    // The seeds are always fetched: they are what the crawl was asked for,
    // whatever the patterns say.
    for (opts.seeds) |seed| {
        try frontier.addSeed(seed);
    }

    // Every row of this crawl carries the same id, so the rows of two
    // crawls can be told apart once they are in the same table.
    const crawl_id = try crawlId(allocator);
    defer allocator.free(crawl_id);

    var out = try Output.init(allocator, opts.output);
    defer out.deinit();

    if (opts.concurrency <= 1) {
        try worker(app, &frontier, &out, opts, crawl_id);
    } else {
        // One browser per thread, the way the CDP server gives every
        // connection one: an isolate is not shared between threads.
        const threads = try allocator.alloc(std.Thread, opts.concurrency);
        defer allocator.free(threads);
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{ app, &frontier, &out, opts, crawl_id });
        }
        for (threads) |thread| thread.join();
    }
}

fn workerThread(app: *lp.App, frontier: *Frontier, out: *Output, opts: Opts, crawl_id: []const u8) void {
    worker(app, frontier, out, opts, crawl_id) catch |err| {
        log.err(.app, "crawl worker", .{ .err = err });
    };
}

/// One browser, one session, and the pages that come with them.
fn worker(app: *lp.App, frontier: *Frontier, out: *Output, opts: Opts, crawl_id: []const u8) !void {
    var browser: lp.Browser = undefined;
    try browser.init(app, .{ .env = .{ .with_inspector = true } });
    defer browser.deinit();

    const notification = try lp.Notification.init(app.allocator);
    defer notification.deinit();

    var session = try browser.newSession(notification);
    defer browser.closeSession();

    // One page for the crawl: a page owns a V8 context, and building one
    // from the snapshot is the most expensive thing a crawl can do.
    var page = try session.createPage();
    defer page.close();

    // The session's arena holds the navigation history of every page the
    // session fetched, and an arena gives its memory back only when it is
    // released. A new session every so often gives it back, and the pool
    // the arena came from hands the same memory to the next session.
    var since_recycle: usize = 0;

    // The content of the pages, when the crawl was asked for it. The
    // buffer is reused: the record is written before the next page is
    // fetched.
    var content: std.Io.Writer.Allocating = .init(app.allocator);
    defer content.deinit();

    while (frontier.next()) |job| {
        crawlPage(session, page, frontier, out, opts, crawl_id, &content, job) catch |err| {
            log.err(.app, "crawl page", .{ .err = err, .url = job.url });
        };
        frontier.done();
        // The URL was the queue's; the crawl is done with it.
        frontier.release(job.url);

        since_recycle += 1;
        if (opts.recycle_every > 0 and since_recycle >= opts.recycle_every) {
            since_recycle = 0;
            page.close();
            browser.closeSession();
            session = try browser.newSession(notification);
            page = try session.createPage();
        }
    }
}

/// Fetch one page, read it, and queue the links it has.
fn crawlPage(
    session: *lp.Session,
    page: lp.Session.PageHandle,
    frontier: *Frontier,
    out: *Output,
    opts: Opts,
    crawl_id: []const u8,
    content: *std.Io.Writer.Allocating,
    job: Frontier.Job,
) !void {
    const started = lp.datetime.milliTimestamp(.real);
    var record = Record{
        .crawl_id = crawl_id,
        .fetched_at = lp.datetime.DateTime.now().unix(.seconds),
        .url = job.url,
        .depth = job.depth,
    };

    // The frame wants a sentinel-terminated URL. The session's arena holds
    // it: the frame's own is gone once the navigation replaces the frame.
    const url = try session.arena.allocator().dupeSentinel(u8, job.url, 0);

    // A navigation, the way the CDP does it. When the frame is idle the
    // navigation happens in place: the frame keeps its context, so a page
    // does not cost a V8 context. Otherwise the page is replaced, and the
    // replacement takes the frame's place.
    const frame_before = page.frame();
    const in_place = frame_before != null and frame_before.?._load_state == .waiting;
    if (in_place) {
        frame_before.?.navigate(url, .{ .reason = .address_bar, .kind = .{ .push = null } }) catch |err| {
            record.@"error" = @errorName(err);
            record.ms = lp.datetime.milliTimestamp(.real) - started;
            try out.write(record);
            return;
        };
    } else {
        session.initiateRootNavigation(page.frame_id, url, .{ .reason = .address_bar, .kind = .{ .push = null } }) catch |err| {
            record.@"error" = @errorName(err);
            record.ms = lp.datetime.milliTimestamp(.real) - started;
            try out.write(record);
            return;
        };
    }

    var runner = session.runner(.{});
    const result = runner.waitForFrameResult(page.frame_id, opts.wait_ms, .{ .until = opts.wait_until }) catch |err| {
        record.@"error" = @errorName(err);
        record.ms = lp.datetime.milliTimestamp(.real) - started;
        try out.write(record);
        return;
    };
    if (result == .timeout) record.timed_out = true;

    // A root navigation replaces the page, so the frame we started from is
    // not the frame that is loaded now.
    const frame = page.frame() orelse return;

    record.status = frame._http_status orelse 0;
    record.final_url = frame.url;

    // A redirect took the page somewhere else: that URL has been fetched
    // already, so a link to it is not worth a second request.
    if (!std.mem.eql(u8, frame.url, job.url)) {
        frontier.markSeen(frame.url);
    }
    record.bot_challenge = frame._bot_challenge != null;
    if (frame._last_navigate_error) |err| {
        // The page was answered, it just had nothing to crawl.
        record.skipped = @errorName(err);
    }
    record.title = frame.document.getTitle(frame) catch "";

    // The content of the page, when the crawl was asked for it.
    if (opts.content) |mode| {
        content.clearRetainingCapacity();
        lp.dumpPageContent(session.browser.app, mode, opts.max_content_bytes, frame, &content.writer) catch |err| {
            log.err(.app, "crawl content", .{ .err = err, .url = job.url });
            record.@"error" = @errorName(err);
        };
        record.content = content.written();
    }

    // The links, from the DOM the engine built: no script, no round trip.
    const links = lp.links.collectLinks(frame.call_arena, frame.document.asNode(), frame) catch &.{};
    record.links = @intCast(links.len);
    for (links) |link| {
        frontier.add(link.href, job.depth + 1) catch |err| {
            log.err(.app, "crawl link", .{ .err = err, .href = link.href });
        };
    }

    // The routes an SPA reached without a link: the entries of the session
    // history that belong to this page's document.
    const navigation = session.navigationFor(frame);
    for (navigation.entries()) |entry| {
        if (!entry.sameDocument(frame)) continue;
        const route = entry.url() orelse continue;
        frontier.add(route, job.depth + 1) catch |err| {
            log.err(.app, "crawl route", .{ .err = err, .url = route });
        };
    }

    record.ms = lp.datetime.milliTimestamp(.real) - started;
    try out.write(record);
}

/// The URLs to fetch, and the ones already seen.
const Frontier = struct {
    allocator: Allocator,
    /// How many URLs, at most.
    limit: usize,
    /// How deep to go from the seeds. Nothing limits the depth when null.
    max_depth: ?u16,
    /// The hosts the crawl stays on, when it stays on any.
    hosts: std.ArrayList([]const u8) = .empty,
    scope: Scope = .host,
    /// The patterns a URL has to match to be followed, and the ones that
    /// keep it from being followed.
    includes: std.ArrayList(lp.Regex.Regex) = .empty,
    excludes: std.ArrayList(lp.Regex.Regex) = .empty,

    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList(Job) = .empty,
    head: usize = 0,
    /// The pages a worker is fetching right now. The queue can be empty
    /// while pages are in flight, and those pages still have links to give.
    in_flight: usize = 0,
    /// The URLs already seen, by their canonical hash. A hash and not the
    /// URL itself: a crawl of a million pages would otherwise hold a
    /// million strings, and the only thing the set does with them is
    /// compare them.
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,

    const Job = struct {
        url: []const u8,
        depth: u16,
    };

    fn init(allocator: Allocator, limit: usize, scope: Scope, max_depth: ?u16) Frontier {
        return .{
            .allocator = allocator,
            .limit = limit,
            .scope = scope,
            .max_depth = max_depth,
        };
    }

    fn deinit(self: *Frontier) void {
        // The jobs that were handed out are gone; the rest are ours.
        for (self.queue.items[self.head..]) |job| {
            self.allocator.free(job.url);
        }
        self.queue.deinit(self.allocator);
        for (self.hosts.items) |host| {
            self.allocator.free(host);
        }
        self.hosts.deinit(self.allocator);
        self.seen.deinit(self.allocator);
    }

    /// Queue a URL, unless it is one we have seen or one we may not follow.
    fn add(self: *Frontier, url: []const u8, depth: u16) !void {
        if (!isFetchable(url)) return;
        if (!self.inScope(url)) return;
        if (!self.wanted(url)) return;
        try self.enqueue(url, depth);
    }

    /// Queue a seed. The patterns do not apply to it: the crawl was asked
    /// for it.
    fn addSeed(self: *Frontier, url: []const u8) !void {
        if (!isFetchable(url)) return;
        try self.enqueue(url, 0);
    }

    fn enqueue(self: *Frontier, url: []const u8, depth: u16) !void {
        // The depth of a URL is the depth of the page that found it, plus
        // one. A URL deeper than the limit is not worth a request.
        if (self.max_depth) |max| {
            if (depth > max) return;
        }

        // The canonical form of the URL, hashed. Nothing is allocated: a
        // page has ten links and a crawl has millions of pages, and none
        // of them needs a string to be compared.
        const hash = canonicalHash(url);

        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);

        if (self.seen.count() >= self.limit) return;
        const gop = try self.seen.getOrPut(self.allocator, hash);
        if (gop.found_existing) return;

        const owned = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned);
        try self.queue.append(self.allocator, .{ .url = owned, .depth = depth });
        // Someone waiting for work has something to do now.
        self.cond.signal(lp.io);
    }

    /// The next URL to fetch. Waits for one when the queue is empty but
    /// pages are still in flight, and gives up only when there is nothing
    /// left to fetch at all.
    fn next(self: *Frontier) ?Job {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        while (true) {
            if (self.head < self.queue.items.len) {
                const job = self.queue.items[self.head];
                // The worker owns the URL now; the queue lets it go.
                self.queue.items[self.head] = undefined;
                self.head += 1;
                self.in_flight += 1;
                return job;
            }
            // Nothing queued and nothing in flight: the crawl is over.
            if (self.in_flight == 0) return null;
            self.cond.waitUncancelable(lp.io, &self.mutex);
        }
    }

    /// Mark a URL as seen without queueing it: the URL a page ended on,
    /// when a redirect took it there. A link to that URL is not worth a
    /// second request.
    fn markSeen(self: *Frontier, url: []const u8) void {
        const hash = canonicalHash(url);
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.seen.put(self.allocator, hash, {}) catch {};
    }

    /// A page is done. Its links are in the queue by now.
    fn done(self: *Frontier) void {
        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        self.in_flight -= 1;
        // The last page of the crawl may have left the queue empty.
        self.cond.broadcast(lp.io);
    }

    /// Give back the memory of a URL the crawl is done with.
    fn release(self: *Frontier, url: []const u8) void {
        self.allocator.free(url);
    }

    fn inScope(self: *Frontier, url: []const u8) bool {
        switch (self.scope) {
            .any => return true,
            .host => {},
            .domain => {
                // The seed's host, or a subdomain of it. A leading "www."
                // counts for neither: it is the same site.
                const host = withoutWww(hostOf(url));
                for (self.hosts.items) |h| {
                    const seed = withoutWww(h);
                    if (std.mem.eql(u8, seed, host)) return true;
                    if (host.len > seed.len and
                        std.mem.endsWith(u8, host, seed) and
                        host[host.len - seed.len - 1] == '.')
                    {
                        return true;
                    }
                }
                return false;
            },
        }
        if (self.hosts.items.len == 0) return true;
        const host = hostOf(url);
        for (self.hosts.items) |h| {
            if (std.mem.eql(u8, h, host)) return true;
        }
        return false;
    }

    /// Whether the patterns let the URL through.
    fn wanted(self: *Frontier, url: []const u8) bool {
        if (self.excludes.items.len > 0) {
            for (self.excludes.items) |re| {
                if (re.matches(url)) return false;
            }
        }
        if (self.includes.items.len == 0) return true;
        for (self.includes.items) |re| {
            if (re.matches(url)) return true;
        }
        return false;
    }
};

fn isFetchable(url: []const u8) bool {
    if (url.len == 0) return false;
    if (std.mem.startsWith(u8, url, "http://")) return true;
    if (std.mem.startsWith(u8, url, "https://")) return true;
    return false;
}

/// The host of a URL, without the "www." that does not make it another
/// site.
fn withoutWww(host: []const u8) []const u8 {
    if (std.mem.startsWith(u8, host, "www.")) return host[4..];
    return host;
}

/// The host of a URL, without the port.
fn hostOf(url: []const u8) []const u8 {
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |i| {
        rest = rest[i + 3 ..];
    } else {
        return "";
    }
    if (std.mem.indexOfAny(u8, rest, "/?#")) |i| {
        rest = rest[0..i];
    }
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |i| {
        // A port, unless it is part of an IPv6 address.
        if (std.mem.indexOfScalar(u8, rest[0..i], ']') == null) {
            rest = rest[0..i];
        }
    }
    return rest;
}

/// The hash two URLs are compared by: the same canonical form as before -
/// no fragment, no tracking parameters, and the remaining query parameters
/// in a fixed order - hashed instead of built.
///
/// Nothing is allocated: the pairs are slices into the URL, and they are
/// sorted in place in a fixed-size array. A URL with more parameters than
/// the array holds is hashed in the order it came in, which is the same
/// URL more often than not.
fn canonicalHash(url: []const u8) u64 {
    var rest = url;
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| rest = rest[0..i];

    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        query = rest[i + 1 ..];
        rest = rest[0..i];
    }

    // The pairs, as slices into the query. They point into the URL, which
    // outlives the hash.
    var pairs: [64][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const name = if (std.mem.indexOfScalar(u8, pair, '=')) |j| pair[0..j] else pair;
        if (isTracking(name)) continue;
        if (count == pairs.len) break;
        pairs[count] = pair;
        count += 1;
    }
    std.mem.sort([]const u8, pairs[0..count], {}, lessThanBytes);

    var hash = std.hash.Wyhash.init(0);
    hash.update(rest);
    for (pairs[0..count]) |pair| {
        // The separator keeps "?a=1&b=2" from hashing like "?a=1b=2".
        hash.update("&");
        hash.update(pair);
    }
    return hash.final();
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const tracking_params = [_][]const u8{
    "cmpid",       "dclid",       "fbclid",         "gbraid",     "gclid",       "gclsrc",    "hsctatracking",
    "icid",        "igshid",      "mc_cid",         "mc_eid",     "mkt_tok",     "msclkid",   "ncid",
    "oly_anon_id", "oly_enc_id",  "piwik_campaign", "piwik_kwd",  "ref",         "ref_src",   "ref_url",
    "referrer",    "sc_campaign", "sc_channel",     "sc_content", "sc_geo",      "sc_medium", "sc_outcome",
    "s_kwcid",     "spm",         "srsltid",        "trk",        "trkcampaign", "ttclid",    "twclid",
    "vero_conv",   "vero_id",     "wbraid",         "wickedid",   "yclid",       "_ga",       "_gl",
    "_hsenc",      "_hsmi",       "_ke",            "__hssc",     "__hstc",
};

fn isTracking(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "utm_")) return true;
    for (tracking_params) |p| {
        if (std.ascii.eqlIgnoreCase(name, p)) return true;
    }
    return false;
}

/// The records, one JSON object per line.
const Output = struct {
    allocator: Allocator,
    mutex: std.Io.Mutex = .init,
    file: ?std.Io.File = null,
    // The writer keeps the file and its buffer: its interface points back at
    // it, so it cannot be copied out of here.
    stdout: ?std.Io.File.Writer = null,

    fn init(allocator: Allocator, path: ?[]const u8) !Output {
        var out = Output{
            .allocator = allocator,
            .file = null,
            .stdout = null,
        };
        if (path) |p| {
            out.file = try std.Io.Dir.cwd().createFile(lp.io, p, .{});
        } else {
            out.stdout = std.Io.File.stdout().writerStreaming(lp.io, &.{});
        }
        return out;
    }

    fn deinit(self: *Output) void {
        if (self.file) |*f| {
            f.close(lp.io);
        }
    }

    fn write(self: *Output, record: Record) !void {
        var line: std.Io.Writer.Allocating = .init(self.allocator);
        defer line.deinit();
        try std.json.Stringify.value(record, .{}, &line.writer);
        try line.writer.writeByte('\n');

        self.mutex.lockUncancelable(lp.io);
        defer self.mutex.unlock(lp.io);
        if (self.file) |*f| {
            try f.writeStreamingAll(lp.io, line.written());
        } else if (self.stdout) |*w| {
            try w.interface.writeAll(line.written());
            try w.interface.flush();
        }
    }
};
