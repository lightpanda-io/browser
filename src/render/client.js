const DEFAULT_ENDPOINT = new URL("/v1/render", import.meta.url).href;
const DEFAULT_MAX_RESPONSE_BYTES = 16 * 1024 * 1024;
const DEFAULT_CLOSE_TIMEOUT_MS = 30_000;

function resolveTarget(target) {
  if (typeof target === "string") target = document.querySelector(target);
  if (!(target instanceof Element)) throw new TypeError("Lightpanda renderer target not found");
  return target;
}

function aborted(signal) {
  return signal.reason ?? new DOMException("Lightpanda render superseded", "AbortError");
}

async function readResponseText(response, limit) {
  const contentLengthHeader = response.headers?.get?.("content-length");
  const parsedContentLength =
    typeof contentLengthHeader === "string" && /^\d+$/.test(contentLengthHeader)
      ? Number(contentLengthHeader)
      : null;
  const contentLength = Number.isSafeInteger(parsedContentLength) ? parsedContentLength : null;
  if (contentLength !== null && contentLength > limit) {
    throw new RangeError(`Lightpanda response exceeds ${limit} bytes`);
  }
  const contentEncoding = response.headers?.get?.("content-encoding")?.trim().toLowerCase();
  const expectedLength =
    !contentEncoding || contentEncoding === "identity" ? contentLength : null;

  const reader = response.body?.getReader?.();
  if (!reader) {
    const text = await response.text();
    if (new TextEncoder().encode(text).byteLength > limit) {
      throw new RangeError(`Lightpanda response exceeds ${limit} bytes`);
    }
    return text;
  }

  let bytes = expectedLength === null ? null : new Uint8Array(expectedLength);
  let chunks = bytes ? null : [];
  let length = 0;
  let offset = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > limit) {
      await reader.cancel().catch(() => {});
      throw new RangeError(`Lightpanda response exceeds ${limit} bytes`);
    }
    if (bytes && length <= bytes.byteLength) {
      bytes.set(value, offset);
      offset = length;
    } else {
      if (bytes) {
        chunks = [bytes.subarray(0, offset)];
        bytes = null;
      }
      chunks.push(value);
    }
  }

  if (bytes) return new TextDecoder().decode(bytes.subarray(0, length));

  bytes = new Uint8Array(length);
  offset = 0;
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

function liveHeaders(response) {
  const session = response.headers?.get?.("x-lightpanda-live-session");
  const version = Number(response.headers?.get?.("x-lightpanda-live-version"));
  if (!/^[0-9a-f]{32}$/.test(session ?? "") || !Number.isSafeInteger(version) || version < 1) {
    throw new Error("Lightpanda live response is missing session metadata");
  }
  return { session, version };
}

export class LightpandaRenderer extends EventTarget {
  #target;
  #endpoint;
  #liveEndpoint;
  #token;
  #maxResponseBytes;
  #closeTimeoutMs;
  #credentialless;
  #supportsCredentialless;
  #controller = null;
  #sequence = 0;
  #lastRequest = null;
  #live = null;
  #liveClose = null;
  #liveActivation = false;
  #liveClickHandler;
  #liveChangeHandler;

  constructor(target, options = {}) {
    super();
    this.#target = resolveTarget(target);
    this.#endpoint = new URL(options.endpoint ?? DEFAULT_ENDPOINT, document.baseURI).href;
    this.#liveEndpoint = new URL(options.liveEndpoint ?? "/v1/live", this.#endpoint).href;
    this.#token = options.token ?? null;
    this.#maxResponseBytes = options.maxResponseBytes ?? DEFAULT_MAX_RESPONSE_BYTES;
    if (!Number.isSafeInteger(this.#maxResponseBytes) || this.#maxResponseBytes < 1) {
      throw new RangeError("maxResponseBytes must be a positive safe integer");
    }
    this.#closeTimeoutMs = options.closeTimeoutMs ?? DEFAULT_CLOSE_TIMEOUT_MS;
    if (!Number.isSafeInteger(this.#closeTimeoutMs) || this.#closeTimeoutMs < 1) {
      throw new RangeError("closeTimeoutMs must be a positive safe integer");
    }

    const iframe = document.createElement("iframe");
    iframe.title = options.title ?? "Lightpanda rendered page";
    iframe.loading = "eager";
    iframe.referrerPolicy = "no-referrer";
    iframe.style.cssText = options.style ?? "display:block;width:100%;height:100%;border:0";
    if (options.className) iframe.className = options.className;
    this.#supportsCredentialless = "credentialless" in iframe;
    this.#credentialless = options.credentialless !== false;
    if (options.requireCredentialless && !this.#supportsCredentialless) {
      throw new Error("This browser does not support credentialless iframes");
    }
    this.iframe = iframe;
    this.#liveClickHandler = (event) => this.#activateFromClick(event);
    this.#liveChangeHandler = (event) => this.#setValueFromChange(event);
    this.#setLiveMode(false);

    if (options.replace === false) this.#target.append(iframe);
    else this.#target.replaceChildren(iframe);
  }

  async render(url, options = {}) {
    const source = new URL(url, document.baseURI).href;
    const sequence = ++this.#sequence;
    this.#controller?.abort();
    const controller = new AbortController();
    this.#controller = controller;
    try {
      await this.#closeLive();
      if (sequence !== this.#sequence || controller.signal.aborted) throw aborted(controller.signal);
    } catch (error) {
      if (this.#controller === controller) this.#controller = null;
      if (error?.name !== "AbortError") {
        this.dispatchEvent(new CustomEvent("rendererror", { detail: error }));
      }
      throw error;
    }
    this.#setLiveMode(false);

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

  async open(url, options = {}) {
    if (this.#credentialless && !this.#supportsCredentialless) {
      throw new Error(
        "Live rendering requires credentialless iframe support; set credentialless:false to opt into credentialed subresources",
      );
    }

    const source = new URL(url, document.baseURI).href;
    const previousSandbox = this.iframe.getAttribute("sandbox");
    const sequence = ++this.#sequence;
    this.#controller?.abort();
    const controller = new AbortController();
    this.#controller = controller;
    try {
      await this.#closeLive();
      if (sequence !== this.#sequence || controller.signal.aborted) throw aborted(controller.signal);
    } catch (error) {
      if (this.#controller === controller) this.#controller = null;
      if (error?.name !== "AbortError") {
        this.dispatchEvent(new CustomEvent("liveerror", { detail: error }));
      }
      throw error;
    }
    this.#setLiveMode(true);

    const bounds = this.#target.getBoundingClientRect();
    const request = {
      op: "open",
      url: source,
      wait_ms: options.waitMs,
      width: Math.max(1, Math.round((options.width ?? bounds.width) || 1280)),
      height: Math.max(1, Math.round((options.height ?? bounds.height) || 720)),
    };
    for (const key of Object.keys(request)) {
      if (request[key] == null) delete request[key];
    }

    try {
      const response = await this.#postLive(request, controller.signal);
      if (!response.ok) {
        const detail = await readResponseText(response, 512).catch((error) => error.message);
        throw new Error(`Lightpanda live render failed (${response.status}): ${detail}`);
      }

      const metadata = liveHeaders(response);
      const live = { ...metadata, url: source, options: { ...options } };
      // Install the provisional session before reading/loading the snapshot.
      // A superseding render can now await its close before sending new work.
      this.#live = live;
      const html = await readResponseText(response, this.#maxResponseBytes);
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      await waitForFrame(
        this.iframe,
        html,
        controller.signal,
        () => sequence === this.#sequence,
      );
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      this.#bindLiveClicks();
      this.dispatchEvent(new CustomEvent("live", { detail: { url: source, version: metadata.version } }));
      return this.iframe;
    } catch (error) {
      await this.#closeLive().catch(() => {});
      if (sequence === this.#sequence) this.iframe.setAttribute("sandbox", previousSandbox);
      if (error?.name !== "AbortError") {
        this.dispatchEvent(new CustomEvent("liveerror", { detail: error }));
      }
      throw error;
    } finally {
      if (this.#controller === controller) this.#controller = null;
    }
  }

  destroy() {
    ++this.#sequence;
    this.#controller?.abort();
    this.#controller = null;
    void this.#closeLive().catch(() => {});
    this.iframe.remove();
  }

  #setLiveMode(live) {
    // Live snapshots have no scripts or forms. Same-origin access lets this
    // library capture semantic target clicks from the replacement document.
    this.iframe.setAttribute("sandbox", live ? "allow-same-origin" : "allow-forms");
    if (this.#supportsCredentialless) this.iframe.credentialless = this.#credentialless;
  }

  #headers() {
    const headers = { accept: "text/html", "content-type": "application/json" };
    if (this.#token) headers.authorization = `Bearer ${this.#token}`;
    return headers;
  }

  #postLive(request, signal) {
    return fetch(this.#liveEndpoint, {
      method: "POST",
      headers: this.#headers(),
      body: JSON.stringify(request),
      credentials: "omit",
      signal,
    });
  }

  #bindLiveClicks() {
    const snapshot = this.iframe.contentDocument;
    if (!snapshot?.addEventListener) {
      throw new Error("Lightpanda cannot access the live snapshot document");
    }
    snapshot.addEventListener("click", this.#liveClickHandler);
    snapshot.addEventListener("change", this.#liveChangeHandler);
  }

  #setLiveInteractionBusy(busy) {
    this.iframe.inert = busy;
    const root = this.iframe.contentDocument?.documentElement;
    if (root) root.inert = busy;
  }

  #activateFromClick(event) {
    if (event.target?.closest?.('[data-lp-live-kind="value"]')) return;
    const target = event.target?.closest?.("[data-lp-live-target]");
    if (!target || !this.#live) return;
    const index = Number(target.getAttribute("data-lp-live-target"));
    if (!Number.isSafeInteger(index) || index < 0) return;
    if (event.button != null && event.button !== 0) return;
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;

    event.preventDefault();
    event.stopPropagation();
    if (this.#liveActivation || this.#liveClose) return;

    this.#liveActivation = true;
    this.#setLiveInteractionBusy(true);
    void this.#activate(index)
      .catch((error) => {
        if (error?.name !== "AbortError") {
          void this.#closeLive().catch(() => {});
          this.dispatchEvent(new CustomEvent("liveerror", { detail: error }));
        }
      })
      .finally(() => {
        this.#liveActivation = false;
        this.#setLiveInteractionBusy(false);
      });
  }

  #setValueFromChange(event) {
    const target = event.target?.closest?.('[data-lp-live-kind="value"]');
    if (!target || !this.#live || this.#liveActivation || this.#liveClose) return;
    const rawIndex = target.getAttribute("data-lp-live-target");
    if (rawIndex === null) return;
    const index = Number(rawIndex);
    if (!Number.isSafeInteger(index) || index < 0 || typeof target.value !== "string") return;
    const selectedIndex =
      Number.isSafeInteger(target.selectedIndex) && target.selectedIndex >= 0
        ? target.selectedIndex
        : null;

    this.#liveActivation = true;
    this.#setLiveInteractionBusy(true);
    void this.#setValue(index, target.value, selectedIndex)
      .catch((error) => {
        if (error?.name !== "AbortError") {
          void this.#closeLive().catch(() => {});
          this.dispatchEvent(new CustomEvent("liveerror", { detail: error }));
        }
      })
      .finally(() => {
        this.#liveActivation = false;
        this.#setLiveInteractionBusy(false);
      });
  }

  async #activate(target) {
    const live = this.#live;
    if (!live) return;
    const sequence = ++this.#sequence;
    this.#controller?.abort();
    const controller = new AbortController();
    this.#controller = controller;

    try {
      const response = await this.#postLive({
        op: "activate",
        session: live.session,
        version: live.version,
        target,
        wait_ms: live.options.waitMs,
      }, controller.signal);
      if (!response.ok) {
        const detail = await readResponseText(response, 512).catch((error) => error.message);
        throw new Error(`Lightpanda live activation failed (${response.status}): ${detail}`);
      }

      const metadata = liveHeaders(response);
      const html = await readResponseText(response, this.#maxResponseBytes);
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      await waitForFrame(
        this.iframe,
        html,
        controller.signal,
        () => sequence === this.#sequence,
      );
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      this.#live = { ...live, ...metadata };
      this.#bindLiveClicks();
      this.dispatchEvent(new CustomEvent("live", { detail: { url: live.url, version: metadata.version, target } }));
    } finally {
      if (this.#controller === controller) this.#controller = null;
    }
  }

  async #setValue(target, value, selectedIndex) {
    const live = this.#live;
    if (!live) return;
    const sequence = ++this.#sequence;
    this.#controller?.abort();
    const controller = new AbortController();
    this.#controller = controller;

    try {
      const request = {
        op: "set_value",
        session: live.session,
        version: live.version,
        target,
        value,
        wait_ms: live.options.waitMs,
      };
      if (selectedIndex !== null) request.selected_index = selectedIndex;
      const response = await this.#postLive(request, controller.signal);
      if (!response.ok) {
        const detail = await readResponseText(response, 512).catch((error) => error.message);
        throw new Error(`Lightpanda live value update failed (${response.status}): ${detail}`);
      }

      const metadata = liveHeaders(response);
      const html = await readResponseText(response, this.#maxResponseBytes);
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      await waitForFrame(this.iframe, html, controller.signal, () => sequence === this.#sequence);
      if (sequence !== this.#sequence) throw aborted(controller.signal);
      this.#live = { ...live, ...metadata };
      this.#bindLiveClicks();
      this.dispatchEvent(new CustomEvent("live", { detail: { url: live.url, version: metadata.version, target } }));
    } finally {
      if (this.#controller === controller) this.#controller = null;
    }
  }

  async #closeLive() {
    if (this.#liveClose) return this.#liveClose;
    const live = this.#live;
    if (!live) return;

    this.#liveActivation = false;
    const controller = new AbortController();
    const timeout = setTimeout(() => {
      controller.abort(new DOMException("Lightpanda live close timed out", "TimeoutError"));
    }, this.#closeTimeoutMs);
    const closing = (async () => {
      const response = await this.#postLive({ op: "close", session: live.session }, controller.signal);
      if (!response.ok && response.status !== 404) {
        const detail = await readResponseText(response, 512).catch((error) => error.message);
        throw new Error(`Lightpanda live close failed (${response.status}): ${detail}`);
      }
      if (this.#live?.session === live.session) this.#live = null;
    })();
    this.#liveClose = closing;
    try {
      await closing;
    } finally {
      clearTimeout(timeout);
      if (this.#liveClose === closing) this.#liveClose = null;
    }
  }
}

export function attachLightpandaRenderer(target, options) {
  return new LightpandaRenderer(target, options);
}
