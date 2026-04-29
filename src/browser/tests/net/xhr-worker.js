// Exercises XMLHttpRequest inside a worker. Receives a command from the page,
// performs the XHR, and posts the results back.
self.onmessage = function(e) {
  const cmd = e.data;
  try {
    if (cmd.kind === 'basic') {
      const req = new XMLHttpRequest();
      const states = [];
      req.onreadystatechange = () => states.push(req.readyState);
      req.onload = () => {
        postMessage({
          ok: true,
          status: req.status,
          status_text: req.statusText,
          response_url: req.responseURL,
          response_text_length: req.responseText.length,
          content_type: req.getResponseHeader('Content-Type'),
          states,
        });
      };
      req.onerror = () => postMessage({ ok: false, err: 'xhr error', status: req.status });
      req.open('GET', 'http://127.0.0.1:9582/xhr');
      req.send();
      return;
    }

    if (cmd.kind === 'arraybuffer') {
      const req = new XMLHttpRequest();
      req.responseType = 'arraybuffer';
      req.onload = () => {
        const view = new Uint8Array(req.response);
        postMessage({
          ok: true,
          status: req.status,
          byte_length: req.response.byteLength,
          first: view[0],
          third: view[2],
          last: view[6],
          response_type: req.responseType,
        });
      };
      req.onerror = () => postMessage({ ok: false, err: 'xhr error', status: req.status });
      req.open('GET', 'http://127.0.0.1:9582/xhr/binary');
      req.send();
      return;
    }

    if (cmd.kind === 'document_unsupported') {
      const req = new XMLHttpRequest();
      req.responseType = 'document';
      req.onload = () => {
        let threw = false;
        let err = null;
        try {
          // Reading .response in worker context with responseType=document
          // must error: workers have no DOM document.
          void req.response;
        } catch (e) {
          threw = true;
          err = String(e);
        }
        postMessage({ ok: true, status: req.status, threw, err });
      };
      req.onerror = () => postMessage({ ok: false, err: 'xhr error', status: req.status });
      req.open('GET', 'http://127.0.0.1:9582/xhr');
      req.send();
      return;
    }

    postMessage({ ok: false, err: 'unknown command' });
  } catch (err) {
    postMessage({ ok: false, err: String(err), stack: err.stack });
  }
};
