(() => {
  let failed = false;
  let observed_ids = {};
  // includes observations no script could be attributed to (e.g. a module
  // after an await, where currentScript is null)
  let observation_count = 0;
  let eventuallies = [];
  let async_capture = null;
  let current_script_id = null;

  // set inside a testing.diverges() block when not in Lightpanda
  let diverging = null;

  // can only have 1 async test per <script>, this tracks it
  let async_seen = new Set();

  // runner will wait until this is empty (or timeout)
  let async_pending = new Set();


  let module_asyncs_done = 0;
  let module_asyncs_started = 0;
  let parsed_module_asyncs = 0;

  document.addEventListener('DOMContentLoaded', () => {
    parsed_module_asyncs = _moduleAsyncCount();
  });

  // A script that throws after an expect* passed would otherwise count as ok.
  // Checked in assertOk, once dispatch is over: a test that expects the error
  // cancels it (window.onerror returning true, or preventDefault()).
  let reported_errors = [];
  window.addEventListener('error', (e) => {
    reported_errors.push({event: e, script_id: _currentScriptId()});
  });

  // Same for a rejection nothing handled: a test that expects one cancels its
  // unhandledrejection event.
  let unhandled_rejections = [];
  window.addEventListener('unhandledrejection', (e) => {
    unhandled_rejections.push({event: e, script_id: _currentScriptId()});
  });

  // Runs fn, cancelling the errors it reports to window, and returns them.
  function withReportedErrors(fn) {
    const errors = [];
    const onError = (e) => {
      errors.push(e.error);
      e.preventDefault();
    };
    window.addEventListener('error', onError);
    try {
      fn();
    } finally {
      window.removeEventListener('error', onError);
    }
    return errors;
  }

  function expectTrue(actual) {
     expectEqual(true, actual);
  }

  function expectFalse(actual) {
     expectEqual(false, actual);
  }

  function expectEqual(expected, actual, opts) {
    if (_equal(expected, actual)) {
      if (diverging) {
        _divergeMatched(_displayValue(actual), opts);
        return;
      }
      _registerObservation('ok', opts);
      return;
    }
    if (diverging) {
      _diverged(`expected: ${_displayValue(expected)}, got: ${_displayValue(actual)}`, opts);
      return;
    }
    failed = true;
    _registerObservation('fail', opts);
    let err = `expected: ${_displayValue(expected)}, got: ${_displayValue(actual)}\n  script_id: ${_currentScriptId()}`;
    if (async_capture) {
      err += `\n stack: ${async_capture.stack}`;
    }
    console.error(err);
    throw new Error('expectEqual failed');
  }

  function fail(reason) {
    if (diverging) {
      _diverged(reason);
      return;
    }
    failed = true;
    console.error(reason);
    throw new Error('testing.fail()');
  }

  function expectError(expected, fn) {
    withError((err) => {
      if (!err.toString().includes(expected)) {
        if (diverging) {
          _diverged(`expected error to contain: ${expected}, was: ${err.toString()}`);
          return;
        }
        console.error(`Expecte error to contains: ${expected}, was: ${err.toString()}`);
        expectEqual(true, false);
      } else {
        // to record a successful case
        expectTrue(true);
      }
    }, fn);
  }

  function withError(cb, fn) {
    try{
      fn();
    } catch (err) {
      cb(err);
      return;
    }

    console.error(`expected error but no error received\n`);
    throw new Error('no error');
  }

  // Resolves once observer notifications queued so far have been delivered:
  // WPT's waitForNotification, two frames then a task. Page load isn't
  // ordered against them.
  function nextFrame() {
    return new Promise((resolve) => {
      requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve)));
    });
  }

  function onload(cb) {
    const script_id = _currentScriptId();
    if (!script_id) {
      throw new Error('testing.onload called outside of a script');
    }
    eventuallies.push({
      callback: cb,
      script_id: script_id,
    });
  }

  async function async() {
    // currentScript is null while a module runs (Lightpanda sets it, against
    // the spec).
    const script = document.currentScript;
    const is_module = script === null || script.type === 'module';
    if (is_module) {
      module_asyncs_started += 1;
    }
    const script_id = script ? script.id : _moduleAsyncName(module_asyncs_started);

    if (async_seen.has(script_id) && IS_TEST_RUNNER) {
      throw new Error(`testing.async() called more than once for script '${script_id}'. A script may only register one async block (the runner can declare success in the gap between two of them); split the test into separate <script> tags.`);
    }
    async_seen.add(script_id);

    let resolve = null
    const promise = new Promise((r) => { resolve = r});
    async_pending.add(script_id);

    return {
      promise: promise,
      resolve: resolve,
      capture: {script_id: script_id, stack: new Error().stack},
      done: async function(cb) {
        const res = await this.promise;
        async_pending.delete(script_id);
        if (is_module) {
          module_asyncs_done += 1;
        }
        async_capture = this.capture;
        try {
          cb(res);
        } catch (err) {
          console.warn(script_id, err);
          failed = true;
        }
        async_capture = false;
      }
    };
  }

  function assertOk() {
    if (failed) {
      throw new Error('Failed');
    }

    for (let {event, script_id} of reported_errors) {
      if (event.defaultPrevented === false) {
        throw new Error(`script id: '${script_id}' uncaught error: ${event.message}`);
      }
    }

    for (let {event, script_id} of unhandled_rejections) {
      if (event.defaultPrevented === false) {
        throw new Error(`script id: '${script_id}' unhandled rejection: ${event.reason}`);
      }
    }

    if (async_pending.size > 0) {
      return false;
    }

    const module_asyncs = _moduleAsyncCount();
    if (module_asyncs_done < module_asyncs) {
      // a module hasn't reached its testing.async() (yet)
      return false;
    }
    if (module_asyncs_done > module_asyncs) {
      throw new Error(`${module_asyncs_done} testing.async() blocks completed outside of a classic script, but only ${module_asyncs} inline module scripts call testing.async()`);
    }

    if (observation_count === 0 && eventuallies.length === 0) {
      // A script may still be waiting on something (a module's await) without
      // having registered a testing.async() block.
      return false;
    }

    for (let e of eventuallies) {
      current_script_id = e.script_id;
      e.callback();
      current_script_id = null;
    }

    if (observation_count === 0) {
      throw new Error('no test observations were recorded');
    }

    const scripts = document.getElementsByTagName('script');
    for (let script of scripts) {
      const script_id = script.id;
      if (!script_id || script.type === 'module') {
        // modules are counted instead, above
        continue;
      }

      const status = observed_ids[script_id];
      if (status !== 'ok') {
         throw new Error(`script id: '${script_id}' failed: ${status || 'no assertions'}`);
      }
    }

    return true;
  }

  function diverges(reason, fn) {
    if (!reason) {
      throw new Error('testing.diverges() needs a reason');
    }
    if (IS_TEST_RUNNER) {
      return _expectSync(fn());
    }
    if (diverging) {
      throw new Error('testing.diverges() blocks cannot be nested');
    }

    diverging = {reason: reason, count: 0, matched: 0};
    const state = diverging;
    let result = null;
    try {
      result = fn();
    } catch (err) {
      _diverged(`threw ${err}`);
    } finally {
      diverging = null;
    }
    _expectSync(result);
    if (state.count === 0 && state.matched === 0) {
      failed = true;
      _registerObservation('fail');
      console.error(`testing.diverges() block made no checks: ${reason}\n  script_id: ${_currentScriptId()}`);
    }
  }

  function _expectSync(result) {
    if (result instanceof Promise) {
      throw new Error('testing.diverges() callback must be synchronous');
    }
  }

  // An expected difference counts as a passing observation, so a script made
  // only of diverges() blocks isn't reported as having no assertions.
  function _diverged(detail, opts) {
    diverging.count += 1;
    _registerObservation('ok', opts);
    console.info(`diverges (${diverging.reason}): ${detail}\n  script_id: ${_currentScriptId()}`);
  }

  // Doesn't throw: fn's exceptions count as differences.
  function _divergeMatched(detail, opts) {
    diverging.matched += 1;
    failed = true;
    _registerObservation('fail', opts);
    console.error(`testing.diverges() check passed, move it out of the block (${diverging.reason}): ${detail}\n  script_id: ${_currentScriptId()}`);
  }

  // Brackets messages the browser itself logs (not console.* calls, so they
  // can't be silenced) for an expected error case. Folded into a collapsed
  // group so a clean run in Chrome/Firefox shows nothing unexpected.
  function beginBrowserLog(reason) {
    if (IS_TEST_RUNNER === false) {
      console.groupCollapsed(`expected browser logs: ${reason || _currentScriptId()}`);
    }
  }

  function endBrowserLog() {
    if (IS_TEST_RUNNER === false) {
      console.groupEnd();
    }
  }

  function printTimeoutState() {
    if (observation_count === 0) {
      console.warn('no test observations were recorded');
    }
    if (async_pending.size > 0) {
      console.warn(`Pending async scripts: ${Array.from(async_pending.keys()).join(', ')}`);
    }
    const module_asyncs = _moduleAsyncCount();
    if (module_asyncs_done < module_asyncs) {
      console.warn(`${module_asyncs_done} of ${module_asyncs} module testing.async() blocks completed, ${module_asyncs_started} started`);
    }
  }

  const IS_TEST_RUNNER = window.navigator.userAgent.startsWith("Lightpanda/");

  window.testing = {
    fail: fail,
    async: async,
    diverges: diverges,
    assertOk: assertOk,
    expectTrue: expectTrue,
    expectFalse: expectFalse,
    expectEqual: expectEqual,
    expectError: expectError,
    withError: withError,
    withReportedErrors: withReportedErrors,
    printTimeoutState: printTimeoutState,
    beginBrowserLog: beginBrowserLog,
    endBrowserLog: endBrowserLog,
    onload: onload,
    nextFrame: nextFrame,
    IS_TEST_RUNNER: IS_TEST_RUNNER,
    HOST: '127.0.0.1',
    ORIGIN: 'http://127.0.0.1:9582',
    BASE_URL: 'http://127.0.0.1:9582/src/browser/tests/',
    skipAsync: skipAsync
  };

  async function skipAsync() {
    const state = await async();
    state.resolve();
    state.done(() => { expectTrue(true); });
  }

  if (IS_TEST_RUNNER === false) {
    // The page is running in a different browser. Probably a developer making sure
    // a test is correct. There are a few tweaks we need to do to make this a
    // seamless, namely around adapting paths/urls.
    window.testing.HOST = location.hostname;
    window.testing.ORIGIN = location.origin;

    window.testing.BASE_URL = location.origin + '/src/browser/tests/';
    // An external runner (../demo/browser-tests) polls assertOk itself.
    if (window.__lp_external_runner !== true) {
      console.warn(`The page is not being executed in the test runner, certain behavior has been adjusted`);
      window.addEventListener('load', testing.assertOk);
    }
  }


  window.$ = function(sel) {
    return document.querySelector(sel);
  }

  window.$$ = function(sel) {
    return document.querySelectorAll(sel);
  }

  function _equal(expected, actual) {
    if (expected === actual) {
      return true;
    }
    if (expected === null || actual === null) {
      return false;
    }
    if (typeof expected !== 'object' || typeof actual !== 'object') {
      return false;
    }

    if (Object.keys(expected).length != Object.keys(actual).length) {
      return false;
    }

    if (expected instanceof Node) {
      if (!(actual instanceof Node)) {
         return false;
      }
      return expected.isSameNode(actual);
    }

    for (property in expected) {
      if (actual.hasOwnProperty(property) === false) {
        return false;
      }
      if (_equal(expected[property], actual[property]) === false) {
        return false;
      }
    }

    return true;
  }

  function _moduleAsyncScripts() {
    return Array.from(document.querySelectorAll('script[type=module]:not([src])'))
      .filter((script) => script.text.includes('testing.async('));
  }

  function _moduleAsyncCount() {
    return Math.max(_moduleAsyncScripts().length, parsed_module_asyncs);
  }

  // Inline modules start in document order, so the nth testing.async() from a
  // module is the nth such script, as long as each one calls it before its
  // first other await.
  function _moduleAsyncName(n) {
    const script = _moduleAsyncScripts()[n - 1];
    return script?.id ? `module #${n} (${script.id})` : `module #${n}`;
  }

  function _registerObservation(status, opts) {
    observation_count += 1;
    const script_id = opts?.script_id || _currentScriptId();
    if (!script_id) {
      return;
    }
    if (observed_ids[script_id] === 'fail') {
      return;
    }

    observed_ids[script_id] = status;
  }

  function _currentScriptId() {
    if (current_script_id) {
      return current_script_id;
    }

    if (async_capture) {
      return async_capture.script_id;
    }

    const current_script = document.currentScript;

    if (!current_script) {
      return null;
    }
    return current_script.id;
  }

  function _displayValue(value) {
    if (value instanceof Element) {
      return `HTMLElement: ${value.outerHTML}`;
    }
    if (value instanceof Attr) {
      return `Attribute: ${value.name}: ${value.value}`;
    }
    if (value instanceof Node) {
      return value.nodeName;
    }
    if (value === window) {
      return '#window';
    }
    if (value instanceof Array) {
      return `array: \n${value.map(_displayValue).join('\n')}\n`;
    }

    const seen = [];
    return JSON.stringify(value, function(key, val) {
      if (val != null && typeof val == "object") {
          if (seen.indexOf(val) >= 0) {
              return;
          }
          seen.push(val);
      }
      return val;
    });
  }
})();
