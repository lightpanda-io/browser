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
 * Linking: `make lib` builds liblightpanda.so (zig-out/lib) and
 * installs this header (zig-out/include) plus a pkg-config file:
 *   cc app.c $(PKG_CONFIG_PATH=zig-out/lib/pkgconfig pkg-config --cflags --libs lightpanda)
 * or by hand:
 *   cc app.c -Izig-out/include -Lzig-out/lib -llightpanda
 * The library resolves its dependencies internally and exports only lp_*
 * symbols (safe next to a host's own OpenSSL/curl/sqlite), and it is
 * dlopen-able for FFI (Python ctypes etc.).
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

/* Zero-initialize for defaults: no proxy, default user agent, no HTTP
 * cache, 5s HTTP timeout, 30s JS watchdog, telemetry off. */
typedef struct lp_options {
    const char *user_agent;      /* NULL: default ("Lightpanda/1.0") */
    size_t user_agent_len;
    const char *http_proxy;      /* NULL: none */
    size_t http_proxy_len;
    const char *http_cache_dir;  /* NULL: no persistent HTTP cache */
    size_t http_cache_dir_len;
    uint32_t http_timeout_ms;    /* 0: default (5000) */
    int32_t watchdog_ms;         /* 0: default (30000), <0: disabled */
    bool enable_telemetry;       /* false: no telemetry */
} lp_options;

typedef enum lp_format {
    LP_FORMAT_HTML = 0,
    LP_FORMAT_MARKDOWN = 1,
    LP_FORMAT_TREE_JSON = 2,  /* semantic (accessibility-style) tree, JSON */
    LP_FORMAT_TREE_TEXT = 3   /* semantic tree, indented text */
} lp_format;

typedef enum lp_wait_until {
    LP_WAIT_DEFAULT = 0, /* page fully settled ("done"), or the selector */
    LP_WAIT_LOAD = 1,
    LP_WAIT_DOMCONTENTLOADED = 2,
    LP_WAIT_NETWORKALMOSTIDLE = 3,
    LP_WAIT_NETWORKIDLE = 4,
    LP_WAIT_DONE = 5
} lp_wait_until;

/* Zero-initialize for defaults: HTML after the page settles, 5s budget. */
typedef struct lp_fetch_opts {
    int format;                /* lp_format */
    uint32_t wait_ms;          /* 0: default (5000) */
    int wait_until;            /* lp_wait_until */
    const char *wait_selector; /* NULL: none; else wait for this CSS selector */
    size_t wait_selector_len;
} lp_fetch_opts;

/* Initialize the library. opts may be NULL (all defaults). On LP_OK,
 * *out is the process-wide browser handle. */
lp_status lp_init(const lp_options *opts, lp_browser **out);

/* Tear down the handle, closing any remaining sessions. Terminal — see the
 * threading contract above. */
void lp_shutdown(lp_browser *browser);

/* Load url in a throwaway session, run its JavaScript, and return the page
 * serialized per opts (NULL: all defaults). "curl that runs JavaScript".
 * Every call gets a fresh session (cookies, storage, pages); the underlying
 * browser is created on first use and reused, so looping lp_fetch is cheap. */
lp_status lp_fetch(lp_browser *browser, const char *url, size_t url_len,
                   const lp_fetch_opts *opts, lp_result *out);

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
 *   lp_call(s, "markdown", "{\"url\":\"https://example.com\"}", &r)
 * is a complete one-call scrape. */
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

/* JSON array of every tool lp_call accepts:
 * [{"name", "description", "inputSchema"}, ...]. Static — do not free. */
const char *lp_tools_json(void);

/* Library version string. Static — do not free. */
const char *lp_version(void);

#ifdef __cplusplus
}
#endif

#endif /* LIGHTPANDA_H */
