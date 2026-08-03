import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

let autoLoadFrames = true;
let supportCredentialless = true;

class FakeElement extends EventTarget {
  attributes = new Map();
  style = {};
  value = "";

  setAttribute(name, value) {
    this.attributes.set(name, value);
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }

  replaceChildren(child) {
    this.child = child;
  }

  getBoundingClientRect() {
    return { width: 640, height: 480 };
  }

  closest(selector) {
    if (selector === "[data-lp-live-target]" && this.getAttribute("data-lp-live-target") !== null) {
      return this;
    }
    if (
      selector === '[data-lp-live-kind="value"]'
      && this.getAttribute("data-lp-live-kind") === "value"
    ) {
      return this;
    }
    return this.parent?.closest(selector) ?? null;
  }
}

class FakeDocument {
  listeners = new Map();
  documentElement = new FakeElement();

  addEventListener(type, listener) {
    this.listeners.set(type, listener);
  }

  dispatchClick(target, init = {}) {
    const event = {
      target,
      ...init,
      prevented: false,
      stopped: false,
      preventDefault() {
        this.prevented = true;
      },
      stopPropagation() {
        this.stopped = true;
      },
    };
    this.listeners.get("click")?.(event);
    return event;
  }

  dispatchChange(target) {
    this.listeners.get("change")?.({ target });
  }

  dispatchInput(target) {
    this.listeners.get("input")?.({ target });
  }
}

class FakeFrame extends FakeElement {
  credentialless = false;
  contentDocument = new FakeDocument();

  constructor() {
    super();
    if (!supportCredentialless) delete this.credentialless;
  }

  set srcdoc(value) {
    this.snapshot = value;
    this.contentDocument = new FakeDocument();
    if (autoLoadFrames) queueMicrotask(() => this.dispatchEvent(new Event("load")));
  }

  remove() {
    this.removed = true;
  }
}

globalThis.Element = FakeElement;
globalThis.document = {
  baseURI: "https://preview.example/",
  querySelector() {
    return null;
  },
  createElement(name) {
    assert.equal(name, "iframe");
    return new FakeFrame();
  },
};

let fetchImpl;
globalThis.fetch = (...args) => fetchImpl(...args);

async function waitUntil(predicate) {
  for (let attempt = 0; attempt < 20; ++attempt) {
    if (predicate()) return;
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.fail("condition did not become ready");
}

function streamingResponse(parts, headers = {}, { mutateFirstBeforeSecond = false } = {}) {
  const encoder = new TextEncoder();
  const chunks = parts.map((part) => encoder.encode(part));
  let index = 0;
  let cancelled = false;
  return {
    ok: true,
    status: 200,
    headers: new Headers(headers),
    body: {
      getReader() {
        return {
          async read() {
            if (index === chunks.length) return { done: true };
            const value = chunks[index++];
            if (mutateFirstBeforeSecond && index === 2) {
              chunks[0][0] = "X".charCodeAt(0);
            }
            return { done: false, value };
          },
          async cancel() {
            cancelled = true;
          },
        };
      },
    },
    get cancelled() {
      return cancelled;
    },
  };
}

const source = (await readFile(new URL("./client.js", import.meta.url), "utf8")).replace(
  /^const DEFAULT_ENDPOINT = .*;$/m,
  'const DEFAULT_ENDPOINT = "https://renderer.example/v1/render";',
);
const { attachLightpandaRenderer } = await import(
  `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`,
);

{
  autoLoadFrames = false;
  let sent;
  fetchImpl = async (endpoint, options) => {
    sent = { endpoint, options };
    return new Response(
      '<!doctype html><base href="https://source.example/"><h1>Rendered</h1>',
      { headers: { "content-type": "text/html" } },
    );
  };

  const target = new FakeElement();
  const renderer = attachLightpandaRenderer(target, { token: "test-token" });
  const pending = renderer.render("https://source.example/page");
  await waitUntil(() => renderer.iframe.snapshot);
  renderer.iframe.dispatchEvent(new Event("load"));
  const frame = await pending;

  assert.equal(target.child, frame);
  assert.equal(frame.getAttribute("sandbox"), "allow-forms");
  assert.equal(frame.getAttribute("sandbox").includes("allow-scripts"), false);
  assert.equal(frame.getAttribute("sandbox").includes("allow-same-origin"), false);
  assert.equal(frame.credentialless, true);
  assert.match(frame.snapshot, /<h1>Rendered<\/h1>/);
  assert.equal(sent.endpoint, "https://renderer.example/v1/render");
  assert.equal(sent.options.headers.authorization, "Bearer test-token");
  assert.deepEqual(JSON.parse(sent.options.body), {
    url: "https://source.example/page",
    width: 640,
    height: 480,
  });
}

{
  autoLoadFrames = true;
  const responses = [];
  fetchImpl = () => new Promise((resolve) => responses.push(resolve));
  const renderer = attachLightpandaRenderer(new FakeElement());

  const first = renderer.render("https://source.example/first");
  const firstRejected = assert.rejects(first, { name: "AbortError" });
  const second = renderer.render("https://source.example/second");
  await waitUntil(() => responses.length === 1);
  responses[0](new Response("<h1>Second</h1>"));
  await second;
  await firstRejected;
  assert.match(renderer.iframe.snapshot, /Second/);
}

{
  autoLoadFrames = false;
  fetchImpl = async () => new Response("<h1>Waiting</h1>");
  const renderer = attachLightpandaRenderer(new FakeElement());
  const pending = renderer.render("https://source.example/destroy");
  const rejected = assert.rejects(pending, { name: "AbortError" });
  await waitUntil(() => renderer.iframe.snapshot);
  renderer.destroy();
  await rejected;
  assert.equal(renderer.iframe.removed, true);
}

{
  autoLoadFrames = true;
  fetchImpl = async () => new Response("upstream failed", { status: 502 });
  const renderer = attachLightpandaRenderer(new FakeElement());
  await assert.rejects(
    renderer.render("https://source.example/fail"),
    /Lightpanda render failed \(502\): upstream failed/,
  );
}

{
  fetchImpl = async () => new Response("12345");
  const renderer = attachLightpandaRenderer(new FakeElement(), { maxResponseBytes: 4 });
  await assert.rejects(
    renderer.render("https://source.example/large"),
    /Lightpanda response exceeds 4 bytes/,
  );
}

{
  const response = streamingResponse(
    ["abc", "def"],
    { "content-length": "6" },
    { mutateFirstBeforeSecond: true },
  );
  fetchImpl = async () => response;
  const renderer = attachLightpandaRenderer(new FakeElement());
  await renderer.render("https://source.example/preallocated");
  assert.equal(renderer.iframe.snapshot, "abcdef");
}

{
  const cases = [
    [streamingResponse(["short"], { "content-length": "8" }), "short"],
    [streamingResponse(["abc", "def"], { "content-length": "3" }), "abcdef"],
    [streamingResponse(["abc", "def"], { "content-length": "invalid" }), "abcdef"],
    [
      streamingResponse(["abc", "def"], {
        "content-length": "3",
        "content-encoding": "gzip",
      }),
      "abcdef",
    ],
  ];
  for (const [response, expected] of cases) {
    fetchImpl = async () => response;
    const renderer = attachLightpandaRenderer(new FakeElement());
    await renderer.render("https://source.example/fallback");
    assert.equal(renderer.iframe.snapshot, expected);
  }
}

{
  const response = streamingResponse(["123", "45"]);
  fetchImpl = async () => response;
  const renderer = attachLightpandaRenderer(new FakeElement(), { maxResponseBytes: 4 });
  await assert.rejects(
    renderer.render("https://source.example/streaming-large"),
    /Lightpanda response exceeds 4 bytes/,
  );
  assert.equal(response.cancelled, true);
}

{
  supportCredentialless = false;
  let requested = false;
  fetchImpl = async () => {
    requested = true;
    return new Response();
  };
  const renderer = attachLightpandaRenderer(new FakeElement());
  await assert.rejects(
    renderer.open("https://source.example/live"),
    /Live rendering requires credentialless iframe support/,
  );
  assert.equal(requested, false);
  supportCredentialless = true;
}

{
  autoLoadFrames = true;
  let phase = "render";
  fetchImpl = async () => {
    if (phase === "render") return new Response("<h1>One shot</h1>");
    return new Response("open failed", { status: 502 });
  };
  const renderer = attachLightpandaRenderer(new FakeElement());
  await renderer.render("https://source.example/static");
  assert.equal(renderer.iframe.getAttribute("sandbox"), "allow-forms");
  phase = "open";
  await assert.rejects(
    renderer.open("https://source.example/live"),
    /Lightpanda live render failed \(502\): open failed/,
  );
  assert.equal(renderer.iframe.getAttribute("sandbox"), "allow-forms");
}

{
  autoLoadFrames = false;
  const operations = [];
  let finishClose;
  fetchImpl = async (_endpoint, options) => {
    const request = JSON.parse(options.body);
    operations.push(request.op ?? "render");
    if (request.op === "open") {
      return new Response('<a href="/next" data-lp-live-target="0">Next</a>', {
        headers: {
          "x-lightpanda-live-session": "fedcba9876543210fedcba9876543210",
          "x-lightpanda-live-version": "1",
        },
      });
    }
    if (request.op === "close") {
      return new Promise((resolve) => {
        finishClose = () => resolve(new Response(null, { status: 204 }));
      });
    }
    return new Response("<h1>Replacement</h1>");
  };

  const renderer = attachLightpandaRenderer(new FakeElement());
  const opened = renderer.open("https://source.example/live");
  const openRejected = assert.rejects(opened, { name: "AbortError" });
  await waitUntil(() => renderer.iframe.snapshot);

  const replacement = renderer.render("https://source.example/replacement");
  await waitUntil(() => finishClose);
  assert.deepEqual(operations, ["open", "close"]);

  autoLoadFrames = true;
  finishClose();
  await replacement;
  await openRejected;
  assert.deepEqual(operations, ["open", "close", "render"]);
  assert.match(renderer.iframe.snapshot, /Replacement/);
}

{
  autoLoadFrames = true;
  const requests = [];
  fetchImpl = async (endpoint, options) => {
    const request = JSON.parse(options.body);
    requests.push({ endpoint, request, authorization: options.headers.authorization });
    if (request.op === "open") {
      return new Response('<a href="/next" data-lp-live-target="0" data-lp-live-kind="activate">Next</a>', {
        headers: {
          "x-lightpanda-live-session": "0123456789abcdef0123456789abcdef",
          "x-lightpanda-live-version": "1",
        },
      });
    }
    if (request.op === "activate") {
      return new Response('<button data-lp-live-target="0" data-lp-live-kind="activate">Updated</button>', {
        headers: {
          "x-lightpanda-live-session": "0123456789abcdef0123456789abcdef",
          "x-lightpanda-live-version": "2",
        },
      });
    }
    assert.equal(request.op, "close");
    return new Response(null, { status: 204 });
  };

  const renderer = attachLightpandaRenderer(new FakeElement(), {
    endpoint: "https://custom-renderer.example/api/render",
    token: "live-token",
  });
  await renderer.open("https://source.example/live");
  assert.equal(renderer.iframe.getAttribute("sandbox"), "allow-same-origin");
  assert.equal(renderer.iframe.getAttribute("sandbox").includes("allow-scripts"), false);
  assert.equal(renderer.iframe.getAttribute("sandbox").includes("allow-forms"), false);
  assert.equal(renderer.iframe.credentialless, true);
  assert.equal(requests.length, 1);
  assert.deepEqual(requests[0], {
    endpoint: "https://custom-renderer.example/v1/live",
    request: {
      op: "open",
      url: "https://source.example/live",
      width: 640,
      height: 480,
    },
    authorization: "Bearer live-token",
  });

  const target = new FakeElement();
  target.setAttribute("data-lp-live-target", "0");
  target.setAttribute("data-lp-live-kind", "activate");
  const modified = renderer.iframe.contentDocument.dispatchClick(target, { ctrlKey: true });
  assert.equal(modified.prevented, false);
  assert.equal(modified.stopped, false);
  assert.equal(requests.length, 1);
  const auxiliary = renderer.iframe.contentDocument.dispatchClick(target, { button: 1 });
  assert.equal(auxiliary.prevented, false);
  assert.equal(auxiliary.stopped, false);
  assert.equal(requests.length, 1);

  const firstClick = renderer.iframe.contentDocument.dispatchClick(target);
  const secondClick = renderer.iframe.contentDocument.dispatchClick(target);
  assert.equal(firstClick.prevented, true);
  assert.equal(secondClick.prevented, true);
  assert.equal(firstClick.stopped, true);
  assert.equal(secondClick.stopped, true);
  assert.equal(requests.length, 2);
  await waitUntil(() => requests.length === 2);
  await waitUntil(() => /Updated/.test(renderer.iframe.snapshot));
  assert.deepEqual(requests[1].request, {
    op: "activate",
    session: "0123456789abcdef0123456789abcdef",
    version: 1,
    target: 0,
  });
  renderer.destroy();
  await waitUntil(() => requests.length === 3);
  assert.deepEqual(requests[2].request, {
    op: "close",
    session: "0123456789abcdef0123456789abcdef",
  });
}

{
  autoLoadFrames = true;
  const requests = [];
  let finishSetValue;
  fetchImpl = async (_endpoint, options) => {
    const request = JSON.parse(options.body);
    requests.push(request);
    if (request.op === "open") {
      return new Response(
        '<select data-lp-live-target="4" data-lp-live-kind="value"><option>before</option></select>',
        {
          headers: {
            "x-lightpanda-live-session": "11223344556677889900aabbccddeeff",
            "x-lightpanda-live-version": "1",
          },
        },
      );
    }
    if (request.op === "set_value") {
      return new Promise((resolve) => {
        finishSetValue = () => resolve(new Response(
          '<select data-lp-live-target="4" data-lp-live-kind="value"><option>after</option></select>',
          {
            headers: {
              "x-lightpanda-live-session": "11223344556677889900aabbccddeeff",
              "x-lightpanda-live-version": "2",
            },
          },
        ));
      });
    }
    assert.equal(request.op, "close");
    return new Response(null, { status: 204 });
  };

  const renderer = attachLightpandaRenderer(new FakeElement());
  await renderer.open("https://source.example/live-values", { waitMs: 1234 });
  const snapshot = renderer.iframe.contentDocument;
  const target = new FakeElement();
  target.setAttribute("data-lp-live-target", "4");
  target.setAttribute("data-lp-live-kind", "value");
  target.value = "after";
  target.selectedIndex = 2;

  const click = snapshot.dispatchClick(target);
  assert.equal(click.prevented, false);
  assert.equal(click.stopped, false);
  const nestedTarget = new FakeElement();
  nestedTarget.parent = target;
  nestedTarget.setAttribute("data-lp-live-target", "7");
  nestedTarget.setAttribute("data-lp-live-kind", "activate");
  const nestedClick = snapshot.dispatchClick(nestedTarget);
  assert.equal(nestedClick.prevented, false);
  assert.equal(nestedClick.stopped, false);
  snapshot.dispatchInput(target);
  assert.equal(requests.length, 1);

  snapshot.dispatchChange(target);
  await waitUntil(() => finishSetValue);
  assert.equal(renderer.iframe.inert, true);
  assert.equal(snapshot.documentElement.inert, true);
  snapshot.dispatchChange(target);
  assert.equal(requests.length, 2);
  assert.deepEqual(requests[1], {
    op: "set_value",
    session: "11223344556677889900aabbccddeeff",
    version: 1,
    target: 4,
    value: "after",
    wait_ms: 1234,
    selected_index: 2,
  });

  finishSetValue();
  await waitUntil(() => />after</.test(renderer.iframe.snapshot));
  await waitUntil(() => renderer.iframe.inert === false);
  assert.equal(renderer.iframe.contentDocument.documentElement.inert, false);
  renderer.destroy();
  await waitUntil(() => requests.length === 3);
}

{
  autoLoadFrames = true;
  const operations = [];
  fetchImpl = async (_endpoint, options) => {
    const request = JSON.parse(options.body);
    operations.push(request.op);
    if (request.op === "open") {
      return new Response('<input data-lp-live-target="1" data-lp-live-kind="value">', {
        headers: {
          "x-lightpanda-live-session": "22334455667788990011aabbccddeeff",
          "x-lightpanda-live-version": "1",
        },
      });
    }
    if (request.op === "set_value") return new Response("failed", { status: 500 });
    assert.equal(request.op, "close");
    return new Response(null, { status: 204 });
  };

  const renderer = attachLightpandaRenderer(new FakeElement());
  await renderer.open("https://source.example/live-value-failure");
  const target = new FakeElement();
  target.setAttribute("data-lp-live-target", "1");
  target.setAttribute("data-lp-live-kind", "value");
  target.value = "failed";
  renderer.iframe.contentDocument.dispatchChange(target);
  await waitUntil(() => operations.includes("close"));
  await waitUntil(() => renderer.iframe.inert === false);
  assert.equal(renderer.iframe.contentDocument.documentElement.inert, false);
}

{
  autoLoadFrames = true;
  const operations = [];
  let closeAttempts = 0;
  fetchImpl = async (_endpoint, options) => {
    const request = JSON.parse(options.body);
    operations.push(request.op ?? "render");
    if (request.op === "open") {
      return new Response("<p>Live</p>", {
        headers: {
          "x-lightpanda-live-session": "00112233445566778899aabbccddeeff",
          "x-lightpanda-live-version": "1",
        },
      });
    }
    if (request.op === "close") {
      closeAttempts += 1;
      if (closeAttempts === 1) return new Response("busy", { status: 500 });
      return new Response(null, { status: 204 });
    }
    return new Response("<h1>Recovered</h1>");
  };

  const renderer = attachLightpandaRenderer(new FakeElement());
  await renderer.open("https://source.example/live");
  await assert.rejects(
    renderer.render("https://source.example/static"),
    /Lightpanda live close failed \(500\): busy/,
  );
  assert.deepEqual(operations, ["open", "close"]);

  await renderer.render("https://source.example/static");
  assert.deepEqual(operations, ["open", "close", "close", "render"]);
  assert.match(renderer.iframe.snapshot, /Recovered/);
}

{
  autoLoadFrames = true;
  const operations = [];
  let closeAttempts = 0;
  let timedOutSignal;
  fetchImpl = async (_endpoint, options) => {
    const request = JSON.parse(options.body);
    operations.push(request.op ?? "render");
    if (request.op === "open") {
      return new Response("<p>Live</p>", {
        headers: {
          "x-lightpanda-live-session": "ffeeddccbbaa99887766554433221100",
          "x-lightpanda-live-version": "1",
        },
      });
    }
    if (request.op === "close") {
      closeAttempts += 1;
      if (closeAttempts === 1) {
        timedOutSignal = options.signal;
        return new Promise((_resolve, reject) => {
          const aborted = () => reject(options.signal.reason);
          if (options.signal.aborted) aborted();
          else options.signal.addEventListener("abort", aborted, { once: true });
        });
      }
      return new Response(null, { status: 204 });
    }
    return new Response("<h1>Recovered after timeout</h1>");
  };

  const renderer = attachLightpandaRenderer(new FakeElement(), { closeTimeoutMs: 5 });
  await renderer.open("https://source.example/live");
  await assert.rejects(
    renderer.render("https://source.example/static"),
    { name: "TimeoutError" },
  );
  assert.equal(timedOutSignal.aborted, true);
  assert.deepEqual(operations, ["open", "close"]);

  await renderer.render("https://source.example/static");
  assert.deepEqual(operations, ["open", "close", "close", "render"]);
  assert.match(renderer.iframe.snapshot, /Recovered after timeout/);
}

assert.throws(
  () => attachLightpandaRenderer(new FakeElement(), { closeTimeoutMs: 0 }),
  /closeTimeoutMs must be a positive safe integer/,
);
