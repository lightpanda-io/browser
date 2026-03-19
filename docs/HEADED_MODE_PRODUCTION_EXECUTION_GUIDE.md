# Headed Mode Production Execution Guide

This document is for an assistant working inside the Lightpanda headed fork.
It is not a brainstorm. It is the execution order for taking the current fork
from "headed foundation with many working slices" to "production-ready
minimalist browser for real daily use".

Read this together with:
- `docs/FULL_BROWSER_MASTER_TRACKER.md`
- `docs/HEADED_MODE_ROADMAP.md`
- `docs/WINDOWS_FULL_USE.md`

The branch to treat as product truth is:
- `fork/headed-mode-foundation`

## Product Bar

The first production cut must satisfy all of these:
- headed browsing on Windows is a first-class product mode, not a demo
- normal users can browse common sites without relying on CDP automation
- shell UX is stable: tabs, address bar, back/forward/reload/stop, downloads,
  bookmarks, history, settings, session restore, crash recovery
- rendered output is good enough for mainstream sites, not just localhost probes
- storage and network policy are coherent across tabs and restart
- screenshots use the same surface the user sees
- headless and CDP continue to work and are not regressed by headed work
- build and validation workflow self-recovers from known transient Windows/Zig
  cache failures

## Current Baseline

Assume these are already in place unless a regression proves otherwise:
- native Win32 headed window lifecycle
- address bar, back, forward, reload, stop
- tab strip, duplicate, reopen closed tab, session restore
- internal `browser://start`, `browser://tabs`, `browser://history`,
  `browser://bookmarks`, `browser://downloads`, and `browser://settings`
- persisted cookies, localStorage, IndexedDB, downloads, bookmarks, settings,
  telemetry/profile identity
- file upload and attachment download promotion
- image, stylesheet, script, font, and authenticated subresource loading
- basic canvas 2D drawing plus first WebGL slices
- bounded headed probe coverage across the existing `tmp-browser-smoke/` suites
- Windows/MSVC build success for the fork

Do not spend time re-solving those unless they are broken again.

## Architecture Map

Use these files as the primary ownership map:

- App and runtime wiring
  - `src/App.zig`
  - `src/Config.zig`
  - `src/main.zig`
  - `src/lightpanda.zig`
- profile and host-path handling
  - `src/HostPaths.zig`
- display backend and shell command bridge
  - `src/display/Display.zig`
  - `src/display/win32_backend.zig`
  - `src/display/BrowserCommand.zig`
- paint and presentation path
  - `src/render/DisplayList.zig`
  - `src/render/DocumentPainter.zig`
- browser core and page/session behavior
  - `src/browser/Browser.zig`
  - `src/browser/Page.zig`
  - `src/browser/EventManager.zig`
- network/runtime plumbing
  - `src/http/`
  - `src/browser/webapi/net/`
- HTML/CSS/DOM/Web APIs
  - `src/browser/webapi/`
  - `src/browser/webapi/element/html/`
- canvas and graphics
  - `src/browser/webapi/canvas/CanvasRenderingContext2D.zig`
  - `src/browser/webapi/canvas/CanvasSurface.zig`
  - `src/browser/webapi/canvas/OffscreenCanvas.zig`
  - `src/browser/webapi/canvas/WebGLRenderingContext.zig`
- smoke and acceptance probes
  - `tmp-browser-smoke/`

## Non-Negotiable Rules

1. Keep headed rendering, screenshots, and hit-testing on one shared surface.
   Do not add screenshot-only or probe-only rendering paths.
2. When a site or probe fails, fix the shared engine path, not the single page.
3. Every substantive slice must land with:
   - a focused Zig test where possible
   - a bounded headed probe for the real Win32 surface
4. Preserve headless and CDP behavior.
5. Do not delete `.lp-cache-win` for routine build recovery; it is expensive to
   rebuild and usually not the real problem.
6. Treat stale logs as stale until reproduced. Old `_link_trace.log` style
   failures are not proof of the current blocker.

## Delivery Checkpointing

When the run is organized into fixed-deliverable slices:
- after every verified batch of 25 completed deliverables, make a normal
  commit and push it to the current fork branch head
- do not wait for a much larger slice to finish before checkpointing
- keep verification ahead of the commit and push so each checkpoint is a real
  recovery point

## Build Self-Recovery Routine

If a Windows build times out or fails before real compiler diagnostics:

1. Check for orphaned processes first.
   - Inspect `zig`, `cargo`, `ninja`, `build.exe`, `cl`, `link`, and
     `lld-link`.
   - Kill only confirmed orphan PIDs.
2. Capture fresh logs.
   - `zig build -Dtarget=x86_64-windows-msvc --summary all 1> tmp-current-build.stdout.txt 2> tmp-current-build.stderr.txt`
3. Classify.
   - `failed to spawn build runner ... build.exe: FileNotFound` means default
     `.zig-cache` corruption.
   - `GetLastError(5): Access is denied` while Zig tries to spawn children
     usually means an environment restriction, not a source break.
   - only direct parser/type/linker diagnostics justify code edits
4. Validate the toolchain separately.
   - `zig build --help`
   - a tiny direct `zig build-exe` probe
   - retry with fresh cache dirs:
     - `--cache-dir .zig-cache-recover`
     - `--global-cache-dir .zig-global-cache-recover`
5. If fresh-cache build works, recover normal operation with:
   - `powershell -ExecutionPolicy Bypass -File .\scripts\windows\manage_build_artifacts.ps1 -CleanBuildCaches`
6. Re-run the default build and continue only after it succeeds.

Timeout budgets:
- warm rebuild: about 5 minutes
- cold/fresh-cache build: 15 to 20 minutes

## Definite Execution Order

Do the remaining work in this order. Do not jump ahead to packaging before the
release gates below are genuinely green.

### Phase 0: Build, Test, and Probe Discipline

Objective:
- make the fork routine to build, diagnose, and validate

Primary files:
- `scripts/windows/manage_build_artifacts.ps1`
- `docs/WINDOWS_FULL_USE.md`
- `build.zig`
- probe scripts under `tmp-browser-smoke/`

Tasks:
- keep the build-cache recovery workflow documented and stable
- standardize captured build logs for every long Windows build
- convert the existing smoke directories into named gate suites, not ad hoc runs
- separate warm-build expectations from cold-build expectations in docs
- ensure the main validation runbook tells future assistants which probe family
  to run for each subsystem change

Exit criteria:
- a future assistant can recover from corrupted `.zig-cache` without guessing
- every major subsystem has a known bounded probe entry point
- cold build timing no longer gets misclassified as a hang

### Phase 1: Rendering and Composition Fidelity

Objective:
- make the visible headed surface reliable enough for mainstream sites

Primary files:
- `src/render/DocumentPainter.zig`
- `src/render/DisplayList.zig`
- `src/display/win32_backend.zig`
- `src/browser/webapi/element/html/Image.zig`

Tasks:
- complete the remaining high-value CSS/layout fidelity gaps in the shared
  display-list path
- strengthen clipping, overflow, and compositing behavior for nested content
- improve image placement, scaling, alpha, and transformed hit-testing parity
- ensure caret, selection, focus rings, and control states remain visually
  coherent during scroll and zoom
- remove any remaining placeholder presentation behavior that is still visible
  on real pages
- prioritize failures that affect text-heavy pages, commerce/product pages, and
  documentation sites before edge-case art demos

Acceptance:
- `tmp-browser-smoke/layout-smoke`
- `tmp-browser-smoke/inline-flow`
- `tmp-browser-smoke/flow-layout`
- `tmp-browser-smoke/rendered-link-dom`
- `tmp-browser-smoke/showcase`

Exit criteria:
- pages no longer depend on dummy layout/presentation behavior to remain usable
- the visible surface is the same surface used by screenshots and hit-testing

### Phase 2: Text, Fonts, Editing, and IME

Objective:
- make reading and typing feel native enough for real use

Primary files:
- `src/display/win32_backend.zig`
- `src/render/DocumentPainter.zig`
- `src/browser/webapi/element/html/Input.zig`
- `src/browser/webapi/element/html/TextArea.zig`
- `src/browser/webapi/element/html/Label.zig`

Tasks:
- finish the Windows text-input polish that docs already call out as incomplete:
  IME candidate UI, composition edge cases, dead keys, and keyboard-layout
  correctness
- improve text measurement and font fallback for mixed-family real pages
- validate selection, clipboard, caret movement, focus traversal, and form
  editing against more realistic pages
- keep headed text metrics consistent with canvas text metrics and DOM geometry
- ensure zoom and DPI scaling do not break caret or text-control behavior

Acceptance:
- `tmp-browser-smoke/form-controls`
- `tmp-browser-smoke/font-smoke`
- `tmp-browser-smoke/font-render`
- `tmp-browser-smoke/find`
- `tmp-browser-smoke/zoom`

Exit criteria:
- users can reliably type, edit, paste, select, and navigate forms on the real
  surface without input corruption or visual desync

### Phase 3: Canvas and Graphics Completion

Objective:
- move from early canvas/WebGL slices to "common web graphics just work"

Primary files:
- `src/browser/webapi/canvas/CanvasRenderingContext2D.zig`
- `src/browser/webapi/canvas/CanvasPath.zig`
- `src/browser/webapi/canvas/CanvasSurface.zig`
- `src/browser/webapi/canvas/OffscreenCanvas.zig`
- `src/browser/webapi/canvas/WebGLRenderingContext.zig`
- `src/browser/webapi/element/html/Canvas.zig`

Known high-value gaps to close first:
- `CanvasRenderingContext2D.zig` still carries no-op transforms:
  `save`, `restore`, `scale`, `rotate`, `translate`, `transform`,
  `setTransform`, `resetTransform`
- `CanvasRenderingContext2D.zig` still carries no-op or partial path APIs:
  `quadraticCurveTo`, `bezierCurveTo`, `arc`, `arcTo`, `clip`
- `OffscreenCanvas.zig` still has stubbed `convertToBlob` and
  `transferToImageBitmap`

Tasks:
- finish transform stack semantics and path rasterization needed by common chart
  and editor libraries
- complete clipping and compositing semantics used by canvases embedded in real
  layouts
- advance OffscreenCanvas enough for libraries that move rendering off the main
  canvas object
- continue WebGL from clear/basic triangle support to the minimum viable buffer,
  shader, texture, and resize behavior needed by common UI/chart use
- make canvas-backed hit-testing, screenshots, and paints stay consistent

Acceptance:
- `tmp-browser-smoke/canvas-smoke`
- any new focused graphics probes added for transforms, clipping, and blob/image
  export

Exit criteria:
- mainstream canvas/chart pages and simple WebGL pages render on the headed
  surface without obvious placeholder behavior

### Phase 4: DOM, CSS, and Web API Compatibility

Objective:
- close the high-frequency API gaps that cause real sites to branch away or fail

Primary files:
- `src/browser/webapi/Window.zig`
- `src/browser/webapi/Performance.zig`
- `src/browser/webapi/ResizeObserver.zig`
- `src/browser/webapi/XMLSerializer.zig`
- `src/browser/webapi/selector/`
- `src/browser/webapi/navigation/`
- `src/browser/webapi/element/html/`

Known gaps worth prioritizing:
- `Window.alert` is still exposed as a noop
- `Performance` includes stub timing values
- `ResizeObserver` is skeletal
- `XMLSerializer` returns an empty structure
- `Slot` and some shadow/DOM details are still placeholder-level

Tasks:
- prioritize APIs that modern frameworks use for layout, scheduling, routing,
  and hydration
- improve selector and DOM mutation correctness only where it changes site
  behavior, not for abstract spec score alone
- add the missing observer/performance/browser APIs required for real app shells
- keep invalid input contained to the page rather than crashing headed mode

Acceptance:
- focused Zig tests per API family
- real-site or localhost probes for framework shells that previously branched
  away because an API was stubbed

Exit criteria:
- common app-shell frameworks stop failing on obvious missing API families

### Phase 5: Networking, Navigation, and Security Correctness

Objective:
- make real page loading behavior coherent across tabs, restarts, and protected
  resources

Primary files:
- `src/http/`
- `src/browser/webapi/net/`
- `src/browser/webapi/element/html/Link.zig`
- `src/browser/webapi/element/html/Style.zig`
- `src/browser/webapi/element/html/Image.zig`
- `src/lightpanda.zig`

Tasks:
- continue tightening request policy for cookies, referer, auth, redirects, and
  cache behavior across every subresource class
- ensure navigation failure handling, attachment handling, and popup policy stay
  correct under restart, back/forward, and retry flows
- validate websocket, fetch-abort, credentialed fetch, stylesheet import, and
  script/module behavior against realistic sequence timing
- harden download/file-path isolation and shell-action safety
- make sure profile persistence works identically whether the profile path is
  absolute or repo-local relative

Acceptance:
- `tmp-browser-smoke/image-smoke`
- `tmp-browser-smoke/stylesheet-smoke`
- `tmp-browser-smoke/fetch-abort`
- `tmp-browser-smoke/fetch-credentials`
- `tmp-browser-smoke/websocket-smoke`
- `tmp-browser-smoke/downloads`
- `tmp-browser-smoke/attachment-downloads`

Exit criteria:
- cross-tab and restart behavior for network-backed features is deterministic
- protected subresources and downloads behave like one browser, not a set of
  unrelated demos

### Phase 6: Shell, Profile, and Product Polish

Objective:
- turn the current shell into a product people can live in for long sessions

Primary files:
- `src/lightpanda.zig`
- `src/display/BrowserCommand.zig`
- `src/display/win32_backend.zig`
- `src/HostPaths.zig`

Tasks:
- polish tab UX, keyboard shortcuts, disabled states, focus behavior, and
  internal-page navigation flows
- keep history/bookmarks/downloads/settings pages usable on long-lived profiles
- harden crash recovery, startup restore, homepage behavior, and error-page
  recovery
- ensure native shell actions from downloads remain safe and predictable
- stabilize profile-path behavior across manual overrides, relative paths, and
  future packaged installs

Acceptance:
- `tmp-browser-smoke/browser-pages`
- `tmp-browser-smoke/tabs`
- `tmp-browser-smoke/settings`
- `tmp-browser-smoke/popup`
- `tmp-browser-smoke/file-upload`
- `tmp-browser-smoke/manual-user`

Exit criteria:
- a user can browse, close, reopen, recover, download, and manage settings over
  a long session without needing CDP or manual profile surgery

### Phase 7: Reliability, Performance, and Crash Recovery

Objective:
- make the browser trustworthy for repeated daily use

Primary files:
- `src/App.zig`
- `src/crash_handler.zig`
- `src/lightpanda.zig`
- `src/display/win32_backend.zig`
- `src/render/DocumentPainter.zig`

Tasks:
- add memory, startup, and steady-state performance checkpoints
- investigate leaks and unbounded growth across tabs, fonts, images, and canvas
- make crash capture and restart recovery explicit, not accidental
- audit long-session behavior for downloads, internal pages, and storage
- add soak runs that open, reload, close, and restore tabs repeatedly

Acceptance:
- repeated headed probe loops without crash or runaway memory growth
- a manual soak script for long-lived headed sessions

Exit criteria:
- the browser survives long sessions and repeated reopen cycles without obvious
  degradation

### Phase 8: Packaging, Install, and Release

Objective:
- ship the fork as a usable Windows browser build, not just a local developer
  artifact

Primary files:
- `build.zig`
- `docs/WINDOWS_FULL_USE.md`
- packaging/release scripts added for this phase

Tasks:
- define install layout, default profile location, and user-visible data paths
- package the executable and dependent runtime assets coherently
- keep first-run experience, logging, and update instructions clear
- document supported Windows version, known limitations, and fallback modes
- turn the current tracker state into a release checklist with explicit gates

Exit criteria:
- a new user can install, launch, browse, and find their profile/downloads
  without reading source code

## Release Gate Matrix

Do not call the fork production ready until these suites are green in headed
mode on the release candidate build:

- shell and navigation
  - `tmp-browser-smoke/tabs`
  - `tmp-browser-smoke/browser-pages`
  - `tmp-browser-smoke/settings`
  - `tmp-browser-smoke/wrapped-link`
  - `tmp-browser-smoke/popup`
- rendering and layout
  - `tmp-browser-smoke/layout-smoke`
  - `tmp-browser-smoke/inline-flow`
  - `tmp-browser-smoke/font-render`
  - `tmp-browser-smoke/image-smoke`
- forms and file handling
  - `tmp-browser-smoke/form-controls`
  - `tmp-browser-smoke/file-upload`
  - `tmp-browser-smoke/downloads`
  - `tmp-browser-smoke/attachment-downloads`
- storage and session
  - `tmp-browser-smoke/cookie-persistence`
  - `tmp-browser-smoke/localstorage-persistence`
  - `tmp-browser-smoke/indexeddb-persistence`
  - `tmp-browser-smoke/sessionstorage-scope`
- network/runtime
  - `tmp-browser-smoke/fetch-abort`
  - `tmp-browser-smoke/fetch-credentials`
  - `tmp-browser-smoke/websocket-smoke`
  - `tmp-browser-smoke/stylesheet-smoke`
- graphics
  - `tmp-browser-smoke/canvas-smoke`

Also require:
- successful default-cache Windows build
- successful fresh-cache Windows build
- one long manual session run on a non-trivial real-site mix

## Bare Metal Path

The bare-metal path is the next deployment target after the headed Windows
product path is green. It is not a separate browser. It is the same browser
core compiled against a narrower host surface.

Do not fork browser behavior. Move OS assumptions out to explicit platform
services and keep the display list, browser pages, input model, and request
policy shared.

### Bare Metal Target Definition

- Boot directly into the Lightpanda shell on a freestanding or firmware-style
  target.
- No Win32, no desktop shell, no implicit app-data directory, no dependence on
  a host user profile.
- Use the same browser pages and same headed presentation pipeline semantics.
- Start on QEMU or an emulator image first. Hardware support comes after the
  emulator path is stable.

### Platform Seams

- `src/App.zig`: stop assuming the platform is a desktop app with a process
  profile directory.
- `src/HostPaths.zig`: split filesystem-backed profile resolution from the
  abstract notion of a browser profile root.
- `src/display/Display.zig`: keep the backend boundary generic so Win32 and
  bare-metal backends can share the same `DisplayList` contract.
- `src/display/win32_backend.zig`: treat as the hosted reference backend, not
  the product architecture.
- `src/Net.zig` and `src/http/`: isolate sockets, timers, and I/O readiness
  behind platform services.
- `src/crash_handler.zig` and `src/log.zig`: support non-console sinks such as
  serial output or a ring buffer.
- `build.zig`: add a freestanding or bare-metal target class and select the
  platform module at compile time.
- `src/sys/`: grow the platform-specific services for framebuffer, input,
  timers, persistent storage, and optional network glue.

### Bare Metal Execution Order

#### Phase 9: Platform Service Boundary

Objective:
- make the browser core compile against explicit host services instead of
  Win32 or desktop assumptions

Primary files:
- `src/App.zig`
- `src/HostPaths.zig`
- `src/lightpanda.zig`
- `src/display/Display.zig`
- `src/Net.zig`
- `build.zig`
- `src/sys/`

Tasks:
- define a small host-service surface for:
  - profile storage
  - display surface
  - input events
  - clock and timers
  - logging
  - fatal exit / reboot hooks
- move direct `std.fs` usage in persistence and startup flows behind the host
  storage service
- keep `Browser`, `Page`, `EventManager`, `DocumentPainter`, and
  `DisplayList` free of firmware-specific code
- add a mock host implementation so unit tests can run without a windowing
  system
- make sure the build system can select the hosted Windows backend or the
  bare-metal backend without changing browser logic

Acceptance:
- the browser core compiles with the mock host
- persistence and startup code paths are testable without Win32
- the current Windows backend remains intact while the host seam is added

Exit criteria:
- the browser no longer assumes desktop process semantics in core code

#### Phase 10: Boot and Presentation

Objective:
- get pixels and input on screen with the same shared display-list path

Primary files:
- `src/display/Display.zig`
- `src/display/win32_backend.zig`
- `src/render/DisplayList.zig`
- `src/render/DocumentPainter.zig`
- `src/browser/EventManager.zig`
- `src/browser/Page.zig`
- `src/browser/webapi/element/html/Canvas.zig`
- `src/sys/`

Tasks:
- implement a bare-metal display backend that consumes `DisplayList` and paints
  to a framebuffer or equivalent compositor target
- implement a visible boot/loading state so startup failures are obvious
- wire keyboard and pointer input into the same browser event path used by the
  Windows backend
- keep screenshots and visible output semantically identical to the headed
  Win32 path
- choose one initial boot stack and keep it narrow:
  - QEMU or emulator framebuffer first
  - then physical hardware
- do not create a second renderer just for the boot path

Acceptance:
- boot lands in the browser shell
- `browser://start` renders on the bare-metal surface
- click, type, scroll, and tab switching work in the boot image
- framebuffer screenshots are reproducible from the same presentation state

Exit criteria:
- the same browser UI can be driven on the bare-metal surface without desktop
  dependencies

#### Phase 11: Persistence and Networking

Objective:
- make browser state survive power loss and restart on a non-desktop target

Primary files:
- `src/HostPaths.zig`
- `src/lightpanda.zig`
- `src/browser/webapi/storage/`
- `src/browser/webapi/net/`
- `src/http/`
- `src/browser/webapi/element/html/Link.zig`
- `src/browser/webapi/element/html/Style.zig`
- `src/browser/webapi/element/html/Image.zig`

Tasks:
- back profile data with a durable bare-metal store instead of host app-data
  paths
- preserve cookies, localStorage, IndexedDB, bookmarks, downloads, settings,
  and session state across reboot
- expose or emulate the minimum storage semantics needed by the existing
  browser pages
- bring up networking with the smallest viable path that supports HTTP, HTTPS,
  redirects, cookies, and downloads
- keep request policy identical to the Windows path for protected resources
- make failures explicit when storage or network hardware is absent

Acceptance:
- profile state survives reboot
- navigation, downloads, and storage-backed browser pages work after restart
- protected subresource behavior matches the Windows path

Exit criteria:
- the browser can be used across power cycles without losing the user profile

#### Phase 12: Boot Image and Release

Objective:
- produce a bootable browser image that can be tested and shipped

Primary files:
- `build.zig`
- `docs/WINDOWS_FULL_USE.md`
- packaging and release scripts added for this phase

Tasks:
- add boot-image packaging to the build or adjacent packaging scripts
- define image layout, firmware assumptions, and required device support
- document supported emulator or hardware classes, memory floor, input devices,
  and network devices
- create repeatable boot smoke scripts and artifact capture
- keep a fast recovery path for image boot failures

Acceptance:
- a bootable image launches the browser shell in an emulator or on hardware
- the same smoke suites have a bare-metal execution mode
- startup, navigation, and restart survive repeated boot cycles

Exit criteria:
- the bare-metal path can be delivered and reproduced without source edits

### Bare Metal Release Gate

Do not call the bare-metal path production ready until:
- the image boots reliably on the chosen emulator and at least one target
  hardware class
- the browser shell is usable with keyboard and pointer input
- profile state persists across reboot
- the network path handles normal navigation and downloads
- the same core browser pages work without Win32
- boot and runtime failures are reproducible from saved logs

### Bare Metal Validation Rule

Every bare-metal slice must end with:
1. a compile check for the bare-metal target or the nearest supported host
   equivalent
2. the relevant unit tests for the modules that changed
3. the relevant smoke/probe suite for the surface that changed
4. saved logs or artifacts for any failure

Do not move to the next bare-metal layer until the current layer compiles and
its validation passes.

### Bare Metal Module Split

Keep the bare-metal host code in `src/sys/` and related build glue, not in the
browser core.

Split the first bring-up into these host modules:
- `src/sys/boot.zig` for startup, panic routing, and shutdown
- `src/sys/framebuffer.zig` for the pixel surface and screenshot capture
- `src/sys/input.zig` for keyboard and pointer event ingestion
- `src/sys/timer.zig` for monotonic time, sleeps, and animation pacing
- `src/sys/storage.zig` for profile persistence and file emulation
- `src/sys/net.zig` for the transport and socket/driver shim
- `src/sys/serial_log.zig` for log output when no desktop console exists

Rules:
- browser code never talks to drivers directly
- the display backend consumes a generic surface, not a boot-specific API
- persistence goes through the storage service, not raw block I/O in browser
  code
- request policy stays in the shared HTTP/browser layers; only the transport
  changes
- the boot module owns the initial run loop and the last-resort failure path

### Bare Metal Smoke Order

Bring up the image in this order:
1. boot banner plus panic output
2. framebuffer fill and browser chrome paint
3. keyboard focus, text entry, and mouse click delivery
4. `browser://start` and `browser://tabs`
5. profile save/restore across a restart
6. network navigation to a localhost smoke page
7. downloads and storage-backed browser pages
8. one real-site fetch with the same request policy as Windows

If a step fails, fix the earliest missing layer. Do not debug later layers
before the current one is stable.

### Bare Metal Batch 1: 25 Deliverables

This is the first concrete bare-metal checkpoint batch. Complete the items in
order. Do not skip ahead. Every item still follows the Bare Metal Validation
Rule, and the whole batch ends with the commit-and-push checkpoint rule.

1. Add `src/sys/host.zig` with the canonical host-service interface for
   storage, display, input, timer, logging, and power control. Exit check: the
   browser core compiles against the interface without Win32 imports in core
   files.
2. Add a mock host implementation for unit tests. Exit check: startup and
   persistence tests run without a windowing system or firmware target.
3. Refactor `src/App.zig` to accept host services instead of assuming desktop
   process semantics. Exit check: app startup no longer depends on implicit
   app-data or desktop globals.
4. Add `src/sys/boot.zig` for startup, panic routing, and shutdown. Exit check:
   boot code can emit a visible failure and terminate cleanly.
5. Add `src/sys/serial_log.zig` for non-console logging. Exit check: fatal
   errors can be captured on a serial sink or ring buffer.
6. Add `src/sys/timer.zig` for monotonic time, sleeps, and pacing. Exit check:
   animation and event loops can advance without `std.time` calls in browser
   core code.
7. Add `src/sys/input.zig` for keyboard and pointer ingestion. Exit check: a
   platform test can inject keypress and click events deterministically.
8. Add `src/sys/framebuffer.zig` for pixel output and screenshot capture.
   Exit check: a framebuffer test can draw and read back pixels.
9. Add `src/sys/storage.zig` for profile root resolution and durable file
   operations. Exit check: profile files can be created, reopened, and
   enumerated on the mock host.
10. Add `src/sys/net.zig` for transport and socket glue. Exit check: the
    network shim can be swapped without changing browser request policy code.
11. Extend `build.zig` with a target-class switch for hosted vs bare-metal
    builds. Exit check: both target classes can be selected without editing
    browser logic.
12. Refactor `src/HostPaths.zig` to use profile file and subdir helpers for
    bare-metal-safe path resolution. Exit check: profile file paths resolve in
    tests and on the mock host.
13. Replace direct profile-directory assumptions in `src/lightpanda.zig` with
    host-safe directory helpers. Exit check: cookies, settings, session,
    bookmarks, and downloads still round-trip under the hosted backend.
14. Add compile tests that instantiate browser core types with the mock host.
    Exit check: `Browser`, `Page`, `EventManager`, `DisplayList`, and
    `DocumentPainter` compile without Win32-specific branches.
15. Add the bare-metal display backend skeleton that consumes `DisplayList`.
    Exit check: the backend can accept a list and paint a trivial frame.
16. Add a visible boot and loading state. Exit check: startup failures are
    obvious on the framebuffer instead of vanishing into a black screen.
17. Wire keyboard focus and text entry through the bare-metal input path. Exit
    check: address bar focus and text input work in the shell.
18. Wire pointer input through the bare-metal input path. Exit check: links and
    controls are activatable with a pointer.
19. Bring up `browser://start` on the bare-metal surface. Exit check: the
    start page renders and responds to interaction.
20. Bring up `browser://tabs` and tab switching on the bare-metal surface.
    Exit check: opening, switching, and closing tabs work across a restart.
21. Back profile persistence for bookmarks, settings, and session state with
    the durable storage layer. Exit check: the data survives a restart in the
    emulator.
22. Back cookies, localStorage, and IndexedDB with the durable storage layer.
    Exit check: storage-backed browser pages still work after power loss.
23. Implement the minimal bare-metal HTTP and HTTPS navigation path. Exit
    check: localhost navigation and a download smoke pass on the emulator.
24. Verify one real-site fetch on bare metal with the same request policy as
    Windows. Exit check: the same policy gates content on both hosted and
    bare-metal paths.
25. Package a bootable image and emulator launch smoke with artifact capture.
    Exit check: a repeatable image launch can be driven without source edits.

## Anti-Patterns

Do not do these:
- do not add probe-only rendering behavior that real pages cannot use
- do not special-case one site if the underlying engine path is still wrong
- do not treat old logs as current truth
- do not mark a phase done because a single localhost probe turned green
- do not delete dependency caches to solve a transient local Zig cache issue

## Definition Of Done

The fork is production ready only when:
- the default Windows headed build is routine and self-recovering
- the shell is stable for long daily sessions
- common sites render and interact correctly enough for ordinary use
- the existing smoke matrix is green and organized as a release gate
- the remaining obvious API stubs no longer drive common sites off the happy
  path
- the product can be installed and used by someone who is not inside the repo
- the bare-metal path has a bootable browser image, persistent profile, working
  input and networking, and its own reproducible smoke gates
