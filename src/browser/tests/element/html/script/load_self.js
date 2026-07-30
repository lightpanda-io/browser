// The load event is fired at the element *after* this script finishes
// executing, so a listener registered here, from inside the script itself,
// still receives it.
document.currentScript.addEventListener('load', () => {
  window.self_load += 1;
});
