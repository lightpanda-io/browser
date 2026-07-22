# **PandaScript vs Puppeteer and Playwright**

**Author:** Adrià Arrufat

**Last modified:** July 19, 2026

**Short description:** The same browsing tasks written as PandaScripts and as Puppeteer/Playwright scripts: near-identical code, none of the stack. Real numbers against live Hacker News, a hydration-heavy storefront, ad-heavy news pages, and a network-free login fixture.

**Keywords:** pandascript, puppeteer, playwright, automation, benchmarks

## **TL;DR**

A PandaScript is the same script you would write for Puppeteer or Playwright, minus everything around it: no Node, no npm install, no browser download, no CDP connection. One binary reads the file and does the work. On live sites (Hacker News, a hydration-heavy storefront, ad-heavy news pages), a Lightpanda configuration is the fastest in **every cell of every table**, and the PandaScript replay specifically is the fastest **warm** configuration on every task — 53% ahead of a pre-warmed headless Chrome on Hacker News, 2.8× on the storefront, 3.6× on the news pages — and the fastest cold wherever the site's own variance doesn't blur the Lightpanda configurations into a tie. Take the network out and the stack itself is the story: a complete login flow replays in 58 ms, browser startup included — ~5× faster than CDP on the same engine, 7–9× faster than Chrome — and the whole replay peaks at 16–155 MB of memory where the Chrome stacks need 305–1,400 MB. An earlier version of this benchmark had us *losing* two of these tables, and investigating instead of shrugging produced two merged engine fixes and one more issue on file — that story is in here too, because benchmarks you only publish when you win aren't benchmarks.

## **The same task, three scripts**

The task: open the Hacker News front page, take the top five stories, visit each story's comment page, and return the top three comments for each. Six page loads, one JSON result.

As a PandaScript:

```js
const page = new Page();
await page.goto("https://news.ycombinator.com");

const { stories } = page.extract({
  stories: [{
    selector: "tr.athing",
    limit: 5,
    fields: {
      id: { selector: "", attr: "id" },
      rank: ".rank",
      title: ".titleline > a",
      url: { selector: ".titleline > a", attr: "href" }
    }
  }]
});

const results = [];
for (const story of stories) {
  await page.goto(`https://news.ycombinator.com/item?id=${story.id}`);
  let comments = [];
  try {
    ({ comments } = page.extract({
      comments: [{
        selector: "tr.comtr",
        limit: 3,
        fields: { user: ".hnuser", text: ".commtext" }
      }]
    }));
  } catch {}
  results.push({ rank: story.rank, title: story.title, url: story.url, comments });
}

return results;
```

As a Puppeteer script:

```js
import puppeteer from "puppeteer-core";

const endpoint = process.env.BROWSER_WS ?? "ws://127.0.0.1:9222";
const browser = await puppeteer.connect(
  endpoint.startsWith("ws://")
    ? { browserWSEndpoint: endpoint }
    : { browserURL: endpoint },
);
const context = await browser.createBrowserContext();
const page = await context.newPage();

await page.goto("https://news.ycombinator.com");

const stories = await page.$$eval("tr.athing", (rows) =>
  rows.slice(0, 5).map((row) => ({
    id: row.id,
    rank: row.querySelector(".rank")?.textContent ?? "",
    title: row.querySelector(".titleline > a")?.textContent ?? "",
    url: row.querySelector(".titleline > a")?.href ?? "",
  })),
);

const results = [];
for (const story of stories) {
  await page.goto(`https://news.ycombinator.com/item?id=${story.id}`);
  const comments = await page.$$eval("tr.comtr", (rows) =>
    rows.slice(0, 3).map((row) => ({
      user: row.querySelector(".hnuser")?.textContent ?? "",
      text: row.querySelector(".commtext")?.textContent ?? "",
    })),
  );
  results.push({ rank: story.rank, title: story.title, url: story.url, comments });
}

console.log(JSON.stringify(results));

await page.close();
await context.close();
await browser.disconnect();
```

The Playwright version is the Puppeteer version with `chromium.connectOverCDP` — we won't repeat it. Line counts: 33 (PandaScript), 39 (Puppeteer), 35 (Playwright).

The middle of every script is the same. Navigate, select, loop. The differences sit at the edges. The Puppeteer and Playwright scripts spend their first ten lines connecting to a browser that something else has to have started, and their last three disconnecting from it. The PandaScript starts working on line one, because the script runner *is* the browser.

The other difference is how data comes out. Puppeteer and Playwright hand you `$$eval`: you ship an imperative function into the page and collect what it returns. PandaScript's `extract` takes a declarative schema — selectors in, JSON out. Schemas survive replay better than code: a selector either matches or it doesn't, and when it doesn't, the error names the selector instead of a stack frame inside an anonymous function serialized into a page you can't see.

## **What you install**

|  | Puppeteer / Playwright | PandaScript |
| :---- | :---- | :---- |
| Runtime | Node.js | — |
| Dependencies | `npm install`, `node_modules/` | — |
| Browser | Chromium download (~170 MB) or a running Chrome | — |
| Connection | Launch browser, connect over CDP | — |
| Total | Two processes and a protocol | `lightpanda agent script.js` |

This table is the setup cost of the *fifth* line of the Puppeteer script above. It is paid per machine, per CI runner, per Docker image, and again every time Chrome revs and the pinned driver version disagrees with it.

## **What we measured**

Numbers are worthless without method, so: every configuration ran the tasks against **live** sites — real network, real pages, no fixtures. Three live workloads chosen to bracket the space, not to flatter anyone: a light server-rendered site (news.ycombinator.com), a hydration-heavy storefront (eu.gymshark.com), and an ad-and-tracker-heavy news page (apnews.com) — plus a local login fixture that removes the network entirely. Five configurations: the PandaScript replayed by `lightpanda agent`, and the Puppeteer and Playwright scripts each driving `lightpanda serve` and headless Chrome over CDP.

One configuration choice to be explicit about: **the Lightpanda configurations run with `--http-cache-dir` set.** Chrome's HTTP cache is on by default; Lightpanda's is one flag away, and comparing a caching browser against a deliberately non-caching one answers a question nobody is asking. Each browser (or replay process) gets a fresh cache directory — no state travels between cold runs, which is stricter than Chrome, whose pre-created profile persists across our cold runs. An earlier version of this benchmark ran stock-vs-stock instead; that dataset (and what investigating it fixed in the engine) is covered below.

Runs were interleaved round-robin — one execution of each configuration per rotation (12 measured rotations after 2 warmups) — so site latency drift hits every configuration equally. We report medians. 10 of 552 measured executions failed validity checks and were excluded: one Chrome navigation timeout and one Lightpanda navigation that hit the 5-second default HTTP timeout, both on the news task's ad-tail, and eight runs where Puppeteer's node adoption raced the storefront's post-load hydration re-render — Chrome keeps replaced nodes resolvable and Lightpanda currently doesn't ([filed as #2994](https://github.com/lightpanda-io/browser/issues/2994); Playwright on the same engine is untouched, and the affected cells report their reduced n below. Yes, this benchmark got a third engine bug on file before publication — working as intended). Raw per-run data including every failure, the harness, and the exact scripts are in the [benchmarks repo](https://github.com/lightpanda-io/agent-benchmarks/tree/main/pandascript-vs-cdp) (`results/v3-*`).

Two modes:

* **Cold** — nothing running to result JSON on stdout. For CDP configurations the clock includes launching the browser and connecting; for PandaScript it's the one command doing everything. Fresh cache everywhere.
* **Warm** — steady state for repeated tasks: whatever the architecture keeps between runs, it keeps. For the CDP configurations that's the running browser (and its cache); the clock covers a fresh `node script.js`, which still pays Node startup and the CDP connect, because a new task against a browser pool always does. A PandaScript replay is one process with nothing to hold resident, so its warm state is its persistent cache directory — the clock still covers the entire command, browser startup included.

Machine: Linux (kernel 7.1.3), Intel Core Ultra 7 258V, Node v26.4, Chrome 150, puppeteer-core 24.14, playwright-core 1.57, Lightpanda built ReleaseFast from main @299eb2c5.

### **Cold: nothing running → JSON**

| Configuration | Median | vs PandaScript |
| :---- | ----: | ----: |
| **PandaScript replay** | **1.88 s** | — |
| Puppeteer → lightpanda serve | 2.20 s | +17% |
| Playwright → lightpanda serve | 2.27 s | +21% |
| Puppeteer → Chrome | 3.11 s | +65% |
| Playwright → Chrome | 3.30 s | +76% |
| **PandaScript replay, parallel variant** | **1.41 s** | **−25%** |

### **Warm: browser already running → JSON**

| Configuration | Median |
| :---- | ----: |
| **PandaScript replay** | **1.65 s** |
| Puppeteer → lightpanda serve | 1.88 s |
| Playwright → lightpanda serve | 2.01 s |
| Playwright → Chrome | 2.52 s |
| Puppeteer → Chrome | 2.60 s |

![Per-run timing distributions for the Hacker News scrape, cold and warm, all five configurations](figures/scrape.svg)
*Every measured run, not just the medians (the vertical tick per row). Live-site variance is real; the round-robin protocol makes it hit every configuration equally.*

### **Reading the numbers honestly**

Six serial page loads against a live site is mostly network: every configuration spends the bulk of its time waiting on news.ycombinator.com. That is the real world the benchmark bought. Three things still separate the columns.

**The stack tax is visible at identical engines.** Puppeteer and Playwright driving `lightpanda serve` run the *same engine* as the PandaScript replay — the only difference is Node, the CDP WebSocket, and per-call protocol round-trips. On this light site that difference is 17–21% cold and 14–22% warm; on the heavier pages below it grows with page activity — 37–43% warm on the storefront, 48–56% warm on the news pages — because more page activity means more protocol traffic. (Cold on those heavy sites, the site's own run-to-run variance is larger than the stack tax, and the three Lightpanda configurations finish inside each other's interquartile ranges — read those cells as a tie.) This is the purest measurement of what the driver layer costs, because everything else is held constant.

**Chrome loses every cell, and the margin is the page weight.** Warm — the friendliest case for Chrome, launch cost excluded — its fastest configuration trails the replay by 53% here, 2.8× on the storefront, and 3.6× on the news pages. Some of that is the engine (a text-only browser skips the ad and media payload that Chrome must fetch and execute before `load`), some is the stack (Node + CDP per task). Cold adds Chrome's launch on top: ~100 ms launch-to-ready vs ~50 ms for `lightpanda serve` — and the PandaScript number *includes* its browser's startup, because there is no separate browser.

If you operate a warm browser pool, the warm rows are your rows — and they're no longer the close ones. Node startup and the CDP connect are paid per task, pool or no pool; the login table below shows that fixed cost in isolation. The cold rows are for everyone else: a cron job, a CI step, a serverless function, a script on a laptop — contexts where "the browser is already running" is an assumption someone has to operate. (And if you've read [our 9× throughput numbers](https://lightpanda.io/blog/posts/from-local-to-real-world-benchmarks) and wonder how they square with these smaller margins: those measure CPU-bound page processing and memory footprint; these tables are serial tasks dominated by a live site's network latency. Both are true; they answer different questions.)

**Parallelism is where the model pays off.** The parallel PandaScript variant creates one `Page` per story and `Promise.all`s the five detail loads: 1.41 s median cold, 1.20 s warm — the fastest numbers in this post against a live site. You can write the same fan-out in Puppeteer or Playwright — pages are cheap in Lightpanda precisely so that you can — but in a PandaScript it's four lines, and the agent writes those lines for you (more on that below).

## **A heavier page: retail price monitoring**

Hacker News is server-rendered and light — friendly territory for any browser. Real scraping work more often looks like this: a JS-heavy storefront, and a task shaped like price monitoring. Open a collection page on eu.gymshark.com, take the first three products, visit each product page, return name, price, and sizes:

```js
const page = new Page();
await page.goto("https://eu.gymshark.com/es-ES/collections/all-products/mens");

const { products } = page.extract({
  products: [{
    selector: "[class*='product-card_card-wrapper']",
    limit: 3,
    fields: {
      name: { selector: "[class*='product-card_title'] a" },
      url: { selector: "a[href*='/products/']", attr: "href" }
    }
  }]
});

for (const product of products) {
  await page.goto(product.url);
  page.waitForSelector("fieldset[class*='add-to-cart_sizes']");
  const details = page.extract({
    price: { selector: "[class*='product-information_price']" },
    sizes: ["fieldset[class*='add-to-cart_sizes'] label[class*='size_size']"]
  });
  product.price = parseFloat(details.price.replace(",", "."));
  product.sizesAvailable = details.sizes;
}

return products;
```

The Puppeteer and Playwright versions are the same shape (selectors identical, `$$eval` in place of the schema). Four page loads per run, same rotation protocol. (The earlier version of this benchmark used allbirds.com here; after several days of benchmark campaigns their bot protection began blocking Lightpanda-fingerprinted traffic from our IP — an occupational reality of benchmarking against production storefronts — so the current dataset uses Gymshark. Same task shape, same script structure.)

| Configuration | Cold | Warm |
| :---- | ----: | ----: |
| **PandaScript replay** | 5.78 s | **2.38 s** |
| Playwright → lightpanda serve | 4.27 s | 3.39 s |
| Puppeteer → lightpanda serve | 6.19 s¹ | 3.24 s¹ |
| Puppeteer → Chrome | 7.31 s | 6.56 s |
| Playwright → Chrome | 7.06 s | 7.10 s |

¹ n=9 cold, n=7 warm: the excluded runs are the [#2994](https://github.com/lightpanda-io/browser/issues/2994) handle race — Puppeteer-specific, disclosed above.

![Per-run timing distributions for the retail task, cold and warm, all five configurations](figures/retail.svg)

Cold on a heavy storefront is the noisiest measurement in this post — the site's own variance (CDN weather, per-request personalization) spreads every configuration's runs across a 3–8 s band, and the three Lightpanda configurations land inside each other's interquartile ranges: read their cold column as a tie at ~4–6 s, collectively ahead of Chrome's 7.1–7.3 s. Warm is where the shape gets crisp: with caches doing their job on a page full of shared assets, the replay's steady-state run is 2.38 s against 6.56–7.10 s for Chrome — **2.8× faster** — and the same-engine gap is 37–43%.

### **The first run of this benchmark, we lost — twice. Here's what happened**

We almost published two very different tables, and the honest version of this post has to include both.

The first loss was the original retail run: Chrome winning outright, the replay 46% behind warm. The investigation (the full evidence chain, including the dead ends, is in [RETAIL-INVESTIGATION.md](https://github.com/lightpanda-io/agent-benchmarks/blob/main/pandascript-vs-cdp/RETAIL-INVESTIGATION.md)) found **two missing web APIs sending the theme down its worst path**: modern loaders feature-detect `HTMLScriptElement.supports("module")` and `link.relList.supports("modulepreload")`; both were missing, so the storefront's theme fell back to a legacy `fetch()`-based chunk loader — 676 network requests instead of 305 for two pages, the same Vue bundle fetched nine times per page. Implementing the two functions ([merged as #2886](https://github.com/lightpanda-io/browser/pull/2886), ~20 lines) flipped the theme onto the modern path, halved the network traffic, and eliminated a ~4% driver-level flake as a bonus. The fix is platform-level, not site-tuned: request profiles on further storefronts now match Chrome's within a few percent.

The second loss was subtler. With the engine fixed, the remaining warm gap traced to caching — so we measured `--http-cache-dir` on every task, and found it made the agent path faster everywhere but made the **CDP-server path dramatically slower**: on an offline fixture, cache *hits* were slower than cache misses, ~170 ms slower per page. A 30-second reproduction ([published](https://github.com/lightpanda-io/agent-benchmarks/tree/main/pandascript-vs-cdp/repro-serve-cache), filed as [#2987](https://github.com/lightpanda-io/browser/issues/2987)) pinned it to the client's wait loop: cache-served responses are delivered with no network I/O behind them, so after delivering one, the tick sat in an I/O poll that nothing would ever wake. [PR #2989](https://github.com/lightpanda-io/browser/pull/2989) fixed the wait condition; on the repro, warm cache hits went from ~1,200 ms to 18–23 ms. Every table in this post is measured on the post-fix binary — it's why the cache flag could graduate from a caveat-laden appendix in the earlier version of this post to the benchmarked configuration in this one.

The meta-point matters more than either fix: **the benchmark was the diagnostic tool.** Two wall-time losses on real sites localized two concrete engine bugs — both merged upstream before this post shipped — and the final rerun surfaced a third: Chrome keeps framework-replaced DOM nodes resolvable for driver handle adoption where Lightpanda currently forgets them, which is exactly the kind of graceful-degradation detail you only find by racing a real storefront's hydration ([#2994](https://github.com/lightpanda-io/browser/issues/2994), the reduced-n footnote in the retail table). That feedback loop is the actual argument for benchmarking against live sites and publishing what you find, losses included.

A note on the other opt-in flags, measured on the earlier dataset with the same interleaved A/B discipline: `--disable-subframes` was worth **−9%** on the ad-iframe-heavy news task and nothing on retail; `--v8-max-heap-mb 128` shaved **17% off the retail task's peak memory** at no time cost and did nothing where the V8 heap wasn't the constraint. Flags are levers, not magic: each pays off on the workload shape it targets.

## **Where text-only wins big: news pages**

We added this task specifically to stress the one dimension the other two sites don't: dozens of async third-party tags — ads, analytics, video players. Media monitoring is also exactly the kind of job people script. The task: an AP News section page → the top three articles → headline and opening paragraphs from each. Four page loads per run.

| Configuration | Cold | Warm |
| :---- | ----: | ----: |
| **PandaScript replay** | 4.01 s | **1.90 s** |
| Puppeteer → lightpanda serve | 3.84 s¹ | 2.82 s |
| Playwright → lightpanda serve | 6.54 s | 2.96 s |
| Puppeteer → Chrome | 9.74 s | 6.76 s |
| Playwright → Chrome | 10.93 s¹ | 7.12 s |

¹ n=11: one navigation timeout each — Lightpanda's at its 5-second default HTTP timeout, Chrome's at Playwright's 30 seconds.

![Per-run timing distributions for the news task, cold and warm, all five configurations](figures/news.svg)
*The ad-tech tail is real — cold medians for the Lightpanda configurations sit within each other's interquartile ranges, so read them as a tie. The Chrome rows are not a tie.*

This is the table where the engine choice dwarfs everything else: **Chrome needs ~2.4× the time cold and ~3.6× warm** — 9.7–10.9 s vs 3.8–6.5 s cold, 6.8–7.1 s vs 1.9–3.0 s warm. The reason is structural, not clever: before `load` fires, Chrome downloads and runs the page's ad and media payload, because rendering it is Chrome's job. A text-only browser fetches the document and the scripts and skips the rest. On ad-heavy pages that's not an optimization, it's a different amount of work.

## **The login flow**

Scraping is half the story; the other half is acting on a page. The login task: open the HN login form, fill credentials, submit, then read the account's karma from its profile page.

```js
const page = new Page();
await page.goto("https://news.ycombinator.com/login");

page.fill("input[name=acct]", "$LP_HN_USERNAME");
page.fill("input[name=pw]", "$LP_HN_PASSWORD");
page.press("input[name=pw]", "Enter");

page.waitForState({ state: "load" });
page.waitForSelector("#logout");

await page.goto("https://news.ycombinator.com/user?id=$LP_HN_USERNAME");
const { karma } = page.extract({
  karma: "#hnmain table table tr:nth-child(3) td:nth-child(2)"
});

return { karma: parseInt(karma, 10) };
```

16 lines, against 40 for Puppeteer and 35 for Playwright — the connect/teardown ceremony is a bigger share of a small script.

Look at the credentials. `$LP_HN_USERNAME` is not an environment-variable lookup in the script — it's a placeholder resolved inside the Lightpanda process when the tool call runs. The literal value never appears in the script file, never transits the LLM when an agent writes the script, and never lands in a session transcript. In the Node scripts, secrets management is your problem; `process.env` in the script is the polite version of it.

### **Login timing: the stack tax without the network**

We timed this flow against a local fixture that mirrors HN's login markup selector-for-selector (the scripts differ from the ones above only in the base URL), and that's a deliberate choice, not a compromise: with the network removed, nothing is left but the stack itself — same code, same waits, the cleanest measurement of driver overhead in this post. It's also the only responsible option: benchmarking a production login endpoint means dozens of logins from one IP, which anti-abuse systems rightly block. Medians, IQR within a few ms throughout.

| Configuration | Cold | Warm |
| :---- | ----: | ----: |
| **PandaScript replay** | **58 ms** | **56 ms** |
| Puppeteer → lightpanda serve | 306 ms | 252 ms |
| Playwright → lightpanda serve | 317 ms | 260 ms |
| Puppeteer → Chrome | 491 ms | 367 ms |
| Playwright → Chrome | 512 ms | 394 ms |

Read the cold column again. 58 ms is the *entire task*: start the browser, load the login page, fill two fields, submit, follow the redirect, load the profile page, extract the karma. The CDP configurations on the same engine take ~5× as long, and most of that isn't the protocol chatter — it's Node starting up and connecting, a fixed ~250 ms tax that no script content can amortize away on a short task. Against Chrome it's 8–9×, launch included (6.5–7× warm). This is what the live-site benchmarks' percentages become once the network stops hiding them: short, action-dense tasks — exactly the shape of a replayed automation — are where the in-process model runs away.

## **What each stack costs to keep in memory**

Wall time is half of the operational story; the other half is what has to stay resident to do the work. Measuring this fairly across configurations takes some care, because the configurations aren't the same shape: a PandaScript replay is one process, while the CDP configurations are a Node process *plus* a browser — and in Chrome's case, a whole process tree (browser, GPU process, network service, a renderer per page). So each number below is the **peak memory of everything that configuration needs**, captured by sampling the full process tree of each side at 150 ms intervals during a cold task run and summing **PSS** rather than RSS — summing RSS across Chrome's tree would double-count every shared library and unfairly inflate its number. Five runs per cell, medians, same binary and cache configuration as the timing tables.

| Task | PandaScript replay | Node + lightpanda serve | Node + Chrome |
| :---- | ----: | ----: | ----: |
| HN scrape | **32 MB** | 114–120 MB | 419–445 MB |
| Retail (storefront) | **155 MB** | 419–421 MB | 915–1,421 MB |
| News monitoring | **121 MB** | 262–276 MB | 978–994 MB |
| Login (fixture) | **16 MB** | 96–101 MB | 305–345 MB |

Three readings. First, the replay needs **6–22× less memory than the Chrome stacks** for the same tasks — the smaller end of that range is the retail row, and it's worth saying why: executing a heavy hydration bundle costs real V8 heap no matter who runs it, so JS-heavy pages compress everyone's advantage. That's consistent with [what we've published before](https://lightpanda.io/blog/posts/from-local-to-real-world-benchmarks) at the engine level, now measured for the full stack a user actually runs. Second, Chrome crossing **a gigabyte on ad-heavy and storefront pages alike** is the memory version of the timing story above: rendering the payload isn't just slow, it's resident. Third, this is the number that decides *density*: on a 4 GB box, that's roughly thirty concurrent news-monitoring replays versus four Chrome stacks — before Chrome's number grows further with tabs and contexts. (One caveat, and it cuts against us: the login replay finishes in ~60 ms, so the 150 ms sampler catches its peak only a couple of times — PandaScript's 16 MB may understate its true peak, which would overstate that row's ratio. The longer-running rows don't have this problem.)

## **Where the script comes from**

You can write a PandaScript by hand — the API above is the whole surface, and if you've used Playwright you already know how to think in it. But the intended workflow is that you don't write it at all: work through the task once in [`lightpanda agent`](https://lightpanda.io/blog/posts/introducing-lightpanda-agent-and-pandascript), in plain English, then `/save task.js`. The agent distills the session into a script like the ones above. Replays run with no model in the loop: zero tokens, deterministic. You pay for reasoning once and keep the artifact.

Once, concretely, being: we had the agent write the news-monitoring script from this post in a single session — "go to the AP world-news hub, take the first 3 articles, return headline and opening paragraphs." One-time API cost: **$0.82** (Claude Sonnet 4.6; ~2.9K output tokens plus prompt-cache writes of the page content it read while working). Every replay since costs zero and needs no key at all.

That's also why `extract` is schema-based and every action takes a CSS selector: recorded selectors replay; ephemeral node IDs and ad-hoc page functions don't. The constraint that makes the language small is the constraint that makes the replay reliable.

## **When you should still use Puppeteer or Playwright**

We ship a CDP server precisely because the answer isn't "never": a decade of existing scripts, test suites built on Playwright's assertions and fixtures, ecosystems of plugins. All of it runs against `lightpanda serve` today — those are the serve columns above, they beat the Chrome columns in every warm cell, and the path is supported and actively developed. The claim is narrower: for a *new* browsing task whose output is data — scraping, monitoring, form automation — the same logic with none of the stack is the better default.

## **FAQ**

### **What is a PandaScript?**

Plain JavaScript with a small set of native browser primitives (`goto`, `extract`, `fill`, `click`, waits) built directly into Lightpanda. `lightpanda agent script.js` replays one deterministically — no Node, no CDP, no LLM, no API key. See the [PandaScript docs](https://lightpanda.io/docs/usage/pandascript).

### **Is PandaScript replacing Puppeteer and Playwright support?**

No. `lightpanda serve` speaks CDP and existing Puppeteer/Playwright scripts run against it unchanged — it's how half the configurations in this post were measured, and it's actively developed.

### **Why is replay faster than CDP on the same engine?**

Because nothing sits between the script and the engine. A `click` in a PandaScript is an in-process function call; the same click from Puppeteer is a serialized protocol message over a WebSocket to a separate process, and the page data comes back the same way. On network-bound live-site tasks that stack costs 14–22% of wall time on a light site and up to ~50% on busy pages; on a network-free login flow, where nothing hides it, it's the difference between 58 ms and 306 ms on the same engine.

### **Do I need an LLM to run a PandaScript?**

No. An LLM (optionally) writes the script during an agent session; replaying it is model-free and token-free. `$LP_*` placeholders keep credentials out of both the script and the model context.

### **Can I benchmark this myself?**

Yes — harness, scripts, raw results: [benchmarks repo](https://github.com/lightpanda-io/agent-benchmarks/tree/main/pandascript-vs-cdp). `lightpanda serve` vs Chrome is one env var in the driver scripts.
