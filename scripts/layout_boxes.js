// Rewrites the page into absolutely positioned boxes, one per element, at
// the position and size the browser computed. Open the result in Chrome to
// see our faux layout drawn by a real renderer.
//
// Lightpanda (layout as we compute it):
//
//   zig-out/bin/lightpanda fetch --wait-until load \
//     --wait-script-file scripts/layout_boxes.js --dump html URL > boxes.html
//
// Chrome (the reference): paste this file into the DevTools console on the
// same page, at the same window size (Lightpanda defaults to 1920x1080).
//
// Every rect is read before anything is changed, because dropping the
// stylesheets changes the layout. Elements inside shadow roots are not
// rewritten. Hover a box for its tag and numbers; data-lp-box holds them too.
(() => {
  const SHOW_TEXT = true;
  const COLORS = ['#e6194b', '#3cb44b', '#4363d8', '#f58231', '#911eb4', '#42d4f4', '#f032e6', '#000000'];

  const root = document.documentElement;
  if (!root) return false;

  const sx = window.scrollX;
  const sy = window.scrollY;
  const elements = [root, ...root.querySelectorAll('*')];

  // Read everything first, in document coordinates.
  const boxes = new Map();
  for (const el of elements) {
    const r = el.getBoundingClientRect();
    boxes.set(el, {
      top: r.top + sy,
      left: r.left + sx,
      width: r.width,
      height: r.height,
      hidden: getComputedStyle(el).display === 'none',
    });
  }

  for (const el of root.querySelectorAll('script, style, link[rel~="stylesheet"]')) {
    el.remove();
  }

  const depthOf = (el) => {
    let d = 0;
    for (let p = el.parentElement; p; p = p.parentElement) d += 1;
    return d;
  };

  const r1 = (n) => Math.round(n * 10) / 10;

  for (const [el, box] of boxes) {
    if (!el.isConnected) continue;

    // Every box is positioned, so each one is the containing block of its
    // children: offsets are relative to the parent's box.
    const parent = el.parentElement && boxes.get(el.parentElement);
    const top = box.top - (parent ? parent.top : 0);
    const left = box.left - (parent ? parent.left : 0);

    const name = el.localName
      + (el.id ? '#' + el.id : '')
      + (typeof el.className === 'string' && el.className.trim() ? '.' + el.className.trim().split(/\s+/).join('.') : '');
    const numbers = `${r1(box.left)},${r1(box.top)} ${r1(box.width)}x${r1(box.height)}`;

    for (const attr of ['src', 'srcset']) el.removeAttribute(attr);
    el.setAttribute('title', `${name} ${numbers}`);
    el.setAttribute('data-lp-box', numbers);

    // Outline instead of border: it doesn't move the children.
    const color = COLORS[depthOf(el) % COLORS.length];
    el.setAttribute('style', [
      box.hidden ? 'display:none' : '',
      'position:absolute',
      'box-sizing:border-box',
      'margin:0',
      'border:0',
      'overflow:visible',
      `top:${r1(top)}px`,
      `left:${r1(left)}px`,
      `width:${r1(box.width)}px`,
      `height:${r1(box.height)}px`,
      `outline:1px solid ${color}`,
      'outline-offset:-1px',
      'background:transparent',
      SHOW_TEXT ? 'font:10px/1.2 monospace;color:#888' : 'font-size:0;color:transparent',
    ].filter(Boolean).join(';'));
  }

  return true;
})();
