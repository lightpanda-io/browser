<p align="center">
  <a href="https://lightpanda.io"><img src="https://cdn.lightpanda.io/assets/images/logo/lpd-logo.png" alt="Logo" height=170></a>
</p>
<h1 align="center">Lightpanda 浏览器</h1>
<p align="center">
<strong>专为 AI Agent 和自动化打造的从零构建的无头浏览器。</strong><br>
不是 Chromium 的 fork，也不是 WebKit 的补丁。这是一个用 Zig 编写的全新浏览器。
</p>

</div>
<div align="center">

[![许可证](https://img.shields.io/github/license/lightpanda-io/browser)](https://github.com/lightpanda-io/browser/blob/main/LICENSE)
[![Twitter 关注](https://img.shields.io/twitter/follow/lightpanda_io)](https://twitter.com/lightpanda_io)
[![GitHub stars](https://img.shields.io/github/stars/lightpanda-io/browser)](https://github.com/lightpanda-io/browser)
[![Discord](https://img.shields.io/discord/1391984864894521354?style=flat-square&label=discord)](https://discord.gg/K63XeymfB5)

</div>
<div align="center">

[<img width="350px" src="https://cdn.lightpanda.io/assets/images/github/execution-time.svg">
](https://github.com/lightpanda-io/demo)
&emsp;
[<img width="350px" src="https://cdn.lightpanda.io/assets/images/github/memory-frame.svg">
](https://github.com/lightpanda-io/demo)
</div>

*在 AWS EC2 m5.large 实例上，使用 Puppeteer 向本地网站请求 100 个页面的测试结果。
详见 [基准测试详情](https://github.com/lightpanda-io/demo)。*

Lightpanda 是一款专为无头（headless）使用场景打造的开源浏览器：

- 支持 Javascript 执行
- 支持 Web API（部分支持，开发中）
- 通过 [CDP](https://chromedevtools.github.io/devtools-protocol/) 兼容 Playwright[^1]、Puppeteer 和 chromedp

为 AI Agent、LLM 训练、爬虫抓取和自动化测试提供飞快的体验：

- **极低内存占用**（比 Chrome 少 9 倍）
- **极速执行响应**（比 Chrome 快 11 倍）
- **瞬间启动**

[^1]: **Playwright 支持声明：**
由于 Playwright 的特性，能在当前浏览器版本运行的脚本可能无法在未来版本中正常工作。Playwright 使用中间 JavaScript 层，根据浏览器的可用功能选择执行策略。如果 Lightpanda 添加了新的 [Web API](https://developer.mozilla.org/en-US/docs/Web/API)，Playwright 可能会为同一脚本选择不同的执行路径，而这些新路径可能会尝试使用尚未实现的功能。Lightpanda 努力添加兼容性测试，但无法涵盖所有场景。如果您遇到问题，请提交 [GitHub issue](https://github.com/lightpanda-io/browser/issues) 并附上该脚本最后已知的可用版本。

## 快速开始

### 安装
**安装每夜构建版 (Nightly builds)**

你可以从 [nightly builds](https://github.com/lightpanda-io/browser/releases/tag/nightly) 下载适用于 Linux x86_64 和 MacOS aarch64 的最新二进制文件。

*Linux 用户*
```console
curl -L -o lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-x86_64-linux && \
chmod a+x ./lightpanda
```

*MacOS 用户*
```console
curl -L -o lightpanda https://github.com/lightpanda-io/browser/releases/download/nightly/lightpanda-aarch64-macos && \
chmod a+x ./lightpanda
```

*Windows + WSL2 用户*

Lightpanda 浏览器兼容在 Windows 的 WSL 内部运行。请参照 Linux 指南在 WSL 终端进行安装。建议在 Windows 宿主机上安装 Puppeteer 等客户端。

**通过 Docker 安装**

Lightpanda 提供针对 Linux amd64 和 arm64 架构的 [官方 Docker 镜像](https://hub.docker.com/r/lightpanda/browser)。
以下命令将拉取镜像并启动容器，在 `9222` 端口暴露 Lightpanda 的 CDP 服务：
```console
docker run -d --name lightpanda -p 9222:9222 lightpanda/browser:nightly
```

### 抓取 URL 内容 (Dump)

```console
./lightpanda fetch --obey_robots --log_format pretty  --log_level info https://demo-browser.lightpanda.io/campfire-commerce/
```

### 启动 CDP 服务器

```console
./lightpanda serve --obey_robots --log_format pretty  --log_level info --host 127.0.0.1 --port 9222
```

CDP 服务器启动后，你可以通过配置 `browserWSEndpoint` 来运行 Puppeteer 脚本。

```js
'use strict'

import puppeteer from 'puppeteer-core';

// 使用 browserWSEndpoint 传入 Lightpanda 的 CDP 服务器地址
const browser = await puppeteer.connect({
  browserWSEndpoint: "ws://127.0.0.1:9222",
});

// 脚本的其余部分保持不变
const context = await browser.createBrowserContext();
const page = await context.newPage();

await page.goto('https://demo-browser.lightpanda.io/amiibo/', {waitUntil: "networkidle0"});

const links = await page.evaluate(() => {
  return Array.from(document.querySelectorAll('a')).map(row => {
    return row.getAttribute('href');
  });
});

console.log(links);

await page.close();
await context.close();
await browser.disconnect();
```

### 遥测 (Telemetry)
默认情况下，Lightpanda 会收集并发送使用情况遥测数据。可以通过设置环境变量 `LIGHTPANDA_DISABLE_TELEMETRY=true` 来禁用。你可以在此处阅读隐私政策：[https://lightpanda.io/privacy-policy](https://lightpanda.io/privacy-policy)。

## 项目状态

Lightpanda 目前处于 Beta 阶段，正在积极开发中。稳定性和功能覆盖范围正在不断提高，许多网站已经可以正常工作。你仍可能会遇到错误或崩溃，如果遇到，请提交包含具体细节的 issue。

以下是已实现的关键特性：

- [x] HTTP 加载器 ([Libcurl](https://curl.se/libcurl/))
- [x] HTML 解析器 ([html5ever](https://github.com/servo/html5ever))
- [x] DOM 树
- [x] Javascript 支持 ([v8](https://v8.dev/))
- [x] DOM APIs
- [x] Ajax (XHR & Fetch)
- [x] DOM 导出 (Dump)
- [x] CDP/Websockets 服务器
- [x] 点击 (Click)
- [x] 表单输入 (Input form)
- [x] Cookies
- [x] 自定义 HTTP 请求头
- [x] 代理支持 (Proxy)
- [x] 网络拦截 (Network interception)
- [x] 通过 `--obey_robots` 选项支持 `robots.txt`

注意：Web API 数量繁多。开发一款浏览器（即使仅用于无头模式）是一项巨大的工程，功能覆盖范围会随着时间推移而增加。

## 从源码构建

### 前置条件

Lightpanda 使用 [Zig](https://ziglang.org/) `0.15.2` 编写。你必须安装正确版本的 Zig 才能构建项目。此外，还需要安装 Rust（用于构建 html5ever）以及 cmake。

### 构建与运行

你可以使用 `make build` 构建完整浏览器，或使用 `make build-dev` 进行调试。也可以直接运行 `zig build run`。

## 贡献

Lightpanda 通过 GitHub 接受 Pull Request。在 PR 过程中你需要签署我们的 [CLA](CLA.md)，否则我们将无法接受你的贡献。

## 为什么发起这个项目？

### 现代网页必须执行 Javascript
在过去，抓取网页就像发起一个类似 cURL 的 HTTP 请求一样简单。但现在已经行不通了，因为 Javascript 无处不在：Ajax、单页应用 (SPA)、无限滚动、React/Vue 等框架。

### Chrome 并不是合适的工具
如果需要 Javascript，为什么不直接用真正的浏览器？把一个庞大的桌面应用黑掉并运行在服务器上，在大规模使用时运行成千上万个 Chrome 实例，这真的好吗？
- 极度消耗内存和 CPU，运行成本高昂
- 大规模打包、部署和维护困难
- 臃肿，许多特性在无头模式下毫无用处

### Lightpanda 专为性能而生
如果我们想要在真正的无头浏览器中兼顾 Javascript 支持和高性能，就必须从零开始。不是另一个 Chromium 的变体，而是真正的从零开始。这听起来很疯狂，但这就是我们所做的：
- **不基于** Chromium, Blink 或 WebKit
- 使用注重优化的底层系统编程语言 (**Zig**)
- 极简主义：不包含图形渲染功能
