onmessage = async (e) => {
  try {
    const res = await fetch(e.data);
    postMessage({ ok: true, text: await res.text() });
  } catch (err) {
    postMessage({ ok: false, err: String(err) });
  }
};
