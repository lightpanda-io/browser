// Simple worker that echoes messages back with a prefix
onmessage = function(event) {
  postMessage({ echo: event.data, from: 'worker' });
};
