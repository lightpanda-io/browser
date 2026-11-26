// Not a real Error, so V8 captures no stack when it's created (like Ember
// Data's AdapterError): only the throw site says which script it comes from.
function AdapterError(message) { this.message = message; }
AdapterError.prototype = Object.create(Error.prototype);
setTimeout(() => { throw new AdapterError('boom'); });
