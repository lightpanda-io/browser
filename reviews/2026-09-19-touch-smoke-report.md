# Real-client touch smoke results

Tested commit: `46c200755`, freshly compiled with `make download-v8 && make build-dev`.
Clients: puppeteer-core 25.11.0 and playwright-core 1.63.0.
Reference browser: Chrome 152.0.7977.83, disposable headless profile.
Fixture: localhost HTML containing a button, another element, and event-recording listeners. No external sites used.

| Scenario | Lightpanda Puppeteer | Lightpanda Playwright | Chrome |
| --- | --- | --- | --- |
| Repeated touchscreen.tap, list shape, coordinates, IDs | Pass | Pass | Pass both clients |
| page.tap('#a') | Pass | FAIL: 10-second timeout, html intercepts pointer events | Pass both clients |
| page.tap('#a', {force:true}) diagnostic | Not run | Pass touch delivery | Pass Playwright |
| Out-of-page tap followed by another gesture | Pass | Pass | Pass both clients |
| Puppeteer TouchHandle start/move/end, target retained | Pass | Not applicable | Pass |
| CDP populated touchEnd uses release coordinates | Pass | Pass | Pass both clients |
| CDP empty touchEnd uses last-move coordinates | Pass | Pass | Pass both clients |
| CDP populated touchCancel uses release coordinates | Accepted | Accepted | REJECTED by both clients: TouchCancel must not have any touch points. |
| CDP empty touchCancel uses last-move coordinates, non-cancelable | Pass | Pass | Pass both clients |

The CDP coordinate cases use each real client's CDP session API. They are distinct from the high-level touchscreen/page tap tests. Contact state is cleared between raw cases to prevent Chrome's rejected populated cancel from contaminating the next case.

Lightpanda's successful taps produce `touchstart,touchend`. Chrome produces `pointerdown,touchstart,pointerup,touchend,mousedown,mouseup,click`. Thus the touch delivery checks pass without establishing application click activation. The lack of PointerEvents and compatibility mouse/click events remains observable with both libraries.

Playwright's ordinary selector tap reliably fails, while its coordinate tap and forced selector tap deliver touches. This remains a real-client compatibility failure; this run has not established whether it was introduced by the latest commit. Force mode is only a diagnostic, not a passing result for the normal API.

The populated touchCancel behavior differs from Chrome 152. The claim that Chrome accepts populated cancel requests is not supported by this run. Keep this separate from the confirmed populated touchEnd fix.

No repository source files were changed. Existing untracked reviews/ and .DS_Store files were preserved. Full Zig suites were not rerun in this smoke pass; the user's reported 1588/1588 result is separate evidence.

Test artifacts remain in `/private/tmp/lightpanda-touch-smoke.PLJ8fV/`: `smoke.mjs`, `package-lock.json`, `full-results.json`, and `run.log`. Rerun there with `node smoke.mjs`; it starts and stops the local servers and disposable Chrome instance. A nonzero exit is expected while the normal Playwright selector tap and populated Chrome cancellation cases differ from the harness assertions.

An additional isolated-world diagnostic using Runtime.enable on Playwright's extra CDP session terminated with a client assertion before producing evidence. It is not included in the table or in full-results.json. No disposable Chrome instance remained afterward.
