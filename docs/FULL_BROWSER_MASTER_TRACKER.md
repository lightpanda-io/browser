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
- remaining blocker: form-driven `_blank` submission through the session-owned
  pending-tab-open path is still crashing on Windows headed `browse`

### Gate 2: Shared Subresource Loader And Profile

Status: Planned

Goal:
- move page assets and browser state onto a consistent browser-managed runtime

Exit criteria:
- images, CSS, scripts, fonts, and other subresources use the shared browser
  network/client path
- cookies, cache, auth, proxy, redirects, uploads, downloads, and persistent
  profile storage behave consistently
- file chooser and download manager flows exist
- same-origin, CORS, CSP, mixed-content, and certificate error behavior are
  coherent enough for mainstream browsing

### Gate 3: Layout Engine Replacement

Status: Planned

Goal:
- replace the remaining dummy and heuristic layout paths with a real layout
  engine

Exit criteria:
- block and inline formatting contexts behave predictably
- flexbox support is usable on common sites
- positioning, overflow, fixed/sticky basics, margin/padding/border handling,
  and intrinsic sizing are implemented
- form controls and replaced elements layout correctly in normal documents

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
