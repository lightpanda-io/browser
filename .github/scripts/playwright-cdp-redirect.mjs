import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer as createHttpServer } from "node:http";
import { createServer as createTcpServer } from "node:net";
import { once } from "node:events";

import { chromium } from "playwright-core";

const binary = process.argv[2];
if (!binary) throw new Error("usage: node playwright-cdp-redirect.mjs <lightpanda-binary>");

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve(server.address().port);
    });
  });
}

async function reservePort() {
  const server = createTcpServer();
  const port = await listen(server);
  await new Promise((resolve) => server.close(resolve));
  return port;
}

function closeServer(server) {
  return new Promise((resolve) => server.close(resolve));
}

async function waitForLightpanda(child, port) {
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Lightpanda startup timeout")), 5_000);
    const onData = (chunk) => {
      const line = chunk.toString();
      if (!line.includes("server running") || !line.includes(`127.0.0.1:${port}`)) return;
      clearTimeout(timeout);
      child.off("error", onError);
      child.off("exit", onExit);
      resolve();
    };
    const onError = (error) => {
      clearTimeout(timeout);
      reject(error);
    };
    const onExit = (code) => {
      clearTimeout(timeout);
      reject(new Error(`Lightpanda exited during startup (${code})`));
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.once("error", onError);
    child.once("exit", onExit);
  });
}

const destinationRequests = [];
const destination = createHttpServer((request, response) => {
  destinationRequests.push(request.headers);
  response.end("ok");
});
const destinationPort = await listen(destination);
const destinationUrl = `http://127.0.0.1:${destinationPort}/destination`;

const initialRequests = [];
const initial = createHttpServer((request, response) => {
  initialRequests.push(request.headers);
  response.writeHead(302, { location: destinationUrl });
  response.end();
});
const initialPort = await listen(initial);
const initialUrl = `http://127.0.0.1:${initialPort}/start`;

const cdpPort = await reservePort();
const child = spawn(binary, [
  "serve",
  "--host",
  "127.0.0.1",
  "--port",
  String(cdpPort),
  "--log-level",
  "info",
], {
  env: { ...process.env, LIGHTPANDA_DISABLE_TELEMETRY: "true" },
});

let browser;
try {
  await waitForLightpanda(child, cdpPort);
  browser = await chromium.connectOverCDP(`ws://127.0.0.1:${cdpPort}`);
  const context = await browser.newContext();
  const page = await context.newPage();
  const session = await context.newCDPSession(page);
  const pausedUrls = [];
  const continuationErrors = [];

  session.on("Fetch.requestPaused", async (event) => {
    if (event.request.url !== initialUrl && event.request.url !== destinationUrl) return;
    pausedUrls.push(event.request.url);
    const params = { requestId: event.requestId };
    if (event.request.url === initialUrl) {
      params.headers = Object.entries({
        ...event.request.headers,
        "x-single-hop-probe": "initial",
      }).map(([name, value]) => ({ name, value: String(value) }));
    }
    try {
      await session.send("Fetch.continueRequest", params);
    } catch (error) {
      continuationErrors.push(error);
    }
  });

  await session.send("Fetch.enable", {
    patterns: [{ urlPattern: "*", requestStage: "Request" }],
  });
  const response = await page.goto(initialUrl, {
    waitUntil: "domcontentloaded",
    timeout: 6_000,
  });

  assert.equal(response.status(), 200);
  assert.deepEqual(pausedUrls, [initialUrl, destinationUrl]);
  assert.equal(continuationErrors.length, 0);
  assert.equal(initialRequests.length, 1);
  assert.equal(initialRequests[0]["x-single-hop-probe"], "initial");
  assert.equal(destinationRequests.length, 1);
  assert.equal(destinationRequests[0]["x-single-hop-probe"], undefined);

  console.log("Playwright auxiliary CDP redirect interception passed");
} finally {
  await browser?.close().catch(() => {});
  if (child.exitCode === null && child.signalCode === null) {
    child.kill("SIGTERM");
    await Promise.race([once(child, "exit"), new Promise((resolve) => setTimeout(resolve, 2_000))]);
  }
  await Promise.all([closeServer(initial), closeServer(destination)]);
}
