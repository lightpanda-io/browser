(() => {
  let failed = false;
  let observed_ids = {};
  let eventuallies = [];
  let current_script_id = null;

  function expectTrue(actual) {
     expectEqual(true, actual);
  }

  function expectFalse(actual) {
     expectEqual(false, actual);
  }

  function expectEqual(expected, actual) {
    if (_equal(expected, actual)) {
      _registerObservation('ok');
      return;
    }
    failed = true;
    _registerObservation('fail');
    let err = `expected: ${_displayValue(expected)}, got: ${_displayValue(actual)}\n  script_id: ${_currentScriptId()}`;
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

  window.testing = {
    fail: fail,
    assertOk: assertOk,
    expectTrue: expectTrue,
    expectFalse: expectFalse,
    expectEqual: expectEqual,
    expectError: expectError,
    withError: withError,
    eventually: eventually,
    todo: function(){},
  };

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

  function _registerObservation(status) {
    const script_id = _currentScriptId();
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

    // Quickjs can deal with  cyclical objects, but browsers can't. We
    // serialize with a custom replacer so that the tests can be run in browsers.
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
