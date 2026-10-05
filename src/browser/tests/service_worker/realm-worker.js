// Loaded into two realms: as a service worker and as a dedicated worker.
//
// The dedicated side reports back and the page asserts on the message. The
// service worker side has no way to reach a client yet, so it asserts on
// itself and throws — a throw here stops it before it installs, which the page
// sees as `active` never becoming "activated".
const report = {
  hasXHR: typeof XMLHttpRequest !== 'undefined',
  hasFileReaderSync: typeof FileReaderSync !== 'undefined',
  hasFetch: typeof fetch !== 'undefined',
  hasWebSocket: typeof WebSocket !== 'undefined',
  // [Exposed=(ServiceWorker,Window)] — the constructor and the property that
  // hands one out should both be service-worker-only.
  hasCookieStoreCtor: typeof CookieStore !== 'undefined',
  hasCookieStoreProp: 'cookieStore' in self,
  // Blink has this as [Exposed=Window]; a service worker would get
  // ExtendableCookieChangeEvent, which we don't implement.
  hasCookieChangeEvent: typeof CookieChangeEvent !== 'undefined',
  // Inherited from a page served from loopback; always true for a service worker.
  isSecureContext: self.isSecureContext,
};

// A global postMessage exists on DedicatedWorkerGlobalScope only.
if (typeof postMessage === 'function') {
  postMessage(report);
} else {
  const bad = [];
  if (report.hasXHR) bad.push('XMLHttpRequest');
  if (report.hasFileReaderSync) bad.push('FileReaderSync');
  if (report.hasCookieChangeEvent) bad.push('CookieChangeEvent');
  if (!report.hasCookieStoreCtor) bad.push('missing CookieStore');
  if (!report.hasCookieStoreProp) bad.push('missing cookieStore');
  if (report.isSecureContext !== true) bad.push('isSecureContext');
  if (bad.length) {
    throw new Error('service worker realm: ' + bad.join(', '));
  }
}
