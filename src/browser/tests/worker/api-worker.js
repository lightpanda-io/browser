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
      },
    });
  } catch (e) {
    postMessage({ ok: false, err: String(e), stack: e.stack });
  }
})();
