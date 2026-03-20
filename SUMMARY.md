# Lightpanda Browser: Document Summary

**What it is:** A headless browser built in Zig from scratch. Not a Chromium fork. Targets AI agents, scraping, and automated testing.

**Performance:** 9x less memory (24 MB vs 207 MB) and 11x faster (2.3s vs 25.2s) than headless Chrome, measured over 100 pages via Puppeteer.

---

## Section Summaries

**Quick Start:** Install via nightly binary (Linux/macOS/Windows WSL2) or Docker. Run `fetch` to dump a URL or `serve` to start a CDP server. Connect Puppeteer/Playwright via `ws://127.0.0.1:9222`.

**Lightpanda vs Headless Chrome:** Choose Lightpanda for low-memory scraping, AI agent browsing, CI testing, and markdown extraction. Use Chrome for screenshots, PDFs, WebGL, or full Web API coverage. Supported: HTTP, HTML5, DOM, JS (V8), Ajax, CDP, cookies, proxy, network interception, robots.txt.

**Use Cases:** AI agents via MCP or CDP, web scraping at scale, headless Chrome replacement in CI, LLM training data extraction with `--dump markdown`.

**Architecture:** CDP/WebSocket client → HTML parsed to DOM → CSS applied → JS via V8 → response as HTML, markdown, or structured data.

**Why Lightpanda?:** Modern web requires JS execution; Chrome is too heavy to run at scale; Lightpanda is built in Zig with no graphical renderer for minimal footprint.

**Build from Source:** Requires Zig 0.15.2, v8, Libcurl, html5ever, and Rust. `make build` or `zig build run`. Optional v8 snapshot for faster startup.

**Test:** `make test` for unit tests; `make end2end` for end-to-end; WPT suite runs via a Go runner in the demo repo.

**Contributing:** PRs via GitHub; CLA required. [Good first issues](https://github.com/lightpanda-io/browser/labels/good%20first%20issue) labeled.

**Compatibility Note:** Playwright scripts may break after Lightpanda updates when new Web APIs shift Playwright's execution path. File an issue with the last working version.

**FAQ:** What Lightpanda is, Chrome comparison, Chromium fork question, Playwright/cloud usage, Zig rationale, OS support, robots.txt.
