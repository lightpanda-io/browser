// Dynamic import() in a classic worker — before the ScriptManagerBase
// split, this path crashed on a null script_manager unwrap.
(async function() {
  try {
    const mod = await import('./import-module.js');
    postMessage({
      ok: true,
      message: mod.message,
      product: mod.multiply(6, 7),
    });
  } catch (e) {
    postMessage({ ok: false, err: String(e) });
  }
})();
