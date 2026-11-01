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
the local macOS 27.2 target offline and failed to connect to DTServiceHub. Actual
presented-frame measurements remain unverified until that connection works.

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
It did not reproduce the foreground layout cost or establish an opacity fix.

Evidence is retained under
`/tmp/tern-performance-audit-build/reports/20261101T003603Z-100/` and
`/tmp/tern-performance-audit-build/reports/20261101T004216Z-workspace-diagnostic/`.
Background retention test logs are in
`/tmp/tern-workspace-retention-verification-2/test.log`.
A copy of these reports, the original process samples, and the final Core log is
kept in `~/.codex/backups/tern-performance-20261101/evidence/`.

The full Core suite passed 590 tests in 101 suites
(`/tmp/tern-perf-core-final-tests.log`). Calendar, preparation, WebKit, and five
reader lifecycle/viewport tests passed focused hosted runs. The full hosted suite
still needs a clean final run: the sidebar's native focus/resize test has been
interrupted by foreground changes and has also exposed a geometry settle delay.
Actual reader latency, scrolling targets, active-sync/offline scenarios, memory
plateau, and the final installed universal Release remain unverified. The user
requested background work while foreground timing runs are deferred.
