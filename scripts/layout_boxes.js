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
//
// Text is drawn with the metrics our layout measures it with (text_measure:
// every glyph 0.6em, a space 0.33em), which a monospace face with a negative
// word-spacing matches. In Chrome's own run the text then overflows boxes
// sized for the real font: there, set SHOW_TEXT to false.
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
    const cs = getComputedStyle(el);
    boxes.set(el, {
      top: r.top + sy,
      left: r.left + sx,
      width: r.width,
      height: r.height,
      hidden: cs.display === 'none',
      inline: cs.display.startsWith('inline'),
      outOfFlow: cs.position === 'absolute' || cs.position === 'fixed',
      fontSize: parseFloat(cs.fontSize) || 16,
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
    var color = '#fff';
    const tag = el.tagName;
    if (tag == 'HTML') {
      color = '#fff';
    } else if (tag == 'BODY') {
      color = '#fff';
    } else {
      color = COLORS[depthOf(el) % COLORS.length];
    }
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
      SHOW_TEXT ? `font:${r1(box.fontSize)}px/1.2 monospace;word-spacing:-0.27em;color:#888` : 'font-size:0;color:transparent',
    ].filter(Boolean).join(';'));
  }

  // Text has no box of its own, and every element is now out of the flow, so
  // text after an element would be drawn as if that element weren't there.
  // Next to elements, start each run where our layout has it: right of the
  // inline box before it, or under the block before it, on a line that
  // doesn't wrap (see Element.lineOffset).
  if (SHOW_TEXT) {
    for (const [el, box] of boxes) {
      if (!el.isConnected || box.hidden || el.children.length === 0) continue;
      let prev = null;
      for (const node of [...el.childNodes]) {
        if (node.nodeType === 1) {
          const b = boxes.get(node);
          if (b && !b.hidden && !b.outOfFlow) prev = b;
          continue;
        }
        if (node.nodeType !== 3 || !node.data.trim()) continue;
        let top = 0;
        let left = 0;
        if (prev) {
          top = prev.top - box.top + (prev.inline ? 0 : prev.height);
          left = prev.inline ? prev.left + prev.width - box.left : 0;
        }
        const span = document.createElement('span');
        span.setAttribute('data-lp-text', '');
        span.setAttribute('style', `position:absolute;white-space:pre;top:${r1(top)}px;left:${r1(left)}px`);
        // One space where a run of them collapses, kept at the edges: it's
        // the gap to the neighbouring boxes.
        span.textContent = node.data.replace(/\s+/g, ' ');
        node.replaceWith(span);
      }
    }
  }

  return true;
})();
