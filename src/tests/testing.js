// Note: this code tries to make sure that we don't fail to execute a <script>
// block without reporting an error. In other words, if the test passes, you
// should be confident that the code actually ran.
// We do a couple things to ensure this.
// 1 - We make sure that ever script with an id has at least 1 assertion called
// 2 - We add an onerror handler to every script and, on error, fail.
//
// This is pretty straightforward, with the only complexity coming from "eventually"
// assertions, which are assertions we lazily check in `getStatus()`. We
// do this because, by the time `getStatus()`, `page.wait()` will have been called
// and any timer (setTimeout, requestAnimation, MutationObserver, etc...) will
// have been evaluated. Test which use/test these behavior will use `eventually`.
(() => {
  function expectEqual(expected, actual) {
    _recordExecution();
    if (_equal(expected, actual)) {
      return;
    }
    testing._status = 'fail';
    let msg = `expected: ${JSON.stringify(expected)}, got: ${JSON.stringify(actual)}`;

    console.warn(
      `id: ${testing._captured?.script_id || document.currentScript.id}`,
      `msg: ${msg}`,
      `stack: ${testing._captured?.stack || new Error().stack}`,
    );
  }

  function expectError(expected, fn) {
    withError((err) => {
      expectEqual(expected, err.toString());
    }, fn);
  }

  function withError(cb, fn) {
    try{
      fn();
    } catch (err) {
      cb(err);
      return;
    }
    expectEqual('an error', null);
  }

  function skip() {
    _recordExecution();
  }

  // Should only be called by the test runner
  function getStatus() {
    // if we're already in a fail state, return fail, nothing can recover this
    if (testing._status === 'fail') return 'fail';
    // run any eventually's that we've captured
    for (const ev of testing._eventually) {
      testing._captured = ev[1];
      ev[0]();
      testing._captured = null;
    }

    // Again, if we're in a fail state, we can immediately fail
    if (testing._status === 'fail') return 'fail';

    // make sure that any <script id=xyz></script> tags we have have had at least
    // 1 assertion. This helps ensure that if a script tag fails to execute,
    // we'll report an error, even if no assertions failed.
    const scripts = document.getElementsByTagName('script');
    for (script of scripts) {
      const id = script.id;
      if (!id) {
        continue;
      }

      if (!testing._executed_scripts.has(id)) {
        console.warn(`Failed to execute any expectations for <script id="${id}">...</script>`),
        testing._status = 'fail';
      }
    }

    return testing._status;
  }

  // Set expectations to happen at some point in the future. Necessary for
  // testing callbacks which will only be executed after page.wait is called.
  function eventually(fn) {
    // capture the current state (script id, stack) so that, when we do run this
    // we can display more meaningful details on failure.
    testing._eventually.push([fn, {
      script_id: document.currentScript.id,
      stack: new Error().stack,
    }]);

    _registerErrorCallback();
  }

  async function async(promise, cb) {
    const script_id = document.currentScript.id;
    const stack = new Error().stack;
    const value = await promise;
    this._captured = {script_id: script_id, stack: stack};
    cb(value);
    this._captured = null;
  }

  function _recordExecution() {
    if (testing._status === 'fail') {
      return;
    }
    testing._status = 'ok';

    const script_id = testing._captured?.script_id || document.currentScript.id;
    testing._executed_scripts.add(script_id);
    _registerErrorCallback();
  }

  // We want to attach an onError callback to each <script>, so that we can
  // properly fail it.
  function _registerErrorCallback() {
    const script = document.currentScript;
    if (!script) {
      // can be null if we're executing an eventually assertion, but that's ok
      // because the errorCallback would have been registered for this script
      // already
      return;
    }

    if (script.onerror) {
      // already registered
      return;
    }

    script.onerror = function(err, b) {
      testing._status = 'fail';
      console.warn(
        `id: ${script.id}`,
        `msg: There was an error executing the <script id=${script.id}>...</script>.\n      There should be a eval error printed above this.`,
      );
    }
  }

  function _equal(a, b) {
    if (a === b) {
      return true;
    }
    if (a === null || b === null) {
      return false;
    }
    if (typeof a !== 'object' || typeof b !== 'object') {
      return false;
    }

    if (Object.keys(a).length != Object.keys(b).length) {
      return false;
    }

    for (property in a) {
      if (b.hasOwnProperty(property) === false) {
        return false;
      }
      if (_equal(a[property], b[property]) === false) {
        return false;
      }
    }

    return true;
  }

  window.testing = {
    _status: 'empty',
    _eventually: [],
    _executed_scripts: new Set(),
    _captured: null,
    skip: skip,
    async: async,
    getStatus: getStatus,
    eventually: eventually,
    expectEqual: expectEqual,
    expectError: expectError,
    withError: withError,
  };

  // Helper, so you can do $(sel) in a test
  window.$ = function(sel) {
    return document.querySelector(sel);
  }

  // Helper, so you can do $$(sel) in a test
  window.$$ = function(sel) {
    return document.querySelectorAll(sel);
  }

  if (!console.lp) {
    // make this work in the browser
    console.lp = console.log;
  }
})();
