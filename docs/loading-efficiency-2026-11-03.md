# Loading efficiency pass — November 3, 2026

This pass targets avoidable work on launch, mail selection and sync, sidebar
motion, Tasks navigation, and attachment/analytics refresh. Existing bounded
reader sessions, prepared-document caches, lazy rows, background image decoding,
and calendar presentation caches remain in use.

## Changes

- Open both SQLite stores away from the main actor, including configuration
  migrations, so launch UI can continue responding.
- Reuse WebKit's persisted compiled content rules across launches. The versioned
  identifier and existing fail-closed behavior preserve remote-content policy.
- Separate label appearance from changing unread/total counts. Count updates
  still refresh sidebar badges without invalidating every mail-row projection.
- Cache each account's visible label hierarchy instead of sorting it repeatedly
  for expansion and selection queries.
- Avoid publishing unchanged row selections, pages, account presentation and
  address context. Search and snoozed snapshots also reuse unchanged prepared rows.
- Keep only the newest pending mail-list, attachment-library and analytics
  snapshot for slow consumers. Other observation streams retain lossless delivery.
- Fetch the selected Tasks list directly when list metadata is already known.
  Explicit and periodic refresh still discover new or removed lists.
- Hold the dragged sidebar width during native split motion and skip redundant
  native divider corrections. The detail view keeps its identity through toggles.
- Enforce room for Mail beside an open utility panel after native window resizing.
  Use compact Calendar controls earlier to keep shared toolbar controls in place.

## Verification

- Core: **791 tests in 130 suites passed** in the final run, including the new
  slow-consumer snapshot regression. Core's dependency lockfile was restored by
  running this suite after Xcode, as the repository instructions require.
- App: **119 tests across 14 focused suites passed** in one consolidated run.
  Coverage includes mail rows, selection, label badges, Tasks, attachments,
  analytics, prefetching, reader preparation, WebKit, sidebar layout/motion and
  workspace retention. The opt-in system Reduce Motion audit was skipped;
  this pass did not change the user's system preference.
- The optimized Release build with `TERN_PERFORMANCE` succeeded. Debug app tests
  compile and exercise the same production changes.
- Diff whitespace checks passed for all changed source/test files.

New regressions establish that 100 unchanged selection revalidations produce no
reader observation notifications, count-only label updates do not rebuild row
projections, actual label appearance changes still update rows, selecting a known
Tasks list performs one read instead of also fetching list metadata, and a paused
snapshot consumer receives the newest of 20 writes rather than replaying all 20.
Native layout coverage also checks resizing with an open utility panel, compact
Calendar navigation, and returning to Mail with that panel still open.

The first broader runs exposed assistant clipping at narrow widths and Calendar
toolbar overflow/position changes. Both were fixed and passed the consolidated
run. An attachment-sidebar assertion failed once during overlapping GUI jobs;
it subsequently passed alone and in the final consolidated run.

Local evidence is in `build/loading-final-core-tests.log`,
`build/loading-final-regression-tests.log`, and
`build/loading-release-verified-build.log`. Source and artifact hashes are in
`build/loading-source-manifest.json`. These diagnostic files stay outside the
published source tree.

## Measurement scope

Native drawing-commit timings are programmatic interaction proxies, not physical
input latency or GPU frame presentation. Concurrent builds and GUI tests affected
early diagnostic runs. A later baseline and the final candidate failed the
foreground/key-window validity prerequisite; the candidate accepted no timing
samples. The earlier partial baseline also hit its diagnostic runtime limit.
None establishes a before/after speedup, universal near-instant loading, or a
GPU frame-rate improvement. Those claims require an uninterrupted foreground
benchmark and presented-frame profiling.
Network responses remain dependent on the service and connection. No production
installation or account-data migration was performed as part of this pass.
