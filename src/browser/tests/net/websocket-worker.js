// Exercises the WebSocket API inside a worker. Posts 'ready' once the message
// handler is wired so the page knows it can send a command without racing
// worker startup. On command, opens a WebSocket to the test echo server,
// sends a message, and reports the echoed reply plus the close code/reason
// back to the page.
self.onmessage = function(e) {
  const cmd = e.data;
  try {
    if (cmd.kind === 'echo') {
      const received = [];
      const ws = new WebSocket('ws://127.0.0.1:9584/');

      ws.addEventListener('open', () => {
        ws.send('from-worker');
      });

      ws.addEventListener('message', (ev) => {
        received.push(ev.data);
        ws.close(1000, 'bye');
      });

      ws.addEventListener('close', (ev) => {
        postMessage({
          ok: true,
          received,
          url: ws.url,
          ready_state: ws.readyState,
          code: ev.code,
          reason: ev.reason,
          was_clean: ev.wasClean,
        });
      });

      ws.addEventListener('error', () => {
        postMessage({ ok: false, err: 'websocket error' });
      });
      return;
    }

    postMessage({ ok: false, err: 'unknown command' });
  } catch (err) {
    postMessage({ ok: false, err: String(err), stack: err.stack });
  }
};

postMessage({ ready: true });
