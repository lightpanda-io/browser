// Per-realm ServiceWorker object identity: within one realm there is one
// ServiceWorker object per worker, however you reach it. Asserted at top level
// so a mismatch throws before install — a throw inside a listener is swallowed
// by the dispatcher and would make this test pass regardless.
if (self.serviceWorker !== self.registration.installing) {
  throw new Error('self.serviceWorker !== self.registration.installing');
}
if (self.registration !== self.registration) {
  throw new Error('self.registration is not stable');
}

// waitUntil is only for the lifecycle event being dispatched: on an event the
// script constructed itself it must throw rather than hold a promise.
try {
  new ExtendableEvent('x').waitUntil(Promise.resolve());
  throw new Error('waitUntil on a constructed event did not throw');
} catch (e) {
  if (e.name !== 'InvalidStateError') {
    throw e;
  }
}
