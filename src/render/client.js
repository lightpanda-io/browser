const DEFAULT_ENDPOINT = new URL("/v1/render", import.meta.url).href;
const DEFAULT_MAX_RESPONSE_BYTES = 16 * 1024 * 1024;

function resolveTarget(target) {
  if (typeof target === "string") target = document.querySelector(target);
  if (!(target instanceof Element)) throw new TypeError("Lightpanda renderer target not found");
  return target;
}

function aborted(signal) {
  return signal.reason ?? new DOMException("Lightpanda render superseded", "AbortError");
}

async function readResponseText(response, limit) {
  const contentLength = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(contentLength) && contentLength > limit) {
    throw new RangeError(`Lightpanda response exceeds ${limit} bytes`);
  }

  const reader = response.body?.getReader?.();
  if (!reader) {
    const text = await response.text();
    if (new TextEncoder().encode(text).byteLength > limit) {
      throw new RangeError(`Lightpanda response exceeds ${limit} bytes`);
    }
    return text;
  }

  const chunks = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > limit) {
      await reader.cancel().catch(() => {});
      throw new RangeError(`Lightpanda response exceeds ${limit} bytes`);
    }
    chunks.push(value);
  }

  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function waitForFrame(iframe, html, signal, isCurrent) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      iframe.removeEventListener("load", loaded);
      iframe.removeEventListener("error", failed);
      signal.removeEventListener("abort", cancelled);
    };
    const loaded = () => {
      cleanup();
      if (!isCurrent()) reject(aborted(signal));
      else resolve();
    };
    const failed = () => {
      cleanup();
      reject(new Error("Lightpanda iframe failed to load the snapshot"));
    };
    const cancelled = () => {
      cleanup();
      reject(aborted(signal));
    };

    if (signal.aborted) return cancelled();
    iframe.addEventListener("load", loaded, { once: true });
    iframe.addEventListener("error", failed, { once: true });
    signal.addEventListener("abort", cancelled, { once: true });
    iframe.srcdoc = html;
  });
}

export class LightpandaRenderer extends EventTarget {
  #target;
  #endpoint;
  #token;
  #maxResponseBytes;
  #controller = null;
  #sequence = 0;
  #lastRequest = null;

  constructor(target, options = {}) {
    super();
    this.#target = resolveTarget(target);
    this.#endpoint = new URL(options.endpoint ?? DEFAULT_ENDPOINT, document.baseURI).href;
    this.#token = options.token ?? null;
    this.#maxResponseBytes = options.maxResponseBytes ?? DEFAULT_MAX_RESPONSE_BYTES;
    if (!Number.isSafeInteger(this.#maxResponseBytes) || this.#maxResponseBytes < 1) {
      throw new RangeError("maxResponseBytes must be a positive safe integer");
    }

    const iframe = document.createElement("iframe");
    // Same-frame forms remain native. Top-level and new-window targets stay
    // blocked because the snapshot is not granted popup or top-navigation access.
    iframe.setAttribute("sandbox", "allow-forms");
    iframe.title = options.title ?? "Lightpanda rendered page";
    iframe.loading = "eager";
    iframe.referrerPolicy = "no-referrer";
    iframe.style.cssText = options.style ?? "display:block;width:100%;height:100%;border:0";
    if (options.className) iframe.className = options.className;
    const supportsCredentialless = "credentialless" in iframe;
    if (options.requireCredentialless && !supportsCredentialless) {
      throw new Error("This browser does not support credentialless iframes");
    }
    if (options.credentialless !== false && supportsCredentialless) iframe.credentialless = true;
    this.iframe = iframe;

    if (options.replace === false) this.#target.append(iframe);
    else this.#target.replaceChildren(iframe);
  }

  async render(url, options = {}) {
    const source = new URL(url, document.baseURI).href;
    const sequence = ++this.#sequence;
    this.#controller?.abort();
    const controller = new AbortController();
    this.#controller = controller;

    const bounds = this.#target.getBoundingClientRect();
    const request = {
      url: source,
      wait_ms: options.waitMs,
      wait_until: options.waitUntil,
      wait_selector: options.waitSelector,
      width: Math.max(1, Math.round((options.width ?? bounds.width) || 1280)),
      height: Math.max(1, Math.round((options.height ?? bounds.height) || 720)),
    };
    for (const key of Object.keys(request)) {
      if (request[key] == null) delete request[key];
    }
    this.#lastRequest = { url: source, options: { ...options } };

    try {
      const headers = { accept: "text/html", "content-type": "application/json" };
      if (this.#token) headers.authorization = `Bearer ${this.#token}`;
      const response = await fetch(this.#endpoint, {
        method: "POST",
        headers,
        body: JSON.stringify(request),
        credentials: "omit",
        signal: controller.signal,
      });
      if (!response.ok) {
        const detail = await readResponseText(response, 512).catch((error) => error.message);
        throw new Error(`Lightpanda render failed (${response.status}): ${detail}`);
      }

      const html = await readResponseText(response, this.#maxResponseBytes);
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      await waitForFrame(
        this.iframe,
        html,
        controller.signal,
        () => sequence === this.#sequence,
      );
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      this.dispatchEvent(new CustomEvent("render", { detail: { url: source } }));
      return this.iframe;
    } catch (error) {
      if (error?.name !== "AbortError") {
        this.dispatchEvent(new CustomEvent("rendererror", { detail: error }));
      }
      throw error;
    } finally {
      if (this.#controller === controller) this.#controller = null;
    }
  }

  refresh(options = undefined) {
    if (!this.#lastRequest) throw new Error("render() must be called before refresh()");
    return this.render(
      this.#lastRequest.url,
      options ? { ...this.#lastRequest.options, ...options } : this.#lastRequest.options,
    );
  }

  destroy() {
    ++this.#sequence;
    this.#controller?.abort();
    this.#controller = null;
    this.iframe.remove();
  }
}

export function attachLightpandaRenderer(target, options) {
  return new LightpandaRenderer(target, options);
}
