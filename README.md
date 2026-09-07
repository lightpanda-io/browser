<p align="center">
  <a href="https://lightpanda.io"><img src="https://cdn.lightpanda.io/assets/images/logo/lpd-logo.png" alt="Logo" height=170></a>
</p>
<h1 align="center">Lightpanda Browser</h1>
<p align="center">
<strong>The headless browser built from scratch for AI agents and automation.</strong><br>
Not a Chromium fork. Not a WebKit patch. A new browser, written in Zig.
</p>

</div>
<div align="center">

[![License](https://img.shields.io/github/license/lightpanda-io/browser)](https://github.com/lightpanda-io/browser/blob/main/LICENSE)
[![Twitter Follow](https://img.shields.io/twitter/follow/lightpanda_io)](https://twitter.com/lightpanda_io)
[![GitHub stars](https://img.shields.io/github/stars/lightpanda-io/browser)](https://github.com/lightpanda-io/browser)
[![Discord](https://img.shields.io/discord/1391984864894521354?style=flat-square&label=discord)](https://discord.gg/K63XeymfB5)

</div>
<div align="center">

[<img width="350px" src="https://cdn.lightpanda.io/assets/images/github/execution-time-v2.svg">
](https://github.com/lightpanda-io/demo)
&emsp;
[<img width="350px" src="https://cdn.lightpanda.io/assets/images/github/memory-frame-v2.svg">
](https://github.com/lightpanda-io/demo)
</div>

## Benchmarks

Requesting 933 real web pages over the network on a AWS EC2 m5.large instance.
See [benchmark details](https://github.com/lightpanda-io/demo/blob/main/BENCHMARKS.md#crawler-benchmark).

| Metric | Lightpanda | Headless Chrome | Difference |
| :---- | :---- | :---- | :---- |
| Memory (peak, 100 pages) | 123MB | 2GB | ~16 less |
| Execution time (100 pages) | 5s | 46s | ~9x faster |

## Quick start

### Install

**Package Managers**

Latest nightly from Homebrew:
```console
brew install lightpanda-io/browser/lightpanda
```

Latest nightly from Arch Linux User Repository:
```console
yay -S lightpanda-nightly-bin
```

**Download from the nightly builds**

You can download the last binary from the [nightly
builds](https://github.com/lightpanda-io/browser/releases/tag/nightly) for
Linux and MacOS for both x86_64 and aarch64.

*For Linux*
```console
curl -L -o lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux && \
chmod a+x ./lightpanda
```

Verify the binary before running anything:
```console
./lightpanda version
```

[Linux aarch64 is also available](https://github.com/lightpanda-io/browser/releases/tag/nightly)

> **Note:** The Linux release binaries are linked against glibc. On musl-based distros (Alpine, etc.) the binary fails with `cannot execute: required file not found` because the glibc dynamic linker is missing. Use a glibc-based base image (e.g., `FROM debian:bookworm-slim` or `FROM ubuntu:24.04`) or [build from sources](#build-from-sources).

*For MacOS*
```console
curl -L -o lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-aarch64-macos && \
chmod a+x ./lightpanda
```

[MacOS x86_64 is also available](https://github.com/lightpanda-io/browser/releases/tag/nightly)

*For Windows + WSL2*

Lightpanda has no native Windows binary. Install it inside WSL following the Linux steps above.

WSL not installed? Run `wsl --install` from an administrator shell, restart, then open `wsl`.
See [Microsoft's WSL install guide](https://learn.microsoft.com/en-us/windows/wsl/install) for details.

Your automation client (Puppeteer, Playwright, etc.) can run either inside WSL or on the Windows host. WSL forwards `localhost:9222` automatically.

**Install from Docker**

Lightpanda provides [official Docker
images](https://hub.docker.com/r/lightpanda/browser) for both Linux amd64 and
arm64 architectures.
The following command fetches the Docker image and starts a new container exposing Lightpanda's CDP server on port `9222`.
```console
docker run -d --name lightpanda -p 127.0.0.1:9222:9222 lightpanda/browser:nightly
```

### Dump a URL

```console
./lightpanda fetch --obey-robots --dump html --log-format pretty  --log-level info https://demo-browser.lightpanda.io/campfire-commerce/
```

You can use `--dump markdown` to convert directly into markdown, or
`--dump png > page.png` or `--dump pdf > page.pdf` for a text-only rendering
of the page.
`--wait-until`, `--wait-ms`, `--wait-selector` and `--wait-script` are
available to adjust waiting time before dump.

### Start a CDP server

```console
./lightpanda serve --obey-robots --log-format pretty  --log-level info --host 127.0.0.1 --port 9222
```
Once the CDP server started, you can run a Puppeteer script by configuring the
`browserWSEndpoint`.

<details>
<summary>Example Puppeteer script</summary>

```js
import puppeteer from 'puppeteer-core';

// use browserWSEndpoint to pass the Lightpanda's CDP server address.
const browser = await puppeteer.connect({
  browserWSEndpoint: "ws://127.0.0.1:9222",
});

// The rest of your script remains the same.
const context = await browser.createBrowserContext();
const frame = await context.newPage();

// Dump all the links from the frame.
await frame.goto('https://demo-browser.lightpanda.io/amiibo/', {waitUntil: "networkidle0"});

const links = await frame.evaluate(() => {
  return Array.from(document.querySelectorAll('a')).map(row => {
    return row.getAttribute('href');
  });
});

console.log(links);

await frame.close();
await context.close();
await browser.disconnect();
```
</details>

### Agent mode

`lightpanda agent` lets you drive the browser with a native agent. Describe what
you want in plain English or with slash commands, and it controls the browser:
navigating pages, clicking through flows, filling forms, extracting structured
data. Think of it as a robot you're directing to use the web, more than a
chatbot you're having a conversation with.

Because the agent runs inside the same process as the browser, every tool call
is a direct operation and you retain Lightpanda's speed and memory advantage.

The output of an agent session is a
[PandaScript](https://lightpanda.io/docs/usage/pandascript): vanilla JavaScript
with a small set of native browser primitives built directly into Lightpanda.
Run `/save` to export one from your current session, then replay it with
`lightpanda run <script>.js`. Scripts are deterministic and token-free, so
you can prototype with the LLM and ship the output to production without a
model at runtime.

It supports Anthropic, OpenAI, Gemini, Google Vertex AI, Mistral, Hugging
Face, the [Vercel AI Gateway](https://vercel.com/ai-gateway) (one key for
hundreds of models from every major lab), any OpenAI-compatible endpoint via
`OPENAI_BASE_URL`, and local models via Ollama or llama.cpp. You can also run
without an LLM using `--no-llm`, which drops you into the REPL. See the
[agent documentation](https://lightpanda.io/docs/usage/agent) for the full
reference.

```console
./lightpanda agent                                    # auto-detects API key from env
./lightpanda agent --task "top story on news.ycombinator.com?"
./lightpanda agent --no-llm                           # basic REPL, no LLM
./lightpanda run session.js                           # run a recorded script
./lightpanda agent --provider gemini --task "..."     # force a specific provider
./lightpanda agent --list-models                      # models available for the detected provider
VERTEX_API_KEY=... ./lightpanda agent --provider vertex             # Vertex AI, express mode
GOOGLE_CLOUD_PROJECT=my-proj ./lightpanda agent --provider vertex   # Vertex AI, token via gcloud auth
AI_GATEWAY_API_KEY=... ./lightpanda agent --provider vercel --model moonshotai/kimi-k2   # any model behind Vercel AI Gateway
OPENAI_BASE_URL=https://my-gateway/v1 OPENAI_API_KEY=... ./lightpanda agent            # any OpenAI-compatible server
```

### Native MCP and skill

The MCP server communicates via MCP JSON-RPC 2.0 over stdio.

Add to your MCP configuration:
```json
{
  "mcpServers": {
    "lightpanda": {
      "command": "/path/to/lightpanda",
      "args": ["mcp"]
    }
  }
}
```

#### HTTP transport and independent sessions

For serving several agents from one process, start the MCP server over HTTP
instead of stdio by giving it a port (add `--host x.x.x.x` to specify the
interface to listen on):

```bash
lightpanda mcp --port 9223
```

Clients POST JSON-RPC to `http://host:9223/mcp`. Each connection is routed to
its own **browsing session** — its own page, cookies and memory — so agents no
longer clobber each other's page:

- A client that `initialize`s without an `Mcp-Session-Id` header is assigned a
  fresh session; the id comes back in the response's `Mcp-Session-Id` header.
  Send it on subsequent requests to stay on that session (**isolation**).
- Two agents that send the **same** `Mcp-Session-Id` share one browsing context
  (**sharing** — e.g. a workflow where several agents work the same page).
- The `session_new`, `session_list` and `session_close` tools manage sessions
  explicitly. Sending `DELETE /mcp` with an `Mcp-Session-Id` closes that session.

[Read full documentation](https://lightpanda.io/docs/open-source/guides/mcp-server)

A skill is available in [lightpanda-io/agent-skill](https://github.com/lightpanda-io/agent-skill).

### Telemetry

By default, Lightpanda collects and sends usage telemetry. This can be disabled by setting an environment variable `LIGHTPANDA_DISABLE_TELEMETRY=true`. You can read Lightpanda's privacy policy at: [https://lightpanda.io/privacy-policy](https://lightpanda.io/privacy-policy).

### Core dumps

Set `LIGHTPANDA_DISABLE_CORE_DUMP` (to any value) to suppress crash core dumps by zeroing the soft `RLIMIT_CORE` at startup.

## Status

Lightpanda is in Beta and currently a work in progress. Stability and coverage are improving and many websites now work.
You may still encounter errors or crashes. Please open an issue with specifics if so.

Here are the key features we have implemented:

- [x] CORS (enable with `--experimental-features cors`)
- [x] HTTP loader ([Libcurl](https://curl.se/libcurl/))
- [x] HTML parser ([html5ever](https://github.com/servo/html5ever))
- [x] DOM tree
- [x] Javascript support ([v8](https://v8.dev/))
- [x] DOM APIs
- [x] Ajax
  - [x] XHR API
  - [x] Fetch API
- [x] DOM dump
- [x] CDP/websockets server
- [x] Click
- [x] Input form
- [x] Cookies
- [x] Custom HTTP headers
- [x] Proxy support
- [x] Network interception
- [x] Respect `robots.txt` with option `--obey-robots`

NOTE: There are hundreds of Web APIs. Developing a browser (even just for headless mode) is a huge task. Coverage will increase over time.

## Build from sources

### Prerequisites

Lightpanda is written with [Zig](https://ziglang.org/) `0.15.2`. You have to
install it with the right version in order to build the project.

Lightpanda also depends on
[v8](https://chromium.googlesource.com/v8/v8.git),
[Libcurl](https://curl.se/libcurl/) and [html5ever](https://github.com/servo/html5ever).

To be able to build the v8 engine, you have to install some libs:

For **Debian/Ubuntu based Linux**:

```
sudo apt install xz-utils ca-certificates \
    pkg-config libglib2.0-dev \
    clang make curl git
```
You also need to [install Rust](https://rust-lang.org/tools/install/).

For systems with [**Nix**](https://nixos.org/download/), you can use the devShell:
```
nix develop
```

For **MacOS**, you need cmake and [Rust](https://rust-lang.org/tools/install/).
```
brew install cmake
```

### Build and run

You can build the entire browser with `make build` or `make build-dev` for debug
env.

But you can directly use the zig command: `zig build run`.

#### Embed v8 snapshot

Lighpanda uses v8 snapshot. By default, it is created on startup but you can
embed it by using the following commands:

Generate the snapshot.
```
zig build snapshot_creator -- src/snapshot.bin
```

Build using the snapshot binary.
```
zig build -Dsnapshot_path=../../snapshot.bin
```

See [#1279](https://github.com/lightpanda-io/browser/pull/1279) for more details.

## Test

### Unit Tests

You can test Lightpanda by running `make test`.

```bash
make test                                       # Run all tests
make test F="server"                            # Filter by substring
TEST_FILTER="WebApi: #selector_all" make test   # Filter main + subtest (separator: #)
TEST_VERBOSE=true make test
TEST_FAIL_FIRST=true make test
METRICS=true make test                          # Capture allocation/duration metrics as JSON
```

### End to end tests

To run end to end tests, you need to clone the [demo
repository](https://github.com/lightpanda-io/demo) into `../demo` dir.

You have to install the [demo's node
requirements](https://github.com/lightpanda-io/demo?tab=readme-ov-file#dependencies-1)

You also need to install [Go](https://go.dev) > v1.24.

```
make end2end
```

### Web Platform Tests

Lightpanda is tested against the standardized [Web Platform
Tests](https://web-platform-tests.org/).

We use [a fork](https://github.com/lightpanda-io/wpt/tree/fork) including a custom
[`testharnessreport.js`](https://github.com/lightpanda-io/wpt/blob/fork/resources/testharnessreport.js). Results are [published](https://perf.lightpanda.io/wpt) daily.

For reference, you can easily execute a WPT test case with your browser via
[wpt.live](https://wpt.live).

#### Configure WPT HTTP server

To run the test, you must clone the repository, configure the custom hosts and generate the
`MANIFEST.json` file.

Clone the repository with the `fork` branch.
```
git clone -b fork --depth=1 git@github.com:lightpanda-io/wpt.git
```

Enter into the `wpt/` dir.

Install custom domains in your `/etc/hosts`
```
./wpt make-hosts-file | sudo tee -a /etc/hosts
```

Generate `MANIFEST.json`
```
./wpt manifest
```
Use the [WPT's setup
guide](https://web-platform-tests.org/running-tests/from-local-system.html) for
details.

#### Run WPT test suite

An external [Go](https://go.dev) runner is provided by
[github.com/lightpanda-io/demo/](https://github.com/lightpanda-io/demo/)
repository, located into `wptrunner/` dir.
You need to clone the project first.

First start the WPT's HTTP server from your `wpt/` clone dir.
```
./wpt serve
```

Run a Lightpanda browser

```
zig build run -- --insecure-disable-tls-host-verification
```

Then you can start the wptrunner from the demo's clone dir:
```
cd wptrunner && go run .
```

Or one specific test:

```
cd wptrunner && go run . Node-childNodes.html
```

`wptrunner` command accepts `--summary` and `--json` options modifying output.
Also `--concurrency` define the concurrency limit.

:warning: Running the whole test suite will take a long time. In this case,
it's useful to build in `releaseFast` mode to make tests faster.

```
zig build -Doptimize=ReleaseFast run
```

## Contributing

See [CONTRIBUTING.md](https://github.com/lightpanda-io/browser/blob/main/CONTRIBUTING.md) for guidelines.
You must sign our [CLA](CLA.md) during the pull request process.
- [Discord](https://discord.gg/K63XeymfB5)

## Why Lightpanda?

### Javascript execution is mandatory for the modern web

Simple HTTP requests used to be enough for web automation. That's no longer the case. Javascript now drives most of the web:

- Ajax, Single Page Apps, infinite loading, instant search
- JS frameworks: React, Vue, Angular, and others

### Chrome is not the right tool

Running a full desktop browser on a server works, but it does not scale well. Chrome at hundreds or thousands of instances is expensive:

- Heavy on RAM and CPU
- Hard to package, deploy, and maintain at scale
- Many features are not necessary in headless made

### Lightpanda is built for performance

Supporting Javascript with real performance meant building from scratch rather than forking Chromium:

- Not based on Chromium, Blink, or WebKit
- Written in Zig, a low-level language with explicit memory control
- No graphical rendering engine


## 🌐 Web Resources & Interactive Index
- [CATEGORY HERO72](https://eduquests.github.io/category-hero72.html)
- [CATEGORY BATTLESHIP](https://learnaction.netlify.app/category-battleship.html)
- [TERMS](https://brainquests.pages.dev/terms.html)
- [FINGER SOCCER TOURNAMENT](https://eduquests.netlify.app/finger-soccer-tournament.html)
- [MATH LAVA TOWER RACE](https://eduquests.netlify.app/math-lava-tower-race.html)
- [MERRY CHRISTMAS CONNECT](https://eduquests.onrender.com/merry-christmas-connect.html)
- [MAGIC BUBBLES](https://eduquests.netlify.app/magic-bubbles.html)
- [CAT LIFE SIMULATOR DEVIL CAT](https://eduquests.netlify.app/cat-life-simulator-devil-cat.html)
- [THE LOST CITY MATCH 3](https://eduquests.onrender.com/the-lost-city-match-3.html)
- [PUMPKIN PATCH](https://eduquests.github.io/pumpkin-patch.html)
- [CATEGORY MINECRAFT](https://welearnaction.onrender.com/category-minecraft.html)
- [STRYKON](https://eduquests.onrender.com/strykon.html)
- [BATTLE SHOT ELITE](https://welearnaction.onrender.com/battle-shot-elite.html)
- [CATEGORY DESTROY256](https://eduquests.onrender.com/category-destroy256.html)
- [LIMITED DEFENSE](https://welearnaction.onrender.com/limited-defense.html)
- [POP THE BUBBLE](https://learnaction.netlify.app/pop-the-bubble.html)
- [BUBBLE SHOOTER CLASSIC](https://welearnaction.onrender.com/bubble-shooter-classic.html)
- [DONT TAP](https://eduquests.onrender.com/dont-tap.html)
- [INDEX16](https://eduquests.onrender.com/index16.html)
- [SITEMAP](https://brainquests.vercel.app/sitemap.html)
- [CHICKEN BLAST](https://welearnaction.onrender.com/chicken-blast.html)
- [CATEGORY CASUAL 2](https://eduquests.netlify.app/category-casual-2.html)
- [BUILD YOUR AQUARIUM](https://eduquests.onrender.com/build-your-aquarium.html)
- [GEOMETRY FLAP](https://eduquests.onrender.com/geometry-flap.html)
- [MATE IN CHESS](https://eduquests.github.io/mate-in-chess.html)
- [CUBE COMBO](https://eduquests.github.io/cube-combo.html)
- [TIMEWARRIORS](https://eduquests.onrender.com/timewarriors.html)
- [PRIVACY](https://cryptotify.pages.dev/privacy.html)
- [ONLINE PORTAL](https://cryptotify.netlify.app/)
- [JEWEL MONSTERS](https://eduquests.github.io/jewel-monsters.html)
- [WRECK THE TOWER](https://eduquests.onrender.com/wreck-the-tower.html)
- [INDEX15](https://eduquests.onrender.com/index15.html)
- [RAGDOLL BOB PUZZLE](https://eduquests.github.io/ragdoll-bob-puzzle.html)
- [WORD SEARCH UNIVERSE](https://eduquests.netlify.app/word-search-universe.html)
- [CATEGORY CONTROLLER 2](https://eduquests.netlify.app/category-controller-2.html)
- [CATEGORY UNBLOCKED WEBSITES](https://eduquests.github.io/category-unblocked-websites.html)
- [CATEGORY DESTROY256](https://eduquests.netlify.app/category-destroy256.html)
- [STACK TOWER PRO](https://welearnaction.onrender.com/stack-tower-pro.html)
- [CATEGORY MOBILE2 112](https://eduquests.github.io/category-mobile2-112.html)
- [PORT SHIPPING TYCOON](https://eduquests.github.io/port-shipping-tycoon.html)
- [BALLOON MATCH 3D](https://eduquests.netlify.app/balloon-match-3d.html)
- [CATEGORY CAR 2](https://eduquests.netlify.app/category-car-2.html)
- [ONE SHOT TOWER PHYSICS DESTROYER](https://eduquests.onrender.com/one-shot-tower-physics-destroyer.html)
- [DRAW TO FISH FIGHT](https://welearnaction.onrender.com/draw-to-fish-fight.html)
- [ZEN SOLITAIRE](https://eduquests.github.io/zen-solitaire.html)
- [ROOM SORT FLOOR PLAN](https://welearnaction.onrender.com/room-sort-floor-plan.html)
- [STEAL BRAINROT ARENA](https://eduquests.github.io/steal-brainrot-arena.html)
- [MINETAP](https://eduquests.github.io/minetap.html)
- [BRAINROT HOOK SWING](https://eduquests.onrender.com/brainrot-hook-swing.html)
- [CATEGORY THINKY 3](https://ieduquests.web.app/category-thinky-3.html)
- [INDEX9](https://eduquests.netlify.app/index9.html)
- [CAR SIMULATOR 3D CAR GAME 3D](https://eduquests.github.io/car-simulator-3d-car-game-3d.html)
- [CATEGORY PREMIUM PERKS71](https://eduquests.github.io/category-premium-perks71.html)
- [TRAFFIC JAM HOP ON](https://eduquests.github.io/traffic-jam-hop-on.html)
- [GRASS LAND](https://eduquests.onrender.com/grass-land.html)
- [ROYAL REBELLION PUNK MAGIC](https://eduquests.netlify.app/royal-rebellion-punk-magic.html)
- [SITEMAP](https://brainquests.onrender.com/sitemap.html)
- [MASK EVOLUTION 3D](https://learnaction.github.io/mask-evolution-3d.html)
- [THRONE VS BALLOONS](https://welearnaction.onrender.com/throne-vs-balloons.html)
- [CATEGORY HORROR](https://eduquests.onrender.com/category-horror.html)
- [GLAMOUR BEACHLIFE](https://welearnaction.onrender.com/glamour-beachlife.html)
- [SUV TRAFFIC RACER](https://eduquests.netlify.app/suv-traffic-racer.html)
- [MONSTER SCHOOL VS SIREN HEAD](https://eduquests.github.io/monster-school-vs-siren-head.html)
- [FOOD TOWER DEFENSE](https://eduquests.github.io/food-tower-defense.html)
- [GRANNY RETURNS 3D EVIL DESTINY](https://welearnaction.onrender.com/granny-returns-3d-evil-destiny.html)
- [CATEGORY DRESS UP 2](https://eduquests.onrender.com/category-dress-up-2.html)
- [TERMS](https://cryptotify.github.io/terms.html)
- [NUMBER TRICKY PUZZLES](https://eduquests.onrender.com/number-tricky-puzzles.html)
- [PRIVACY](https://cryptotify.github.io/privacy.html)
- [FROG KNIGHT](https://eduquests.onrender.com/frog-knight.html)
- [CATEGORY CASUAL969](https://eduquests.onrender.com/category-casual969.html)
- [BUBBLE SHOOTER VALENTINE](https://eduquests.github.io/bubble-shooter-valentine.html)
- [ONLINE PORTAL](https://eduquests.onrender.com/)
- [CATEGORY ESCAPE](https://eduquests.github.io/category-escape.html)
- [ANTISTRESS RELAXATION BOX](https://welearnaction.onrender.com/antistress-relaxation-box.html)
- [COLOR CARGO PUZZLE RUSH](https://eduquests.onrender.com/color-cargo-puzzle-rush.html)
- [SITEMAP](https://quizverses.pages.dev/sitemap.html)
- [FAMILY SQUID CHALLENGE](https://learnaction.github.io/family-squid-challenge.html)
- [ITALIAN BRAINROT QUIZ](https://eduquests.github.io/italian-brainrot-quiz.html)
- [DOGGO DROP](https://welearnaction.onrender.com/doggo-drop.html)
- [TERMS](https://studyquesthub.web.app/terms.html)
- [BUILDING MODS FOR MINECRAFT](https://eduquests.netlify.app/building-mods-for-minecraft.html)
- [JET FIGHTER AIRPLANE RACING](https://eduquests.onrender.com/jet-fighter-airplane-racing.html)
- [ROOFTOP CHALLENGE](https://eduquests.github.io/rooftop-challenge.html)
- [PRIVACY](https://studyquests.pages.dev/privacy.html)
- [UFO ATTACK](https://welearnaction.onrender.com/ufo-attack.html)
- [FOAM AND FIND](https://eduquests.onrender.com/foam-and-find.html)
- [TANGRAM PUZZLE](https://eduquests.onrender.com/tangram-puzzle.html)
- [CATEGORY MINECRAFT81](https://eduquests.github.io/category-minecraft81.html)
- [ONLINE PORTAL](https://quizverses-9d2f2.web.app/)
- [PIXEL FUN COLOR BY NUMBER](https://eduquests.github.io/pixel-fun-color-by-number.html)
- [OHPEACH IT](https://eduquests.netlify.app/ohpeach-it.html)
- [MR THROW](https://eduquests.github.io/mr-throw.html)
- [TIMBERLAND ARRANGE PUZZLE GAME](https://eduquests.github.io/timberland-arrange-puzzle-game.html)
- [PRIVACY](https://cryptotify9.onrender.com/privacy.html)
- [ZEN TILE](https://eduquests.onrender.com/zen-tile.html)
- [CATEGORY BLOCK91](https://learnaction.netlify.app/category-block91.html)
- [ITALIAN BRAINROT BOMB 2PLAYER](https://eduquests.github.io/italian-brainrot-bomb-2player.html)
- [DONUT RUN](https://eduquests.netlify.app/donut-run.html)
- [CATEGORY MOBILE2 095](https://eduquests.github.io/category-mobile2-095.html)
- [CATEGORY CASUAL 5](https://learnaction.netlify.app/category-casual-5.html)
- [RUN FROM BABA YAGA](https://eduquests.netlify.app/run-from-baba-yaga.html)
- [LAMPHEAD](https://eduquests.netlify.app/lamphead.html)
- [BUBBLE IT JAM](https://welearnaction.onrender.com/bubble-it-jam.html)
- [ITALIAN BRAINROT SURVIVE PARKOUR](https://eduquests.github.io/italian-brainrot-survive-parkour.html)
- [CATEGORY CUTE](https://eduquests.onrender.com/category-cute.html)
- [CATEGORY MOUSE1 697](https://eduquests.github.io/category-mouse1-697.html)
- [HOME DESIGN SMALL HOUSE](https://welearnaction.onrender.com/home-design-small-house.html)
- [SWEET AND FRUITY MAKEUP](https://learnaction.github.io/sweet-and-fruity-makeup.html)
- [ULTIMATE FLYING CAR 2](https://eduquests.github.io/ultimate-flying-car-2.html)
- [CATEGORY TOWER DEFENSE](https://eduquests.github.io/category-tower-defense.html)
- [CATEGORY CONTROLLER](https://eduquests.onrender.com/category-controller.html)
- [TRUCK SIMULATOR ARCADE CHAMPIONSHIP](https://ieduquests.web.app/truck-simulator-arcade-championship.html)
- [TERMS](https://skillplay.github.io/terms.html)
- [HYPER NURSE HOSPITAL GAMES](https://eduquests.onrender.com/hyper-nurse-hospital-games.html)
- [DAYCARE TYCOON](https://ieduquests.web.app/daycare-tycoon.html)
- [3D BLOCK GLADIATOR SWORD DRAW](https://eduquests.netlify.app/3d-block-gladiator-sword-draw.html)
- [STICK NINJA SURVIVAL](https://eduquests.onrender.com/stick-ninja-survival.html)
- [CATEGORY BLOCK94](https://eduquests.netlify.app/category-block94.html)
- [CATEGORY FOOTBALL](https://eduquests.onrender.com/category-football.html)
- [INDEX12](https://learnaction.netlify.app/index12.html)
- [YOUTUBER MCRAFT 2PLAYER](https://learnaction.github.io/youtuber-mcraft-2player.html)
- [DUCKLINGS](https://eduquests.onrender.com/ducklings.html)
- [FASHION PRINCESS DRESS UP FOR GIRLS](https://welearnaction.onrender.com/fashion-princess-dress-up-for-girls.html)
- [PRIVACY](https://themindplay.pages.dev/privacy.html)
- [THROUGH THE WALL 3D](https://eduquests.github.io/through-the-wall-3d.html)
- [BUBBLE SHOOTER REMASTERED](https://eduquests.netlify.app/bubble-shooter-remastered.html)
- [HIDE BALL](https://eduquests.github.io/hide-ball.html)
- [CATEGORY CARE](https://learnaction.netlify.app/category-care.html)
- [MAGIC SORT](https://learnaction.netlify.app/magic-sort.html)
