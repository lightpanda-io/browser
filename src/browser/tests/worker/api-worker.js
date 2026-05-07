// Exercises WebAPI classes available in WorkerGlobalScope.
// Replies with either { ok: true, results: {...} } or { ok: false, err }.
(async function() {
  try {
    // Headers
    const headers = new Headers();
    headers.set('X-Test', 'hello');
    headers.append('X-Test', 'world');

    // FormData (no form - pure data container)
    const fd = new FormData();
    fd.set('name', 'first');
    fd.append('name', 'second');

    // Request
    const request = new Request('https://example.com/path', {
      method: 'POST',
      headers: { 'x-custom': 'header' },
      body: 'request body',
    });
    const request_body_text = await request.text();

    // Response
    const response = new Response('response body', {
      status: 201,
      statusText: 'Created',
      headers: { 'content-type': 'text/plain' },
    });
    const response_body_text = await response.text();
    const response_clone_text = await response.clone().text();

    // AbortController + AbortSignal dispatch (exercises the inline-else dispatch path)
    const controller = new AbortController();
    const ac_aborted_before = controller.signal.aborted;
    let ac_listener_fired = false;
    controller.signal.addEventListener('abort', () => { ac_listener_fired = true; });
    controller.abort('cancelled');
    const ac_aborted_after = controller.signal.aborted;
    const ac_reason = String(controller.signal.reason);

    // Pre-aborted static constructor + throwIfAborted
    const pre = AbortSignal.abort('already-gone');
    const pre_aborted = pre.aborted;
    let pre_threw = false;
    try { pre.throwIfAborted(); } catch (_) { pre_threw = true; }

    // URL.createObjectURL / revokeObjectURL from a worker
    const blob = new Blob(['hello worker'], { type: 'text/plain' });
    const blob_url = URL.createObjectURL(blob);
    const blob_url_is_blob = blob_url.startsWith('blob:');
    URL.revokeObjectURL(blob_url);

    // self.location
    const loc = self.location;
    const loc_is_worker_location = loc instanceof WorkerLocation;
    const loc_identity_stable = self.location === loc;
    const loc_href = loc.href;
    const loc_protocol = loc.protocol;
    const loc_pathname = loc.pathname;
    const loc_to_string = String(loc);

    postMessage({
      ok: true,
      results: {
        headers_get: headers.get('x-test'),
        headers_has: headers.has('x-test'),
        headers_has_missing: headers.has('x-missing'),
        formdata_get: fd.get('name'),
        formdata_getall: fd.getAll('name'),
        request_url: request.url,
        request_method: request.method,
        request_headers_custom: request.headers.get('x-custom'),
        request_body_text,
        response_status: response.status,
        response_status_text: response.statusText,
        response_ok: response.ok,
        response_headers_content_type: response.headers.get('content-type'),
        response_body_text,
        response_clone_text,
        ac_aborted_before,
        ac_aborted_after,
        ac_listener_fired,
        ac_reason,
        pre_aborted,
        pre_threw,
        blob_url_is_blob,
        loc_is_worker_location,
        loc_identity_stable,
        loc_href,
        loc_protocol,
        loc_pathname,
        loc_to_string,
      },
    });
  } catch (e) {
    postMessage({ ok: false, err: String(e), stack: e.stack });
  }
})();
