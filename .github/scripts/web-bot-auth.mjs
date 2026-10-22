// Run with Node.js 22 or later: node .github/scripts/web-bot-auth.mjs ./lightpanda
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createPrivateKey, createPublicKey, verify } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

// Published test key from RFC 8037 Appendix A.1. Never use it in production.
// https://www.rfc-editor.org/rfc/rfc8037.html#appendix-A.1
const privateKey = createPrivateKey({
  format: "jwk",
  key: {
    kty: "OKP",
    crv: "Ed25519",
    d: "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A",
    x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
  },
});
const publicKey = createPublicKey(privateKey);
const keyid = "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k";
const agent = '"https://wba.example"';

function header(request, name) {
  // req.headers combines duplicate lines. Keep rawHeaders to detect duplicates.
  const values = [];
  for (let i = 0; i < request.rawHeaders.length; i += 2) {
    if (request.rawHeaders[i].toLowerCase() === name) {
      values.push(request.rawHeaders[i + 1]);
    }
  }
  assert.equal(values.length, 1, `${request.url}: expected one ${name} header`);
  return values[0];
}

function verifyRequests(requests, port) {
  const nonces = new Set();
  const signatures = new Set();
  for (const request of requests) {
    const host = header(request, "host");
    const signatureAgent = header(request, "signature-agent");
    const signatureInput = header(request, "signature-input");
    const signature = header(request, "signature");
    assert.equal(signatureAgent, agent, `${request.url}: Signature-Agent origin`);

    const input = /^sig1=(\("@authority" "signature-agent"\);created=(\d+);expires=(\d+);keyid="([^"]+)";alg="ed25519";nonce="([A-Za-z0-9+/]{86}==)";tag="web-bot-auth")$/.exec(signatureInput);
    assert.ok(input, `${request.url}: Signature-Input format`);
    const [, parameters, created, expires, receivedKeyid, nonce] = input;
    assert.equal(receivedKeyid, keyid);
    assert.ok(Number(created) <= request.receivedAt);
    assert.ok(Number(expires) >= request.receivedAt);
    assert.equal(Number(expires) - Number(created), 60);

    const nonceBytes = Buffer.from(nonce, "base64");
    assert.equal(nonceBytes.length, 64);
    assert.equal(nonceBytes.toString("base64"), nonce, "canonical padded base64 nonce");
    assert.ok(!nonces.has(nonce), `${request.url}: nonce reused`);
    nonces.add(nonce);

    const signatureMatch = /^sig1=:([A-Za-z0-9+/]{86}==):$/.exec(signature);
    assert.ok(signatureMatch, `${request.url}: Signature format`);
    const signatureBytes = Buffer.from(signatureMatch[1], "base64");
    assert.equal(signatureBytes.length, 64);
    assert.equal(signatureBytes.toString("base64"), signatureMatch[1]);
    assert.ok(!signatures.has(signature), `${request.url}: signature reused`);
    signatures.add(signature);

    // RFC 9421 section 2.5: LF between lines, no final LF. Preserve the
    // received parameters verbatim, including nonce and parameter order.
    const base = `"@authority": ${host}\n"signature-agent": ${signatureAgent}\n"@signature-params": ${parameters}`;
    assert.ok(verify(null, Buffer.from(base), publicKey, signatureBytes), `${request.url}: invalid signature for ${host}`);
  }

  for (const path of ["/", "/subresource.js", "/redirect", "/redirect-target"]) {
    const matches = requests.filter((request) => request.url === path);
    assert.equal(matches.length, 1, `expected one request to ${path}`);
    assert.equal(matches[0].method, "GET");
    const hostname = path === "/redirect-target" ? "localhost" : "127.0.0.1";
    assert.equal(header(matches[0], "host"), `${hostname}:${port}`);
  }
}

async function listen(server) {
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return server.address().port;
}

async function connect(child, output) {
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    assert.equal(child.exitCode, null, `Lightpanda exited before CDP was ready:\n${output()}`);
    assert.equal(child.signalCode, null, `Lightpanda was killed before CDP was ready:\n${output()}`);
    // --port 0 lets Lightpanda bind its own ephemeral port without a
    // reserve-close-bind race. Read the bound address from its startup log.
    const address = /\$msg="server running" address=127\.0\.0\.1:(\d+)\s/.exec(output());
    if (!address) {
      await delay(50);
      continue;
    }
    const port = Number(address[1]);
    let socket;
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`, {
        signal: AbortSignal.timeout(500),
      });
      if (response.ok) {
        const { webSocketDebuggerUrl } = await response.json();
        socket = new WebSocket(webSocketDebuggerUrl);
        await once(socket, "open", { signal: AbortSignal.timeout(1_000) });
        return socket;
      }
    } catch {
      // The server may still be starting.
      socket?.close();
    }
    await delay(50);
  }
  throw new Error(`Timed out waiting for CDP:\n${output()}`);
}

function cdp(socket) {
  let id = 0;
  const pending = new Map();
  socket.addEventListener("message", ({ data }) => {
    const message = JSON.parse(data);
    const command = pending.get(message.id);
    if (!command) return;
    pending.delete(message.id);
    clearTimeout(command.timeout);
    if (message.error) command.reject(new Error(JSON.stringify(message.error)));
    else command.resolve(message.result);
  });
  socket.addEventListener("close", () => {
    for (const command of pending.values()) {
      clearTimeout(command.timeout);
      command.reject(new Error("CDP connection closed"));
    }
    pending.clear();
  });
  return (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const commandId = ++id;
    const timeout = setTimeout(() => {
      pending.delete(commandId);
      reject(new Error(`CDP command timed out: ${method}`));
    }, 20_000);
    pending.set(commandId, { resolve, reject, timeout });
    socket.send(JSON.stringify({ id: commandId, method, params, sessionId }));
  });
}

const directory = await mkdtemp(join(tmpdir(), "lightpanda-wba-"));
const requests = [];
let child;
let socket;
let output = "";
const server = createServer((request, response) => {
  requests.push({
    method: request.method,
    url: request.url,
    rawHeaders: request.rawHeaders,
    receivedAt: Math.floor(Date.now() / 1000),
  });
  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Cache-Control", "no-store");
  switch (request.url) {
    case "/":
      response.setHeader("Content-Type", "text/html");
      response.end('<!doctype html><script src="/subresource.js"></script>');
      break;
    case "/subresource.js":
      response.setHeader("Content-Type", "text/javascript");
      response.end(`
        window.wbaSubresource = true;
        fetch("/redirect")
          .then(response => {
            if (!response.ok) throw new Error("fetch status " + response.status);
            return response.text();
          })
          .then(text => { window.wbaResult = text; })
          .catch(error => { window.wbaError = String(error); });
      `);
      break;
    case "/redirect":
      response.writeHead(302, { Location: `http://localhost:${server.address().port}/redirect-target` });
      response.end();
      break;
    case "/redirect-target":
      response.setHeader("Content-Type", "text/plain");
      response.end("redirect complete");
      break;
    default:
      response.writeHead(404);
      response.end();
  }
});

try {
  const port = await listen(server);
  const keyFile = join(directory, "rfc8037-test-key.pem");
  await writeFile(keyFile, privateKey.export({ format: "pem", type: "pkcs8" }));
  child = spawn(resolve(process.argv[2] ?? "zig-out/bin/lightpanda"), [
    "serve", "--host", "127.0.0.1", "--port", "0", "--log-format", "logfmt",
    "--web-bot-auth-key-file", keyFile,
    "--web-bot-auth-keyid", keyid,
    "--web-bot-auth-domain", "wba.example",
  ], {
    env: { ...process.env, LIGHTPANDA_DISABLE_TELEMETRY: "true", NO_PROXY: "127.0.0.1,localhost", no_proxy: "127.0.0.1,localhost" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (data) => { output += data; });
  child.stderr.on("data", (data) => { output += data; });
  await once(child, "spawn");
  socket = await connect(child, () => output);
  const send = cdp(socket);
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Page.enable", {}, sessionId);
  const navigation = await send("Page.navigate", { url: `http://127.0.0.1:${port}/` }, sessionId);
  assert.ok(!navigation.errorText, navigation.errorText);

  const deadline = Date.now() + 20_000;
  let completed = false;
  while (Date.now() < deadline) {
    const evaluation = await send("Runtime.evaluate", {
      expression: "({ subresource: window.wbaSubresource === true, result: window.wbaResult, error: window.wbaError })",
      returnByValue: true,
    }, sessionId);
    assert.ok(!evaluation.exceptionDetails, JSON.stringify(evaluation.exceptionDetails));
    const state = evaluation.result.value;
    assert.ok(!state.error, state.error);
    if (state.result !== undefined) {
      assert.equal(state.subresource, true, "script subresource must execute");
      assert.equal(state.result, "redirect complete", "fetch must read the redirect response");
      completed = true;
      break;
    }
    await delay(50);
  }
  assert.ok(completed, "timed out waiting for the script and redirected fetch");
  verifyRequests(requests, port);
  if (process.env.WBA_REQUEST_LOG) {
    await writeFile(process.env.WBA_REQUEST_LOG, JSON.stringify(requests, null, 2));
  }
  console.log(`Verified ${requests.length} signed requests, including the script and cross-host redirect.`);
} catch (error) {
  if (output) console.error(output);
  throw error;
} finally {
  socket?.close();
  if (child?.pid !== undefined && child.exitCode === null && child.signalCode === null) {
    const exited = once(child, "exit");
    child.kill("SIGTERM");
    const killTimeout = setTimeout(() => child.kill("SIGKILL"), 2_000);
    await exited;
    clearTimeout(killTimeout);
  }
  server.closeAllConnections();
  await new Promise((resolve) => server.close(resolve));
  await rm(directory, { recursive: true, force: true });
}
