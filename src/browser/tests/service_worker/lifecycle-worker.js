// Records the lifecycle it went through so the page can read it back.
const seen = [];

self.addEventListener('install', (e) => {
  seen.push('install');
  // The canonical install handler shape: waitUntil with a promise that only
  // settles on a later turn of the loop.
  e.waitUntil(new Promise((resolve) => setTimeout(resolve, 0)));
});

self.addEventListener('activate', (e) => {
  seen.push('activate');
  e.waitUntil(self.skipWaiting());
});

self.addEventListener('message', (e) => {
  seen.push('message:' + e.data);
});

self.addEventListener('message', () => {
  // Nothing to reply through yet (no `clients`), so the page reads state
  // indirectly, via the registration's slots.
});
