// Exercises fetch() inside a worker. Receives a command from the page,
// performs the fetch, and posts the results back.
self.onmessage = async function(e) {
  const cmd = e.data;
  try {
    if (cmd.kind === 'basic') {
      const response = await fetch('http://127.0.0.1:9582/xhr');
      const text = await response.text();
      postMessage({
        ok: true,
        status: response.status,
        url: response.url,
        type: response.type,
        content_type: response.headers.get('Content-Type'),
        length: text.length,
      });
      return;
    }

    if (cmd.kind === 'post') {
      const response = await fetch('http://127.0.0.1:9582/xhr', {
        method: 'POST',
        body: 'hello-from-worker',
      });
      const text = await response.text();
      postMessage({ ok: true, status: response.status, length: text.length });
      return;
    }

    if (cmd.kind === 'blob') {
      const blob = new Blob(['Hello from worker blob!'], { type: 'text/plain' });
      const blobUrl = URL.createObjectURL(blob);
      const response = await fetch(blobUrl);
      const text = await response.text();
      URL.revokeObjectURL(blobUrl);
      postMessage({
        ok: true,
        status: response.status,
        url_matches: response.url === blobUrl,
        content_type: response.headers.get('Content-Type'),
        text,
      });
      return;
    }

    postMessage({ ok: false, err: 'unknown command' });
  } catch (err) {
    postMessage({ ok: false, err: String(err), stack: err.stack });
  }
};
