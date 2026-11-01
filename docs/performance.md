# Navigation performance

Tern caches calendar layout, mail rows, message documents, and decoded contact
images. Foreground reading has priority over speculative preparation. The
implementation is still being measured: warm mode switches currently miss the
acceptance targets below, and the new build has not been installed.

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
Normal Release builds contain no synthetic audit entry point. The script reports
the JSON output path. It requests normal termination, then uses a bounded fallback
only for the synthetic process it launched if termination hangs. The process
report records whether graceful exit succeeded. This does not verify the normal
app's quit workflow.

Acceptance runs require at least 100 warm switches in each direction, recent and
locally stored message selection, and sustained scrolling. Reports retain failures and
timeouts separately from successful percentiles. A scenario with missing content
or missing visibility probes must not be reported as passing.

For a normal Release launch, `--navigation-report=<absolute-path>` enables a
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
views. Minimized or fully occluded windows suspend automatic reader activity.

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
`~/.codex/backups/tern-performance-20261101/evidence/20261101T100342Z-100-workspace-only-normal/`.
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

Retained selection feedback p95 was 308.83 ms even though its data-ready marker
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
kept in `~/.codex/backups/tern-performance-20261101/evidence/`.

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
`~/.codex/backups/tern-performance-20261101/evidence/normal-universal-fcb181f/`.

## Retained-reader result after selection isolation

The controlled normal Release run on November 1 completed 100/100 retained-reader
selections after six warmups, with zero failures or superseded reader generations.
It meets the warm-reader latency target for this synthetic scenario:

| Measurement | Before p50 / p95 / p99 | After p50 / p95 / p99 | Target |
| --- | --- | --- | --- |
| Retained readable content | 326.27 / 353.63 / 404.70 ms | 81.77 / 95.55 / 98.97 ms | p95 ≤100 ms; p99 ≤200 ms: met |
| Selection feedback | p95 308.83 ms | 58.27 / 65.90 / 71.17 ms | p95 ≤50 ms: not met |

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
contract because feedback misses its target and local measurements are incomplete.
The test app was terminated after reporting; this run does not verify graceful
quit. No production installation has occurred.

Evidence, source manifest, raw results and assessment are retained at
`~/.codex/backups/tern-performance-20261101/evidence/20261101T143859Z-100-reader-only-normal/`.
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

Retained selection feedback p95 was 61.21 ms, still above 50 ms. The local
scenario intentionally cancels selection-feedback spans when the selected list
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
`~/.codex/backups/tern-performance-20261101/evidence/20261101T153445Z-100-reader-only-normal/`.
The later visual-row candidate passed 28 focused tests and built successfully,
but no after timings were collected within the three-minute user slot. No new
production installation has occurred.
