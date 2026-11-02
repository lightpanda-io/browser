// The worker global's prototype is its interface's prototype, as in browsers.
onmessage = function() {
  postMessage({
    proto_is_scope_proto: Object.getPrototypeOf(self) === DedicatedWorkerGlobalScope.prototype,
    ctor_is_scope: self.constructor === DedicatedWorkerGlobalScope,
    no_own_ctor: !Object.prototype.hasOwnProperty.call(self, 'constructor'),
    is_worker_global: self instanceof WorkerGlobalScope,
  });
};
