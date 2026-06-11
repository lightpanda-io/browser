// Nothing consumes this preload, so it must never be evaluated. If it runs, the
// flag trips the assertion in preload.html (and this fail() fires directly).
window.unused_preload_ran = true;
testing.fail('an unconsumed <link rel=preload as=script> must not execute');
