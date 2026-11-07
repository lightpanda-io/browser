// Comlink-style: replies through a port transferred in with the message, then
// hands a port of its own back to the page.
onmessage = function(event) {
  const port = event.data.port;
  port.onmessage = (e) => {
    port.postMessage({ echo: e.data, ports: event.ports.length, same: event.ports[0] === port });
  };

  const back = new MessageChannel();
  back.port1.onmessage = (e) => postMessage({ back: e.data });
  postMessage({ port: back.port2 }, [back.port2]);
};
