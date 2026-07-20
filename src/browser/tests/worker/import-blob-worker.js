onmessage = (e) => {
  try {
    importScripts(e.data);
    postMessage({ ok: true, value: self.importedValue });
  } catch (err) {
    postMessage({ ok: false, err: String(err) });
  }
};
