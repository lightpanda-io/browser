// Exercises EventSource inside a worker. Receives a command from the page,
// consumes the stream, and posts the results back.
self.onmessage = function() {
  try {
    const received = [];
    const es = new EventSource('http://127.0.0.1:9582/sse/simple');
    es.onopen = () => received.push('open');
    es.onmessage = (e) => received.push(e.data);
    es.addEventListener('custom', (e) => {
      received.push(e.data);
      es.close();
      postMessage({ ok: true, received, readyState: es.readyState });
    });
    es.onerror = () => postMessage({ ok: false, err: 'eventsource error' });
  } catch (err) {
    postMessage({ ok: false, err: String(err) });
  }
};
