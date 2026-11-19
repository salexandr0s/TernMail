# Navigation performance

Tern caches calendar layout, mail rows, message documents, and decoded contact
images. Foreground reading has priority over speculative preparation. The
implementation is still being measured. Nobody has watched a run of the mode
switches or of message selection. The mail list and the conversations of
expanded messages exceed the scrolling budget. On the code of `2e8f3287`, the
switches to and from the attachment library met the 100 ms target in the one
run made.

Paths under `evidence/` refer to the local audit archive; those artifacts are not included in this repository.

## Acceptance targets

| Interaction | Release target on the reference Mac |
| --- | --- |
| Selection feedback | p95 ≤50 ms |
| Return to a mode or rendered email | p95 ≤100 ms; p99 ≤200 ms |
| Locally stored email needing preparation | p95 ≤200 ms for the representative corpus |
| Uncached email | Header p95 ≤100 ms; render ≤200 ms after required bytes arrive |
| Steady scrolling | Fewer than 1% missed presented frames; no app-caused stall ≥100 ms |

Navigation diagnostics distinguish input timestamps from programmatic selection.
Both end when content is ready and a subsequent visible native drawing commit
occurs. The probe rejects inactive,
detached, occluded, unready, and superseded views. This endpoint is not a GPU
presentation timestamp. Display-link callback gaps are a main-run-loop proxy;
Instruments is required to verify actual frame hitches. No subjects, addresses,
message identifiers, or message bodies enter diagnostic reports.

A mode switch's timing ends when the new section's content is drawn. The
toolbar's items change after that, and the benchmark records when they have as
`toolbarFollow`, apart from the switch's own timing.

Selection-feedback correction: the historical `selectionFeedback` endpoint used
the workspace's probe. It checked list readiness and a visible workspace redraw,
but did not check the selected native row or its highlight. The 308.83, 65.90 and
61.21 ms p95 values below are workspace-redraw proxies, not measurements of visible
selection. They cannot establish whether the 50 ms highlight target was met.
A row-local native-selection check is planned; it will still need to distinguish
its drawing-commit proxy from actual presented pixels.

Reader processing latency starts when a required body or resource reaches the
view's data observer. It includes subsequent state publication and layout, but
does not include the interval between network delivery and that observer.
Reports retain full input-to-visible latency alongside this narrower measure.
Synthetic transport scenarios also record the complete response before
persistence and identify that earlier origin separately in the report.

## Repeatable measurements

Run `bash scripts/benchmark-navigation.sh 100`, then repeat with `1000`. This builds
an optimized app with the separate identifier `dev.tern.performance`, an opt-in
`TERN_PERFORMANCE` compilation condition, synthetic accounts, and in-memory stores.
The script passes the identifier as `TERN_APP_BUNDLE_IDENTIFIER`, which also
sets the host ID that the embedded Claude helper accepts. A `TERN_PERFORMANCE`
build stops at launch if its bundle ID is `dev.tern.mail`. Debug and Release
builds contain no synthetic audit entry point: a Debug app stops when it gets an
audit or benchmark flag, and Release ignores those flags. The script reports
the JSON output path. It requests normal termination, then uses a bounded fallback
only for the synthetic process it launched if termination hangs. The process
report records whether graceful exit succeeded. This does not verify the normal
app's quit workflow.

Acceptance runs require at least 100 warm switches in each direction, recent and
locally stored message selection, and sustained scrolling. Reports retain failures and
timeouts separately from successful percentiles. A scenario with missing content
or missing visibility probes must not be reported as passing.

The script takes a third argument, the variant. `unattended` passes
`--performance-unattended`: the benchmark window goes in front of other apps'
windows and the run no longer requires the app to be active or its window to be
key. Use it to compare two builds when nobody is at the Mac to bring the app to
the front. The report records `unattended: true` and the validator rejects it,
so these timings never count as acceptance. Set `TERN_PERFORMANCE_REPORT_DIR`
to a folder the sandboxed app can write and the caller can read, such as one
under `~/Downloads`, when the caller may not read the app's container.

With the scroll scope, `TERN_PERFORMANCE_POINTER_ON_LIST=1` scrolls the mail
list three times: with the pointer parked in a corner of the window, resting on
the list, and parked again. It moves the real pointer and puts it back, so run
it only while nobody is using the Mac.
`TERN_PERFORMANCE_POINTER_ON_READER=1` does the same for the reader: each
conversation scrolls with the pointer parked, then again as `<name>-pointer`
with the pointer resting on the middle of the reader. Every scroll result
records `pointerInWindowAtStart`, because a run that doesn't place the pointer
leaves it where it was.

The `compose-only` scope opens a compose window 100 times through File > New
Message and 100 times through Message > Reply, after three untimed openings of
each, and closes every window untouched, which discards its draft. `all` leaves
these out, so its main-thread heartbeat stays comparable with earlier reports.
Each opening is timed from the menu item's action to four moments: the window
becomes key; the main thread is first free with the window on screen; a field
in the window has the cursor and gets the keys typed since the command; and the
main thread stays free after that. `draftOnly` times the model call that makes
the draft, with no window. Reply answers a conversation the reader has opened,
so its draft comes whole from the cache. A Forward, or a reply to a message
whose body isn't cached, opens from the cached headers and gets the quote and
files while the window is open, so no opening waits for Gmail. The timings
have no budget yet, so the validator only checks that every opening
completed. The compose windows take the keyboard, so this scope needs the Mac
to itself, like any attended run.

For a normal Debug or Release launch, `--navigation-report=<absolute-path>` enables a
local JSON report. Use a writable location in the app's container, such as
`~/Library/Containers/dev.tern.mail/Data/tmp/navigation.json` (expand `~` before
passing it). Reports are bounded and written at most once per second; normal
launches write no report. This option does not select mail or change accounts.

Run performance checks on a quiet machine, with the app visible and unobscured.
Record the source revision, build configuration, operating system, display refresh
rate, fixture size, and app/WebKit memory. Compare cold, retained, prepared, local,
and network-bound reading separately. Large conversations and oversized HTML are
stress cases; they must not block input even when preparation takes longer.

Verified builds pass `TERN_BUILD_REVISION=<source-commit>` to `xcodebuild`.
The resulting `TernBuildRevision` key in the bundle's Info.plist identifies that
revision. Ordinary development builds use `development`. A reused audit binary
must be identified by its own metadata and executable hash, not the current
worktree revision.

## Cache ownership

The prepared-content budget is 64 MiB: 56 MiB for HTML and immutable inline
resources, plus 8 MiB for calendar text extraction. Decoded contact images have a
32 MiB pixel budget. Retained snapshots share 32 MiB: 12 MiB for mail lists,
12 MiB for calendar ranges, and 8 MiB for reader source sessions. Displayed working
state and WebKit child processes are measured separately from these byte caches.

Calendar keeps the displayed range and prepares complete, locally stored adjacent
ranges in one background task. Adjacent preparation makes no network requests.
Each window retains three reader sessions and at most two hidden message WebKit
views. The app also keeps one spare message WebKit view that no message has used.
It has its own non-persistent data store and has loaded only an empty page, so its
WebKit child process is already running when the next message takes it. A new
spare is built once that message has laid out and input has paused for a second.
Minimized or fully occluded windows suspend automatic reader activity and release
the spare, and memory pressure releases it until the next message opens.

Account removal, disposable-cache reset, permission changes, content revisions,
and rendering-policy changes invalidate the relevant cached values. Hidden
readers cannot mark messages read or publish active-reader commands. Memory
pressure releases speculative and hidden state while preserving navigation.

## Verification record

Implementation began from `ceed505` on `codex/instant-navigation`. The installed
baseline executable SHA-256 was
`e576c3eb2bb3d2678ad0f8a1913546e68472dace4c5489fb7e3a6e2199d0a95d`.
Its exact source revision was not embedded in the bundle and is not assumed.
The rollback bundle is kept outside the repository.

Initial process samples identified substantial main-thread SwiftUI/AppKit layout
work and repeated calendar timestamp parsing. Xcode 26.3 Instruments reported
the local macOS 27.2 target offline and failed to connect to DTServiceHub. A later
device listing succeeded, but recording still rejected a verified live synthetic
test PID despite its debugging entitlement. Actual presented-frame measurements
remain unverified until recording works.

The first foreground optimized run on November 1, 2026 completed 96 of 100
programmatic mode switches before another app took focus. It used 106 calendar
events and 1,120 configured messages per synthetic account. These partial results
identify a remaining bottleneck; they are not an acceptance run.

| Retained destination | Completed samples | p50 | p95 | p99 |
| --- | --- | --- | --- | --- |
| Calendar | 48 | 257.0 ms | 283.2 ms | 291.2 ms |
| Mail | 48 | 1,453.0 ms | 1,473.7 ms | 1,475.2 ms |

The main-actor heartbeat recorded 112 delays of at least 100 ms, with a maximum
of 1,458.2 ms. Warm switches did not repeat calendar or mail-list preparation.
Process samples instead showed repeated native hosting-view layout, key-view-loop
work, and toolbar updates. A background structural test preserved both mail-table
identities and scroll offsets and recorded no transient table or probe detachments.
Attachment counters alone did not explain the layout cost. A subsequent
background test forced graph updates and reproduced heavy main-thread CPU work.
Neither nonzero inactive opacity nor disabling automatic key-loop recalculation
removed that work, so neither is a production remedy.

Isolating the mail columns from toolbar inputs passed background checks for
Outbox, search, reader selection and reader-pane visibility. Early Debug controls
forced extra layout passes; their numbers do not represent navigation latency.
The optimized control using natural layout invalidation recorded 281–295 ms of
Mail CPU and 137–152 ms of Calendar CPU outside the sampled interval. Inset
publications stayed at zero. This hosted default fixture also emits SceneStorage
warnings and contains four mail rows and no calendar events. Keeping Mail at
constant opacity beneath Calendar did not reduce this cost: Mail used 277–330 ms
and Calendar 142–156 ms outside the sampled interval. That experiment was removed.
These are diagnostic CPU measurements, not foreground navigation percentiles.
Consolidating three identical Mail timing probes into one preserved all metrics
and passed nine navigation tests plus the workspace test. The same control still
used 275–303 ms of Mail CPU and 135–148 ms of Calendar CPU after its first sample,
so the probe hosts were not the dominant cost.
Remaining toolbar/layout cost is still under investigation.

A single-child container around the mail columns also showed no improvement:
Mail median CPU was 284.4 ms in both variants. Native item identities, toolbar
order, column geometry and row insets matched. The experiment was removed while
its useful regression coverage was retained.

The toolbar's selection-dependent content now has separate View bodies. A
windowless observation baseline and regression check show that selection changes
no longer invalidate the toolbar declaration, while the affected actions still
observe selection and read-state updates. Native popover and keyboard behavior
still need verification; this dependency result alone is not a speed guarantee.

A later foreground run at `c1961b2` completed all 200 mode switches with zero
failures, using the 100-event fixture. Each direction has 100 samples:

| Retained destination | p50 | p95 | p99 |
| --- | --- | --- | --- |
| Calendar | 188.24 ms | 215.42 ms | 232.95 ms |
| Mail | 356.91 ms | 412.44 ms | 434.75 ms |

The build is faster than the earlier measured revision, but both directions
still fail the contract. Content-ready p95 is 23.85 ms for Calendar and 25.25 ms
for Mail. Most time remains between readiness and the native drawing commit:
p95 193.36 ms and 388.02 ms respectively. The heartbeat recorded 212 stalls of
at least 100 ms, max 452.96 ms. These timings use programmatic navigation and
native drawing commits; physical input and GPU presentation remain unmeasured.

App footprint grew from 228.5 to 309.8 MiB; the last 100 switches account for
4.9 MiB of that growth. Stored corpus bytes stayed fixed and no reader WebViews
were attached. This does not establish a memory plateau or a leak. Raw results,
phase distributions and provenance are in
`evidence/20261101T100342Z-100-workspace-only-normal/`.
Two earlier launches failed foreground eligibility and collected no samples;
they are excluded from performance comparisons.

A background visibility-only control kept real mode, search, title and focus
changes while freezing toolbar visibility declarations. Median main-thread CPU
changed from 273.8 to 204.1 ms for Mail and 166.0 to 86.3 ms for Calendar.
Separately measured settling work changed from 39.65 to 0.8 ms and 36.6 to
2.0 ms respectively. All native visibility, identity, geometry and search checks
passed in the corrected run. The temporary control is removed: it identifies
work to eliminate but does not implement correct mode-specific toolbars.

The search field now observes its own model updates and scopes Find requests to
their originating mode and model. Three optimized regressions passed, including
retained native field identity, explicit Find, mode switching and folded-field
restoration. These checks establish behavior and observation boundaries; their
effect on foreground navigation latency has not yet been measured.

Selected-text focus observation now lives in Reply and shortcut views, keeping
it out of MainView. Seventeen optimized background tests passed across six
suites. In the same small background fixture, median switch CPU including the
settling tail changed from 313.45 to 201.3 ms for Mail and 202.1 to 202.85 ms for
Calendar. This supports a Mail CPU improvement; it is not a visible navigation
measurement. The experimental native-action fixture could not exercise the
controls and was removed after archiving. Later direct UI checks verified standard
toolbar Reply and its exact selected-text quote; compact and shortcut routes
remain pending.

The audit also supports a reader-only scope with 100 recent selections and
100 locally stored messages requiring preparation. Local selections are spaced
beyond neighbor prefetch, and validation requires actual preparation misses.
The first complete run at `cee3a90-dirty` passed all 200 visibility checks with
zero failures, but missed the latency targets:

| Reader tier | Samples | p50 | p95 | p99 |
| --- | --- | --- | --- | --- |
| Retained renderer | 100 | 326.27 ms | 353.63 ms | 404.70 ms |
| Local preparation miss | 100 | 699.93 ms | 959.37 ms | 987.06 ms |

The retained workspace-redraw proxy p95 was 308.83 ms even though its data-ready marker
arrived within 0.009 ms in every sample. HTML preparation p95 was 0.527 ms across
501 preparations; the local run also prepares neighbors. The heartbeat recorded
333 stalls of at least 100 ms, max 396.85 ms. This points to main-thread display
and scheduling work rather than expensive HTML preparation. Retained navigation
kept two WebViews attached with no creates or destroys; the local scenario kept
three, creating 100 and destroying 99 as expected while cycling the cache.
Raw results, stage distributions and exact dirty-source provenance are retained
under `evidence/20261101T112207Z-100-reader-only-normal/`. No profiler ran during
this measurement. GPU presentation remains unmeasured.

A subsequent Time Profiler launch attempt failed to connect to DTServiceHub.
The exported trace has zero duration and no process or data tables; it provides
no performance evidence. Process sampling is the current profiling fallback.

macOS also produced an automatic CPU report for the accepted reader run: 90 CPU
seconds over 101 seconds. Twenty-one of 36 coarse snapshots include SwiftUI list
diffing, with app frames in ThreadListView row construction reading selection and
rebuilding swipe actions. Fifty-four samples were lost and scenarios are not
separated, so these counts do not provide precise attribution. The source-level
selection dependency is the next optimization target.

A short normal/omitted/normal command-tree comparison completed every visible
switch and found no material benefit from omitting MailCommands. Its CPU medians
matched the second normal run, so the experiment was removed and menus remain
unchanged. Results are in `/tmp/tern-performance-command-controls/`.

Reader sessions now keep a stable display order while retaining their separate
MRU eviction order. Nine focused optimized tests passed, and direct UI checks
verified Collapse, Expand, Find and standard selected-text Reply when the active
reader precedes a hidden session. Performance impact remains unmeasured. The
hosted-test app exited unexpectedly after discarding that draft; logs are
consistent with SIGSEGV, but no crash stack was available. A normal-linkage
standalone reproduction is required before release. The hosted artifact has
duplicate package linkage and is not a timing or installation candidate.

Evidence is retained under
`/tmp/tern-performance-audit-build/reports/20261101T003603Z-100/` and
`/tmp/tern-performance-audit-build/reports/20261101T004216Z-workspace-diagnostic/`.
Background retention test logs are in
`/tmp/tern-workspace-retention-verification-2/test.log`.
The background CPU baseline and column-isolation results are in
`/tmp/tern-workspace-background-cpu-2/test.log` and
`/tmp/tern-workspace-isolation-verification/test.log`.
The optimized control is in `/tmp/tern-performance-release-background-4/`.
A copy of these reports, the original process samples, and the final Core log is
kept in `evidence/`.

The full Core suite passed 590 tests in 101 suites
(`/tmp/tern-perf-core-final-tests.log`). Calendar, preparation, WebKit, and five
reader lifecycle/viewport tests passed focused hosted runs. All four sidebar
methods now pass across separate foreground runs, including assistant sizing.
CalendarLayoutTests, MessageWebViewTests and NativeMailActionTests also passed
before an interrupted foreground suite. ReaderViewportTests and
RecipientAvatarTests remain incomplete in that run; the full hosted suite still
needs a clean final result.
The expanded synthetic transport/corpus suite passed seven optimized tests, and
navigation diagnostics passed nine. The retained-reader focus regression passed
in a background window; internal WebKit descendant focus still needs foreground
validation. Reader latency is measured above and fails; scrolling targets, active-sync/offline timing,
memory plateau, and the final installed universal Release remain unverified.
Foreground testing was authorized and the completed mode run is recorded above.

The latest broad background hosted run passed 394 tests across 62 suites, followed
by five safe WebKit checks. Six suites with foreground or panel paths were
excluded, so this does not replace the required complete foreground run.

A normal universal Release build at `fcb181f` passed arm64/x86_64, embedded revision,
hardened runtime and strict signature checks without audit/test overrides.
The source and lockfiles stayed unchanged. It has not been launched or installed;
this is build verification, not performance acceptance. Logs and metadata are in
`evidence/normal-universal-fcb181f/`.

## Retained-reader result after selection isolation

The controlled normal Release run on November 1 completed 100/100 retained-reader
selections after six warmups, with zero failures or superseded reader generations.
It meets the warm-reader latency target for this synthetic scenario:

| Measurement | Before p50 / p95 / p99 | After p50 / p95 / p99 | Target |
| --- | --- | --- | --- |
| Retained readable content | 326.27 / 353.63 / 404.70 ms | 81.77 / 95.55 / 98.97 ms | p95 ≤100 ms; p99 ≤200 ms: met |
| Workspace-redraw proxy after selection | p95 308.83 ms | 58.27 / 65.90 / 71.17 ms | Actual highlight target unverified |

Retained p95 is 73% lower. The comparison includes the native visibility guard,
stable reader order, selection isolation and functional fixes; it does not isolate
each change's contribution. Selection-only factory work is independently verified:
the native regression now records zero warmed factories, and the 100-selection
audit records zero factories and 1,200 row-body evaluations. All 19 optimized
MessageListTests pass, including rapid selection stability, native/model agreement,
account isolation, metadata changes, and stable table/scroll identity.

The after artifact is clean source `3ddffa27508e54924b85aeb10498cab67f5d6699`,
equivalent to `cbcbe34` plus only the explicit audit start gate. Executable SHA-256:
`4894d2df6227e5a3269901f6b09407e4a8c77446edf4b39ee749a8c7fbc8eab5`.
It is hardened arm64 Release with normal package linkage. It excludes the newer
height/visibility tracing and unaccepted row-controls experiment. The before
artifact is the `cee3a90-dirty` run documented above.

The retained scenario kept two attached WebViews with no creates or destroys.
Prepared documents remained 31,757 bytes, stored bodies 5,340 bytes and inline
resources 19,184 bytes. There were 243 prepared-cache hits and 101 height reports.
App physical footprint moved from 285.9 to 283.9 MB; samples after the first ten
switches stayed between 283.5 and 283.9 MB. This is a short warm interval, not a
hundreds-of-messages memory plateau. WebKit child-process attribution remains
unavailable, so those processes are not included in the app footprint.

The local-preparation scenario completed only 76/100 before foreground eligibility
was lost. Its timings are descriptive only and are not accepted against the local
target. It recorded 91,200 row factories, 386 preparations, 77 renderer creations
and 76 destructions, with three WebViews attached. Newly discovered attachment
metadata explains substantial page-update work; the next row-controls experiment
must preserve those updates while reducing unchanged-row work.

Across the whole partial run, the main-actor heartbeat recorded 105 waits of at
least 100 ms, maximum 230.51 ms. These counts are not separated by scenario and
are not GPU missed-frame measurements. Scrolling targets remain unverified.

The exact frontmost PID was checked before the gate was released. No CUA,
debugger or profiler overlapped measurement. The audit endpoint requires ready
content in the visible viewport followed by a native drawing commit; it does not
measure GPU presentation or input-queue delay before programmatic selection.
This historical schema has no native-input monitor. The whole report fails the
contract because actual highlight latency is unverified and local measurements are incomplete.
The test app was terminated after reporting; this run does not verify graceful
quit. No production installation has occurred.

Evidence, source manifest, raw results and assessment are retained at
`evidence/20261101T143859Z-100-reader-only-normal/`.
For another uninterrupted run, prepare the gated window before asking the user
for availability, then release it immediately when ready.

Future programmatic audits use schema 4 (`891478e`). A count-only local event
monitor starts after setup and foreground eligibility; mouse-down, key-down or
wheel input invalidates the report even if every requested switch completes.
Events continue unchanged and no payload is recorded. App compilation, all nine
NavigationPerformanceTests and validator valid/invalid cases passed. The historical
schema-3 results above retain their original limitations and are not rewritten.

Two later controls produced no accepted optimization. A per-row controls boundary,
with and without an outer selection tag, still rebuilt an unchanged offscreen
body during attachment discovery and was removed. A toolbar-placement
comparison had strong monotonic CPU drift across normal/outer/normal fixtures
and four cross-window generated-UUID assertion failures. That control was also
removed; its CPU values do not establish either a benefit or a regression.
Details and evidence locations are in `docs/research/open-source-performance.md`.

## Complete guarded baseline before the visual-row change

The schema-4 run at `4077af18c898e08feabe61f1d18b3d8306d84943` completed 100/100
retained and 100/100 local selections with zero failures and zero unexpected
native input. It contains the verified selection/list boundary and audit guards,
and excludes the later `f0d5692` visual-row leaf.

| Measurement | p50 | p95 | p99 | Target result |
| --- | --- | --- | --- | --- |
| Retained readable-content commit | 63.23 ms | 70.30 ms | 76.72 ms | 100/200 ms met |
| Local preparation miss | 330.32 ms | 480.50 ms | 491.09 ms | 200 ms not met |

The retained workspace-redraw proxy p95 was 61.21 ms; actual highlight latency
was not measured. The local scenario intentionally cancels selection-feedback spans when the selected list
row is offscreen; only its reader/header endpoints are assessed. Local header
p95 was 110.86 ms. Preparation itself remained cheap: 501 preparations at p95
0.460 ms; 209 list projections at p95 1.921 ms.

Retained counters were zero row factories, 1,100 visual bodies and 208 prepared
hits. Two WebViews stayed attached without churn; prepared documents, stored
bodies and inline resources stayed at 31,757/5,340/19,184 bytes. App footprint
went from 285.36 to 283.38 MB. Local loading recorded 118,800 factories and 3,278
visual bodies, with 100 renderer creations/99 destructions and three attached
WebViews. Prepared data grew to 1.624 MB as the corpus grew; this does not prove
a memory plateau. App-only local footprint peaked at 296.57 MB and ended at
264.49 MB. WebKit child-process ownership remains unattributed.

The whole run recorded 127 main-actor heartbeat waits ≥100 ms, maximum 232.96 ms.
These are not per-scenario GPU frame measurements. Window bounds, display refresh
rate and native visible-row count were not recorded. The earlier retained run
evaluated 1,200 visual bodies rather than 1,100, so equal geometry cannot be
asserted retrospectively. Historical deltas are descriptive combined-change
comparisons, not an isolated attribution. Future runs must record geometry.

The normal hardened arm64 executable hash is
`7293e518febb4bbbcfa6458a92a2899a6792c556fa98fea318d364bae0cbec36`.
Evidence and complete cache/memory/stage reports are in
`evidence/20261101T153445Z-100-reader-only-normal/`.
The later visual-row candidate passed 28 focused tests and built successfully,
but no after timings were collected within the three-minute user slot. No new
production installation has occurred.

## Selection feedback and hover verification

The hover changes use the existing 6% tint and 120 ms motion token on mail and
sidebar rows. Selected rows suppress the tint; Reduce Motion disables its
animation. Only the decorative background animates. The delayed-body regression
confirms that native list selection updates before bodies arrive, a late prior
body cannot change the current selection, and hidden readers do not mark mail read.
Twenty MessageList and twelve Navigation checks pass in optimized hosted tests.
The native blue selection was seen in the standalone app; mail/sidebar hover
appearance still needs a completed visual check.

The new opt-in feedback endpoint, `selectedNativeRowDrawingProxyV1`, requires the
current account/mailbox identity, singleton native selection and an intersecting
row viewport at both local probe drawing and its queued completion. Ordinary
launches create no such row probes. This measures native selected state plus a
drawing callback and main-queue turn. It does not observe `NSTableRowView.drawSelection`
or GPU presentation and cannot be compared with historical workspace-probe values.

The November 1 run at 17:49 UTC completed 100 retained and 100 local selections
with zero failures and zero unexpected native input. Selections were programmatic;
these timings exclude native input-queue delay before the model receives selection:

| Measurement | p50 | p95 | p99 | Target result |
| --- | --- | --- | --- | --- |
| Selected native-row drawing proxy, retained scenario | 62.35 ms | 74.85 ms | 92.40 ms | 50 ms p95 not met |
| Retained readable-content commit | 76.12 ms | 90.71 ms | 115.08 ms | 100/200 ms met |
| Local preparation miss | 354.76 ms | 514.96 ms | 552.54 ms | 200 ms not met |

Retained header p95 was 74.84 ms; local header p95 was 141.16 ms. All retained
reader samples used retained sessions; all local samples required preparation
from stored bodies. At the report snapshot, twelve feedback probes were attached,
with one eligible in the retained scenario. Local selections outside the realized
rows intentionally cancel feedback spans; they are not counted as highlight
measurements.

Warm selections built zero row models and evaluated 200 visual rows, plus 1,200
lightweight selection observers. There were 211 prepared-cache hits and 100
height reports. Two WebViews remained attached without renderer churn. App
physical footprint moved from 255.85 to 246.97 MB. Local selections built 118,800
row models, evaluated six visual rows and 2,388 selection observers, and recorded
501 preparations, 100 WebView creations and 99 destructions. Attached WebViews
increased from two to three; footprint moved from 251.68 to 261.74 MB. The local
body/resource corpus and prepared cache grew, so this is not a memory-plateau
measurement.

Selection readiness p95 was 0.006 ms and readiness-to-row-proxy p95 was 74.84 ms.
The remaining measured delay is after model readiness, though the proxy can
trail native highlight drawing. Local preparation p95 was 0.514 ms and list
projection p95 was 2.526 ms; these small stages do not explain the full delay.
The whole-run heartbeat counted 128 of 1,020 waits at least 100 ms, maximum
231.49 ms. These are neither per-scenario attribution nor missed-frame counts.

The measured window was 1280×800 points at (212,63), with display metadata
recorded before release. No CUA, debugger or profiler overlapped measurement.
The gate released at 17:49:41.553 UTC, the report was captured at 17:50:34.871,
and exact-owned cleanup stopped the process at 17:50:41.610 within the user's
two-minute slot. This does not establish graceful quit. The validator correctly
failed the feedback, local-content and local-header budgets. No scrolling or
normal-mailbox acceptance claim follows from this run.

The clean source was `d3c105ae8757c8ba9e1daa989760335fffff7a4a`, derived from the
visual-row candidate plus hover, delayed-body regression and row diagnostics.
It excludes the pending prefetch experiment and Stage A layout tracing. The
normal hardened arm64 executable SHA-256 is
`b31f96ae1f294aa31d406b1adb701a65d2719dae72632d9706afbcf4a503f11b`.
Raw results, gate metadata and process reports are in
`evidence/tern-selection-feedback-reader-20261101T174918Z/`.
The previous baseline did not capture geometry and used different diagnostics;
reader differences cannot be attributed to the visual-row or hover change alone.
The active selection-feedback goal remains incomplete, and the production app
has not been replaced.

The next candidate, `5fb16af`, removes redundant reader-store publications.
Before the change, retained activation and no-op source restoration notified
observers despite unchanged displayed membership and source-retention flags.
The hidden-reader MRU suffix did change after activation, so simply suppressing
notifications would have been wrong. The candidate predicts that order in the
first presentation, keeps MRU bookkeeping unobserved, and publishes real
membership/source changes. All four observation tests pass after reproducing
two expected failures on the original code; the full focused run passed 31
checks, including native selection before body delivery. Evidence is archived
in `evidence/tern-reader-observation-baseline/` and
`evidence/tern-reader-observation-candidate/` under the same backup root.
This demonstrates fewer redundant notifications. Its effect on visible latency
still needs a controlled Release comparison.

A later partial run on `a086e262` recorded 100 retained selections with zero
scenario failures. Readable-content p50/p95/p99 was 53.13/63.43/79.14 ms; the
selected-row drawing proxy was 41.70/54.89/64.15 ms. These values are provisional:
the runner stopped after 18 seconds without the final report or native-input
validity total. The local snapshot contains only ten selections. Do not treat
the partial run as passing the performance contract or infer zero native input.

The outer window/display geometry matched the prior run, but 11 attached probes
and 1,100 selection observers differed from the baseline's 12 and 1,200. Internal
column geometry was not recorded. Zero row factories, 200 visual evaluations,
204 prepared hits and two attached WebViews were recorded; prepared data remained
31,757 bytes and app footprint moved from 271.52 to 269.58 MB. WebKit child memory
and the whole-run heartbeat were not captured. These limits prevent a clean
causal before/after claim.

Root released this run at 18:48:14.810 UTC, too late in the user's
18:46:17–18:48:17 slot. The relative watcher budget then ended at 18:48:32.849,
15.85 seconds after the promised stop. The next runner must enforce an absolute
availability deadline and reserve cleanup time. Evidence is preserved under
`evidence/tern-reader-session-partial-20261101T184736Z/`.

The complete run on the same `a086e262` artifact at 19:21 UTC supersedes that
partial run for acceptance. It completed 100 retained and 100 local selections
with zero scenario failures, zero unexpected native input and no report error.
The fixed-deadline runner released at 19:21:33.185 and confirmed the test PID
gone at 19:22:28.377, inside the 19:21:14–19:23:14 availability window.

| Measurement | Prior complete run p95 | Current p50 / p95 / p99 | Target result |
| --- | ---: | ---: | --- |
| Retained readable content | 90.71 ms | 53.91 / 60.73 / 66.09 ms | Pass: p95 ≤100 ms, p99 ≤200 ms |
| Selected native row drawing proxy | 74.85 ms | 43.16 / 54.14 / 59.33 ms | Fail: p95 ≤50 ms |
| Local content requiring preparation | 514.96 ms | 337.57 / 490.84 / 498.07 ms | Fail: p95 ≤200 ms |
| Local header | 141.16 ms | 103.07 / 110.10 / 134.79 ms | Fail: p95 ≤100 ms |

These are programmatic selections. The selected-row endpoint remains a native
state/drawing proxy, not GPU presentation or physical input latency. The outer
window/display geometry matched the prior complete `d3c105a` run, but attached
probes differed (12 versus 11), and internal geometry was not recorded. The
table is a descriptive comparison; it does not isolate the reader-store change's
causal effect. The focused observation regressions independently establish that
the change removes redundant notifications while preserving real updates.

The retained scenario recorded zero row factories, 200 visual body evaluations,
1,100 selection observers, 240 prepared hits, 100 height reports and two attached
WebViews throughout. Prepared data remained 31,757 bytes. App footprint moved
from 270.06 to 267.62 MB. Local openings recorded 118,800 row factories despite
only one visual body evaluation, 501 preparation misses/renders, 100 WebViews
created and 99 destroyed, with attached views moving from two to three. Local
app footprint moved from 287.69 to 299.70 MB while the prepared/stored corpus grew.
The final app footprints exceed the prior run's 246.97/261.74 MB; these single-run
snapshots do not establish a causal memory regression or a plateau. Five possible
WebKit subprocesses had no responsibility attribution and cannot be summed as
the test app's children.

Whole-run heartbeat recorded 127 of 983 gaps at least 100 ms, with a 220.66 ms
maximum. This mixes phases and does not measure scrolling frame loss. Local
preparation itself was short (501 spans, p95 0.47 ms); the resource stage's
p95 was 153.67 ms, which includes waiting and delivery. Further attribution is
needed before changing that path. Local list reconstruction remains a measured
source of repeated work, with its contribution to elapsed time still unisolated.

Raw reports, gate/cleanup records, validation and analysis are archived under
`evidence/tern-reader-session-reader-20261101T192114Z/`.
Hover appearance, mode switching, scrolling and normal-mailbox verification
remain incomplete. No new production build has been installed.

The final change before the user's requested manual-testing pause is `fa1c75e`.
Mailbox page publication previously mutated selected-thread and selected-message
sets even when their intersections were unchanged. Two conditional assignments
now preserve those sets without publishing a selection change. Real removals
still prune selection, and account-qualified IDs remain intact.

A regression drives actual attachment publication and thread deletion in both
list modes, with matching bare message/thread IDs across two accounts. The
unchanged-code baseline reproduced five no-op notification failures while its
pruning/survivor checks passed. The candidate passed the full 21-test MessageList
suite with the same test bytes, including the existing selection-before-body
and stale-completion integration checks. This proves reduced notifications;
its contribution to row construction or visible latency remains unmeasured.
Evidence is archived in `evidence/tern-mailbox-selection-{baseline,candidate}/`
under the same backup root. No further benchmark is planned before the manual
testing handover requested by the user.

For that handover, the full committed `fa1c75e` source was built as a normal
universal Release and installed at `~/Applications/Tern.app`
at 20:07:02 UTC. It includes the sidebar, Favorites, saved-search, Calendar-sidebar
and mail-row hover changes. Both architectures, strict signature, embedded
revision, normal build flags and unchanged OAuth configuration were verified.
The installed executable SHA-256 is
`dcfb64f4023a1dbffa12ced540598426833d708248d3b5565df24f8407ba775c`.
The prior app is preserved for rollback. Installation/provenance is recorded in
`evidence/tern-manual-release-verification/installation.json` and canonical
`build/Tern-build-info.json`.

The user reported that the app felt much faster after reopening it. This is
manual feedback, not another timing sample. Work is paused at their request;
the remaining performance targets and hover appearance need subsequent feedback
or measurement before claiming completion.

## Smoothness pass, 13 November 2026

This pass covers `bed7ebd4..1f4b12b1` on `fix/smoothness-pass`. It changed how
the views observe the store, how a message opens, how the lists and the calendar
redraw, and what fits at each window width.

The numbers in this table come from the hosted Debug-Testing app with synthetic
data. Each was taken by the tests or probes of the change it belongs to, before
and after that change on the same Mac. They are not acceptance results.

| Measurement | Before | After |
| --- | --- | --- |
| Main-thread block when a message opens its web view | 46–56 ms | 1.2–1.8 ms with the spare view |
| Time to a message's first reported height | 107–128 ms | 14–17 ms with the spare view |
| Row factory runs when one conversation is starred, 61-row page | 61 | 0 |
| Body runs of an untouched retained reader on a selection change | 1 | 0 |
| Calendar grid body runs on a selection click | 1 | 0 |
| Pasted-image PNG encoding on the main actor | 240–2,758 ms | 0 ms, encoded off the main actor |
| Width a week needs before it scrolls sideways | 736 pt | 512 pt |

### Layout at each width

The synthetic app captured its own window in-process, through
`Tests/AppTests/ReadmeScreenshots.swift` with extra sizes that were not
committed, and each image was read: Mail at 720, 1,100 and 1,500 points; the
week at 720, 960 and 1,500; the day at 720; the month at 720, 900, 960 and
1,500; Today at 720 and 1,500; Waiting for at 1,100; the week in dark Increase
Contrast at 960; and the Tasks panel and the assistant at 1,500. The week fit at
720 points without a sideways scroll, and the toolbar folded its controls with
none left in the overflow menu.

The month view had one flaw. At 720 points a chip kept its time and cut the
title to two or three letters. A chip now drops the time when the title beside
it would get less than 48 points (`1f4b12b1`), and every chip in a month changes
at the same cell width.

These are still images. The Favorites animation, the dimmed task row, the
summary's landing, the spare web view's refill and the week swipe were not
watched in motion.

### A message body that stayed blank

One of twelve capture runs timed out after 15 seconds waiting for the selected
message's body. It was the first run of a fresh process, the cause was not
found, and the eleven runs after it passed. A blank body is what a web content
process that ended leaves behind, and the reader did not handle that case on
`main` either. The message view now loads its message again, at once when its
reader is shown and otherwise when it is next shown (`bbff9047`). Whether that
case caused the failed run is unknown.

### `main` against the branch

Two optimized `TERN_PERFORMANCE` builds ran back to back on this Mac: `main` at
`bed7ebd4` and the branch at `1f4b12b1`. The `main` build carries the code of
`47eb9bbd` uncommitted, six files under `App/Performance`, `App/LaunchMode.swift`
and `scripts/`, so that it accepts the unattended variant. Each scope ran once
per build with `bash scripts/benchmark-navigation.sh 100 <scope> unattended`,
`main` first, after three minutes without keyboard or pointer input. Unattended
timings compare two builds and cannot pass the acceptance targets, and with one
run per build a difference of a few milliseconds is noise.

All 200 mode switches and both sets of 100 selections completed on both builds
with no failures and no unexpected native input.

| Measurement | `main` p50 / p95 / p99 | Branch p50 / p95 / p99 |
| --- | --- | --- |
| Warm switch to Calendar | 401 / 494 / 713 ms | 257 / 362 / 394 ms |
| Warm switch to Mail | 374 / 502 / 634 ms | 255 / 337 / 370 ms |
| Stored message needing preparation, readable | 750 / 1,691 / 1,859 ms | 401 / 533 / 704 ms |
| Stored message needing preparation, header | 231 / 445 / 538 ms | 218 / 271 / 299 ms |
| Retained message, readable | 117 / 144 / 149 ms | 117 / 138 / 153 ms |
| Retained message, header and row proxy | 85 / 105 / 107 ms | 88 / 110 / 123 ms |

Mode switches and stored messages are faster on the branch; retained messages
are unchanged. The branch still misses the targets: a return to a mode or to a
rendered email has a 100 ms p95 target, and a stored message 200 ms. Final physical footprint was
259 MB on `main` and 257 MB on the branch after the workspace run, and 312 MB
and 306 MB after the reader run.

Sustained scrolling, 30 seconds a surface, by the display-link callback proxy.
The first run of this scope could not find the mailbox list on either build, and
the Mac came back into use during the branch's turn. The lookup was fixed
(`e4024a71`, applied to the `main` build as well) and the scope ran three more
times per build, each after 150 seconds without input. The ranges cover the
three runs:

| Surface | `main` | Branch |
| --- | --- | --- |
| Mailbox | 1,701–1,708 callbacks, 12.3–12.5% delayed, 2 stalls of 100 ms or more, longest gap 378–448 ms | 1,736–1,741 callbacks, 12.9–14.3% delayed, 2 stalls, longest gap 129–135 ms |
| Reader, 20 messages | 1,635–1,638 callbacks, 5.7–5.9% delayed, no stall | 1,635–1,637 callbacks, 5.7% delayed, no stall |
| Reader, 100 messages | 1,628–1,638 callbacks, 6.8–6.9% delayed, no stall | 1,630–1,632 callbacks, 6.9–7.0% delayed, no stall |
| Calendar | 1,787–1,789 callbacks, at most 0.1% delayed, no stall | 1,787–1,789 callbacks, 0.1% delayed, no stall |
| Attachments | Surface not found | Surface not found |

Scrolling is the same on both builds: the changes up to `1f4b12b1` did not make
it smoother, and the mailbox and the reader exceed the 1% budget for delayed
callbacks. The next section covers what was then found in the mailbox. The
first run had shown 18 and 73 stalls in the reader on `main` and none on the
branch. The three later runs showed none on either build, so that difference did
not come from the pass. The branch's longest mailbox gap was shorter in all
three runs. No run found the attachment surface. The benchmark's mail has no
files, so the library was empty, and only the card layout carried the scroll
marker. Since `d03d9f6d` the list layout is marked too, and since `a09c69a4` the
audit stores 300 synthetic files before that scroll. The list's figures are
under "`main` against the branch's last build" below. The reports are in
`~/Downloads/tern-benchmark/main` and `~/Downloads/tern-benchmark/branch`,
outside this repository.

### What delayed the mailbox scroll

`sample` recorded the branch build's main thread every millisecond for 18
seconds of the mailbox scroll. About a quarter of the samples were in work that
had nothing to do with drawing rows: 9.2% under
`NSHostingView.preferencesDidChange()`, where the window worked out its focus
again, 6.4% rebuilding the toolbar's menus, and much of the layout pass those
two forced. The app's own code was under 1%.

Each row's star button had a focus binding, so that the star stays visible while
it has keyboard focus. A focus binding registers its view with the window, and
rows registering and leaving as they scrolled changed the window's focus list on
almost every frame. Buttons take keyboard focus only while Keyboard navigation
is on in System Settings, so a row now binds the star's focus only then. With
the setting off, as it was for every run here, the same profile shows 0.1% and
0.0% in those two places, and hosting-view layout falls from 36.8% to 18.0% of
the samples. With the setting on, the binding and its cost remain.

Two stalls of 100 ms or more were left in every run. Each row also carried two
popovers, for the snooze date and for the sender, that are closed almost all the
time. In a trial build where a row had a popover only while it was open, the
stalls did not appear in any of three runs. The trial was not kept: its snooze
popover stayed closed when it was asked for in the same moment it had closed.

Since `40daeb8e` the list has one snooze popover and one sender popover, pointed
at the row that asked. The missed opening had a plain cause. A request made in
the frame a popover closed went from set to cleared to set again before the view
was drawn, so the view saw no change. Each request now differs from the one
before it. The sender popover on every row had the same fault and then ignored
every later request for that row. Two unattended runs of this build showed 1.1%
and 1.8% delayed callbacks, with one stall of 101 ms in the first and none in
the second. A third run took a click from the person at the Mac and is left out.
In the same two runs the reader showed 6.7–8.0% and 9.0–9.7% delayed callbacks,
above the 5.7% and 6.9–7.0% measured earlier in the day. `main` was not run
alongside those two. It was later; see "`main` against the branch's last build".

| Build | Runs | Delayed callbacks | Stalls of 100 ms or more | p95 gap | Longest gap |
| --- | --- | --- | --- | --- | --- |
| Branch at `1f4b12b1` | 3 | 12.9–14.3% | 2 in each | 27.4–27.8 ms | 129–135 ms |
| Star focus bound only when buttons take focus | 3 | 1.5–1.9% | 2 in each | 20.1–20.3 ms | 122–135 ms |
| Trial: popovers only while open | 2 | 2.4% and 12.9% | None | 21.4 and 27.2 ms | 90 and 51 ms |
| Trial: both, with the binding removed | 1 | 1.5% | None | 20.0 ms | 67 ms |
| One popover of each kind for the list (`40daeb8e`) | 2 | 1.1% and 1.8% | One of 101 ms, then none | 17.3 and 19.4 ms | 101 and 51 ms |

The two popover runs disagree on delayed callbacks. The profile of that build
matched the profile before it, so the popovers do not explain the delayed
callbacks, and the 2.4% run, which began right after its build, is not
comparable with the others.

The reader was sampled the same way during its 20-message scroll. Hosting-view
layout took 47% of the main thread's samples, the lazy stack's sizing about 15%
and the creation of message web views, with the start of their web content
processes, about 7%. The focus work was 1.4%. Each message keeps its own web
view by design, so the reader's scrolling was left as it was, at 5–7% delayed
callbacks.

The Tasks rows and the sidebar's disclosure rows bound focus per row in the same
way. Both now bind their buttons' focus only while buttons take keyboard focus,
as the star does. Neither list was measured.

### `main` against the branch's last build

The scroll scope ran again late in the day on `main` at `bed7ebd4` and on the
branch's code as of `a09c69a4`, the two builds taking turns. A run counts here
only if it took no keyboard or pointer input, kept the foreground and ran with
the screen unlocked. Two runs of `main` and two of the branch met that. One of
the branch's two was the `normal` variant, the only run of this pass that the
benchmark counts as attended. Whether anyone watched it was not recorded. The
two runs at `40daeb8e` from the section above are in the branch column as well.

| Surface | `main`, 2 runs | Branch, 3 unattended runs and the attended one |
| --- | --- | --- |
| Mailbox | 8.1% and 11.2% delayed, 2 and 3 stalls of 100 ms or more, longest gap 417 and 760 ms | 1.1%, 1.8% and 1.3% delayed, attended 1.5%; one stall of 101 ms in the first run and none after; longest gap 50–101 ms |
| Reader, 20 messages | 5.8% and 5.9% delayed, no stall | 6.7%, 8.0% and 6.4% delayed, attended 6.7%; no stall |
| Reader, 100 messages | 7.1% and 8.1% delayed, no stall | 9.0%, 9.7% and 8.0% delayed, attended 8.1% with one stall of 100 ms |
| Calendar | 0.2% delayed, no stall | 0.1% delayed, no stall |
| Attachments | Not measured: no files to scroll | 0.6% delayed over 1,781 callbacks, attended 0.1% over 1,789; no stall |

The mailbox is where the pass shows. Its delayed callbacks fell from 8–11% to
1–2%, and the gaps of 400 ms and more are gone. The calendar and the attachment
list are inside the 1% budget. The mailbox is close to it and the reader is
well outside.

The reader measured a little worse on the branch: about one point more delayed
callbacks at 20 messages, and between nothing and two and a half points more at
100. The cause was not found. Nine earlier runs of four builds of the branch,
the star-focus build among them, showed 5.2–6.0% and 6.6–7.5%. What changed
after them is the mail list's popovers and the benchmark's scroll marker, and
none of it is reader code. Six runs are too few to rule out the machine, and
a discarded branch run, described below, showed 5.3%.

A later pair of runs sampled the main thread during the 20-message scroll on
both builds. The list popovers, the mail rows and the scroll marker took no
samples in the branch's profile, and that profile matches the one taken before
those commits. In the same pair the 100-message scroll, which was not sampled,
showed 7.0% on the branch and 7.5% on `main`. The sampled scroll showed 10.0%
and 10.4%, and the mailbox 1.3% and 14.5%. So the reader's difference in the
table is more likely variation between runs than the build.

The mode switches ran once more on the branch's last build, unattended, with no
run of `main` beside it. All 200 completed: 208 / 317 / 332 ms to Calendar and
203 / 305 / 352 ms to Mail (p50 / p95 / p99), against 257 / 362 / 394 ms and
255 / 337 / 370 ms at `1f4b12b1`. They still miss the 100 ms target. The main
actor was held for 100 ms or more in 203 of 256 heartbeat samples, so the time
goes to work on the main thread after the content is ready.

Those figures overstate the build. The run's first 60 switches averaged about
135 ms, and the rest took 225–287 ms for a reason that was not found. A later
run of that build, taken while `sample` recorded it, showed 124 and 120 ms at
the median. "Mode switches and the toolbar" below has that profile, a run of
the same behaviour at 128 and 121 ms, and what changed.

Six more runs were discarded. Three took a click or a key press. Three lost the
foreground when the person came back to the Mac. The mailbox finished in three
of the branch's discarded runs and showed 5.4%, 10.4% and 10.7% delayed
callbacks. The reader in the one of them that reached it showed 5.3% and 7.0%.
So the mailbox figures above describe a Mac nobody is using. Whether the
pointer over the list or the other apps' work made the difference is unknown:
every counted run had the pointer wherever it was left, and a row redraws when
the pointer enters or leaves it.

The hosted suite ran on the same code with the screen unlocked: 1,008 of 1,010
tests passed. `SplitDividerHandleTests`' interrupted-drag test and
`TodayViewTests`' snooze-and-complete test failed. Each suite then passed alone,
twice. The same two failed in the full run at `14cfd33f`. Both passed in the
full run at `cf6caf31` before it, and no Today or divider file has changed
since, so they fail now and then in a full run and not because of a later
change.

### Mode switches and the toolbar

This section and the three after it cover the branch
`fix/mode-switch-and-hover`, which starts at `1e490bee`.

`sample` recorded the main thread every millisecond during the mode switches of
`1e490bee`. With one switch following another the thread was busy for about 98%
of the samples, and Tern's own code took about 1.2% of them. The toolbar took
the most: 33.6% of the samples were under `-[NSToolbarView layout]`, 17.1% under
the toolbar items' hosting-view updates, 15.2% under SwiftUI's reading of the
item list and 8.2% rebuilding the items' menu forms. These overlap. The split
views took under 1%.

Going from Mail to Calendar hides about ten toolbar items and shows three, and
the way back does the reverse. Each item is a hosting view of its own, and
AppKit lays the toolbar out again as they change. All of it ran in the pass that
showed the new section, so the section waited for the toolbar.

The toolbar's items now change after the content. The main view keeps the
section whose items the toolbar shows apart from the section in front, and the
first follows the second after `Tokens.Motion.toolbarFollowDelay`, 34 ms. The
section picker reads the section in front, so it moves at once. Mail's hidden
columns keep their widths until the toolbar follows.

The benchmark changed with it. After each measured switch it waits until the
toolbar shows the section in front and the main thread is free, and the report
records that time as `toolbarFollow`. The validator rejects a workspace or
attachments scenario without it. Before this, a run of switches one after
another would have cancelled every follow and timed a toolbar that never
changed.

Three unattended runs of 200 switches, taken within 20 minutes on this Mac with
that benchmark. The first row is the working tree with the toolbar reading the
section in front directly, which is what `1e490bee` does.

| Build | To Calendar, p50 / p95 / p99 | To Mail, p50 / p95 / p99 | Toolbar settled, p50 / p95 / longest | Main actor held 100 ms or more |
| --- | --- | --- | --- | --- |
| Toolbar in the content's pass | 128 / 132 / 142 ms | 121 / 125 / 127 ms | 130 / 136 / 151 ms | 189 of 459 heartbeat samples, longest 141 ms |
| Toolbar follows, before the picker read the section in front | 47 / 52 / 52 ms | 57 / 61 / 65 ms | 182 / 192 / 207 ms | 2 of 1,050, longest 105 ms |
| Toolbar follows, final | 48 / 51 / 53 ms | 58 / 63 / 65 ms | 182 / 190 / 212 ms | 2 of 1,047, longest 111 ms |

The new section is on screen in less than half the time, inside the 100 ms p95
target in these runs. The toolbar's items change about 50 ms later than they
did, because two passes cost more than one. For about 130 ms after a switch the
toolbar shows the items of the section the person left. Unattended timings do
not count toward acceptance. Today and Waiting for have no switch in the
benchmark.

### The switch in captured frames

A hosted test switched between Mail and Calendar six times each way in a
Debug-Testing window and saved the window's image 60 times a second, once with
the toolbar in the content's pass and once with the follow. A Debug build is
slower than the Release figures above, so these times compare the two builds
with each other only. The test is not in the repository.

| Build | To Calendar, first frame with the new section | To Mail, first frame | Toolbar starts to change |
| --- | --- | --- | --- |
| Toolbar in the content's pass | 203 ms | 189 ms | In the same frame |
| Toolbar follows | 107 ms | 124 ms | 288 ms and 286 ms |

These are medians. AppKit animates a change of toolbar items in both builds,
over 150 to 400 ms. With the follow, the section appears and the items start to
move 160–180 ms later in this Debug build. The benchmark puts that gap near
125 ms in Release. No frame showed an empty or half-drawn section. On the way
back to Mail the reader draws its text once more, 30–45 ms after the section
appears, and it does not go blank in between. The frames were read as stills.
Nobody has watched the switch at speed.

The frames showed a fault that came with the follow. Other sections use Mail's
hidden split to line the toolbar up with their own sidebar, so Mail's sidebar
column takes their width while they are in front: 248 points for Calendar
against Mail's 228 by default. On the first return, Mail drew one frame at
Calendar's width and then moved 20 points. All three captures of a first return
showed it. None of six did with the toolbar in the content's pass, whose longer
pass covered the move. The restore of Mail's dividers ran one turn after the
frame that showed Mail. It now also runs in the update that shows Mail, and the
later turn finishes it. Six returns captured after the change showed no move.
The restore stays out of layout passes: moving a divider from one made the split
lay out without end.

### Mail and the attachment library

The attachment library is a mailbox in Mail's sidebar whose page takes the place
of the list and the reader. Selecting it built the library's whole view tree, a
second sidebar included, and emptied Mail's list. Leaving it removed that tree
and filled the list again. A profile of these switches found little of Tern's
own code. The time was under SwiftUI's list updates, with 13% of the main
thread's samples in the row diff, under `NSTableView` at 22% and under the
toolbar's layout at 14%.

The library is now built on its first use and stays mounted behind Mail, as the
workspace keeps its other sections. Behind Mail it takes no input, is hidden
from accessibility, stops observing the cache and closes its popovers and its
preview.

The benchmark's `workspace-only` scope now runs this switch as well. Unattended
runs of 100 switches each way:

| Build | To the library, p50 / p95 / p99 | To Mail, p50 / p95 / p99 | To Calendar in the same run, p50 / p95 |
| --- | --- | --- | --- |
| Library built on each switch | 148 / 158 / 162 ms | 131 / 144 / 151 ms | 51 / 55 ms |
| Library kept mounted, first run | 89 / 145 / 164 ms | 117 / 212 / 272 ms | 73 / 103 ms |
| Library kept mounted, second run | 90 / 121 / 147 ms | 129 / 176 / 196 ms | 64 / 87 ms |

Another process was using the Mac during the last two runs. The switch to
Calendar, which the change does not touch, ran 25–45% slower in them than in the
first. A run of the same build on a quiet Mac, taken while `sample` recorded it,
gave medians of 88 ms to the library and 124 ms back, with Calendar at 50 ms.

Two more unattended runs on 14 November, in which the Calendar switch ran at
46–47 ms, are in "Runs of the final tree, 14 November" below. Entering the
library took 84–85 ms at the median in all five of their scenarios, with p95 of
90–94 ms. The full run before the change had 137–139 ms and 145–164 ms. That
puts the way in inside the 100 ms p95 target. The way back to Mail took
110–122 ms with p95 of 117–142 ms, against 112–124 ms and 119–139 ms before. It
has not changed by more than the noise and still misses the target.

What is left on the way back is Mail's list. Selecting the library is a mailbox
change, so the list empties, and selecting a mailbox again inserts its rows and
measures their heights. With the library kept mounted, that insertion was about
14% of the main thread's samples across both directions, and the toolbar's
layout and menu forms about 25%.

Two other changes were tried and taken out. Holding the toolbar's follow until
the new section had drawn left the library's times where they were, at 146 ms
and 121 ms, and it kept the old section's toolbar items up for its whole 250 ms
limit whenever the draw went unobserved, as it does in a window that is not
active. Keeping Mail's rows mounted behind the library made the way back faster
and the way in slower by about the same amount: 117–129 ms became 108–111 ms,
and 89–90 ms became 111–112 ms. Every mail row reads the selected mailbox, so
the kept rows ran again on each switch. It would also have evaluated Spam's
rows while another mailbox was selected, and one of the two checks that keep a
Spam row from asking a sender's site for an icon reads the selected mailbox.

The library can match the Calendar switch only if showing it stops being a
mailbox change, so that Mail's mailbox, list and reader stay as they are behind
it. That needs a state of its own for the library in place of a mailbox ID, and
it touches sidebar selection, restoration, the commands, the mailbox switcher,
prefetching and the toolbar. It has not been done.

### Scrolling with the pointer on the list

`TERN_PERFORMANCE_POINTER_ON_LIST=1` makes the scroll scope scroll the mail list
three times: with the pointer parked in a corner of the window, resting on the
list, and parked again. It moves the real pointer and puts it back, and it
counts the rows that gained or lost the pointer. The runs below used the
`normal` variant, started by a script with nobody at the Mac. Each ran after
150 seconds without input and took none.

| Build | Parked | On the list | Parked again |
| --- | --- | --- | --- |
| Row hover fades on every change | 1.4% delayed | 13.9% delayed, 688 hover changes | 1.8% delayed |
| Hover skips its fade under a resting pointer | 1.4% | 1.2%, 773 hover changes | 1.6% |
| The same, final build | 1.7% | 0.3%, 778 hover changes | 1.5% |

A list that scrolls under a resting pointer changes a row's hover about 23 times
a second. Each change started a 0.12-second fade of the row's tint and of its
star, so fades ran for the whole scroll. A profile taken across that scroll and
part of the one after it put the mail row's own code at 0.6% of the main
thread's samples; the time was in SwiftUI's hover handling, AppKit's tracking
areas and hosting-view layout.

Hover state now goes through `ternOnHover`. A change that arrives while the
pointer has been still for longer than a fade lasts applies without animation,
and a change the pointer made still fades. `ternHover` uses it, and so do the
mail, task, unsubscribe, attachment, sidebar and favorite rows, the assistant's
cards, attachment chips, drop targets and notices. The mail row's star also
moved into a view of its own, so a hover change no longer runs the row's body.
That was already in the first row of the table and was not measured apart.

The benchmark scrolls the list in code, 18 points a tick. A scroll by wheel or
trackpad was not measured, and the other lists were not measured with the
pointer on them.

Those three runs and the profiled one also scrolled the reader: 5.0–5.3%
delayed callbacks at 20 messages and 5.5–6.3% at 100. That is at or below the
5.7–5.9% and 6.8–8.1% that `main` showed in the tables above, so the branch's
higher reader figures did not come back. `main` was not run beside them.

### Runs of the final tree, 14 November

The benchmark build of `5cf4db29` has the code of `5b89b097`; the commits
between them change this file only. A script ran it twice on the morning of
14 November, each time once the screen was unlocked and the Mac had gone
150 seconds without input: the short scope, then the full run in its four
transport modes. Both are unattended and neither took any input.

| Switch, p50 / p95 / p99 in ms | Short run | Full run, warm | Active sync | Offline | Delayed |
| --- | --- | --- | --- | --- | --- |
| To Calendar | 46 / 48 / 59 | 47 / 51 / 55 | 66 / 79 / 87 | 61 / 66 / 68 | 61 / 77 / 86 |
| To Mail from Calendar | 57 / 60 / 64 | 58 / 62 / 65 | 78 / 93 / 97 | 79 / 85 / 88 | 80 / 105 / 108 |
| To the library | 84 / 91 / 95 | 84 / 93 / 97 | 84 / 94 / 103 | 85 / 90 / 100 | 85 / 91 / 98 |
| To Mail from the library | 118 / 142 / 147 | 122 / 136 / 144 | 118 / 126 / 128 | 113 / 120 / 129 | 110 / 117 / 119 |

The full run before the library change is the comparison. Its Calendar medians
were 1 to 3 ms higher than these and its Mail medians 0 to 8 ms higher. In the
delayed mode its tails were shorter: p95 of 66 ms to Calendar and 90 ms to
Mail, where this run has 77 and 105 ms. One run of each cannot say whether the
build did that. Mail's 105 ms is the only Calendar or Mail p95 over the 100 ms
target.

In the warm scenarios the toolbar settled 180 and 183 ms after a Calendar or
Mail switch at the median, and in the other three modes 213–221 ms. After a
library switch it settled in 207–213 ms.

Message selection did not move. In every scenario of 100 or more selections the
median time to a readable message was within 4 ms of the earlier full run:
50–51 ms for a retained message, 151–161 ms for a stored one and 689 ms from
the network.

The footprint after each scenario was 2 to 11 MB above the earlier run's
through the first twelve scenarios, the four library ones among them, and 15 to
53 MB below it in the last six.

The whole hosted suite ran on the same tree between the two benchmark runs,
with the screen unlocked: 1,009 of 1,010 tests passed. The interrupted-drag test
failed again. Both sidebar tests in the locked-screen table below passed.

That test fails when the test host is the active app. Under a locked screen it
is not, and the test passes. It had passed alone, most likely because the host
is not yet active that early. The resize handles tested the pointer against
`visibleRect`. A view that does not clip reports a visible rect as large as its
nearest clipping ancestor's, which for the test's 12-point handle was the whole
600-point window. A drag released anywhere in that rect left the handle
highlighted. The calendar's scroll navigation tested scroll events against the
same rect. Both now use the view's bounds cut to its visible rect (`92d16309`),
and the suite then passed 1,010 of 1,010 with the screen unlocked. Which
ancestor clips in the app's own windows was not checked, so it is not known
whether either fault showed there.

The full run's scroll phase does not count. The benchmark app lost the
foreground 353 callbacks into the mail list's scroll, the other four surfaces
never started, and the Mac was in use when the run ended. A scroll run of the
same benchmark build, which does not have `92d16309`, followed 22 minutes later
with the pointer option, a minute after that second suite run had finished. It
took no input and kept the foreground. Two more runs that morning lost the
foreground within a minute, as the Mac came back into use, and do not count.
Every run after them waited for ten minutes without input, not 150 seconds.

| Surface, delayed callbacks | This run | Three runs before the library change |
| --- | --- | --- |
| Mail list, pointer parked | 1.4% | 1.4–1.7% |
| Mail list, pointer on it | 1.8%, 774 hover changes | 0.3% and 1.2% with the hover change |
| Mail list, parked again | 1.5% | 1.5–1.8% |
| Reader, 20 messages | 7.3% | 5.0–5.3% |
| Reader, 100 messages | 7.6% | 5.5–6.3% |
| Calendar | 0.1% | 0.1% |
| Attachments | 0.6% | 0.3–0.6% |

No surface had a stall of 100 ms. The reader is 1.3 to 2.3 points higher than
in those runs, and the mail list under the pointer 0.6 to 1.5 points higher.
The library is built on its first use, which in this scope comes after the
reader's scroll, so keeping it mounted cannot have acted on either. One run
cannot tell the build from the state of the Mac. The next section runs two
builds in turn.

### The final build beside the tree before it

A second run of the same build at 11:04 agreed with the first: 3.2% with the
pointer on the list, 7.5% and 8.4% in the reader and 1.1% in the library. The
mail list had one stall of 115 ms with the pointer parked.

`c4d42865` was then built as the benchmark app. It is the tree the three
earlier runs used, before the column restore (`abd64e3f`) and the mounted
library (`37d5a9f7`). The two builds ran in turn with the pointer option.

| Surface, delayed callbacks | Earlier tree, 11:35 | Final build, 12:12 | Earlier tree, 12:16 | Final build, 12:20 |
| --- | --- | --- | --- | --- |
| Mail list, pointer parked | 1.7% | 0.8% | 1.8% | 1.6% |
| Mail list, pointer on it | 1.4% | 0.2% | 4.9% | 5.3% |
| Mail list, parked again | 1.0% | 1.3% | 1.5% | 1.5% |
| Reader, 20 messages | 6.0% | 4.5% | 4.8% | 5.0% |
| Reader, 100 messages | 9.2% | 5.9% | 5.8% | 5.6% |
| Calendar | 0.0% | 0.2% | 0.1% | 0.1% |
| Attachments | 0.7% | 0.4% | 0.3% | 0.4% |

None of the four took input in the app, lost the foreground or had a stall of
100 ms. The Mac took one input 111 seconds before the 11:35 run ended, close to
the reader's two scrolls.

The build does not explain the morning's figures. After midday the final
build's reader showed 4.5% and 5.0% at 20 messages and 5.9% and 5.6% at 100, at
or below the 5.0–5.3% and 5.5–6.3% of the evening before, and the earlier tree
had shown 6.0% and 9.2% at 11:35. Back to back at 12:16 and 12:20, the two
builds were within half a point of each other on every surface. What the Mac
did differently in the morning was not found.

The mail list with the pointer on it ranged from 0.2% to 5.3% on the final
build and from 1.4% to 4.9% on the earlier tree, which had shown 0.3% and 1.2%
the evening before. A callback counts as delayed when it comes more than 25 ms
after the last, one and a half frames. With the pointer on the list the 95th
percentile of that gap was 22.6 to 25.1 ms in each of the eight runs since the
hover change, against 17.2 to 19.7 ms with the pointer parked in the same runs,
so the share depends on which side of the line that twentieth of the callbacks
falls. None of the eight had a gap over 50 ms. Six are over the 1% budget.

Two runs do not count. One of the final build at 11:08 and one of the earlier
tree at 11:32 lost the foreground during the reader's first scroll, though the
Mac took no input. What took it was not found. Their mail-list scrolls had
finished by then: 1.9%, 3.1% under the pointer and 1.6% on the final build;
1.3% with one stall of 159 ms, 2.4% and 1.4% on the earlier tree.

### A process pool for every message view

The final build's scroll over 20 messages was sampled every millisecond for 20
seconds. The sampling slowed the scroll (5.9% delayed, 31 stalls), so that run's
timings do not count. Of 7,787 main-thread samples, 8.4% were in
`MessageWebView.makeNSView`. Most of that, 6.7% of the samples, was
`WebProcessPool::registerUserInstalledFonts`, which WebKit calls from
`loadHTMLString` while it starts the page's web process, and which lists every
font on the Mac (`XTCopyPropertiesForAllFontsWithOptions`, 6.1%).

WebKit keeps that list on the process pool, and a `WKWebViewConfiguration` that
is given no pool creates one. Each message view had a configuration of its own,
so each listed the fonts again. The reader builds a new view whenever a message
opens or scrolls back into the viewport, because a view a message has used is
never given to another.

A standalone program on the same Mac built ten views with the reader's
configuration, half a second apart, and timed the two main-thread calls:

| After the first view, median | A pool per view | One shared pool |
| --- | --- | --- |
| `WKWebView.init` | 7.4–8.5 ms | 0.7–2.8 ms |
| `loadHTMLString` | 31.6–34.9 ms | 0.9–2.7 ms |

Three runs of each. In the last two of each the first view took 42 to 89 ms,
with either. Web content processes went from 1 to 11 for the ten views in both,
so a shared pool does not put two messages in one process.

`93a38ea8` puts every message view in one pool. Each view keeps its own
non-persistent data store, content controller and web process, and the hosted
test that compares two spares now checks the content controllers as well as the
data stores. WebKit deprecated `WKProcessPool` in macOS 12 with the note that
several pools no longer have any effect; the profile and the probe show that on
macOS 27 a pool still decides whether the fonts are listed again. The app
builds without a warning from it.

The build before the change and the build with it then ran in turn on 14
November, each scroll run starting after ten minutes without input:

| Surface, delayed callbacks | Before, 17:45 | Shared pool, 17:48 | Before, 17:52 | Shared pool, 17:55 |
| --- | --- | --- | --- | --- |
| Mail list | 1.1% | 1.8% | 1.4% | 1.4% |
| Reader, 20 messages | 4.5% | 3.9% | 5.0% | 3.7% |
| Reader, 100 messages | 5.9% | 3.8% | 5.9% | 4.4% |
| Calendar | 0.1% | 0.0% | 0.0% | 0.1% |
| Attachments | 0.3% | 0.1% | 0.2% | 0.3% |

| Reader, gap between callbacks | Before | Shared pool |
| --- | --- | --- |
| 95th percentile, 20 messages | 20.3 and 25.3 ms | 19.1 and 18.3 ms |
| 95th percentile, 100 messages | 30.2 and 29.1 ms | 20.6 and 22.0 ms |
| 99th percentile | 58.5–66.7 ms | 50.0–51.0 ms |
| Longest | 82–86 ms | 67 ms |

All four runs count: the app took no input, kept the foreground and had no
stall of 100 ms, and the screen stayed unlocked. The reader's share fell by 0.6
and 1.3 points at 20 messages and by 2.1 and 1.5 points at 100, and its longest
gap by 15 to 19 ms. It is still over the 1% budget. The mail list builds no web
views and did not change.

The new build's scroll over 20 messages was then sampled the same way, and
again that run's timings do not count. `MessageWebView` frames took 1.5% of
7,906 main-thread samples, where the earlier sample had 8.8%, and
`registerUserInstalledFonts` took 0.1%. Apart from the benchmark's own callback
no frame of the app's is above 1.5%. The rest is SwiftUI laying out and drawing
messages: 43.5% of the samples are in `NSHostingView.layout()`, 9.1% of all
samples in the lazy stack placing and measuring its rows, and 14.7% in layer
display.

The last pair of runs had 83 and 97 delayed callbacks before the change and 63
and 74 with it. Going by the distance scrolled and the threads' heights, about
58 and 63 messages scrolled into view in those runs, so what is left looks like
one late frame for each message that enters. That cost has not been broken down
further.

The reader-only scope ran once on each build, at 18:09 and 18:10. Local
selections, which prepare a stored message, took 148 ms at the median, 167 ms
at the 95th percentile and 169 ms at the 99th before the change, and 136, 149
and 154 ms with it. Retained selections were 45, 50 and 56 ms before and 46, 50
and 50 ms with it. Both runs count, with 100 of 100 selections in each scenario.

The full hosted suite passed with the screen unlocked, 1,010 of 1,010, on
`e0fb9c45`, which adds to the pool change a refactor that changes no behavior.
Before that, under a locked screen, the three suites that cover the message
view ran on `93a38ea8`: 23 of 24 tests passed, and
`heightShrinksWhenTextReflowsIntoAWiderPane` failed, as it has before under the
lock.

### What fills the frame a message enters in

The scroll audit now records what the reader did between callbacks: each
message row built, entered or dropped, each body prepared, each web view made,
and each evaluation of the row's and header's bodies. It also records how long
the main thread was awake in each callback, its CPU time, and the core it was
on when the callback's work began. The counts hold no mail. A third reader
surface, `reader-read-100`, scrolls a 100-message conversation of read mail,
which opens with only its newest message expanded, so the scroll brings in
collapsed rows.

The late callbacks are the ones a row enters in. In four runs of the unread
conversations, 39 to 47 of every 55 to 57 entries came with a late callback. In
`read2-2`'s 100-message run, 41 of the 79 late callbacks held an entry and 78
held an evaluation of a header. The main thread was awake 34 to 43 ms at the
median in a callback with an entry and 4 to 5 ms at the median over all of
them.

A conversation of collapsed rows is over budget too. The scroll brings in
about 14 rows a second, and each takes the main thread about 20 ms:

| Run | Header controls | Late callbacks | Awake with an entry, p50 / p95 | Entries late |
| --- | --- | --- | --- | --- |
| `read2-1` | as shipped | 5.7% (99 of 1,736) | 22.9 / 30.5 ms | 96 of 426 |
| `read2-2` | lighter styles | 1.7% (30 of 1,759) | 18.6 / 22.9 ms | 26 of 431 |
| `read2-3` | as shipped | 2.8% (50 of 1,758) | 20.7 / 25.1 ms | 43 of 431 |
| `read2-4` | lighter styles | 1.9% (34 of 1,760) | 18.6 / 22.7 ms | 30 of 432 |

The four ran one after another between 20:06 and 20:21 on 14 November with the
screen unlocked and no input, but not on a quiet Mac; see the last part of
this section. In the same runs the unread conversations were late in 3.4% to
4.7% of callbacks with either set of controls.

"Lighter styles" draws the header's buttons and menus in SwiftUI
(`.buttonStyle(.plain)` and `.menuStyle(.button)`) in place of the AppKit
controls that `.borderless` and `.borderlessButton` make. It was not applied
then, because it changed the header's look: the sender lost its menu arrow and
turned semibold on unread mail, the More icon turned gray, and the three actions
moved about 6 points left. Leaving out one part of the header at a time (the fit
check, the context menu, the popovers, the hover, the avatar, the second line)
moved its build by 0.2 to 0.9 ms of 6.1 ms in the test harness, and scroll runs
without the fit check, the context menu, the popovers or the hover were no
better.

`4012c9d3` gave the header these styles and kept its look. The sender's label
drew its own arrow, More kept the color and size the AppKit button gave it, and
the actions stayed where they were. Captures of the header before and after
matched except the sender: the medium weight for read mail and semibold for
unread, which the code always set, showed, and its arrow sat 2.5 to 4 points
further right. The hover highlights of More and the sender were 2 and about 4
points larger, and the expand button dimmed while pressed. Scroll runs of the
app on 19 November found rows entering slower with these styles, and
`2e8f3287` undid them; see "Finishing pass, 19 November 2026".

#### The header's click surface

The header took the clicks no control claimed through a native view laid over
it, which measured each control's bounds so it could let those clicks through.
SwiftUI resolved the bounds again for every header on screen in every callback:
24,975 times in 1,736 callbacks of `read2-1`. The view now sits behind the
header's content, where each control takes its own clicks without any
measuring, and the action cluster claims the gaps between its icons so a near
miss still does nothing. In the harness, over a lazy stack of 400 collapsed
headers moved 18 points a step, a step with no new row fell from 0.35 to
0.21 ms and a step with a new row from 5.78 to 5.52 ms. A map of where clicks
land, sampled every 6 by 5 points across the header in both states, is the same
before and after, and real single and double clicks open and close the message
as before. The part of `headerDoubleClickChangesExpansionOnceAndControlsKeepTheirOwnActions`
that opens popovers and menus needs focus, so it could not run while the screen
was locked. It passed with the screen unlocked later that evening, with the
rest of the header and message-view suites (29 of 29).

#### The same work, several times slower

Leaving parts out changed little because the cost is not in any one part. In
`read2-3` a collapsed row's steps came at these times after the callback
before. An expanded row's steps in the same run came two and a half to three
times later from the avatar on:

| Step | Collapsed row | Expanded row | Expanded row, first of the run |
| --- | --- | --- | --- |
| Row body | 0.5 ms | 2.4 ms | 0.5 ms |
| Header body | 1.2 ms | 4.2 ms | 1.0 ms |
| Avatar | 3.0 ms | 9.0 ms | 2.6 ms |
| Actions | 3.6 ms | 10.8 ms | 3.3 ms |
| Sender menu | 4.7 ms | 13.4 ms | 4.3 ms |
| Row entered | 8.3 ms | 20.9 ms | 8.0 ms |

The header is the same view in all three columns. What differs is how often a
row enters: every fourth callback in the read conversation, every thirtieth in
the unread one, and straight after opening the conversation for the first.

A test built the same expanded header on different schedules and recorded the
core the main thread was on. This Mac has six efficiency cores and four
performance cores.

| Schedule | Build, median of two rounds | Began on a performance core |
| --- | --- | --- |
| Back to back | 8.0 and 6.5 ms | 40 of 40, twice |
| Every 30th tick of 16.7 ms, 4 ms of arithmetic in the others | 24.9 and 35.3 ms | 0 of 16, twice |
| Every 30th tick, nothing in the others | 24.4 and 33.8 ms | 0 of 16, twice |
| Every 4th tick, 4 ms of arithmetic in the others | 15.6 and 14.8 ms | 35 and 38 of 40 |
| Every 4th tick, nothing in the others | 24.4 and 23.7 ms | 0 of 40, twice |
| Every 30th tick, 10 ms of arithmetic in the others | 8.5 and 8.3 ms | 16 of 16, twice |
| After half a second idle | 34.5 and 34.0 ms | 0 of 12, twice |
| After half a second idle, then 30 ms of arithmetic | 21.6 and 20.1 ms | 0 and 2 of 12 |

The thread's CPU time was within 1 ms of the elapsed time on every schedule, so
nothing took the core away: the work itself ran slower. When the frames before
a build are light, macOS has the main thread on an efficiency core, the build
starts there, and it costs three to five times what it costs back to back.
That matches the reader's scroll, where an entry comes once in thirty callbacks
of 4 to 5 ms each, and it explains why the harness measured a header at 6 ms
while the scroll spent 20 ms and more on one.

The test ran in the testing app with the screen locked, where macOS may treat
the app as being in the background, so it shows the mechanism and not its size
in the app a person is using. The scroll audit now records the core each
callback began on and the thread's CPU time, and `TERN_SCROLL_KEEP_BUSY` adds
arithmetic to every callback of a benchmark run, which the validator rejects as
a diagnostic.

#### The same measurement in the app in front

Four runs of the benchmark build of `ab2fc8f5`, from 23:22 to 23:37 on
2026-11-14, alternated the scroll as shipped with 6 ms of arithmetic added to
every callback. The screen was unlocked, nobody touched the Mac, and no other
process was above 36% of a core when a run started. All four are valid.

| Surface | Delayed, as shipped | Delayed, 6 ms added | Began on an efficiency core, as shipped | Began on one, 6 ms added |
| --- | --- | --- | --- | --- |
| Mail list | 1.5% and 1.6% | 0.2% and 0.3% | 132 and 429 of 1,761 and 1,762 callbacks | none |
| Reader, 20 messages | 4.1% and 3.7% | 4.0% and 3.5% | 32 and 34 of 54 entries | none of 55, twice |
| Reader, 100 messages | 5.1% and 4.9% | 4.1% and 4.2% | 37 of 55 entries, twice | none of 57, twice |
| Read conversation | 8.0% and 4.0% | 12.0% and 5.2% | 2 of 429 and 8 of 430 entries | none of 418 and 424 |
| Calendar | 0.1%, twice | 0.0%, twice | 1,333 and 1,475 of 1,790 and 1,789 callbacks | none |
| Attachments | 0.3%, twice | 0.0% and 0.1% | 1,723 and 1,728 of 1,786 and 1,785 callbacks | 1 and none |

The time the main thread was awake in a callback a row entered in, median and
95th percentile. The last column includes the 6 ms that was added:

| Surface | As shipped | 6 ms added |
| --- | --- | --- |
| Reader, 20 messages | 45.5 and 67.8 ms, 42.2 and 61.3 ms | 33.6 and 41.2 ms, 32.7 and 39.2 ms |
| Reader, 100 messages | 50.4 and 71.6 ms, 52.0 and 65.1 ms | 31.0 and 38.3 ms, 29.8 and 35.6 ms |
| Read conversation | 23.7 and 27.8 ms, 22.6 and 26.6 ms | 24.8 and 30.2 ms, 23.7 and 28.4 ms |

The test's finding holds in the app a person is using. As shipped, about two
thirds of the expanded rows begin their entry on an efficiency core. With the
thread kept busy none do, and an expanded row's own work falls from 42 to 52 ms
to 24 to 28 ms.

That is not enough for the reader. 24 to 28 ms is still at or past the 25 ms
line, so nearly every entry stays a late callback and the delayed share barely
moves. With the added work, the row's views take about 9 ms to build, and what
follows them in the same callback, which the audit does not break down, takes
about 14 ms more. That is the row's own cost on a performance core. The largest
interval does fall, from 67 to 75 ms to 50 ms.

It is enough for the mail list, which goes from 1.5% and 1.6% to 0.2% and 0.3%
and is then inside the 1% budget. Over all its callbacks the 95th percentile of
awake time is 19.4 and 19.6 ms as shipped and 15.6 and 15.0 ms with the 6 ms
included. The list's rows fit a frame when the thread is on a performance core
and miss it when the thread is not.

The read conversation gains nothing. Its rows enter every fourth callback,
which already keeps the thread on performance cores, and an entry costs 23 ms
there. The added 6 ms pushes more of them past the line.

The calendar and the attachment library run almost wholly on efficiency cores
as shipped and stay inside the budget, because their callbacks are short.

The added arithmetic is a diagnostic and not a fix. It spends 6 ms of every
16.7 ms on a performance core for as long as the scroll lasts.

One supported way to ask for the same thing was tried and did nothing. A build
that held a `ProcessInfo` activity with the `latencyCritical` option through
each scroll ran in turn with the same build without it, 23:44 to 23:59, all
four runs valid:

| Surface | With the activity | Without |
| --- | --- | --- |
| Mail list, delayed | 1.8% and 1.5% | 1.7%, twice |
| Mail list, callbacks begun on an efficiency core | 279 and 248 of 1,760 and 1,762 | 273 and 281 of 1,761 and 1,759 |
| Reader, 20 messages, delayed | 4.0% and 4.1% | 4.4% and 4.2% |
| Reader, 20 messages, entries begun on an efficiency core | 34 and 32 of 54 | 36 of 54, twice |
| Reader, 100 messages, delayed | 4.4% and 5.1% | 4.8% and 4.9% |
| Reader, 100 messages, entry awake time, median | 46.6 and 50.7 ms | 50.4 and 49.8 ms |

That change was not kept. The macOS SDK's public work-interval header
(`os/workgroup_interval.h`) has calls to start, update and finish an interval
and none to create one, so that route was not tried.

Two things are still unknown. A scroll driven by a wheel or trackpad may be
scheduled differently from one driven by the display link, and only an attended
run shows that. And nothing here says how to cut the 23 ms a row costs on a
performance core; the options not yet tried are building a row over two frames
and the lighter control styles above. The lighter styles were applied on
19 November in `4012c9d3` and taken out the same day in `2e8f3287`, because
rows entered slower with them in the app (see "Rows entering with the SwiftUI
header").

#### What runs after a row's views

Two runs with the 6 ms added were sampled for 20 seconds each on 15 November,
08:23 to 08:31: one while the 100-message conversation scrolled and one while
the read conversation scrolled. Each sample ran a few seconds into the next
surface, so the shares are approximate, and the sampled surfaces' delay figures
don't count. Shares are of the main thread's samples outside the idle wait and
the added arithmetic:

| Work | Read conversation (collapsed rows) | 100 messages (expanded rows) |
| --- | --- | --- |
| Window toolbar: item updates and layout | 10.9% | 7.8% |
| Main menu and focus state | 4.6% | 6.0% |
| Lazy stack placement | 9.4% | 13.7% |
| Display list | 7.1% | 9.3% |
| Core Animation display and commit | 10.5% | 14.0% |
| WebKit | 0.1% | 3.3% |

The first two rows are work on parts of the window that don't change while a
conversation scrolls: 15.9% and 14.3% together. The stacks reach both from
`NSHostingView.preferencesDidChange()`, called inside the hosting view's layout
pass. From there `AppWindowsController.updateWindowFocus` refreshes the main
menu's focus state (`MainMenuItemHost.requestUpdate`, `updateFocusStore`), and
`ToolbarBridge.preferencesDidChange` builds the toolbar's storage again and
updates each item (`AppKitToolbarStrategy.updateVended`, then
`-[NSToolbarView layout]`).

No Tern view body other than the row's own appears in either sample. The
toolbar's content and the conversation view are not evaluated again; SwiftUI
installs a toolbar and a menu state from inputs that are the same as before.

#### What starts the toolbar and menu work

A scratch build put a switch on each part of a row that hangs something on the
window: the two popovers, the context menu, the tooltips, the address and More
menus, the hover modifier, the header's click surface, and the conversation's
three focused scene values. Eleven sampled runs of the read conversation
followed on 15 November, 08:50 to 14:55, each with the 6 ms added. Nine are
valid. The toolbar, menu and focus share of the main thread's work:

| Switched off | Share |
| --- | --- |
| Nothing | 17.1% and 17.8% |
| Everything | 18.4% |
| Everything but the focused scene values | 19.6% |
| One part at a time, five of the seven | 17.1% to 19.4% |

None of those parts starts it. The two parts without a valid run of their own
are in the run with everything off.

The same samples have `NSHostingView.updateFocusStore()` and
`ViewGraph.setFocusStore(_:)` in about 8% of their stacks, and inside each row
a focusable modifier and a focus-state binding that SwiftUI's `Button` makes
for itself. A second scratch build changed only how a row's six buttons are
made: the disclosure, the avatar, Details, and the star, reply and edit-draft
actions. The menus stayed as they are. Seven runs, 15:29 to 17:40, 6 ms added;
four are valid, and the other three lost the foreground while the Mac was in
use.

| A row's buttons | Toolbar, menu and focus | Focus store | Entry, 20 messages | Entry, 100 messages | Delayed, 20 | Delayed, 100 |
| --- | --- | --- | --- | --- | --- | --- |
| As shipped, 15:29 | 16.2% | 7.9% | 32.6 ms | 30.2 ms | 4.7% | 3.7% |
| A custom `ButtonStyle` | 18.1% | 10.2% | 26.8 ms | 26.7 ms | 2.9% | 4.2% |
| A custom `PrimitiveButtonStyle`: the label with a tap gesture | 2.8% | 0.2% | 19.3 ms | 17.7 ms | 1.7% | 0.6% |
| As shipped, 17:36 | 16.2% | 8.8% | 33.2 ms | 30.7 ms | 4.1% | 4.1% |

The two shares are of the read conversation's sample. Entry is the median time
the main thread was awake in a callback a row entered in, with the 6 ms
included.

A button drawn by one of SwiftUI's styles, or by a custom `ButtonStyle`, has
that focus binding whether or not Keyboard navigation is on in System Settings.
The stacks show what follows when a row enters: the window's focus store
changes, `AppWindowsController.updateWindowFocus` passes the new store to the
main menu's host and to each toolbar item's hosting view, and those update and
lay out again. A primitive style has no binding. With it the focus store leaves
the samples, the toolbar's share falls to 2.8%, and a row's entry is 12 to 14 ms
shorter, which puts it under the 25 ms line with the 6 ms still included. In
that run the 100-message conversation is inside the 1% budget and the
20-message one is at 1.7%.

Two more runs of the same build followed, 18:24 to 18:32, both valid:

| A row's buttons | Toolbar, menu and focus | Focus store | Entry, 20 messages | Entry, 100 messages | Delayed, 20 | Delayed, 100 |
| --- | --- | --- | --- | --- | --- | --- |
| System styles, marked `.focusable(false)` | 16.9% | 8.9% | 33.3 ms | 30.9 ms | 3.9% | 4.0% |
| The primitive style again | 1.3% | 0.2% | 22.2 ms | 21.9 ms | 2.3% | 1.4% |

Marking a button not focusable changes nothing: the binding is made whether or
not the button can take focus. The primitive style's second run gains less
than its first, 8 to 11 ms an entry, and leaves both conversations over the 1%
budget with the 6 ms added.

That build drops the buttons' pressed state and their keyboard focus, so these
runs are a measurement and not a fix. The two variants with no `Button` at all
never got a valid run.

`App/Design/KeyboardNavigation.swift` already holds a narrower form of this
for the mail list: the star on each row binds its own focus state only while
Keyboard navigation is on. The star was still a `.borderless` button then, and
what it cost the list was not measured until 19 November (below, under
"Buttons on the mail list's rows").

#### A style for a row's buttons

`RowButtonStyle` in `App/Design/KeyboardNavigation.swift` is the fix made from
that. While Keyboard navigation is off it is a primitive style: it draws the
label and takes the click with a tap gesture. While Keyboard navigation is on
it hands the button to `.borderless` or `.plain`, so a button takes keyboard
focus in the same cases as before. A message row's six buttons use it, and the
conversation view tracks the setting.

At rest and while pressed it draws what the system styles draw. A bitmap of an
expanded header under each, 1520 by 560 pixels, has no pixel that differs at
rest. With the mouse held down on the disclosure, the avatar, Details, the star
or reply, no pixel inside that button's frame differs either. The system's
borderless style leaves these pressed labels as they are, because each sets its
own foreground style. Its plain style dims a pressed label to 75%, and the row
style does the same.

The first version of the style, `49454f5e`, dimmed every pressed label to
half. The commit after it matches the system and drops the press tracking from
the four borderless buttons. The scroll runs below are of the first version,
except the last four.

Four runs with nothing added to the callbacks, 16 November, 00:19 to 00:35,
all valid, the two builds in turn:

| Build | Read conversation | 20 messages | 100 messages | Mail list |
| --- | --- | --- | --- | --- |
| Shipped, 00:19 | 18.6%, 27.3 ms | 3.8%, 37.2 ms | 4.4%, 27.0 ms | 1.5% |
| Row style, 00:23 | 0.6%, 16.0 ms | 3.5%, 22.3 ms | 5.5%, 26.8 ms | 1.7% |
| Row style, 00:28 | 0.7%, 14.5 ms | 5.1%, 25.1 ms | 6.1%, 27.8 ms | 1.5% |
| Shipped, 00:32 | 3.9%, 22.7 ms | 6.3%, 36.9 ms | 8.3%, 43.6 ms | 1.2% |

Each cell is the delayed share, then the median time the main thread was awake
in a callback a row entered in.

The read conversation, whose rows are collapsed, is inside the 1% budget in
both runs of the row style. About 430 rows enter in that scroll, and 95% of
those callbacks now end within 19.1 to 19.7 ms, against 26.0 to 31.5 ms
shipped.

The conversations of expanded messages stay over budget. A row's entry is
shorter in the 20-message conversation and the longest gap between callbacks
falls from 56 to 57 ms to 37 to 43 ms, but the entry still sits at the 25 ms
line, and the delayed shares of the two builds overlap. The 100-message
conversation shows no gain against the first shipped run and a large one
against the second, so these four runs don't settle it. The mail list, the
calendar and the attachment list are unchanged, as expected: none of their
buttons changed.

One sampled run of each build with the 6 ms added followed that morning, both
valid. The columns are those of the tables above:

| Build | Toolbar, menu and focus | Focus store | Entry, 20 messages | Entry, 100 messages | Delayed, 20 | Delayed, 100 |
| --- | --- | --- | --- | --- | --- | --- |
| Shipped, 08:58 | 16.4% | 8.1% | 34.3 ms | 33.7 ms | 4.0% | 3.8% |
| Row style, 09:13 | 1.5% | 0.2% | 19.8 ms | 18.8 ms | 1.7% | 0.8% |

The shipped build matches its earlier runs. With the style the focus store
leaves the sample, as it did in the scratch build. The 6 ms keeps the main
thread on a performance core, and there an expanded row's entry is 14 to 15 ms
shorter and ends under the 25 ms line. Without the 6 ms a third to two thirds
of those entries begin on an efficiency core and the median is 22 to 28 ms,
which is why the four runs above show less. An earlier sampled run of the
style ended with the screen locked and doesn't count.

Four runs of the final version followed the same day, 11:26 to 14:14, all
valid, with nothing added to the callbacks. The Mac was busier than at night:
its load average was 4 to 6 against 2 to 3, and 32 to 41 of about 55 expanded
rows began on an efficiency core.

| Build | Read conversation | 20 messages | 100 messages | Mail list |
| --- | --- | --- | --- | --- |
| Shipped, 11:26 | 9.3%, 23.9 ms | 4.4%, 47.1 ms | 5.2%, 50.1 ms | 1.7% |
| Row style, 11:29 | 1.4%, 18.1 ms | 4.5%, 34.5 ms | 4.1%, 31.2 ms | 1.4% |
| Row style, 11:33 | 1.0%, 16.0 ms | 3.7%, 36.1 ms | 4.8%, 35.4 ms | 1.6% |
| Shipped, 14:10 | 24.4%, 31.9 ms | 3.5%, 35.8 ms | 4.5%, 38.6 ms | 1.3% |

The read conversation holds its gain, at 1.0% and 1.4% against 9.3% and 24.4%,
but on the busier Mac it sits at the budget and not inside it. The last
shipped run got through 1448 callbacks in that scroll where the others have
about 1750, so its 24.4% is the weakest figure here. The expanded
conversations again show no change in the delayed share. Their longest gap is
50 to 52 ms with the style and 67 to 124 ms shipped.

`MessageHeaderInteractionTests`, `CachedWorkspaceTests` and
`ReaderLayoutDiagnosticsTests` pass with the style, 10 of 10. A press through
accessibility doesn't go through the tap gesture, so the header test now also
clicks the disclosure button with mouse events. Not checked: the buttons
driven from the keyboard with Keyboard navigation on, and a person using them.

#### The pointer inside the window

Two of the sampled runs above happened to have the real pointer inside the
benchmark's window, and both show something the others don't:
`_NSTrackingAreaAKManager _updateTrackingAreasIfNeeded` in 9% and 11% of the
main thread's samples. Every sample taken with the pointer elsewhere has none.
A run leaves the pointer where it finds it, so every reader figure before this
has that as a variable nobody set.

`TERN_PERFORMANCE_POINTER_ON_READER=1` now scrolls each conversation twice,
with the pointer parked in the window's bottom trailing corner and then
resting on the middle of the reader. Four runs of the row style build on
16 November, 16:07 to 17:03. Each cell is the delayed share, then the 95th
percentile of the gap between callbacks:

| Run | 20 messages, parked | 20, on the reader | 100 messages, parked | 100, on the reader | Read, parked | Read, on the reader |
| --- | --- | --- | --- | --- | --- | --- |
| 16:07, lost the foreground after five scrolls | 2.6%, 16.7 ms | 3.1%, 23.5 ms | 2.8%, 19.4 ms | 3.1%, 23.3 ms | | |
| 16:45 | 3.0%, 17.8 ms | 2.8%, 23.4 ms | 2.2%, 17.3 ms | 2.5%, 23.1 ms | 0.8%, 17.3 ms | 0.7%, 17.9 ms |
| 16:51, sampled | 3.0%, 16.7 ms | 3.8%, 24.3 ms | sampled | 2.8%, 23.6 ms | 0.4%, 17.6 ms | 0.3%, 18.0 ms |
| 16:58, sampled | 3.0%, 17.1 ms | 4.1%, 24.2 ms | 3.6%, 20.3 ms | sampled | 0.7%, 18.2 ms | 0.7%, 18.3 ms |

A pointer on the reader moves the delayed share of an expanded conversation
by a point at most, but its slowest twentieth of callbacks arrive 23 to 24 ms
apart where they arrived 17 to 20 ms apart. That is just inside the 25 ms line
the share counts, and past the 16.7 ms a frame has. The read conversation is
the same either way.

The two samples cover the 100-message conversation, one with the pointer
parked and one with it on the reader. Both have the tracking-area update in
12.6% of the main thread's samples, 18% to 19% of its work. So the parked
corner, which is inside the reader's pane, pays it too. It runs once a display
cycle and has two parts:

- AppKit sets the cursor for the pointer's place, which hit-tests the window.
  The test goes through the hosting view into SwiftUI's responders: 7.5% of
  samples.
- AppKit updates tracking areas view by view: 5.0%. A quarter of that is in
  an outline view, which the reader doesn't have, so the walk reaches panes
  that are not scrolling.

With the pointer on the reader the sample adds mouse-entered and mouse-exited
events and WebKit's mouse handling, about 1% each, and more SwiftUI updates.

No run places the pointer outside the window, so what the tracking-area work
costs a frame is not measured: the parked column already includes it.

A scratch build switched the window's cursor rects off for the length of each
scroll (`disableCursorRects()`), so AppKit stops setting the cursor. Five runs
followed on 16 November, 17:08 to 17:43. Four are valid; the 17:14 run lost
the foreground after its fourth scroll. The cells are those of the table
above:

| Cursor rects | 20 messages, parked | 20, on the reader | 100 messages, parked | 100, on the reader |
| --- | --- | --- | --- | --- |
| Off, 17:08, sampled | 2.8%, 16.8 ms | 3.4%, 23.4 ms | sampled | 3.2%, 23.4 ms |
| On, 17:14 | 2.7%, 16.7 ms | 3.7%, 24.2 ms | 3.2%, 18.4 ms | |
| Off, 17:27 | 4.0%, 19.4 ms | 3.2%, 23.8 ms | 4.0%, 19.9 ms | 4.7%, 24.6 ms |
| Off, 17:32 | 3.8%, 18.4 ms | 3.6%, 24.2 ms | 4.0%, 20.0 ms | 3.5%, 23.8 ms |
| On, 17:38 | 3.1%, 16.8 ms | 4.2%, 24.6 ms | 4.1%, 20.8 ms | 4.4%, 24.6 ms |

With the rects off, the sample of the 100-message conversation has the
tracking-area update in 6.8% of the main thread's samples and the cursor's hit
test in 0.2%. Neither the delayed share nor the gap moved, with the pointer
parked or on the reader, so the hit test is not what delays a frame and the
app keeps its cursor rects.

The mail list shows the same cost. A run that ended at 20:58 scrolled it with
the pointer parked, then on the list, then parked again
(`TERN_PERFORMANCE_POINTER_ON_LIST=1`):

| Mail list | Delayed | Gap p95 | Main thread awake per callback, median | Callbacks begun on an efficiency core |
| --- | --- | --- | --- | --- |
| Parked | 1.7% | 19.6 ms | 2.5 ms | 18 |
| On the list | 0.8% | 22.9 ms | 5.6 ms | 0 |
| Parked again | 1.0% | 19.1 ms | 2.7 ms | 445 |

With the pointer on the list, each callback keeps the main thread awake about
3 ms longer and the slowest twentieth of callbacks arrive later, but fewer are
late. None of that scroll's callbacks began on an efficiency core.

#### The callbacks after a row enters

With the pointer parked, a quarter to almost half of the late callbacks in an
expanded conversation held no row entry, only the creation of a message's web
view or the arrival of its height. In the 100-message conversation that was 48
of 109 late callbacks in the build as shipped. From `af555bea` the audit
records how long the main thread was awake in the callbacks of each event kind
and in each late callback (`busyMilliseconds`).

In those callbacks `MessageView`'s body runs twice, and each run builds the
message's header and its actions again. The second run comes from
`contentHeight`, the body's height after layout, which the placeholder uses
once the body is released. It is view state, so writing it from
`onGeometryChange` runs the body once more for every new height. The header is
built again on each run of the body because it takes closures, which SwiftUI
can't compare.

A scratch build had two switches. One kept the height in an object SwiftUI
doesn't observe. The other skipped the header when its value inputs were
unchanged and ignored its closures, which is not safe to ship. Three runs
followed with the pointer placed as in the tables above, each named by the
time it ended:

| Variant, run ended | 20 messages, parked | 20, on the reader | 100 messages, parked | 100, on the reader |
| --- | --- | --- | --- | --- |
| As shipped, 20:23 | 3.9%, 20.0 ms | 5.9%, 26.1 ms | 6.6%, 30.3 ms | 5.6%, 25.4 ms |
| Both switches, 20:47 | 2.5%, 16.7 ms | 2.5%, 22.2 ms | 1.9%, 16.7 ms | 3.0%, 23.4 ms |
| Height only, 20:52 | 2.9%, 16.8 ms | 4.0%, 24.0 ms | 3.4%, 19.3 ms | 2.9%, 23.3 ms |

The same scrolls counted how often `MessageView`'s body and the header ran:

| Variant | 20, parked | 20, on the reader | 100, parked | 100, on the reader |
| --- | --- | --- | --- | --- |
| As shipped | 223 bodies, 240 headers | 120, 154 | 370, 370 | 291, 303 |
| Both switches | 154, 54 | 82, 50 | 238, 61 | 159, 57 |
| Height only | 154, 171 | 79, 113 | 234, 234 | 163, 180 |

The counts change little from run to run; the delayed shares change a lot. The
mail-list run that ended at 20:58 also scrolled both conversations with the
build as shipped and the pointer parked. It counted 221 bodies and 238 headers
in the 20-message conversation and 342 of each in the 100-message one. It
measured 2.5% and 3.9% delayed (16.7 and 18.9 ms at the 95th percentile), close
to the height-only run, and the main thread's median time in a height callback
was 6.1 to 6.2 ms. In the 20:23 run that median was 14.7 and 23.7 ms, and in
the height-only run 6.6 ms. One run of each variant doesn't rank them by the
share.

Neither switch was kept. The height holder, a `LaidOutHeight` class kept in
`@State` the way `ThreadView` keeps `ReaderPaging`, made a hosted test fail. With
it, `longConversationReusesRendererOnQuickReversalAndMeasuredHeightsAfterEviction`
timed out in six of seven runs of the three reader suites with nobody at the
Mac, and in one of four fresh runs of the test alone. The committed code passed
all three suite runs and every run alone. The test moves the clip view to the
end of a 40-message conversation and waits for the first message's web view to
be released. A temporary printout showed what happened in the failing runs: the
offset stayed at the end and the window stayed key and visible, but SwiftUI
built no row there and never released the first body, for more than three
seconds and through a forced layout of the window. The window had one scroll
view, the one the test moved, so the test wasn't holding a stale one. In passing runs, with or
without the holder, it built three rows within 100 ms, moved the offset to fit
them and released the first body by 500 ms. The document's estimated height
before the jump was also shorter in the failing runs: 11,402 to 12,181 points,
against 12,810 to 13,085. Why the change leaves SwiftUI behind a scroll made
through AppKit is not known, so the second body run stays.

The header skip can't ship as written. Mark Unread from Here captures the
conversation's messages when the row is built, and the sender menu's items
capture the view's settings, so a skipped header would act on stale ones.
Skipping it safely needs those inputs passed as values the header can compare,
or the body's state moved into a view of its own so that a new height never
reaches the header.

#### A busy Mac during these runs

The mail list's result drifted through the evening of 14 November while its
code did not change:

| Runs | Mail list late | Attachments late | Calendar late |
| --- | --- | --- | --- |
| 17:48 to 18:06, five | 1.1% to 1.8% | 0.1% to 0.5% | 0.0% to 0.1% |
| 18:34 to 18:59, six | 2.0% to 5.1% | 0.3% to 0.8% | 0.0% to 0.1% |
| 19:23 to 19:43, six | 0.4% to 9.5% | 0.3% to 4.9% | 0.0% to 0.1% |
| 20:01 to 20:21, five | 9.2% to 15.7% | 1.4% to 9.5% | 0.0% to 0.1% |

`mediaanalysisd`, a macOS process, started at 19:14:53 and was using 150% to
210% of a core when it was looked at after 20:21; Spotlight's indexer joined it
later. A mail row enters about every fourth callback and its entry sits close
to the 25 ms line (the main thread's p95 awake time per callback was 18 to
27 ms across these runs), so a small loss of speed moves many callbacks over
it. The calendar, whose callbacks take 6 to 8 ms, did not move. Whether the
audit's new counters cost the earlier rise from 1.4% to 3.5% and more was not
separated from the Mac's load. The runs in this section are fair as pairs made
minutes apart and not as absolute figures. The gate that starts a run now also
waits until no other process is using 40% of a core.

#### Where a conversation opens

A conversation opens at its first expanded message, in display order, when that
message is not the first one and no message is selected. With the oldest
message first, a long conversation of read mail used to open at the top showing
collapsed headers, with its expanded message, the newest, below the first
screen. It now opens with the newest message at the top of the reader. When the
content below that message is shorter than the reader, the reader scrolls as
far as the content allows.

The lazy stack builds a message below the first screen only once the reader
scrolls there, so the first move goes to the message by identity, one turn of
the main actor after the scroll view appears. In a test view, a
`ScrollPosition` set to a message before its scroll view appeared was ignored.
The first move also lands short, because the body has not loaded and the
message is still short, so the scroll stops at the end of the content. In the
same test view a scroll that stopped at the end stayed there when its target
grew: the target was still 404 pt from the top after it grew to 1,200 pt. Rows
above the target that grew by 120 pt moved it down by 120 pt, since SwiftUI
keeps the offset and not the row. So for up to 2 s the reader holds the message
at its top. The message reports its place in the content, and the reader
scrolls back to it after a height or the reader's size changes. Each of these
scrolls waits for the next turn of the main actor, so none runs inside a layout
pass.

The hold ends at the first scroll it did not make, and at a scroll phase from
the user. It compares positions because programmatic and native clip scrolls
report no scroll phase in the test view. A reader at the end of the content
that stays at the end while the content changes height has not been scrolled,
and neither has one that shorter content pulls up to its end. Every other
scroll target also ends the hold: a selected message, the finder, a link to a
message, a summary's source, opening or closing a message, Space paging,
moving between messages with the keyboard, and the reader becoming inactive.

A hosted test opens 30 read messages, waits until the newest one's body has
loaded with its header at the top of the reader, then follows a link to a
collapsed message above it and checks that this header reaches the top and
stays there for 300 ms. In one logged run the first scroll stopped at the end
of the content, 445 pt above the newest message's top. The content then grew
by 74 pt and shrank by 14 pt with the reader at its end, and once the body was
925 pt tall the hold scrolled the reader to the message. The first version of
the hold counted the reader following the end as a scroll from elsewhere and
let go, so the message stayed 385 pt below the top.

A second hosted test scrolls by hand while the hold runs: three wheel steps
of 80 pt in one case, a trackpad gesture of the same length in the other. It
then waits for the body to load and checks that the newest message's header
has not come back to the top. Sent all at once, the gesture's events started
and ended a live scroll without moving the reader, both with the hold on and
2.5 s after the hold ended, so the test sends them 16 ms apart, like real
input. In a diagnostic run the paced gesture moved the reader 240 pt within
60 ms, and the reader stayed there after the body loaded. With the hold
changed to ignore scroll phases and to keep a scroll by hand as its own, both
cases fail. The events come from the test, not from a wheel or trackpad.

`reader-read-100` now waits for the body like the other two reader scenarios.
It then scrolls the reader back to the top and checks that it stays there for
300 ms before the measured scroll starts, so the scroll covers the same rows
from the same place as earlier runs. Its newest message has loaded before the
scroll starts, which was not the case before. These were not measured: how the
scenario's timings moved, how long a conversation that now opens lower takes
to show a readable body, whether marking read and fetching the neighbours now
start before their 300 and 400 ms limits, what the two calendar-suggestion
tasks that wait for the body cost now that it shows, and how a summary that
lands during the hold looks while the reader moves.

#### The benchmark's quit

From 4 November until `d296a1ec`, the harness had to end the app in every kept
benchmark run, which it does 30 s after the final report: all 126 run folders
from that time have `forcedTermination` true in `shutdown.json`. The audit asked
to quit from inside a `DispatchQueue.main` block. The app delegate answers
`terminateLater`, so `terminate(_:)` waits for the async quit review in a
nested event loop, and a run loop nested inside a main-queue block doesn't run
main-queue work. The review's main-actor task never started.

A sample taken 2 to 12 s into the quit had all 7,765 main-thread samples
waiting in that loop under the audit's `terminate(_:)` call. In a small AppKit
probe, a call from a main-actor task or a main-queue block never reached the
review, and a call from a run loop timer or a run loop block reached it within
1 ms. The audit now asks to quit from a run loop timer. A run under a locked
screen then ended 13 s after its report without being forced. The memory pause
accounts for 12 s of that; a run before the fix ended at 32 s.

Earlier timings stand, since the app writes its report before it asks to quit.
Quitting the app itself was never affected: Quit in the menu, the Dock and the
system's quit request call `terminate(_:)` from event handling, and nothing
else in the app calls it.

#### The table warning at launch

A launch of the Debug-Testing app logs "WARNING: Application performed a
reentrant operation in its NSTableView delegate. This warning will become an
assert in the future." two or three times, and never without the sidebar's
list. A temporary diagnostic printed the call stack at that line, and the stack
has no Tern frame. SwiftUI applies a row diff to the sidebar from its run loop
observer (`OutlineListCoordinator.diffRows`). To keep the top row in place,
`-[NSTableView endUpdates]` looks up the row at a point; AppKit caches row
heights to answer, adjusting the cached heights resizes the table, and the
resize asks the same cache for the table's total height. Leaving parts of the
sidebar out moved the count between none and three without pointing at one
part.

The diagnostic also noted what the sidebar held each time its body ran. In an
audit launch, the first two warnings came 67 and 104 ms after the body first
ran with two accounts, and the third 110 ms after it first ran with labels. The
audit adds its second account once the mailbox shows, while a real launch adds
every account before it shows, in `openMailbox(for:)`. Both read the labels
from a cache observation that `startLocal()` starts after the mailbox shows.
Whether the warning comes with anything visible was not checked.

Since `8e05b9c1` a real launch also reads the saved labels before the mailbox
shows, in the read that restores each account's sync state, so they are in the
sidebar's first frame. The observation still starts afterwards and brings later
changes. On a cache file with two accounts and 54 labels each, the read took
1.3 ms at the median, against 0.2 ms for the sync state alone, and 4.8 ms with
314 labels each. In a launch like the real one the labels had caused no
warning: a probe that opens the sidebar the way a real launch does logged none
in 13 runs before the change, when the labels came after the window, and none
in 3 runs after it. Adding a second account after the window shows, as the
audit launch does, logged two each time. The audit launch, which doesn't take
the new path, logged 2, 2 and 3 warnings before the change and 2, 3 and 3
after.

### Runs of the tip, 17 November

On the evening of 17 November the Mac was left to the benchmark. Each run
started once the screen was unlocked, the Mac had taken no input for ten
minutes and no process but Amphetamine held a display-sleep assertion. The
`all` run and two scroll-only runs are of `deb5b444`, the compose run of
`51dc9322`; the commits between them change only the compose audit and two
tests. None of the four took input. When the `all` run started, Spotlight's
`mds_stores` and `mds` were each using most of a core.

| Switch, p50 / p95 in ms | 14 Nov, warm | 17 Nov, warm | 14 Nov, other modes | 17 Nov, other modes |
| --- | --- | --- | --- | --- |
| To Calendar | 47 / 51 | 50 / 55 | 61–66 / 66–79 | 71–72 / 77–82 |
| To Mail from Calendar | 58 / 62 | 49 / 58 | 78–80 / 85–105 | 69–70 / 73–75 |
| To the library | 84 / 93 | 76 / 88 | 84–85 / 90–94 | 91–94 / 101–110 |
| To Mail from the library | 122 / 136 | 88 / 96 | 110–118 / 117–126 | 111–117 / 126–128 |

The other modes are active sync, offline and delayed. Since the library became
a flag on `MailboxModel` (`3727b48c`), Mail stays as it was behind it, and the
warm way back to Mail fell from 122 to 88 ms at the median. In the other three
modes the way back did not move, and the ways to the library and to Calendar
were 6 to 10 ms slower. What those modes add to a library switch was not looked
at, and one run on each day cannot separate the build from the day.

Message selection matched 14 November. At the median a retained message took
53–55 ms (50–51 then), a stored one 150 ms (151–161) and one from the network
685 ms (689). The stored message's header came at 88 / 103 ms, just over its
100 ms target at p95.

| Delayed callbacks | `scroll-1` | `scroll-2` | `all` |
| --- | --- | --- | --- |
| Mail list | 1.2% | 1.5% | 1.9% |
| Mail list, pointer on it | 1.8% | 1.3% | 5.2% |
| Mail list, parked again | 1.6% | 1.6% | 1.8% |
| Reader, 20 messages | 3.5% | 3.2% | 4.0% |
| Reader, 20 messages, pointer on it | 4.4% | 4.8% | 4.9% |
| Reader, 100 messages | 2.9% | 2.9% | 3.8% |
| Reader, 100 messages, pointer on it | 4.2% | 4.3% | 4.2% |
| Read conversation | 0.5% | 0.5% | 0.7% |
| Read conversation, pointer on it | 0.6% | 0.7% | 0.6% |
| Calendar | 0.2% | 0.2% | 0.1% |
| Attachments | 1.4% | 1.5% | 1.4% |

No run had a stall of 100 ms. The per-event records say which frames are late.
In `scroll-2`'s mail list, the main thread was awake 17.7 ms at the median and
20.6 ms at p95 in the frames where a row's avatar ran its body, about 382 of
1,764, against 1.8 ms in frames with no event, and 25 of its 26 late frames
were such frames. In the expanded conversations, the frames a message row
entered or was built in were awake 30 to 33 ms at the median and 38 to 41 ms at
p95, and most late frames were these; each of those scrolls also made 50 to 59
web views. A row entering the read conversation costs about 17 ms and is rarely
late. What is left is a row's own build: the header, actions, avatar and
address menu bodies, and in an expanded message its web view.

Opening a compose window, 100 times each through the menu item after three
untimed openings, timed from the item's action:

| p50 / p95 in ms | New Message | Reply |
| --- | --- | --- |
| The draft alone, no window | 5 / 5 | 10 / 11 |
| The window is key | 45 / 55 | 41 / 46 |
| The main thread is first free, window on screen | 229 / 251 | 224 / 243 |
| A field has the cursor | 287 / 317 | 279 / 303 |
| The main thread stays free | 303 / 337 | 279 / 303 |

The draft is under 4% of the time to the cursor, so opening the window before
its draft exists would gain 10 ms at most. The window is key within 45 ms, and
the main thread then does not come free for another 180 ms, so the cost is in
the window's own build, layout and first display. Keys typed in those 290 ms
reach the new message through the type-ahead (`320ce418`). The first compose
run stopped at its menu lookup, which `a3fe51ea` fixed: a SwiftUI command item
has no action, and reads as disabled, until AppKit tells its menu that it is
about to open.

### Where a compose window's time goes

A run sampled with `sample` every millisecond while the benchmark opened and
closed compose windows (its timings don't count) gave 22,466 busy samples on
the main thread. Each sample is counted once, in the first of these parts found
on its stack:

| Part | Share of busy samples |
| --- | --- |
| The `openWindow` call: SwiftUI builds the window, then AppKit orders it front and makes it key. The toolbar's first layout, inside that, is 10.7% of the total. | 25.5% |
| The toolbar in later updates: SwiftUI rebuilds each item's overflow menu form (4.3%), and AppKit lays out the item views and updates their constraints again | 14.0% |
| SwiftUI hosting views laid out in display cycles, in either window | 22.1% |
| Other SwiftUI view graph updates | 12.4% |
| Closing windows | 6.7% |
| The main window's sidebar outline updating | 4.5% |
| The rest: other display cycle work and event handling | 14.8% |

Tern's own code is a small part of each. The 290 ms to the cursor go to AppKit
and SwiftUI building a window with six toolbar items and three spacers, and
updating it in the rounds that follow while the draft loads and opens for
edits. Fewer toolbar items saved little (below). Since `1739be42` one step
sets up a new draft's sender, signature and font (`MailboxModel.setUpNewDraft`).
The mailbox runs it before the window opens for some drafts; for New Message,
which the benchmark opens, the window runs it after reading the senders.
Opening a window with its draft and sender ready, so that its first round has
the form and enabled items, might save a round; it was not tried.

Closing took 181 ms for an untouched New Message and 183 ms for a Reply at the
median, p95 203 and 201, because the close button waited for the draft's
discard and disabled the window's controls meanwhile. Since `c668e2ac` a window
whose draft needs no save closes at once, and the draft is discarded or kept
after the window goes. A draft with changes Gmail lacks still holds its window
until they are stored, and a loading contact group, a file still attaching or
failed, or a queued write keeps the old path with its alerts. The compose
suites passed on it (62 tests). On 18 November two runs timed 200 closes of
each kind: 14 ms for New Message and 12 ms for Reply at the median, p95 21 and
18.

### Three compose controls in one toolbar item

Formatting, Attach Files and More share one glass background. A trial
(`3edcd3b0`, not on this branch) put them in one toolbar item, which left four
items and three spacers. Two runs of each build, in the order current, grouped,
grouped, current, each opened 100 windows of each kind on 18 November:

| p50 / p95 in ms | New Message, current | New Message, grouped | Reply, current | Reply, grouped |
| --- | --- | --- | --- | --- |
| The window is key | 45 / 51 | 43 / 51 | 29 / 36 | 29 / 35 |
| The main thread is first free, window on screen | 200 / 216 | 198 / 220 | 185 / 205 | 181 / 196 |
| A field has the cursor | 253 / 270 | 251 / 273 | 240 / 256 | 236 / 257 |
| The main thread stays free | 259 / 293 | 259 / 291 | 241 / 256 | 236 / 258 |
| Closing | 14 / 21 | 15 / 20 | 12 / 18 | 12 / 18 |

The grouped medians to the cursor were 2.6 ms lower for New Message and
3.9 ms lower for Reply. 95% bootstrap intervals over the openings ran from 6.3 ms
lower to 1.0 ms higher, and from 6.5 to 1.1 ms lower. The two runs of the
current build differed by up to 3.5 ms at the median, so this is not a clear
gain. The grouped controls also looked different: the three icons sat closer
together in a capsule 26 points narrower, and the accessibility tree put
Formatting and Attach Files inside a group under the toolbar. The trial was
not kept. Two fewer items saving 2 to 4 ms suggests that most of the toolbar's
share in the sample does not depend on how many items it has.

Both builds reached the cursor 34 and 39 ms sooner in these runs than in the
first table (253 and 240 ms against 287 and 279). The first table's runs were
of an earlier build (`51dc9322`, before `c668e2ac`) on 17 November. The cause
of the difference was not checked, so compare compose timings only within one
session.

### Not measured in this pass

The app with real mail was not launched, so launch time on the real cache and
Keychain path is unmeasured. The runs the benchmark counts as attended covered
scrolling only, and nobody is known to have watched them; the mode switches and
message selections have no attended run, so their timings still do not count
toward acceptance. Scrolling by wheel or trackpad was not measured. Motion was read
from captured frames and tests and was not watched at speed, the toolbar's
change after a mode switch included. Instruments was not used; frame hitches
are known only through the callback proxy. Compose windows were timed and
sampled on 17 November and timed again, closing included, on 18 November
(above).

Scrolling since the library change was compared with the tree just before it.
`main` was not run beside either.

The hosted suite passed 1,009 of 1,010 tests with the column restore, again
with the library kept mounted while the kept-rows change was still in, and a
third time on the final tree; the interrupted-drag test failed each time, as it
had before, and passes since `92d16309`. Before that third run, while the screen
was still locked, the six suites that cover the library, the toolbar, the
sidebar and workspace search ran on the final tree three times, 36 tests a run,
and the sidebar suite ran five more times:

| Test, screen locked | Final tree | `main` |
| --- | --- | --- |
| `workspaceKeepsFirstRowsAndMailSearchVisible` | failed 8 of 8 | failed 4 of 4 |
| `attachmentToolbarClearsSidebarAndRestoresMail` | failed 1 of 8 | failed 0 of 4 |
| The other 34 | passed 3 of 3 | not run, apart from the sidebar suite's other 4, which passed 4 of 4 |

The first test presses toolbar buttons and resizes the window, and it fails the
same way on `main` under the lock. The second failed in the first run after a
build, when the library's sidebar was 80 points short of its dragged width three
seconds after the window widened. Run alone twelve more times on each build,
still under the lock, it passed every time: one failure in 20 runs of the final
tree and none in 16 of `main`. The code that sets that width after a resize is
the same on both: `TernSidebarSplit`, the toolbar's room for a sidebar in
`WorkspaceToolbarLayout`, and the path from the window's width to it in
`MainView`. That points at the locked screen and not at the branch, but the one
failure has not been reproduced or explained. Both tests passed in all three
full runs with the screen unlocked, the one on the final tree included.

## Finishing pass, 19 November 2026

This pass is the branch `chore/finishing-pass`, merged into `main` on
19 November, and two commits on `main` after it:

| Commit | Change |
| --- | --- |
| `929a2ad6` | A Today visit keeps its history read when the task that began it is cancelled. |
| `1739be42` | One step sets up a new draft's sender, signature and font, and it does not count as an edit (above, under "Where a compose window's time goes"). |
| `32c0d056` | Forward as Attachment opens its window before the message downloads. |
| `8e05b9c1` | A launch reads the saved labels before the mailbox shows (above, under "The table warning at launch"). |
| `4012c9d3` | The message header draws its controls in SwiftUI (above, under "What fills the frame a message enters in"). |
| `abb6a32e` | A conversation opens at its first expanded message (above, under "Where a conversation opens"). |
| `17082587` | A hosted test scrolls by hand while the opening hold runs (above, under "Where a conversation opens"). |
| `2e8f3287` | The header's menus and buttons are AppKit controls again, which undoes `4012c9d3` (below, under "Rows entering with the SwiftUI header"). |

The hosted suite passed on `abb6a32e`: 1,022 tests in 148 suites in 277 s, with
the screen unlocked and no input during the run. The reader's six suites passed
on the two reader commits alone, 39 tests with 3 skipped in that configuration.
The new opening test failed in its first run on a fault in the hold, which was
fixed before the commit. The suite passed again on `17082587`, 1,023 tests in
285 s, and on `2e8f3287`, 1,023 tests in 281 s. `ClaudeHelperTests` passed on
`17082587` (17 tests), and the Core package's 961 tests in 141 suites passed on
`c55daf22`; no later commit changes the package.

### The pass against its first commit

A first attempt that afternoon measured nothing: input from the person at the
Mac invalidated its first run 30 s in (36 events), and the runner was stopped
so that later runs would not take the screen from them. The runs here were made
that evening, one after another between 19:55 and 21:02, with the screen
unlocked and no input in any run. The Mac was not quiet: its one-minute load
average was 2.9 to 17.8 when a run began.

`929a2ad6`, the pass's first commit, changes only the Today view's model, so it
stands for the tree before the pass, and `c55daf22` is the merged tree. Two
variants of `c55daf22`, neither on `main`, ran in the scroll and reader scopes:
"AppKit menus" (`f9d2ba15`) undoes `4012c9d3`, and "Row style" (`c79746db`)
keeps its SwiftUI menus with another button style (next part). Late callbacks
in the reader's scrolls:

| Scroll | `929a2ad6` | `c55daf22`, two runs | AppKit menus | Row style |
| --- | --- | --- | --- | --- |
| `reader-20` | 3.1% | 4.0%, 3.8% | 3.3% | 4.6% |
| `reader-20-pointer` | 3.3% | 4.2%, 4.5% | 3.4% | 4.0% |
| `reader-100` | 4.0% | 3.7%, 4.0% | 3.7% | 4.7% |
| `reader-100-pointer` | 3.0% | 3.5%, 4.1% | 3.2% | 4.4% |
| `reader-read-100` | 0.7% | 2.0%, 2.2% | 0.5% | 5.0% |
| `reader-read-100-pointer` | 0.3% | 2.9%, 2.9% | 0.6% | 5.2% |

Median time the main thread was awake in a callback in which a row entered:

| Scroll | `929a2ad6` | `c55daf22`, two runs | AppKit menus | Row style |
| --- | --- | --- | --- | --- |
| `reader-20` | 30.1 ms | 38.0, 39.0 ms | 30.0 ms | 44.6 ms |
| `reader-20-pointer` | 31.2 ms | 38.4, 38.5 ms | 30.5 ms | 44.2 ms |
| `reader-100` | 30.2 ms | 39.5, 39.9 ms | 29.8 ms | 41.4 ms |
| `reader-100-pointer` | 31.3 ms | 41.9, 40.7 ms | 31.0 ms | 46.1 ms |
| `reader-read-100` | 15.6 ms | 21.2, 21.3 ms | 16.5 ms | 22.7 ms |
| `reader-read-100-pointer` | 16.8 ms | 21.3, 21.6 ms | 16.7 ms | 22.9 ms |

In callbacks with no reader event the main thread was awake 2.7 to 4.6 ms at
the median in every build. The mailbox, calendar and attachment scrolls bring
in no message rows; their late share was 0.1% to 1.9% in every build, and 3.1%
to 4.5% in `mailbox-pointer`. No scroll had a stall over 100 ms. Every build
was over the 1% budget in the mailbox scrolls and in the conversations of
expanded messages, and only `929a2ad6` and AppKit menus were within it in the
read conversation.

### Rows entering with the SwiftUI header

On `c55daf22`, in a callback in which a row entered a conversation of expanded
messages, the main thread was awake 7.2 to 10.6 ms longer at the median than on
`929a2ad6`, and 4.5 to 5.7 ms longer when a collapsed row of the read
conversation entered. The two runs of `c55daf22` agreed within 1.2 ms. With
AppKit menus, rows entered within 0.9 ms of `929a2ad6`, and the read
conversation's late share fell to 0.5% and 0.6%.

`4012c9d3` drew More and the sender's menu with `.menuStyle(.button)` and
`.buttonStyle(.plain)`, gave the action buttons `.plain` in place of
`.borderless`, and added views to keep the header's look: the sender's arrow,
and a label for More the size of the AppKit button. Row style kept all of that
but gave the two menus the reader's `RowButtonStyle` in place of `.plain`; with
keyboard navigation off, as on this Mac, that style draws the label without a
system button. It was no faster, so the menus' `.plain` is not where the time
goes. These runs do not separate the rest of `4012c9d3`: SwiftUI drawing the
menus, the views added to keep the look, and the action buttons' style. Row
style's More menu also had no accessibility element, so the header tests could
not find it.

`2e8f3287` undoes `4012c9d3` on `main`. The header looks as it did before: the
sender's name has the AppKit menu arrow and does not show the weights the code
sets for read and unread mail.

These runs reverse what the runs of 14 November suggested (above, under "What
fills the frame a message enters in"), in which the read conversation was late
in 1.7% and 1.9% of callbacks with lighter styles and in 5.7% and 2.8% as
shipped. Those runs tried a version of the styles that did not keep the
header's look, and `reader-read-100` then began before the newest message's
body had loaded. Which of the two differences turns the result around was not
tested.

### Buttons on the mail list's rows

Each row of the mail list draws two buttons in the borderless style: the
sender's avatar and the star. `e09bc693`, on the branch `perf/list-row-buttons`
and not in `main`, gives both `RowButtonStyle` (above, under "A style for a
row's buttons"). While Keyboard navigation is off they draw their label and
take the click with a tap gesture. While it is on they are borderless buttons
that take focus, as before.

The change was built on `f9d2ba15`, which has the app code of `2e8f3287`. It
ran twice in the scroll scope, at 21:44 and 21:59, against the app built from
`f9d2ba15` without it: the run of AppKit menus above, at 20:41, and a copy of
the same app at 21:53. No input reached any run. Late callbacks:

| Scroll | Before, 20:41 | Before, 21:53 | Change, 21:44 | Change, 21:59 |
| --- | --- | --- | --- | --- |
| `mailbox` | 1.5% | 1.5% | 1.4% | 1.0% |
| `mailbox-after` | 1.6% | 1.5% | 1.4% | 1.3% |
| `mailbox-pointer` | 3.9% | 3.7% | 0.3% | 0.4% |

In `mailbox-pointer` the rows move under a resting pointer. Before the change,
most of its late callbacks were ones in which no row entered: 63 and 62, against
4 and 8 with the change. Why the system style delayed those frames was not
profiled. In `mailbox`, a callback in which a row entered kept the main thread
awake 17.0 and 16.4 ms at the median with the change, against 18.4 and 18.2 ms
before.

In the other scrolls the two builds were as far apart as two runs of one build.
The conversations of expanded messages were late in 3.1% to 3.9% of callbacks
with either build, the read conversation in 0.2% to 0.6% and the calendar in
0.1% to 0.2%. The attachment library was late in 0.7% and 0.6% with the change
and in 1.0% in both runs before; it has no mail rows, and the difference was
not looked into.

`mailbox-after` is still over the 1% budget in both runs, and `mailbox` in one.
Nearly all their late callbacks are ones in which a row entered, and a row
entering keeps the main thread awake about 16.5 ms, a frame at 60 Hz.

The change is not in `main` because its clicks are unchecked. A tap gesture in
a table row has to act without the table also selecting the row, and the
branch's hosted test for that has not passed in a form that checks it. The
first version found the star and the avatar by clicking along the row's first
line: each acted, and the row still offered VoiceOver its star action. But no
click beside them selected the row either, so the test could not tell, and
after the suite the test host never exited. A sample showed a mouse-down that
the window's gestures had held reaching the table after the test, and the
table waiting in drag detection for a mouse-up. That version sent each click's
down and up with one timestamp. With them queued 30 ms apart, a click on the
subject did not select the row, and the test window was not key. The version
on the branch gives the test a window that reports itself key. The screen
locked before it ran. The other 32 tests in the list's suite passed with the
change; the rest of the hosted suite did not run on it, and nobody has clicked
a star or an avatar in the list by hand.

### Opening, compose and mode switches

Opening a message showed no difference between the builds. The two runs of
`c55daf22` reached the reader in 162 and 135 ms at the median in
`reader-local`, further apart than any two builds: 145 ms on `929a2ad6`, 138 ms
with AppKit menus and 142 ms with Row style. `reader-recent` ranged from 45 to
55 ms the same way.

The compose and workspace scopes ran at about 20:15, once on `929a2ad6` and
once on `c55daf22`, and again between 21:26 and 21:44 with `f9d2ba15` beside
them. `f9d2ba15` has the app code of `2e8f3287`. In the later runs compose ran
twice on `f9d2ba15` and twice on `929a2ad6`, and workspace once on each of the
three. Compose, with the runs of a build pooled:

| p50 / p95 in ms | `929a2ad6`, 3 runs | `c55daf22`, 1 run | `f9d2ba15`, 2 runs |
| --- | --- | --- | --- |
| New Message, the window is key | 41 / 52 | 47 / 54 | 32 / 52 |
| New Message, the main thread is first free, window on screen | 200 / 230 | 205 / 230 | 198 / 224 |
| New Message, the main thread stays free | 276 / 307 | 268 / 304 | 262 / 296 |
| Reply, a field has the cursor | 255 / 290 | 249 / 264 | 249 / 267 |

The time to a new message's key window depends on the run, not the build. Its
median was 30, 46 and 46 ms in the three runs of `929a2ad6`, 29 and 46 ms in
the two of `f9d2ba15`, and 47 ms in the run of `c55daf22`. The 17 ms between
the first two runs was that difference, and what decides it for a run was not
found. A reply reached the cursor about 6 ms sooner on both later builds.
Closing took 14 to 17 ms at the median in all three.

The workspace scope, one run to a column:

| p50 / p95 in ms | `929a2ad6`, 20:20 | `929a2ad6`, 21:30 | `c55daf22`, 20:18 | `c55daf22`, 21:42 | `f9d2ba15`, 21:28 |
| --- | --- | --- | --- | --- | --- |
| Warm switch to Calendar | 58 / 67 | 48 / 53 | 48 / 51 | 49 / 55 | 47 / 51 |
| Warm switch to Mail | 59 / 68 | 48 / 51 | 49 / 51 | 49 / 58 | 47 / 49 |
| To the attachment library | 75 / 86 | 73 / 80 | 80 / 87 | 74 / 81 | 72 / 79 |
| From the library to Mail | 86 / 99 | 85 / 90 | 93 / 104 | 88 / 96 | 84 / 89 |

The first run of `929a2ad6` was slow throughout: the main actor was held for
100 ms or more 34 times in it, against 1 to 7 times in the others, so the warm
switches were not faster on `c55daf22`. The way back to Mail from the library
was 3 to 7 ms slower on `c55daf22` than on `929a2ad6` at the median in both
pairs, and only the first run of `c55daf22` went over the 100 ms budget. On
`f9d2ba15`, which differs from `c55daf22` only in the header, it took 84 / 89
ms. That is one run.

Not checked in this pass: the opening hold under a physical wheel or trackpad
(a hosted test sends synthetic ones; see "Where a conversation opens") and with
a body that takes more than 2 s to load, what sets a run's time to the key
window, and the UI tests, which need Automation Mode and so an administrator's
password. The benchmark counted its runs as attended, but nobody watched them.
