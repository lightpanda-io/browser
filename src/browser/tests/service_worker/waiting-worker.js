// Never settles its install promise, so this worker stays at `installing`
// forever. Used to check that a pending waitUntil actually gates activation.
self.addEventListener('install', (e) => {
  e.waitUntil(new Promise(() => {}));
});
