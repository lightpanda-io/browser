// Regression for the worker deferred-fetch leak: a fetch() whose response
// arrives while a blocking importScripts() syncRequest is in flight gets
// deferred by the DeferringLayer. A worker has no ScriptManager to flush it,
// so without WorkerGlobalScope.importScript's flushFrame the deferred fetch
// never resolves (this await hangs) and its Response arena leaks on teardown.
//
// Ordering matters: fetch() and importScripts() run synchronously with no
// event-loop pump between them, so the fetch is in-flight (not yet completed)
// when importScripts begins pumping ticks — its done lands while the worker's
// frame still has a blocking request, which is exactly what triggers deferral.
self.onmessage = async function() {
  const pending = fetch('http://127.0.0.1:9582/xhr');
  importScripts('defer-noop.js');
  try {
    const response = await pending;
    postMessage({ ok: true, status: response.status });
  } catch (e) {
    postMessage({ ok: false, err: String(e) });
  }
};
