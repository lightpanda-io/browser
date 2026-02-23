(() => {
  let failed = false;
  let observed_ids = {};
  let eventuallies = [];
  let async_capture = null;
  let current_script_id = null;

  function expectTrue(actual) {
     expectEqual(true, actual);
  }

  function expectFalse(actual) {
     expectEqual(false, actual);
  }

  function expectEqual(expected, actual, opts) {
    if (_equal(expected, actual)) {
      _registerObservation('ok', opts);
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
    failed = true;
    console.error(reason);
    throw new Error('testing.fail()');
  }

  function expectError(expected, fn) {
    withError((err) => {
      expectEqual(true, err.toString().includes(expected));
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

  function eventually(cb) {
    const script_id = _currentScriptId();
    if (!script_id) {
      throw new Error('testing.eventually called outside of a script');
    }
    eventuallies.push({
      callback: cb,
      script_id: script_id,
    });
  }

  async function async(cb) {
    let capture = {script_id: document.currentScript.id, stack: new Error().stack};
    await cb(() => { async_capture = capture; });
    async_capture = null;
  }

  function assertOk() {
    if (failed) {
      throw new Error('Failed');
    }

    for (let e of eventuallies) {
      current_script_id = e.script_id;
      e.callback();
      current_script_id = null;
    }

    const script_ids = Object.keys(observed_ids);
    if (script_ids.length === 0) {
      throw new Error('no test observations were recorded');
    }

    const scripts = document.getElementsByTagName('script');
    for (let script of scripts) {
      const script_id = script.id;
      if (!script_id) {
        continue;
      }

      const status = observed_ids[script_id];
      if (status !== 'ok') {
         throw new Error(`script id: '${script_id}' failed: ${status || 'no assertions'}`);
      }
    }
  }

  // our test runner sets this to true
  const IS_TEST_RUNNER = window._lightpanda_skip_auto_assert === true;

  window.testing = {
    fail: fail,
    async: async,
    assertOk: assertOk,
    expectTrue: expectTrue,
    expectFalse: expectFalse,
    expectEqual: expectEqual,
    expectError: expectError,
    withError: withError,
    eventually: eventually,
    IS_TEST_RUNNER: IS_TEST_RUNNER,
    HOST: '127.0.0.1',
    ORIGIN: 'http://127.0.0.1:9582/',
    BASE_URL: 'http://127.0.0.1:9582/src/browser/tests/',
  };

  if (!IS_TEST_RUNNER) {
    // The page is running in a different browser. Probably a developer making sure
    // a test is correct. There are a few tweaks we need to do to make this a
    // seemless, namely around adapting paths/urls.
    console.warn(`The page is not being executed in the test runner, certain behavior has been adjusted`);
    window.testing.HOST = location.hostname;
    window.testing.ORIGIN = location.origin + '/';
    window.testing.BASE_URL = location.origin + '/src/browser/tests/';
    window.addEventListener('load', testing.assertOk);
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

  function _registerObservation(status, opts) {
    script_id = opts?.script_id || _currentScriptId();
    if (!script_id) {
      return;
    }
    if (observed_ids[script_id] === 'fail') {
      return;
    }

    observed_ids[script_id] = status;

    if (document.currentScript != null) {
      if (document.currentScript.onerror === null) {
        document.currentScript.onerror = function() {
          observed_ids[document.currentScript.id] = 'fail';
          failed = true;
        }
      }
    }
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
