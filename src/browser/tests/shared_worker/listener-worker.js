// Exercises the addEventListener flavor on both the global ('connect') and
// the port ('message' + explicit start()), instead of the auto-starting
// onconnect/onmessage attribute setters.
self.addEventListener('connect', (e) => {
  const port = e.ports[0];
  port.addEventListener('message', (event) => {
    port.postMessage('listener:' + event.data);
  });
  port.start();
});
