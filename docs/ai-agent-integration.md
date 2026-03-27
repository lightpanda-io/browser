# AI Agent Integration Patterns

Patterns and examples for connecting AI agents and automation frameworks to Lightpanda via CDP.

## Architecture Overview

```
┌──────────────────────────┐
│  AI Agent / Orchestrator │
│  (LangChain, OpenClaw,   │
│   custom agent, etc.)    │
└──────────┬───────────────┘
           │ CDP (WebSocket)
           ▼
┌──────────────────────────┐
│  Lightpanda CDP Server   │──── fallback ──── Chrome headless
│  (serve mode)            │     (if SPA fails)
└──────────────────────────┘
```

Key design: use Lightpanda as the **default** headless engine for speed and low memory. Fall back to Chrome only when Lightpanda cannot fully render a page (e.g., complex SPAs, authenticated flows).

## Connection Patterns

### Pattern 1: Direct Puppeteer Connection

The simplest pattern. One agent, one browser.

```js
import puppeteer from 'puppeteer-core';

const browser = await puppeteer.connect({
  browserWSEndpoint: 'ws://127.0.0.1:9222/',
});

const context = await browser.createBrowserContext();
const page = await context.newPage();

await page.goto('https://example.com', { waitUntil: 'networkidle0' });
const text = await page.evaluate(() => document.body.innerText);

console.log(text);

await page.close();
await context.close();
await browser.disconnect();
```

### Pattern 2: Parallel Page Pool

For agents that need to crawl many pages concurrently (e.g., research runs).

```js
import puppeteer from 'puppeteer-core';

const CONCURRENCY = 20;
const urls = [/* ... list of URLs to crawl ... */];

const browser = await puppeteer.connect({
  browserWSEndpoint: 'ws://127.0.0.1:9222/',
});

// Process URLs in batches
async function crawlPage(url) {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  try {
    await page.goto(url, { waitUntil: 'networkidle0', timeout: 30000 });
    const content = await page.evaluate(() => document.body.innerText);
    return { url, content, ok: true };
  } catch (err) {
    return { url, error: err.message, ok: false };
  } finally {
    await page.close();
    await context.close();
  }
}

// Run with concurrency limit
const results = [];
for (let i = 0; i < urls.length; i += CONCURRENCY) {
  const batch = urls.slice(i, i + CONCURRENCY);
  const batchResults = await Promise.all(batch.map(crawlPage));
  results.push(...batchResults);
}

await browser.disconnect();
```

> **Memory note:** 20 parallel pages with Lightpanda ≈ 140 MB. The same with Chrome ≈ 5.6 GB.

### Pattern 3: Lightpanda → Chrome Fallback

When Lightpanda can't fully render a page (common with complex SPAs), transparently fall back to Chrome.

```js
import puppeteer from 'puppeteer-core';

const LP_ENDPOINT = 'ws://127.0.0.1:9222/';
const CHROME_PATH = '/usr/bin/google-chrome';

// Fallback detection thresholds
const MIN_DOM_ELEMENTS = 5;
const MIN_BODY_TEXT = 50;
const MAX_JS_ERRORS = 3;

async function fetchWithFallback(url) {
  // Try Lightpanda first
  const lpBrowser = await puppeteer.connect({ browserWSEndpoint: LP_ENDPOINT });
  const ctx = await lpBrowser.createBrowserContext();
  const page = await ctx.newPage();

  let jsErrors = 0;
  page.on('pageerror', () => jsErrors++);

  try {
    await page.goto(url, { waitUntil: 'networkidle0', timeout: 15000 });

    // Check if page rendered properly
    const metrics = await page.evaluate(() => ({
      elementCount: document.querySelectorAll('*').length,
      textLength: document.body?.innerText?.trim().length || 0,
      hasOnlyNoscript: document.body?.children.length === 1 &&
                        document.body?.children[0]?.tagName === 'NOSCRIPT',
    }));

    if (metrics.elementCount >= MIN_DOM_ELEMENTS &&
        metrics.textLength >= MIN_BODY_TEXT &&
        !metrics.hasOnlyNoscript &&
        jsErrors < MAX_JS_ERRORS) {
      const content = await page.evaluate(() => document.body.innerText);
      await page.close();
      await ctx.close();
      await lpBrowser.disconnect();
      return { url, content, engine: 'lightpanda' };
    }

    // Fallback to Chrome
    await page.close();
    await ctx.close();
    await lpBrowser.disconnect();

  } catch {
    try { await page.close(); } catch {}
    try { await ctx.close(); } catch {}
    try { await lpBrowser.disconnect(); } catch {}
  }

  // Chrome fallback
  const chrome = await puppeteer.launch({
    executablePath: CHROME_PATH,
    headless: 'new',
    args: ['--no-sandbox'],
  });
  const chromePage = await chrome.newPage();
  await chromePage.goto(url, { waitUntil: 'networkidle0', timeout: 30000 });
  const content = await chromePage.evaluate(() => document.body.innerText);
  await chrome.close();
  return { url, content, engine: 'chrome-fallback' };
}
```

### Pattern 4: Playwright (Python)

```python
from playwright.async_api import async_playwright

async def crawl(url: str) -> str:
    async with async_playwright() as p:
        browser = await p.chromium.connect_over_cdp("ws://127.0.0.1:9222/")
        context = await browser.new_context()
        page = await context.new_page()
        await page.goto(url, wait_until="networkidle")
        content = await page.inner_text("body")
        await page.close()
        await context.close()
        await browser.close()
        return content
```

> **Note:** Playwright support has [caveats](https://github.com/lightpanda-io/browser#playwright-support-disclaimer). If a script breaks after a Lightpanda update, pin the nightly version and report the issue.

### Pattern 5: chromedp (Go)

```go
package main

import (
	"context"
	"fmt"
	"log"

	"github.com/chromedp/chromedp"
)

func main() {
	allocCtx, cancel := chromedp.NewRemoteAllocator(
		context.Background(),
		"ws://127.0.0.1:9222/",
	)
	defer cancel()

	ctx, cancel := chromedp.NewContext(allocCtx)
	defer cancel()

	var body string
	err := chromedp.Run(ctx,
		chromedp.Navigate("https://example.com"),
		chromedp.WaitReady("body"),
		chromedp.InnerHTML("body", &body),
	)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(body)
}
```

## Performance Benchmarks

Tested on macOS aarch64 (Apple Silicon M4 Max), nightly build `2026-03-22`.

### Fetch Mode

| URL | Time | Notes |
|-----|------|-------|
| `example.com` | 0.5s | Minimal page |
| `news.ycombinator.com` | 1.1s | Server-rendered HTML, 229 links |
| `github.com` | 2.0s | Dynamic content |

### CDP Mode (Puppeteer)

| URL | Time | Links Found |
|-----|------|-------------|
| `example.com` | 501 ms | 1 |
| `news.ycombinator.com` | 1030 ms | 229 |

### Memory Usage (Concurrent Pages)

| Pages | Lightpanda | Chrome Headless | Ratio |
|-------|-----------|-----------------|-------|
| 1 | ~7 MB | ~280 MB | 40x |
| 10 | ~70 MB | ~2.8 GB | 40x |
| 100 | ~696 MB | ~4.2 GB | 6x |

## Recommended Server Configuration

### For AI Agent Workloads (Low Parallelism)

```bash
lightpanda serve --timeout 0 --cdp_max_connections 16
```

Single agent, sequential browsing. Default settings work.

### For Research / Crawl Runs (High Parallelism)

```bash
lightpanda serve \
  --timeout 0 \
  --cdp_max_connections 128 \
  --http_max_concurrent 200 \
  --http_max_host_open 8 \
  --obey_robots
```

Multiple agents or parallel page fetching. Increase HTTP concurrency to avoid bottlenecks.

### For CI / Testing

```bash
lightpanda serve --timeout 30 --cdp_max_connections 8
```

Short-lived sessions. Timeout helps clean up leaked connections.

## Known Limitations

| Area | Status | Workaround |
|------|--------|------------|
| Complex SPAs (React SSR, Angular) | Partial | Chrome fallback |
| WebSocket-heavy sites | [#1952](https://github.com/lightpanda-io/browser/issues/1952) | Chrome fallback |
| Authenticated flows (OAuth, SAML) | Limited | Chrome fallback |
| `console` API interception | [#1953](https://github.com/lightpanda-io/browser/issues/1953) | — |
| Chromium discovery endpoints (`/json/list`) | [#1932](https://github.com/lightpanda-io/browser/issues/1932) | Use `/json/version` only |
| Remote `webSocketDebuggerUrl` | [#1922](https://github.com/lightpanda-io/browser/issues/1922) | Override URL in client |
