// the rejection callback dispatches unhandledrejection synchronously
window.addEventListener('unhandledrejection', (e) => { e.preventDefault(); });
Promise.reject(new Error('tla-checkpoint-reject'));
