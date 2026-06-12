// Nothing imports this module, so it must never be evaluated. If it runs, the
// flag trips the assertion in modulepreload.html (and this fail() fires
// directly).
window.modulepreload_unused_ran = true;
testing.fail('an unconsumed <link rel=modulepreload> must not evaluate');
