let counter = 0;
onconnect = (e) => {
  const port = e.ports[0];
  port.onmessage = () => {
    counter++;
    port.postMessage({ count: counter, name: self.name });
  };
};
