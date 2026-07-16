onconnect = (e) => {
  // Per spec the connect event's source is the port itself (testharness.js
  // relies on this rather than ports[0]).
  const port = e.source;
  port.onmessage = (event) => {
    port.postMessage({ echo: event.data, from: 'shared-worker', sourceIsPort: e.source === e.ports[0] });
  };
};
