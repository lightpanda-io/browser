import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

let autoLoadFrames = true;

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
}

class FakeFrame extends FakeElement {
  set srcdoc(value) {
    this.snapshot = value;
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
  responses[1](new Response("<h1>Second</h1>"));
  await second;
  responses[0](new Response("<h1>First</h1>"));
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
