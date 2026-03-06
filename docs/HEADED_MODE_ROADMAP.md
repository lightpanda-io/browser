# Headed Mode Roadmap (Fork)

This fork targets full headed-mode browser usage while preserving Lightpanda's
current headless strengths.

## Current Status

- `--browser_mode headless|headed` is now accepted.
- `--headed` and `--headless` shortcuts are available.
- On Windows targets, `headed` now starts a native window lifecycle backend.
- On non-Windows targets, `headed` still uses a safe headless fallback with warning.
- `--window_width` / `--window_height` now drive window/screen/viewport values.
- Display runtime abstraction exists with page lifecycle hooks and a Win32 thread backend.
- CDP viewport APIs update runtime viewport (`Emulation.*Metrics*`, `Browser.setWindowBounds`).
- Win32 headed backend now forwards native mouse (down/up/move/wheel/hwheel), click, keydown/keyup, text input (`WM_CHAR`/`WM_UNICHAR`), IME result/preedit composition messages (`WM_IME_COMPOSITION`), back/forward mouse buttons, and window blur events into page input.
- Win32 headed backend now propagates native key repeat state into `KeyboardEvent.repeat`.
- Text control editing now includes caret-aware insertion paths, `Ctrl/Meta + A` select-all, word-wise keyboard edit/navigation shortcuts, textarea vertical/line navigation, `Tab`/`Shift+Tab` focus traversal with `tabindex` ordering, and native clipboard shortcuts (`Ctrl/Meta + C/X/V`, `Ctrl+Insert`, `Shift+Insert`, `Shift+Delete`) with cancelable clipboard event dispatch.
- Windows prereq checker + runbook added (`scripts/windows`, `docs/WINDOWS_FULL_USE.md`).

## Milestones

1. Display abstraction
- Introduce a renderer backend interface with a no-op backend and a
  real windowed backend (Win32 lifecycle backend implemented).
- Keep DOM, JS, networking, and CDP independent from the window backend.

2. Window lifecycle
- Implement window creation, resize, close, and frame pump.
- Wire browser/page lifecycle events to the display backend.

3. Layout and paint pipeline
- Build incremental layout + paint passes from DOM/CSS state.
- Add dirty-region invalidation to avoid full-frame redraws.

4. Input + event synthesis
- Convert OS input events (mouse/keyboard/wheel/focus) into DOM events.
- Keep CDP input paths consistent with native input behavior.

5. Screenshots and surfaces
- Expose pixel surfaces for screenshots/recording while in headed mode.
- Ensure parity between headless and headed screenshot semantics.

6. Stabilization
- Add headed integration tests (window lifecycle, input, rendering, resize).
- Validate performance, memory, and crash-handling budgets.

## Design Constraints

- No regressions to existing headless CLI/CDP behavior.
- Feature flags must keep partial implementations safe.
- Keep platform-specific code isolated behind backend boundaries.
