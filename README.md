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
**Install from the nightly builds**

You can download the last binary from the [nightly
builds](https://github.com/lightpanda-io/browser/releases/tag/nightly) for
Linux x86_64 and MacOS aarch64.

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

You can use `--dump markdown` to convert directly into markdown.
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

[Read full documentation](https://lightpanda.io/docs/open-source/guides/mcp-server)

A skill is available in [lightpanda-io/agent-skill](https://github.com/lightpanda-io/agent-skill).

### Telemetry
By default, Lightpanda collects and sends usage telemetry. This can be disabled by setting an environment variable `LIGHTPANDA_DISABLE_TELEMETRY=true`. You can read Lightpanda's privacy policy at: [https://lightpanda.io/privacy-policy](https://lightpanda.io/privacy-policy).

## Status

Lightpanda is in Beta and currently a work in progress. Stability and coverage are improving and many websites now work.
You may still encounter errors or crashes. Please open an issue with specifics if so.

Here are the key features we have implemented:

- [ ] CORS [#2015](https://github.com/lightpanda-io/browser/issues/2015)
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

You an build the entire browser with `make build` or `make build-dev` for debug
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
[`testharnessreport.js`](https://github.com/lightpanda-io/wpt/commit/01a3115c076a3ad0c84849dbbf77a6e3d199c56f).

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

Then you can start the wptrunner from the Demo's clone dir:
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
