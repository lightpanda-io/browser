// Uncaught exceptions from callbacks inside a worker are reported to the
// worker global: its "error" event fires with the thrown value.
const seen = [];
let reentrant = 0;
self.addEventListener('error', (e) => {
  if (reentrant > 0) {
    // Reached again from our own throw below: the guard failed.
    reentrant += 1;
    if (reentrant < 5) throw new Error('again');
    return;
  }
  const msg = e.error && e.error.message;
  seen.push(msg);
  if (msg === 'reentrant') {
    reentrant = 1;
    // Thrown while reporting: must not be reported again.
    throw new Error('again');
  }
});

self.onmessage = (e) => {
  if (e.data === 'throw') {
    throw new Error('onmessage');
  }
};

const target = new EventTarget();
target.addEventListener('ping', () => { throw new Error('listener'); });
target.dispatchEvent(new Event('ping'));

setTimeout(() => { throw new Error('setTimeout'); }, 0);
queueMicrotask(() => { throw new Error('queueMicrotask'); });
setTimeout(() => { throw new Error('reentrant'); }, 5);

setTimeout(() => postMessage({ seen: seen.slice().sort(), reentrant }), 20);
