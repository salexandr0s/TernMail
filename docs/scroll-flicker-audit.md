# Scrolling flicker audit

Date: 2026-11-03. Priority: Inbox and Attachments, as reported by the user.

The audit found two image lifecycle paths that cleared loaded pixels during scrolling. The fixes preserve retained avatars and let recreated attachment rows render warm public logos immediately. Native regressions reproduce the original image and reader failures and pass with the fixes. Calendar scrolling also caused an unnecessary grid body evaluation; its geometry storage now avoids that update.

These conclusions have source and native-test evidence. Presented-frame flicker, CPU improvement and peak-memory improvement have not been measured. Foreground captures were rejected while the Mac was locked; no rejected timing is treated as a result.

## Findings and fixes

| Priority | Finding | Remediation | Confidence / effort |
| --- | --- | --- | --- |
| 1 | Inbox avatars called `stop()` on disappearance, clearing pixels and restarting lookup when retained row state reappeared. | Keep the model's image and access observation for its SwiftUI state lifetime. Known account photos can render before `onAppear`; identity changes still reconfigure the model. | High; small, implemented |
| 1 | Attachment logos cleared their image at every task restart, and recreated rows had no synchronous decoded-image lookup. | Preserve a matching image across task restarts. Share a bounded decoded public-logo cache and render warm pixels on the first body evaluation. Decode and resize on a serial actor. | High; medium, implemented |
| 2 | Expanded reader bodies were removed at the exact viewport boundary, allowing a quick reversal to lose the native renderer. | Retain an already prepared body for 350 ms after viewport exit. Reentry cancels eviction; collapse, inactivity and memory pressure still release the transient retention. | High; small, implemented |
| 3 | Calendar scroll preferences wrote a frame dictionary into observable view state. One native scroll caused an extra grid body evaluation. | Store the latest hit-test frames in a view-owned reference. Active drag state still publishes updated ranges and scroll direction. | High for the measured update; small, implemented |

Image changes are in [AddressAvatar](../App/Design/AddressAvatar.swift), [AddressAvatarModel](../App/Design/AddressAvatarModel.swift), [DomainLogoAvatar and its decoded cache](../App/Design/DomainLogoAvatar.swift), and [DomainLogoImages](../App/Design/DomainLogoImages.swift). The public-logo cache counts compressed bytes and decoded pixels against an 8 MiB budget, caps entries at 128 domains, and expires entries after seven days. New lookup tasks still consult the existing source cache for freshness. Shared-source reset invalidates pending decode publication; private cache instances do not reset global presentation state.

Contact photos remain account-scoped and require access/version validation. Retained models continue observing revocation, and model destruction cancels observation. A completely new contact row can still show initials while asynchronous access and photo validation finish. The change does not synchronously expose unvalidated contact pixels.

The reader change is in [MessageView](../App/Views/MessageView.swift). Calendar changes are in [CalendarTimeGrid](../App/Calendar/CalendarTimeGrid.swift), [CalendarMonthGrid](../App/Calendar/CalendarMonthGrid.swift), and [CalendarTimelineGesture](../App/Calendar/CalendarTimelineGesture.swift).

## Native before/after evidence

| Check | Original behavior / control | Fixed behavior |
| --- | --- | --- |
| Avatar pixels after native disappearance | Image became `nil`; lookup repeated on reappearance | Same image retained; exactly one lookup |
| Warm logo on a newly constructed row | Source initially required an asynchronous task before pixels were available | First render uses cached pixels; lookup preference still suppresses the logo |
| Reader renderer after quick reversal and a further 400 ms wait | Original renderer was lost | Original renderer survives the canceled eviction deadline |
| Extra calendar grid body evaluations for one 64-point native scroll | 1, from 2 to 3 evaluations | 0 |

The calendar baseline ran the corrected final regression against the original observed frame storage: 13 of 14 tests passed, with the body-count assertion as the sole failure. An earlier test used an unsnapped drag anchor; that test error was corrected before this comparison.

The image/reader control used the new image test scaffolding with the original avatar `onDisappear { model.stop() }` behavior and original reader source. Twelve of fourteen tests passed; the two intended lifecycle regressions failed. This is a behavior control, rather than an untouched application baseline.

The final candidate passed **125 tests in 13 suites**, with no skipped tests. Coverage includes avatar lifecycle, account isolation and revocation, late completions, initial image rendering, cache budget/expiry, reader reuse and eventual eviction, scroll anchors, mail-list selection and identity, attachment models, calendar hit testing/drag state, and assistant scroll tracking. Both optimized baseline and candidate builds passed.

## Other reviewed paths

- Mail rows have account-qualified stable identities, prepared list projections, and selection observation separated from visual row content. Existing native selection tests passed; no blanket `equatable()` or identity replacement was added.
- Attachment list/grid entries have stable IDs, bounded 100-item pages, cached native file icons, and value-based visual cells. Equal page/selection publications are already suppressed. No large file-preview decode was found inside row rendering.
- Reader source identity, HTML load deduplication, coalesced height messages, retained height estimates, and bounded off-main preparation already exist. Their relevant tests passed.
- Assistant geometry tracking keeps frequent frame changes outside observation and publishes follow-state transitions. Sidebar identity and label updates did not reveal another scroll-offset-driven invalidation path.
- Row image frames and the star action reserve their dimensions. The audit did not establish a need to disable native scrolling or interaction animation.

## Runtime capture limits and provenance

Verification used isolated source snapshots based on `e9182490ee59ed45b7cf9e6a24d9a47f6758dbc1` plus the scoped audit changes. Concurrent calendar-editor work and later design/reading/compose changes in the shared checkout were preserved and are outside the verified snapshot. An initial snapshot included that work before its project entries were complete and failed compilation; the corrected committed snapshots built successfully.

Environment: macOS 27.2 (26B123), Xcode 26.3 (17C529), native arm64 builds. Optimized audit binaries use `TERN_PERFORMANCE`; hosted tests use Debug and synthetic accounts.

The existing `dev.tern.performance` app stalled before `main` in sandbox initialization. A fresh synthetic bundle identifier started with the same signing authority and verified identical entitlements. macOS denied terminal access to its private container report, so subsequent attempts used the app's existing Downloads export entitlement. Reports were readable there, but foreground validation failed. Computer use then explicitly reported that the Mac was locked and required manual unlock. These attempts establish capture limitations, not scroll-performance results.

Some synthetic processes needed the existing bounded termination fallback. This does not verify graceful quit of the installed app. No installed-app replacement or live mail/provider action was performed.

Evidence is under `build/Verification/scroll-flicker/`:

- `candidate-tests.xcresult`, `candidate-tests-summary.json`: 125/125 passing tests.
- `calendar-baseline-corrected.xcresult`: original grid's one extra body evaluation.
- `behavior-control-compiled.xcresult`: original avatar and reader lifecycle failures.
- `baseline-build-verified.log`, `candidate-build.log`: optimized builds.
- `candidate-inputs.json`, `candidate-test-inputs.json`, `verified-binaries.json`: source and executable identities.
- `baseline-launch.sample`, rejected runtime reports and process logs: startup/foreground limitations.
- `scope-validation.json`: complete scroll scope accepted, missing surfaces and invalid foreground rejected, existing navigation gates preserved.

## Repeatable capture

The diagnostic runner now supports `scroll-only`, covering mailbox, 20-message reader, 100-message reader, calendar and attachments for 30 seconds each. Existing `all`, workspace and reader acceptance gates remain intact. It measures display-link callback delivery while moving native scroll offsets; this is not GPU presentation or trackpad momentum.

With the Mac unlocked, use a fresh synthetic identity and an app-writable report directory if the default container is unavailable:

```sh
TERN_PERFORMANCE_BUNDLE_ID=dev.tern.scrollaudit.local \
TERN_PERFORMANCE_REPORT_DIR="$HOME/Downloads/Tern-scroll-audit-20261103" \
bash scripts/benchmark-navigation.sh 100 scroll-only
```

Keep the synthetic app visible, key and unobscured. `TERN_PERFORMANCE_START_FILE` optionally supplies an absent absolute sentinel path: activate the prepared app, then create that file before its 90-second setup deadline. Do not provide UI input during measurement. The report validator rejects missing surfaces, interrupted captures and callback-budget failures.

For the remaining visual question, capture the same Inbox and Attachments scrolling in Release with SwiftUI Instruments and Time Profiler. Compare body updates, main-thread image work and frame hitches; record the mailbox size and display refresh rate. Apple's [SwiftUI performance guidance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance) describes how to connect frequent view updates and expensive bodies to runtime evidence. A before/after capture is still needed to quantify visible flicker and actual presented-frame improvement.
