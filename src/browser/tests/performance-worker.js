// Exercises the Performance API inside a worker. Receives a command from
// the page and posts results back.
self.onmessage = async function(e) {
  const cmd = e.data;
  try {
    if (cmd.kind === 'basic') {
      const t = performance.now();
      postMessage({
        ok: true,
        has_performance: typeof performance === 'object',
        is_self_performance: performance === self.performance,
        now_is_number: typeof t === 'number',
        now_non_negative: t >= 0,
        origin_is_number: typeof performance.timeOrigin === 'number',
        origin_positive: performance.timeOrigin > 0,
      });
      return;
    }

    if (cmd.kind === 'marks_and_measures') {
      performance.clearMarks();
      performance.clearMeasures();

      const m = performance.mark('w-start', { startTime: 1.5 });
      performance.mark('w-end', { startTime: 10 });
      const me = performance.measure('w-dur', { start: 'w-start', end: 'w-end' });

      const marks = performance.getEntriesByType('mark');
      const measures = performance.getEntriesByType('measure');
      const byName = performance.getEntriesByName('w-start');

      postMessage({
        ok: true,
        mark_is_mark: m instanceof PerformanceMark,
        mark_start_time: m.startTime,
        measure_is_measure: me instanceof PerformanceMeasure,
        measure_duration: me.duration,
        mark_count: marks.length,
        measure_count: measures.length,
        by_name_count: byName.length,
      });
      return;
    }

    if (cmd.kind === 'event_counts') {
      const ec = performance.eventCounts;
      const keys = Array.from(ec.keys());
      let iter_count = 0;
      for (const [k, v] of ec) {
        if (typeof k === 'string' && typeof v === 'number') iter_count++;
      }
      postMessage({
        ok: true,
        size: ec.size,
        has_click: ec.has('click'),
        has_scroll: ec.has('scroll'),
        get_click_is_number: typeof ec.get('click') === 'number',
        keys_length: keys.length,
        iter_count,
      });
      return;
    }

    if (cmd.kind === 'observer') {
      // The whole point of this test: the observer callback must fire in
      // the worker's JS context, driven by the worker's scheduler.
      performance.clearMarks();

      let resolveCb;
      const fired = new Promise((r) => { resolveCb = r; });

      const observer = new PerformanceObserver((list, obs) => {
        resolveCb({
          entries: list.getEntries().map((e) => ({ name: e.name, type: e.entryType })),
          same_observer: obs === observer,
        });
      });
      observer.observe({ entryTypes: ['mark'] });

      performance.mark('observed-1');
      performance.mark('observed-2');

      const result = await fired;
      observer.disconnect();

      postMessage({
        ok: true,
        observer_is_observer: observer instanceof PerformanceObserver,
        entry_count: result.entries.length,
        first_name: result.entries[0] && result.entries[0].name,
        first_type: result.entries[0] && result.entries[0].type,
        same_observer: result.same_observer,
      });
      return;
    }

    postMessage({ ok: false, err: 'unknown command' });
  } catch (err) {
    postMessage({ ok: false, err: String(err), stack: err.stack });
  }
};
