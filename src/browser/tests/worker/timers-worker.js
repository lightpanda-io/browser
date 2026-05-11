// Exercises setTimeout / setInterval inside a WorkerGlobalScope.
// Mirrors src/browser/tests/window/timers.html.
(async function() {
  try {
    const results = {};

    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    // setTimeout: returns a number; passes extra args through; `this` is self.
    {
      let timeout_this = null;
      const sum = await new Promise((resolve) => {
        const id = setTimeout(function (a, b) {
          timeout_this = this;
          resolve(a + b);
        }, 1, 2, 3);
        results.setTimeout_id_is_number = (typeof id === 'number');
      });
      results.setTimeout_args = sum;
      results.setTimeout_this_is_self = (timeout_this === self);
      results.setTimeout_length = setTimeout.length;
    }

    // setInterval fires repeatedly; clearInterval stops it.
    // A second timer cleared before its first tick must never fire.
    {
      let count1 = 0;
      const id1 = setInterval(() => { count1 += 1; }, 1);

      let fired2 = false;
      const id2 = setInterval(() => { fired2 = true; }, 1);
      clearInterval(id2);

      results.setInterval_ids_distinct = (id1 !== id2);

      await sleep(10);
      clearInterval(id1);
      const after_clear = count1;
      await sleep(5);

      results.setInterval_fired_multiple = (after_clear >= 1);
      results.setInterval_clear_stops = (count1 === after_clear);
      results.setInterval_pre_clear_silent = !fired2;
    }

    // clearTimeout / clearInterval with bogus ids must be silent.
    {
      let threw = false;
      try {
        clearTimeout(-1);
        clearInterval(-2);
      } catch (_) { threw = true; }
      results.clear_invalid_silent = !threw;
    }

    // Legacy: setTimeout("...", n) compiles the string into a function body.
    {
      self.__st_string_ran = 0;
      const id = setTimeout("self.__st_string_ran = 42;", 1);
      results.setTimeout_string_id_is_number = (typeof id === 'number');
      await sleep(5);
      results.setTimeout_string_ran = self.__st_string_ran;
    }

    // Legacy: setInterval("...", n) compiles the string into a function body.
    {
      self.__si_string_ran = 0;
      const id = setInterval("self.__si_string_ran += 1;", 1);
      await sleep(5);
      clearInterval(id);
      results.setInterval_string_ran = (self.__si_string_ran >= 1);
    }

    // Non-function, non-string handlers must throw.
    {
      let threw = false;
      try { setTimeout(123, 1); } catch (_) { threw = true; }
      results.setTimeout_invalid_throws = threw;
    }

    postMessage({ ok: true, results });
  } catch (e) {
    postMessage({ ok: false, err: String(e), stack: e.stack });
  }
})();
