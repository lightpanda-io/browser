// WebGL on an OffscreenCanvas inside a worker. Posts 'ready' first so the page
// doesn't race worker startup.
self.onmessage = function() {
  const canvas = new OffscreenCanvas(8, 4);
  const gl = canvas.getContext('webgl2');
  postMessage({
    context: gl instanceof WebGL2RenderingContext,
    canvas: gl.canvas === canvas,
    width: gl.drawingBufferWidth,
    buffer: gl.createBuffer() instanceof WebGLBuffer,
  });
};
postMessage({ ready: true });
