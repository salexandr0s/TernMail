# Navigation performance

Tern caches calendar layout, mail rows, message documents, and decoded contact
images. Foreground reading has priority over speculative preparation. The
implementation is still being measured: warm mode switches currently miss the
acceptance targets below, and the new build has not been installed.

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

The Tasks rows and the sidebar's disclosure rows bind focus per row in the same
way. Their lists were not measured.

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
goes to work on the main thread after the content is ready. That work was not
profiled.

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

### Not measured in this pass

The app with real mail was not launched, so launch time on the real cache and
Keychain path is unmeasured. The one attended run covered scrolling only; the
mode switches and message selections have no attended run, so their timings
still do not count toward acceptance. Scrolling with the pointer resting on the
list, which is how a person scrolls, was not measured. Motion was read from
still images and tests and was not watched. Instruments was not used; frame
hitches are known only through the callback proxy.
