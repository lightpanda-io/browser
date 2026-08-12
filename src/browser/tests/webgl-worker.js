// Reports what a worker can learn about the GPU from an OffscreenCanvas.
// Posts 'ready' first so the page can send its command without racing worker
// startup, matching the other worker fixtures here.
//
// The point is agreement with the main thread, not the values themselves: a
// worker that reported no GPU while the document reported a full vendor and
// renderer is a self-contradiction no real browser produces, and it was our
// loudest bot signal.
self.onmessage = function () {
  try {
    const canvas = new OffscreenCanvas(256, 256);
    const gl = canvas.getContext('webgl');
    if (!gl) {
      postMessage({ ok: false, reason: 'no webgl context' });
      return;
    }

    const dbg = gl.getExtension('WEBGL_debug_renderer_info');
    postMessage({
      ok: true,
      // UNMASKED_VENDOR_WEBGL / UNMASKED_RENDERER_WEBGL
      vendor: dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : '',
      renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : '',
      has_webgl2: !!new OffscreenCanvas(8, 8).getContext('webgl2'),
      extensions: (gl.getSupportedExtensions() || []).length,
      canvas_is_offscreen: gl.canvas instanceof OffscreenCanvas,
    });
  } catch (e) {
    postMessage({ ok: false, reason: String(e) });
  }
};
postMessage({ ready: true });
