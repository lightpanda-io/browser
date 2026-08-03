import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

let autoLoadFrames = true;
let supportCredentialless = true;

class FakeElement extends EventTarget {
  attributes = new Map();
  style = {};

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
    return this.parent?.closest(selector) ?? null;
  }
}

class FakeDocument {
  listeners = new Map();

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
      return new Response('<a href="/next" data-lp-live-target="0">Next</a>', {
        headers: {
          "x-lightpanda-live-session": "0123456789abcdef0123456789abcdef",
          "x-lightpanda-live-version": "1",
        },
      });
    }
    if (request.op === "activate") {
      return new Response('<button data-lp-live-target="0">Updated</button>', {
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
