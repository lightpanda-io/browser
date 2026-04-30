// Exercises module imports inside a worker. Classic workers can't use
// top-level `import`, so all imports go through dynamic import() — which
// is the path the ScriptManagerBase split was made to enable.
(async function () {
  const results = {};
  try {
    const m1 = await import('./modules/base.js');
    results.basic_baseValue = m1.baseValue;

    const m2 = await import('./modules/importer.js');
    results.transitive_importedValue = m2.importedValue;
    results.transitive_localValue = m2.localValue;

    const m3 = await import('./modules/re-exporter.js');
    results.reexport_baseValue = m3.baseValue;
    results.reexport_importedValue = m3.importedValue;
    results.reexport_localValue = m3.localValue;

    const m4a = await import('./modules/shared.js');
    results.shared_first_inc = m4a.increment();
    results.shared_first_count = m4a.getCount();
    const m4b = await import('./modules/shared.js');
    results.shared_second_inc = m4b.increment();
    results.shared_second_count = m4b.getCount();
    results.shared_same_module = m4a === m4b;

    const ma = await import('./modules/circular-a.js');
    const mb = await import('./modules/circular-b.js');
    results.circular_aValue = ma.aValue;
    results.circular_bValue = mb.bValue;
    results.circular_getFromB = ma.getFromB();
    results.circular_getFromA = mb.getFromA();

    const mm = await import('./modules/meta.js');
    results.meta_url_endsWith = mm.moduleUrl.endsWith('/tests/worker/modules/meta.js');

    let import_404_threw = false;
    try {
      await import('./modules/nonexistent.js');
    } catch (e) {
      import_404_threw = e.toString().includes('FailedToLoad');
    }
    results.import_404_threw = import_404_threw;

    postMessage({ ok: true, results });
  } catch (e) {
    postMessage({ ok: false, err: String(e), stack: e.stack });
  }
})();
