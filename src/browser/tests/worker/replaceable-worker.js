// `console` and `self` are [Replaceable] on WorkerGlobalScope: assignment must
// replace the value even in strict mode, rather than throwing through the
// getter-only accessor. Capture the global in a local binding first, since
// `self` is itself replaceable (reassigning it would break global lookups).
(function () {
  "use strict";
  const g = self;
  try {
    const results = {};

    const prevConsole = g.console;
    g.console = { marker: 7 };
    results.console_replaced = g.console.marker === 7;
    g.console = prevConsole;
    results.console_restored = g.console === prevConsole;

    const prevSelf = g.self;
    g.self = "REPLACED";
    results.self_replaced = g.self === "REPLACED";
    g.self = prevSelf;
    results.self_restored = g.self === prevSelf;

    g.postMessage({ ok: true, results });
  } catch (e) {
    g.postMessage({ ok: false, err: String(e) });
  }
})();
