// The canonical install handler: precache, and hold install open until it's
// done. A throw (no `caches`, a failed fetch) stops the worker before it
// activates.
self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open('sw-precache').then((cache) => cache.addAll(['./lifecycle-worker.js', '/xhr/json']))
  );
});
