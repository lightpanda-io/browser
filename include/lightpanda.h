/* Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
 *
 * Francis Bouvier <francis@lightpanda.io>
 * Pierre Tachoire <pierre@lightpanda.io>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/* Lightpanda embedded as a C library. Implemented by src/c_api.zig, which
 * must stay in sync with this header.
 *
 * Threading contract (v1):
 *   - lp_init may be called ONCE per process. After lp_shutdown the library
 *     cannot be initialized again (V8's platform is not re-initializable).
 *   - Every call on the lp_browser handle and on all of its sessions must
 *     come from the thread that called lp_init. Sessions are cheap and
 *     isolated; parallelism means multiple processes.
 *   - The library is not fork-safe after lp_init.
 *
 * Strings: every string, input and output, is a pointer plus a byte
 * length. Inputs need not be NUL-terminated and outputs are not guaranteed
 * to be. (The only exceptions are lp_version and lp_tools_json, which
 * return static NUL-terminated C strings.)
 *
 * Logging goes to stderr (level: warnings and errors in release builds).
 *
 * Anonymous usage telemetry is enabled in release builds; set
 * LIGHTPANDA_DISABLE_TELEMETRY in the environment to opt out.
 *
 * Linking: `make lib` builds liblightpanda.so (liblightpanda.dylib on macOS)
 * into zig-out/lib and installs this header (zig-out/include) plus a
 * pkg-config file:
 *   cc app.c $(PKG_CONFIG_PATH=zig-out/lib/pkgconfig pkg-config --cflags --libs lightpanda)
 * or by hand:
 *   cc app.c -Izig-out/include -Lzig-out/lib -llightpanda
 * The library resolves its dependencies internally, and the bundled
 * OpenSSL/curl/sqlite are hidden on both platforms, so it is safe to load
 * next to a host's own copies — including dlopen'd for FFI (Python ctypes
 * etc.). ELF exports nothing but lp_*; Mach-O has no version script, so V8's
 * own C++ symbols stay visible there.
 */

#ifndef LIGHTPANDA_H
#define LIGHTPANDA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lp_browser lp_browser;
typedef struct lp_session lp_session;

typedef enum lp_status {
    LP_OK = 0,
    LP_ERR_INVALID_PARAMS = 1,
    /* No page loaded yet; call goto (or pass a url) first. */
    LP_ERR_FRAME_NOT_LOADED = 2,
    LP_ERR_NODE_NOT_FOUND = 3,
    LP_ERR_NAVIGATION_FAILED = 4,
    /* The cancel hook (lp_session_set_cancel_hook) returned true. */
    LP_ERR_CANCELLED = 5,
    LP_ERR_TIMEOUT = 6,
    LP_ERR_OUT_OF_MEMORY = 7,
    LP_ERR_INTERNAL = 8,
    /* API misuse: double init, use after shutdown, NULL handle. */
    LP_ERR_MISUSE = 9
} lp_status;

/* Output of lp_fetch and lp_call. text points at len bytes — read-only,
 * not NUL-terminated — owned by the library: it stays valid until the next
 * lp_call on the same session (for lp_fetch: the next lp_fetch on the same
 * browser), or until that session/browser is torn down. Copy it out to keep
 * it longer — including before handing it to another thread. lp_session_pump
 * does not invalidate it. is_error signals an in-band page-level failure
 * (e.g. a JS throw inside evaluate/extract) whose message is in text; the
 * call itself still returns LP_OK. */
typedef struct lp_result {
    const char *text;
    size_t len;
    bool is_error;
} lp_result;

/* Options structs (lp_options, lp_fetch_opts) are extensible: they are
 * passed with their size, new fields are only ever appended, and zero means
 * "default" for every field. A program built against an older header passes
 * a smaller struct and gets defaults for the fields it lacks; a program
 * built against a newer header that sets a field this library doesn't know
 * fails with LP_ERR_INVALID_PARAMS rather than having it silently ignored.
 * Every field is 8 bytes wide, so the structs have no padding. LP_OPTS
 * builds the pointer/size pair from designated initializers:
 *   lp_fetch(b, url, len, LP_OPTS(lp_fetch_opts, .format = LP_FORMAT_MARKDOWN), &r);
 * NULL with size 0 means all defaults. */
#ifndef __cplusplus
#define LP_OPTS(type, ...) (&(type){__VA_ARGS__}), sizeof(type)
#endif

/* A string that need not be NUL-terminated. */
typedef struct lp_str {
    const char *ptr;
    size_t len;
} lp_str;

typedef struct lp_options {
    lp_str user_agent;           /* NULL ptr: default ("Lightpanda/1.0") */
    lp_str http_proxy;           /* NULL ptr: none */
    lp_str http_cache_dir;       /* NULL ptr: no persistent HTTP cache */
    uint64_t http_timeout_ms;    /* 0: default (15000) */
    int64_t watchdog_ms;         /* 0: default (30000), <0: disabled */
} lp_options;

typedef enum lp_format {
    LP_FORMAT_HTML = 0,
    LP_FORMAT_MARKDOWN = 1,
    LP_FORMAT_TREE_JSON = 2,  /* semantic (accessibility-style) tree, JSON */
    LP_FORMAT_TREE_TEXT = 3   /* semantic tree, indented text */
} lp_format;

typedef enum lp_wait_until {
    /* "load", unless a wait selector or script is given: then that is the
     * whole wait. */
    LP_WAIT_DEFAULT = 0,
    LP_WAIT_LOAD = 1,
    LP_WAIT_DOMCONTENTLOADED = 2,
    LP_WAIT_NETWORKALMOSTIDLE = 3,
    LP_WAIT_NETWORKIDLE = 4,
    LP_WAIT_DONE = 5,
    /* Load work finished, ignoring intervals, long timeouts and polling. */
    LP_WAIT_SETTLED = 6
} lp_wait_until;

/* Bits of lp_fetch_opts.strip: what to leave out of the dump. */
typedef enum lp_strip {
    LP_STRIP_JS = 1 << 0,
    LP_STRIP_UI = 1 << 1,
    LP_STRIP_CSS = 1 << 2,
    LP_STRIP_INVISIBLE = 1 << 3,
    LP_STRIP_SHELL = 1 << 4,
    LP_STRIP_CLUTTER = 1 << 5
} lp_strip;

/* Mirrors `lightpanda fetch`; each field names its flag. */
typedef struct lp_fetch_opts {
    uint64_t format;             /* --dump; lp_format, 0: HTML */
    uint64_t wait_until;         /* --wait-until; lp_wait_until */
    uint64_t wait_ms;            /* --wait-ms; 0: default (5000) */
    lp_str wait_selector;        /* --wait-selector; NULL ptr: none */
    lp_str wait_script;          /* --wait-script; JS expression, NULL ptr: none */
    const lp_str *inject_scripts;/* --inject-script; run in every page */
    size_t inject_scripts_len;
    lp_str selector;             /* --dump-selector; dump the first match only */
    uint64_t strip;              /* --strip-mode; lp_strip bits */
    uint64_t max_bytes;          /* --dump-max-bytes; HTML/markdown, 0: no cap */
    uint64_t with_base;          /* --with-base; 0: off */
    uint64_t with_frames;        /* --with-frames; 0: off */
    uint64_t fail_on_http_error; /* --fail-on-http-error; 0: off */
    uint64_t markdown_alternate; /* --markdown-alternate; 0: off */
} lp_fetch_opts;

/* Initialize the library. On LP_OK, *out is the process-wide browser
 * handle. */
lp_status lp_init(const lp_options *opts, size_t opts_size, lp_browser **out);

/* Tear down the handle, closing any remaining sessions. Terminal — see the
 * threading contract above. */
void lp_shutdown(lp_browser *browser);

/* Load url in a throwaway session, run its JavaScript, and return the page
 * serialized per opts. "curl that runs JavaScript".
 * Every call gets a fresh session (cookies, storage, pages); the underlying
 * browser is created on first use and reused, so looping lp_fetch is cheap. */
lp_status lp_fetch(lp_browser *browser, const char *url, size_t url_len,
                   const lp_fetch_opts *opts, size_t opts_size, lp_result *out);

/* Create an isolated browsing session: its own page, cookies, JS heap. */
lp_status lp_session_new(lp_browser *browser, lp_session **out);

/* Close a session. The pointer is invalid afterwards. Sessions still open
 * at lp_shutdown are closed then. */
void lp_session_close(lp_session *session);

/* Run one browser tool (goto, markdown, html, extract, tree, click, fill,
 * waitForSelector, evaluate, ...) against the session. args_json is the
 * tool's argument object as a JSON string (NULL: no arguments); the tool
 * names and their JSON schemas are enumerated by lp_tools_json. Tools that
 * read the page accept a "url" argument to navigate first, so
 *   lp_call(s, "markdown", strlen("markdown"), args, strlen(args), &r)
 * with args = "{\"url\":\"https://example.com\"}" is a complete one-call
 * scrape. */
lp_status lp_call(lp_session *session, const char *tool, size_t tool_len,
                  const char *args_json, size_t args_json_len,
                  lp_result *out);

/* Pump background work (timers, in-flight fetches) once; returns how many
 * milliseconds the caller may sleep before pumping again. Only needed when
 * idling between calls — every call waits for its own completion. */
uint32_t lp_session_pump(lp_session *session);

/* Install (cb != NULL) or clear (cb == NULL) a cancellation probe, polled
 * on the session's thread during blocking waits; returning true fails the
 * in-flight call with LP_ERR_CANCELLED. The probe may read state set from
 * other threads (e.g. an atomic flag set by a signal handler). */
void lp_session_set_cancel_hook(lp_session *session,
                                bool (*cb)(void *), void *ctx);

/* Diagnostic for the most recent failing call on this session (lp_call) or
 * browser (lp_fetch, lp_session_new): an error name such as "Timeout" or
 * "CertificateError", more specific than the lp_status code. Empty when the
 * last call succeeded; NULL for a NULL handle or after lp_shutdown. len may
 * be NULL. Static — do not free. */
const char *lp_last_error(lp_session *session, size_t *len);
const char *lp_browser_last_error(lp_browser *browser, size_t *len);

/* JSON array of every tool lp_call accepts:
 * [{"name", "description", "inputSchema"}, ...]. Static — do not free. */
const char *lp_tools_json(void);

/* Library version string. Static — do not free. */
const char *lp_version(void);

#ifdef __cplusplus
}
#endif

#endif /* LIGHTPANDA_H */
