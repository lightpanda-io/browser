// Runs Temporal inside a worker. Posts 'ready' once the message handler is
// wired so the page doesn't race worker startup, then replies to any message
// with the results.
self.onmessage = function() {
  try {
    const zdt = Temporal.ZonedDateTime.from('2024-03-10T01:30[America/New_York]');
    postMessage({
      ok: true,
      type: typeof Temporal,
      now_tz: Temporal.Now.timeZoneId(),
      intl_tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      clock_skew: Math.abs(Temporal.Now.instant().epochMilliseconds - Date.now()),
      zoned: zdt.add({ hours: 1 }).toString(),
      hebrew: Temporal.PlainDate.from('2024-04-23').withCalendar('hebrew').monthCode,
      formatted: Temporal.PlainDate.from('2024-01-15').toLocaleString('en-US', { dateStyle: 'long' }),
    });
  } catch (err) {
    postMessage({ ok: false, error: err.toString() });
  }
};

postMessage({ ready: true });
