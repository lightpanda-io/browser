# Full Browser Master Tracker

This tracker defines the path from the current experimental Lightpanda fork to
a production-ready minimalist Zig browser for real daily use. The target is not
full Chrome parity in every area. The target is a fast, installable,
user-facing browser that can browse the modern web reliably and ship most core
features users expect from Chrome-class browsing.

## Product Target

The production bar for this fork is:

- open and use most common real-world sites without falling back to CDP only
- provide a stable headed browser UX with tabs, address bar, history, reload,
  stop, downloads, settings, and session persistence
- render modern HTML/CSS/JS content with acceptable fidelity for mainstream
  browsing
- support core Chrome-like daily-use features: multi-tab browsing, persistent
  profile, cookies/storage, TLS, uploads/downloads, autofill-adjacent form
  usability, screenshots, clipboard, find-in-page, and crash recovery
- preserve headless and CDP strengths as secondary product modes, not the main
  product definition

## Non-Goals For First Production Cut

These are explicitly out of scope for the first production-ready release unless
they become necessary for site compatibility:

- Chrome extension ecosystem compatibility
- Google account sync or cloud profile sync
- full Chrome DevTools parity
- multi-process sandbox parity with Chrome

## Current Baseline

The fork already has a real headed Windows foundation:

- Windows/MSVC build is stable
- `browse` runs in a native Win32 window
- address bar navigation works
- back, forward, reload, and stop browser chrome works
- stop restores the last committed live page/context
- wrapped-link click navigation works
- screenshots/export are wired through the headed presentation surface
- raster `<img>` rendering works for common sources used by the probes
- focus/autofocus/input bootstrap is working in headed mode
- label activation and `Enter` form submit basics work
- bounded localhost smoke probes exist for navigation, history, reload, stop,
  wrapped links, and form interactions
- native tab strip, reopen-closed-tab, and session restore are working in the
  headed shell
- native overlays exist for history, bookmarks, downloads, and basic settings
- headed `browse` now has zoom controls, find-in-page, bookmark persistence,
  download persistence, homepage navigation, and persisted default zoom /
  restore-session settings
- headed `browse` now has a persisted script-popup policy with Win32 settings
  UI, blocked-runtime coverage, and allowed/blocked script popup acceptance
- internal `browser://history`, `browser://bookmarks`, `browser://downloads`,
  `browser://settings`, and `browser://tabs` pages now support stateful
  actions, not just static snapshots
- those internal history, bookmark, and download pages now keep per-tab sort
  state, expose in-page sort controls, and refresh titles/counts plus row order
  live as the sort mode changes
- the normal headed shell shortcuts now target internal browser pages first,
  while the legacy overlays are secondary diagnostic surfaces
- the headed painter now keeps direct paragraph text in the same inline flow as
  inline child chips and links for the current simple mixed-inline path,
  instead of splitting the paragraph into a separate text band above the inline
  controls
- invalid or unsupported selector syntax in page JS and stylesheet matching no
  longer tears down headed mode; selector syntax errors now stay in-page as JS
  failures while invalid stylesheet selectors are skipped safely
- headed JS microtask checkpoints now run inside the target context with a real
  V8 handle scope, removing the clean Google startup `HandleScope::CreateHandle`
  fatal seen during Promise-heavy page initialization repros
- the first real CSS/layout compatibility slice is in place for headed
  documents: `min(...)`, `max(...)`, `clamp(...)`, `%`, `vw`, and `vh` lengths;
  block auto-margin centering; flex-column centering; centered inline child
  flow for `text-align:center`; and absolute out-of-flow positioning, with
  focused painter tests plus bounded headed runtime probes for microtask
  containment, centered flex hero layout, and absolute corner docking

## Achieved Gates

### Gate A: Windows Headed Foundation

Status: Achieved

- native headed window lifecycle
- native input translation and text editing baseline
- `browse` command path
- Windows runtime stabilization and smoke probes

### Gate B: Headed Browser Interaction MVP

Status: Achieved

- address bar navigation
- back/forward/reload/stop chrome
- wrapped-link hit testing and navigation
- live page restore after stop

### Gate C: Shared Presentation Surface

Status: Achieved

- display-list based headed presentation path
- screenshot/export on the same presentation path
- basic text, box, link, and image presentation

### Gate D: Basic Form/Input Reliability

Status: Achieved

- autofocus and initial typing
- label activation
- `Enter` submit path
- stable Windows `SendInput`-driven headed probes

## Remaining Gates

### Gate 1: Browser Shell MVP

Status: Active next milestone

Goal:
- turn the current single-page headed shell into a minimal real browser shell

Exit criteria:
- tab strip with open, close, switch, duplicate, and reopen closed tab
- new-window and basic popup/window handling policy
- visible loading/error states and disabled chrome state where applicable
- history UI, bookmarks UI, downloads UI, and basic settings UI
- find-in-page and zoom controls

Current state inside Gate 1:
- tabs now cover open, close, switch, duplicate, reopen, and clean session restore
- history, bookmarks, downloads, settings, find, and zoom are present in the
  headed shell
- disabled close-state for the single remaining tab is implemented
- rendered `_blank` anchor popups now open in a new tab through the native
  headed surface
- form-driven `_blank` submission now reaches a stable headed new-tab flow
- script-driven `window.open()` now reaches stable headed `_blank` and
  named-target tab flows, and later launcher-page callbacks remain alive after
  popup activation
- script popup policy now covers allowed vs blocked `window.open()` behavior,
  with persisted settings and headed Win32 shell controls
- browser-side named-target queueing/reuse is now implemented for anchors and
  form submission, with direct page/session tests covering anchor click, anchor
  `Enter`, and GET/POST form submission
- bounded headed probes remain the acceptance gate for `_blank` popup flows,
  rendered named-target anchor pointer activation, script popup tab reuse, and
  launcher-background callback survival after popup open
- bounded headed probes now also cover popup policy persistence through the
  settings overlay and blocked script-popup runtime behavior
- rendered same-tab link activation now dispatches a real DOM click first, so
  `onclick`, `preventDefault`, and click-time href mutation are preserved on the
  headed surface before any direct navigation fallback
- dedicated internal browser pages now exist for history, bookmarks, downloads,
  settings, and tabs, backed by current session state or the persisted stores
  already in place
- those browser pages are reachable through both native headed shortcuts and
  `browser://start`, `browser://tabs`, `browser://history`,
  `browser://bookmarks`, `browser://downloads`, and `browser://settings`
  address-bar aliases
- those browser pages now execute real internal actions:
  - tab new, activate, duplicate, reload, close, and reopen-closed flows
    through `browser://tabs/...`
  - history traverse, reload-safe reopen, and clear-session collapse
  - bookmark add-current, open, and remove backed by the persisted bookmark
    store
  - download source, remove, and clear-inactive backed by the persisted
    download store
  - settings toggles for restore-session, script popups, default zoom, and
    homepage mutation
  - homepage navigation to an internal page plus restart-time restore of the
    internal page in the session model
- the standard shell shortcuts now open those internal pages directly:
  - `Ctrl+Shift+A` tabs
  - `Ctrl+H` history
  - `Ctrl+Shift+B` bookmarks
  - `Ctrl+J` downloads
  - `Ctrl+,` settings
- the internal pages now include a shared shell header/nav plus a
  `browser://start` hub page, and `Alt+Home` falls back to that start page when
  no homepage is configured
- bounded headed browser-page probes now cover:
  - history, bookmarks, downloads, and settings actions
  - bookmark add-current, history clear-session, and download clear-all flows
  - start-page cross-navigation
  - `browser://start` quick actions and settings-summary mutations through
    in-page document actions, not only address-bar routes
  - `browser://start` recent history/bookmark/download preview actions through
    in-page document actions
  - tabs-page tab-management actions and reload/reopen recovery
  - `browser://tabs` indexed closed-tab reopen through in-page document actions
  - homepage-to-internal-page restart restore
- legacy overlays are still available for diagnostics on secondary shortcuts,
  but they are no longer the primary shell path
- internal page titles now stay user-facing across active presentation,
  background tab state, restart restore, and the zero-count downloads case
- headed navigation failures now promote into a structured `browser://error`
  page instead of a raw placeholder document
- that error state now remains visible across `browser://start` and
  `browser://tabs`, with bounded headed probes for invalid-address handling,
  disabled back/forward chrome on error, error-state preservation, and
  recovery once the target becomes reachable again
- `browser://history`, `browser://bookmarks`, and `browser://downloads` now
  keep live per-tab filter state, support internal `filter/...` and
  `filter-clear` routes, expose quick-filter links directly on the page, and
  have bounded headed probes for quick-filter plus clear-filter document
  actions
- those same internal history/bookmark/download pages now expose explicit
  per-row open-in-new-tab actions, with bounded headed probes proving the new
  tab opens while the originating internal page tab remains intact
- those same internal history/bookmark/download pages now also keep per-tab
  sort state, support internal `sort/...` routes, expose in-page sort controls,
  and have bounded headed probes for sort changes plus sorted row actions
- `browser://history` now also supports in-page single-entry removal plus
  safe `remove-before` / `remove-after` pruning that preserves the current live
  page, with bounded headed probes for single-remove and both prune directions
- `browser://bookmarks` now supports persisted in-page reorder actions in saved
  order mode, and `browser://downloads` now supports in-place retry of failed
  and interrupted entries with bounded headed document-action coverage
- `browser://bookmarks` now also supports opening all currently visible
  bookmark rows in new background tabs based on the page's active filter and
  sort state, with a bounded headed probe proving the filtered bookmarks page
  stays active while the visible bookmark targets open in saved-order
- `browser://downloads` now also supports native shell actions for completed
  entries, including `Open file`, `Reveal file`, and `Open downloads folder`,
  with bounded headed probes proving each action fires while the originating
  downloads page remains active
- headed `browse` tabs now share one persistent cookie jar instead of keeping
  cookie state session-local per tab, and that cookie jar now survives browser
  restart and can be cleared from `browser://settings`, with bounded same-tab,
  cross-tab, restart, and clear-cookies headed probes
- headed `browse` tabs now also share one persistent origin-scoped
  `localStorage` shed across tabs and browser restart, and that storage can be
  cleared from `browser://settings`, with bounded cross-tab, restart, and
  clear-local-storage headed probes
- that same headed `localStorage` path now also dispatches real cross-tab
  `storage` events through `window.onstorage` and `StorageEvent`, with a
  bounded headed probe proving a listener tab receives the event after a
  sibling tab mutates `localStorage` and both tabs remain alive afterward
- headed `browse` tabs now also keep real per-tab `sessionStorage` state that
  survives same-tab navigation but does not leak across tabs or browser
  restart, with bounded same-tab, cross-tab, and restart headed probes
- headed `browse` tabs now also share one persistent origin-scoped IndexedDB
  shed across tabs and browser restart, and that storage can be cleared from
  `browser://settings`, with bounded cross-tab, restart, and clear-IndexedDB
  headed probes
- that same headed IndexedDB path now also keeps basic object-store index
  definitions and indexed lookups persistent across tabs and browser restart,
  with focused DOM tests plus a bounded headed probe proving indexed entries
  survive restart and can still be read back by index name and key
- that same headed IndexedDB path now also supports object-store and index
  cursor iteration, with focused DOM tests plus a bounded headed cross-tab
  probe proving seeded cursor rows can be read back in sorted order from a
  sibling tab through both `objectStore.openCursor()` and `index.openCursor()`
- that same headed IndexedDB path now also exposes real transaction `mode`
  state on the JS surface for `readonly` vs `readwrite` single-store
  transactions, with focused DOM coverage plus a bounded headed probe proving
  page JS can observe the expected mode values before a successful write
- headed `fetch(...)` now honors credentials policy correctly on authenticated
  pages, with bounded localhost probes proving:
  - default same-origin fetch keeps cookie plus inherited auth
  - `credentials: 'omit'` suppresses both cookie and auth
  - cross-origin `same-origin` suppresses credentials
  - cross-origin `include` sends cookies but not inherited auth
- headed `Request` and `fetch(...)` now also honor `AbortSignal`, with focused
  DOM tests proving `Request.signal` cloning plus immediate-abort rejection,
  and a bounded headed probe proving an in-flight slow fetch aborts at runtime
  with `AbortError` while the server observes the connection being cut
- root `Content-Disposition: attachment` navigations now promote into the
  headed download manager instead of degrading into navigation errors:
  address-bar navigations, in-page link activations, and direct startup URLs
  all enqueue real downloads, restore the suspended page when one exists, and
  fall back to `browser://downloads` when there is no live page to restore
- those same root attachment navigations now adopt the original response stream
  directly into the headed download manager instead of aborting and issuing a
  second GET, with bounded headed probes proving a single request for
  address-bar, in-page link, and direct-startup attachment flows
- headed Windows `browse` now has a native file chooser path for rendered file
  inputs, including multi-select file inputs, plus real multipart form
  submission with selected files and bounded headed probes for single-file
  select-submit, cancel, replace, and multi-file submit flows
- that same Win32 chooser path now derives native dialog file filters from
  common `accept` hints (extensions plus common MIME and wildcard families)
  instead of ignoring `accept` entirely, with focused helper coverage and full
  headed upload regression sweeps
- those same headed upload flows now compose cleanly with named popup targets
  and attachment responses: bounded probes cover target-tab multipart upload,
  same-context upload-to-attachment with restored source page plus downloads
  page visibility, and target-tab upload-to-attachment with both managed
  download capture and source-tab preservation
- headed network image requests in the Win32 renderer now use the shared
  browser `Http` runtime when available instead of the old URLMon-only path,
  with a bounded localhost probe proving the image request carries
  `User-Agent: Lightpanda/1.0` and renders successfully on the headed surface
- those same headed network image requests now inherit page/session request
  policy for cookies and referer, with a bounded localhost probe proving the
  image request carries both the page cookie and the active page referer while
  still rendering successfully on the headed surface
- those same headed network image requests now also carry redirect-set cookies
  through the shared `Http` runtime path, with a bounded localhost redirect
  probe proving the final image request sends both the original page cookie and
  the cookie set on the 302 hop before the image is rendered on the headed
  surface
- those same headed network image requests now distinguish credentialed and
  anonymous fetch policy, with bounded localhost probes proving a credentialed
  auth image still carries page cookie, referer, and URL-userinfo Basic
  `Authorization`, while `crossorigin="anonymous"` suppresses both cookie and
  auth header and still renders successfully on the headed surface
- those same headed network image requests now identify themselves more like
  real image subresources instead of generic fetches, with a bounded localhost
  probe proving the shared-runtime request carries an explicit image `Accept`
  header while still rendering successfully on the headed surface
- same-origin protected subresources now inherit page-URL Basic auth on the
  shared request-policy path without leaking URL userinfo through `Referer`,
  with bounded localhost probes proving a relative headed image request and an
  external script request both carry inherited auth, sanitized referer,
  cookies, and that the authorized script actually executes afterward
- those same connected external scripts now also distinguish credentialed vs
  anonymous fetch policy, with bounded localhost probes proving a credentialed
  script still carries cookie, sanitized referer, inherited auth, and executes
  successfully, while `crossorigin="anonymous"` suppresses both cookie and
  auth on the script request itself and still executes successfully on the
  headed surface
- connected external module scripts now ride the same shared request-policy
  path for both root and child imports, with bounded localhost probes proving
  credentialed and anonymous static module graphs carry the correct
  cookie/referer/auth policy on both the root request and the child request,
  and that the module graph executes successfully on the headed surface
- connected `link rel=stylesheet` elements now load through the shared browser
  `Http` runtime path, expose `link.sheet`, participate in
  `document.styleSheets`, and carry page cookie, sanitized referer, inherited
  auth, and an explicit stylesheet `Accept` header on protected same-origin
  loads, with a bounded headed localhost probe proving the stylesheet request
  succeeds and the page observes both `link.sheet` and stylesheet load
  completion
- those same connected external stylesheets now also distinguish credentialed
  vs anonymous fetch policy, with a bounded headed localhost probe proving
  `crossorigin="anonymous"` suppresses both cookie and auth while preserving
  sanitized referer, stylesheet `Accept`, successful stylesheet load, and
  computed-style application on the headed surface
- those same connected internal and external stylesheets now populate
  `cssRules` and feed the current `getComputedStyle` / headed painter path for
  simple authored rules, with bounded tests and a headed localhost probe
  proving a protected external stylesheet changes the computed page background
  instead of only firing `load`
- those same connected external stylesheet `@import` graphs now carry the
  correct protected vs anonymous request policy on both the root stylesheet
  request and the imported child stylesheet request, with bounded headed
  localhost probes proving imported styles apply successfully in both modes
- simple `@font-face` parsing and shared-runtime font fetches now ride that
  same stylesheet-driven path, with `document.fonts` exposing loaded faces by
  `size`, `status`, `check(...)`, and `load(...)`, and bounded headed
  localhost probes proving protected and anonymous font requests carry the
  correct cookie, sanitized referer, auth suppression or inheritance, explicit
  font `Accept`, and loaded page state on the headed surface
- headed Win32 text rendering now carries authored `font-family`,
  `font-weight`, and `font-style` through the display list into real GDI font
  selection for installed fonts, with a bounded screenshot probe proving the
  headed surface produces materially different glyph widths for authored font
  runs instead of always falling back to one generic face
- those same stylesheet-backed `@font-face` entries now retain supported TTF
  and OTF bytes, flow through the shared display-list presentation path, and
  register as private Win32 fonts for headed text rendering, with a bounded
  two-page localhost screenshot probe proving the same authored family renders
  with materially different glyph widths when the private font is present vs
  when the font URL is missing
- those same private stylesheet-backed font flows now parse multi-source
  `src:` lists with format hints and prefer a later renderable TTF/OTF
  fallback over an earlier unsupported WOFF/WOFF2 source when present, with a
  bounded headed screenshot probe proving a later truetype fallback still
  affects the surface after an earlier missing `woff2` source
- on-screen and offscreen canvas 2D contexts now keep real RGBA backing
  stores for `fillRect`, `clearRect`, `strokeRect`, `getImageData`, and
  `putImageData`, and headed Win32 `browse` now renders those canvas pixels on
  the shared display-list path with a bounded screenshot probe proving the
  rendered border, composited fill, and cleared interior
- those same on-screen and offscreen canvas 2D contexts now also keep real
  text state plus Win32-backed `fillText(...)` and `strokeText(...)`, with
  focused DOM tests and a bounded headed screenshot probe proving red filled
  and blue stroked glyph pixels reach the real destination canvas surface
- those same canvas text paths now also expose real `measureText(...)`
  `TextMetrics` objects backed by the same Win32 measurement path, with
  focused DOM tests plus a bounded headed screenshot probe proving JS-sized
  red and blue bars differ on the real surface when authored fonts differ
- those same on-screen and offscreen canvas 2D contexts now also support a
  first real `drawImage(...)` slice for `HTMLCanvasElement` and
  `OffscreenCanvas` sources, including direct copy, simple scaling, and
  source-rect cropping, with focused DOM tests plus a bounded headed Win32
  screenshot probe proving copied red, blue, and green source pixels reach the
  real destination canvas surface
- those same on-screen and offscreen canvas 2D contexts now also support
  `drawImage(HTMLImageElement, ...)`, with focused DOM tests plus a bounded
  headed Win32 screenshot probe proving decoded red and cropped blue image
  pixels reach the real destination canvas surface
- those same canvas 2D contexts now also support a first real path slice for
  `beginPath`, `moveTo`, `lineTo`, `rect`, `fill`, and `stroke`, with focused
  DOM tests plus a bounded headed Win32 screenshot probe proving filled green
  regions and blue stroke segments reach the real destination canvas surface
- the headed Win32 canvas path now also includes a first real `webgl`
  rendering-context slice for `clearColor(...)` plus `clear(COLOR_BUFFER_BIT)`,
  with focused DOM tests plus a bounded headed Win32 screenshot probe proving a
  full `120x80` clear-colored canvas region reaches the real destination
  surface
- that same headed Win32 `webgl` slice now also has a bounded runtime quality
  gate for `drawingBufferWidth` / `drawingBufferHeight`, proving resized WebGL
  buffer dimensions remain visible to page JS while a clear-colored surface
  still reaches the headed screenshot path
- that same headed Win32 `webgl` path now also includes a first real
  shader/program/buffer draw slice for `createShader`, `shaderSource`,
  `compileShader`, `createProgram`, `attachShader`, `linkProgram`,
  `createBuffer`, `bufferData`, `vertexAttribPointer`, and
  `drawArrays(TRIANGLES, ...)`, with focused DOM tests plus a bounded headed
  screenshot probe proving a red triangle reaches the real destination canvas
  surface
- that same headed Win32 `webgl` path now also supports a first indexed-draw
  and uniform-color slice for `getUniformLocation`, `uniform4f`,
  `ELEMENT_ARRAY_BUFFER`, and `drawElements(TRIANGLES, ..., UNSIGNED_SHORT, ...)`,
  with bounded headed screenshot coverage proving a uniform-colored indexed
  triangle reaches the real destination canvas surface
- that same headed Win32 `webgl` path now also supports a first varying-color
  attribute slice with two enabled vertex attributes, interpolated per-vertex
  color fill, and bounded headed screenshot coverage proving red, green, and
  blue regions reach the real destination canvas surface from one triangle
- the headed browser runtime now also exposes a first real `WebSocket`
  browser-API slice with `CONNECTING` -> `OPEN` -> `CLOSED` state transitions,
  `send`, `close`, `onopen`, `onmessage`, `onerror`, and `onclose`, with a
  focused localhost DOM test plus a bounded headed echo probe proving text
  frames round-trip on the live headed surface path
- that same headed `WebSocket` runtime now also covers binary echo plus richer
  close semantics through `binaryType`, binary `message` payloads, and
  `CloseEvent` `code` / `reason` / `wasClean`, with a bounded headed localhost
  probe proving binary frames round-trip and server-initiated close details
  reach page JS on the live headed surface path
- that same headed `WebSocket` runtime now also covers client-requested
  subprotocol negotiation plus surfaced negotiated extensions, with a bounded
  headed localhost probe proving a requested protocol list yields negotiated
  `protocol === "superchat"`, `extensions === "permessage-test"`, binary
  echo still works, and a clean client close reaches page JS correctly
- the current headed painter now also keeps simple block paragraphs with mixed
  direct text plus inline child elements on one shared inline row instead of
  splitting the direct text into a separate label band above the inline chips,
  with a bounded headed screenshot probe proving left-side paragraph text and
  inline chips share the same content row
- that same mixed-inline painter path now also keeps narrow wrapped mixed
  inline paragraphs in one shared flow across multiple rows and treats `<br>`
  as a real line break inside that flow, with bounded headed screenshot probes
  proving wrapped chips/text stay in one content flow and the following
  paragraph remains below the wrapped or broken inline content
- wrapped mixed-inline anchors now also have bounded headed click coverage on a
  lower wrapped fragment row, proving the lower-row link fragment still
  navigates correctly after the inline-flow and wrapping changes
- that same mixed-inline interaction coverage now also includes `<br>`-split
  inline links and longer wrapped anchors with multiple later fragments, with
  bounded headed probes proving navigation still works from those later visual
  fragments instead of only from the first row
- that same mixed-inline headed interaction path now also covers later-row
  controls, with bounded probes proving a wrapped inline button still
  activates from its lower row and a `<br>`-split inline text input still
  focuses and accepts typed text from the later row on the headed surface
- that same later-row mixed-inline control path now also keeps keyboard
  behavior after focus, with bounded probes proving a wrapped inline button
  can be re-activated with `Space` and a `<br>`-split inline text input can
  submit its form on `Enter` from the headed surface
- mixed control/link coexistence is now covered too, with bounded probes
  proving a wrapped later-row button and a lower later-row link remain
  independently usable in the same paragraph by both direct click and
  button-focus `Tab` then `Enter` traversal
- dense mixed-inline traversal is now covered as well, with a bounded probe
  proving one wrapped paragraph can hand off focus from a later-row button to
  a later-row input and then to a later-row link through `Tab` progression
  while each target still performs its real headed action
- that same mixed-inline later-row interaction coverage now also includes
  checkbox/link coexistence, with a bounded probe proving a wrapped later-row
  checkbox can be toggled by click and `Space`, and that `Tab` then `Enter`
  still reaches and activates a later-row link in the same paragraph
- that same mixed-inline later-row control coverage now also includes dense
  checkbox/button/link coexistence, with a bounded probe proving one wrapped
  paragraph can handle later-row checkbox click activation, later-row button
  click activation, and then `Tab`/`Enter` traversal into a later-row link
- that same later-row mixed-inline selection path now also includes radio/link
  coexistence, with a bounded probe proving a wrapped later-row radio can be
  selected by click and that `Tab` then `Enter` still reaches and activates a
  later-row link in the same paragraph
- that same dense later-row mixed-inline control coverage now also includes
  radio/button/link coexistence, with a bounded probe proving one wrapped
  paragraph can handle later-row radio click selection, later-row button click
  activation, and then `Tab`/`Enter` traversal into a later-row link
- that same dense later-row mixed-inline control coverage now also includes one
  wrapped paragraph containing later-row checkbox, radio, button, and link
  targets together, with a bounded probe proving click activation on the
  checkbox, `Tab`+`Space` activation on the later-row radio and button, and
  `Tab`+`Enter` traversal into the later-row link in DOM order
- that same dense later-row mixed-inline control coverage now also includes a
  wrapped same-family radio pair plus later-row button and link, with a
  bounded probe proving click activation on the first radio, `Tab`+`Space`
  selection of the second radio in the same group, then `Tab`+`Space` button
  activation and `Tab`+`Enter` link navigation in DOM order
- that same dense later-row mixed-inline control coverage now also includes a
  wrapped same-family checkbox pair plus later-row button and link, with a
  bounded probe proving click activation on the first checkbox, `Tab`+`Space`
  activation on the second checkbox, then `Tab`+`Space` button activation and
  `Tab`+`Enter` link navigation in DOM order
- that same later-row mixed-inline same-family checkbox coverage now also
  includes a wrapped form paragraph with a later-row submit control, with a
  bounded probe proving click activation on the first checkbox, `Tab`+`Space`
  activation on the second checkbox, and `Tab`+`Space` submission through the
  real headed form-submit path
- that same later-row mixed-inline same-family radio coverage now also
  includes a wrapped form paragraph with a later-row submit control, with a
  bounded probe proving click activation on the first radio, `Tab`+`Space`
  selection of the second radio in the same group, and `Tab`+`Space`
  submission through the real headed form-submit path
- that same later-row mixed-inline same-family checkbox coverage now also
  includes a wrapped form paragraph with a later-row text input before the
  submit control, with a bounded probe proving click activation on the first
  checkbox, `Tab`+`Space` activation on the second checkbox, `Tab`-driven text
  entry into the later-row input, and `Tab`+`Space` submission through the
  real headed form-submit path
- that same later-row mixed-inline same-family radio coverage now also
  includes a wrapped form paragraph with a later-row text input before the
  submit control, with a bounded probe proving click activation on the first
  radio, `Tab`+`Space` selection of the second radio in the same group,
  `Tab`-driven text entry into the later-row input, and `Tab`+`Space`
  submission through the real headed form-submit path
- that same later-row mixed-inline form coverage now also includes a wrapped
  mixed-family paragraph where checkbox, radio, text input, and submit coexist
  in DOM order, with a bounded probe proving click activation on the checkbox,
  `Tab`+`Space` activation on the later-row radio, typed input on the later-row
  text field, and `Tab`+`Space` submission through the real headed form-submit
  path
- that same later-row mixed-inline form coverage now also includes a denser
  wrapped mixed-family paragraph where a checkbox pair, a radio pair, text
  input, and submit coexist in DOM order, with a bounded probe proving click
  activation on the first checkbox, `Tab`+`Space` activation on the second
  checkbox, first radio, and second radio, then typed input and real headed
  form submission through the later-row submit control
- that same later-row mixed-inline form coverage now also includes a further
  dense wrapped mixed-family paragraph where a checkbox pair, a radio pair,
  two text inputs, and submit coexist in DOM order, with a bounded probe
  proving click activation on the first checkbox, `Tab`+`Space` activation on
  the second checkbox, first radio, and second radio, then typed input through
  both later-row text fields before real headed form submission through the
  later-row submit control
- that same later-row mixed-inline form coverage now also includes submit/link
  coexistence after those dense controls, with bounded probes proving the same
  wrapped paragraph can either reach a later-row link and navigate or continue
  past that link to a later-row submit control and complete a real headed form
  submission
- that same later-row mixed-inline form coverage now also includes two distinct
  later-row link targets before a later-row submit control, with bounded
  probes proving the same dense wrapped paragraph can independently reach the
  first link, reach the second link, or continue past both links to the later-
  row submit control and complete a real headed form submission
- that same later-row mixed-inline form coverage now also includes three
  distinct later-row link targets before a later-row submit control, with
  bounded probes proving the same dense wrapped paragraph can independently
  reach the first link, second link, or third link, or continue past all three
  links to the later-row submit control and complete a real headed form
  submission
- that same later-row mixed-inline form coverage now also includes four
  distinct later-row link targets before a later-row submit control, with
  bounded probes proving the same dense wrapped paragraph can independently
  reach the first, second, third, or fourth link, or continue past all four
  links to the later-row submit control and complete a real headed form
  submission
- that same later-row mixed-inline form coverage now also includes five
  distinct later-row link targets before a later-row submit control, with
  bounded probes proving the same dense wrapped paragraph can independently
  reach the first, second, third, fourth, or fifth link, or continue past all
  five links to the later-row submit control and complete a real headed form
  submission
- that same later-row mixed-inline form coverage now also includes six
  distinct later-row link targets before a later-row submit control, with
  bounded probes proving the same dense wrapped paragraph can independently
  reach the first, second, third, fourth, fifth, or sixth link, or continue
  past all six links to the later-row submit control and complete a real
  headed form submission
- that same later-row mixed-inline form coverage now also includes seven
  distinct later-row link targets before a later-row submit control, with
  bounded probes proving the same dense wrapped paragraph can independently
  reach the first, second, third, fourth, fifth, sixth, or seventh link, or
  continue past all seven links to the later-row submit control and complete a
  real headed form submission
- that same later-row mixed-inline form coverage now also includes eight
  distinct later-row link targets before a later-row submit control, with
  bounded probes proving the same dense wrapped paragraph can independently
  reach the first, second, third, fourth, fifth, sixth, seventh, or eighth
  link, or continue past all eight links to the later-row submit control and
  complete a real headed form submission
- next blocker: keep turning internal pages into richer live shell surfaces so
  fewer browser-shell flows still depend on address-bar routes or secondary
  overlay surfaces

### Gate 2: Shared Subresource Loader And Profile

Status: Active

Goal:
- move page assets and browser state onto a consistent browser-managed runtime

Exit criteria:
- images, connected stylesheets, scripts, fonts, and other subresources use the shared browser
  network/client path
- cookies, cache, auth, proxy, redirects, uploads, downloads, and persistent
  profile storage behave consistently
- file chooser and download manager flows exist
- same-origin, CORS, CSP, mixed-content, and certificate error behavior are
  coherent enough for mainstream browsing

Current known gap entering Gate 2:
- explicit download requests, adopted root-attachment transfers, and other
  browser-managed resource flows still do not share one unified runtime path
  for transfer ownership, persistence, and policy
- headed `browse` now has one shared persistent cookie jar, origin-scoped
  `localStorage` store, and origin-scoped IndexedDB store across tabs and
  restart, with settings clear paths for all three, but broader persisted
  profile state is still thin: cache policy and stronger profile persistence
  beyond cookies/storage are still open
- headed network images now ride the shared `Http` runtime path and inherit
  page/session cookies, sanitized referer, redirect-set cookies, URL-userinfo
  Basic Authorization, same-origin page-URL Basic auth inheritance, anonymous
  credential suppression, and an explicit image `Accept` header, but broader
  auth beyond page-URL Basic credentials and richer resource-type behavior are
  still open
- connected external scripts and static module imports now ride the shared
  `Http` runtime path with inherited auth, sanitized referer, cookie policy,
  explicit script `Accept`, and anonymous credential suppression coverage, but
  broader script/resource parity and one unified subresource ownership path
  are still open
- connected `link rel=stylesheet` requests now ride the same shared `Http`
  runtime path with `link.sheet` / `document.styleSheets` coverage and bounded
  protected-load auth/cookie/referer/`Accept` verification plus anonymous
  credential suppression, stylesheet body application now exists for the
  current simple authored-rule path, and imported child stylesheets now keep
  the same protected vs anonymous policy as the root request; stylesheet-
  backed `@font-face` fetches and `document.fonts` now ride that same path,
  and headed Win32 text rendering now honors both authored installed-font
  family/style/weight and private TTF/OTF plus WOFF/WOFF2 stylesheet-backed
  `@font-face` rendering on the surface, including later renderable
  fallbacks in multi-source `src:` lists, but broader CSS fidelity, real
  text shaping, wider font-format parity beyond WOFF/WOFF2, script/font/
  resource parity, and one unified subresource ownership path are still open;
  the current headed painter now also uses measured Win32 text extents
  instead of pure character-count heuristics for text runs and inline/button
  width decisions
- native file chooser, multi-select file inputs, and multipart upload flows
  now work end to end in headed Windows `browse`, but upload transport still
  needs to converge with the same broader shared runtime/policy path as other
  browser-managed resources
- popup-target and attachment-response upload combinations are now runtime-
  covered; the remaining work is less about basic composition and more about
  converging those flows with the same broader shared transfer/runtime policy

### Gate 3: Layout Engine Replacement

Status: Active

Goal:
- replace the remaining dummy and heuristic layout paths with a real layout
  engine

Exit criteria:
- block and inline formatting contexts behave predictably
- flexbox support is usable on common sites
- positioning, overflow, fixed/sticky basics, margin/padding/border handling,
  and intrinsic sizing are implemented
- form controls and replaced elements layout correctly in normal documents

Current state inside Gate 3:
- the first compatibility slice is landed for common real-site layout pressure:
  safer selector failure containment, length resolution for `%`/`vw`/`vh` plus
  `min(...)`/`max(...)`/`clamp(...)`, auto-margin centering, flex-column
  centering, centered inline child flow, and absolute corner positioning
- that same slice now also covers a first row-direction flex path with wrap,
  `justify-content` spacing, and `align-items` vertical placement for common
  chip/button-style rows, plus selector compatibility for `:lang(...)`,
  `:dir(...)`, `:open`, and vendor `:-webkit-any-link` / `:-moz-any-link`
- headed screenshot export now waits for a real painted presentation instead of
  consuming the one-shot capture on the initial root placeholder frame, with a
  bounded delayed-content probe proving async timer-driven page content reaches
  the exported PNG
- bounded headed probes now prove:
  - Promise-microtask selector failures no longer kill the headed browser
  - centered hero-style flex layouts reach the real Win32 surface
  - absolute left/right corner docking plus later normal flow reach the real
    Win32 surface
  - centered wrapped flex-row content reaches the real Win32 surface across
    multiple lines
  - delayed timer-driven content is present in the screenshot export path
- the remaining gap is still large: this is a pragmatic compatibility slice,
  not a full layout engine

### Gate 4: Paint, Text, And Compositing

Status: Planned

Goal:
- turn the current simple painter into a real browser rendering pipeline

Exit criteria:
- font loading and text shaping are good enough for mainstream sites
- CSS backgrounds, borders, opacity, transforms, clipping, and stacking are
  implemented at an MVP level
- image rendering uses the browser resource pipeline
- canvas, SVG, and screenshot fidelity materially improve
- dirty-region invalidation avoids full-frame redraws for common interactions

### Gate 5: Editing, Forms, And App Interactivity

Status: Planned

Goal:
- make normal website interaction feel dependable

Exit criteria:
- text selection, clipboard, caret movement, IME, drag/drop, and pointer
  capture are stable
- buttons, selects, checkboxes, radios, and file inputs behave correctly
- contenteditable and common rich-text editing flows work to a practical level
- keyboard shortcuts and accessibility-driven focus behavior are coherent

### Gate 6: Modern Web Platform Coverage

Status: Planned

Goal:
- reach enough platform compatibility for mainstream browsing, not just simple
  pages

Exit criteria:
- robust fetch/XHR/WebSocket/navigation/history behavior
- storage APIs needed by common apps are implemented and persistent
- module/script loading and common JS integration paths are reliable
- workers and other core async primitives cover representative real sites

### Gate 7: Tabs, Session Management, And Recovery

Status: Planned

Goal:
- make longer user sessions safe and practical

Exit criteria:
- persistent session restore
- crash recovery and restart restore
- per-tab loading/crash/error state
- memory cleanup on tab close and navigation churn

### Gate 8: Performance, Stability, And Security

Status: Planned

Goal:
- raise the fork from experimental to something users can trust

Exit criteria:
- bounded memory/performance targets for long sessions
- crash logging and reproducible issue reports
- regression probes in CI for headed browsing on Windows
- clear security posture for cookies, storage, network policy, and unsafe
  content handling

### Gate 9: Packaging And Production Readiness

Status: Planned

Goal:
- ship a browser, not just a buildable developer project

Exit criteria:
- Windows installer/package and portable build
- versioned releases and upgrade path
- default profile directory and migration behavior
- documentation for install, troubleshoot, and recover

## Acceptance Bar For Production

Treat the browser as production-ready only when all of these are true:

- a normal user can install it and browse daily sites without needing CDP
- common login, search, reading, download, upload, and form flows work
- multi-tab browsing is stable for long sessions
- rendering quality is good enough that users do not need another browser to
  visually verify the page
- core crash, stop, reload, navigation, and recovery paths are predictable

## Working Rule For Future Milestones

Prefer milestones that move the product from "experimental headed demo" toward
"installable minimalist browser." If a change only helps automation but does
not materially improve the browser product, it should usually rank below work
that advances the gates above.
