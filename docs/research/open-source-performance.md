# Open-source performance comparisons

Research checkpoint: November 1, 2026. Work continues on
`codex/instant-navigation` in a separate performance worktree.
Tern's measured navigation still misses the acceptance targets in
[performance.md](../performance.md). No new production build has been installed.

## Sources and ownership

- MishMail: [`7f4720692f84188fbaa5def97e3748dcaa84cc40`](https://github.com/ronboger/mishmail/commit/7f4720692f84188fbaa5def97e3748dcaa84cc40),
  October 17, 2026, [MIT license](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/LICENSE).
- Mailspring: [`c84212a97df7bab464fbdc8a3a3368785c94af70`](https://github.com/Foundry376/Mailspring/commit/c84212a97df7bab464fbdc8a3a3368785c94af70),
  October 30, 2026, [GPL v3 license](https://github.com/Foundry376/Mailspring/blob/c84212a97df7bab464fbdc8a3a3368785c94af70/LICENSE.md).
  Its rendering and subscription designs were studied; no code was copied.

These revisions were resolved through GitHub before reading the implementations.
All builds and native runtime checks remain serialized through the diagnostic
owner. The canonical checkout and its existing user changes are preserved.

## Ranked hypotheses

| Priority | Technique | Evidence in Tern | Next decision |
| --- | --- | --- | --- |
| 1 | Separate selection updates from row construction | The adapted boundary eliminates warmed selection-only factories; 100 retained selections improve from p95 353.63 to 95.55 ms | Keep the verified boundary; investigate remaining row-body work and attachment-triggered page updates |
| 2 | Verify effective responsive scrolling and rendered coverage | The outer SwiftUI scroll view reports incompatibility; its clip and document views report compatibility | Measure actual scrolling and readable coverage before changing compatibility or realization margins |
| 3 | Detect height oscillation | Tern suppresses duplicate measurements, but no actual A/B cycle has been established | Record raw/applied height sequences under stable width and document generations; change behavior only if cycles cause layout work |
| 4 | Prepaint prepared neighbors | Documents are prepared already; unseen neighbors do not have painted renderers | Consider only if prepared-hit-to-visible WebKit work remains dominant after selection isolation |
| 5 | Change body hydration or calendar retention | Existing preparation is cheap and calendar ranges are retained | Keep current infrastructure unless large-thread or range measurements identify a gap |

## Selection and row construction

MishMail's [selection-owning List](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Sources/MishMail/UI/ThreadListView.swift#L491-L513)
refreshes its binding as selection changes. Its separate
[section content](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Sources/MishMail/UI/ThreadListView.swift#L516-L591)
uses a layout revision to retain row construction. The source
[warns against wrapping flattened sections in `.equatable()`](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Sources/MishMail/UI/ThreadListView.swift#L480-L489)
because selection tags stopped working in that implementation. Tern's native
tests must establish its own behavior on the current OS.

Tern already prepares immutable row projections and has a scalar projection
revision. Two local experiments clarify the remaining dependency:

1. Moving selection reads into rows and a drag modifier still rebuilt all 42
   conversation factories across each of 12 selections, and all 43 message
   factories across each of 24 selections.
2. An observation discriminant found that constructing a binding observes the
   current selection, while constructing a List with an existing binding does
   not. Retaining one binding in the model avoided that dependency but broke
   programmatic native selection: the model selected B while NSTableView kept
   A+B selected. That candidate is rejected.

The verified replacement gives a small List view ownership of the
fresh binding, and keeps row factories behind an existing-revision boundary.
It introduces no second selection state or duplicate projection cache. The
strict native selection, stable table/scroll identity, account/message isolation,
read/star propagation, and zero warmed factory-reconstruction assertions all
passed in the optimized 19-test MessageListTests suite. Conversation factory
rebuilds fell from 42 per selection to zero across 12 warmed changes; message
factory rebuilds fell from 43 per selection to zero across 24 warmed changes.
The fixture has 42 conversation rows or 43 message rows and tests both native
and model-driven selection. Evidence:
`/tmp/tern-list-selection-shell-verification/test.log`.

A subsequent controlled normal Release run completed all 100 retained-reader
selections with zero failures. Visible readable-content commit latency improved
from p95 353.63 ms and p99 404.70 ms to p95 95.55 ms and p99 98.97 ms, meeting
the warm-reader target in this synthetic scenario. This is a combined comparison
of the native visibility guard, stable reader order, selection isolation and
functional fixes, not attribution to this boundary alone. Selection feedback
p95 improved from 308.83 to 65.90 ms and still misses its 50 ms target.

The measured scenario recorded zero row factories, 1,200 row-body evaluations,
two attached WebViews throughout, and no renderer creation or destruction.
Prepared documents stayed at 31,757 bytes; app footprint went from 285.9 to
283.9 MB during the warm scenario. This short stable interval does not establish
long-run memory bounds. No CUA inspection or profiler overlapped measurement.
The endpoint verifies ready content in the visible viewport at a native drawing
commit; it does not measure GPU presentation or input-queue delay before a
programmatic selection. Source and raw evidence are recorded in
`docs/performance.md`.

MishMail also has a cheap selection observer around an immutable visual row.
Tern currently observes selection inside the full visual row. Body-evaluation
counts and CPU measurements will decide whether that further separation is
needed after the list boundary works.

A later diagnostic run completed 100 retained and 100 local selections, but a
CUA inspection overlapped it, so its timings are excluded. Its structural
counters show zero retained row factories and 118,800 local factories. Source
analysis explains the local work through first-time attachment discovery:
35, 75 and 99 changed rows in the retained 200/400/current 600-row pages sum to
the recorded 209 projections. The active page's 99 updates times 600 rows times
two passes exactly match the factory count. The updates carry new attachment
metadata; existing duplicate suppression is working.

A bounded row-controls experiment retained immutable per-item construction
identity while keeping the modifier order and live settings. Its strict native
regression passed changed-row freshness and unchanged visible-row reuse, but an
offscreen unchanged controls body still evaluated again during attachment
publication. Exposing the same account-qualified selection tag at the outer
boundary did not help: the unchanged offscreen count remained 1→2. The experiment
was rejected and removed; no assertion was weakened. The result establishes
offscreen reevaluation, not which internal SwiftUI trait lookup caused it.
Evidence: `/tmp/tern-row-controls-outer-tag-verification-2/test.log`.

The next independent candidate separates a cheap selection observer from the
visual row, following MishMail's existing design. The accepted retained scenario
still evaluated 1,200 visual row bodies across 100 switches. Any new boundary
must keep selection, metadata, date text, hover, appearance and preferences live.

Rapid native selection coverage passes for both conversation and message modes,
including final selection stability without reapplying the target. An earlier
incomplete run had unexplained selection transitions; none occurred in the accepted
100-retained scenario. That historical audit has no native-input monitor. Commit
`891478e` adds a count-only monitor and schema-4 validation for future programmatic
runs: unexpected mouse-down, key-down or wheel input invalidates the report even
if every interaction completes. Events are neither consumed nor logged. Zero
does not exclude accessibility automation. The local-loading scenario completed
only 76/100 and supplies no accepted local-latency result.

Mailspring similarly [constructs rows only for a viewport range with margins](https://github.com/Foundry376/Mailspring/blob/c84212a97df7bab464fbdc8a3a3368785c94af70/app/src/components/list-tabular.tsx#L265-L354)
and [memoizes its row subtree](https://github.com/Foundry376/Mailspring/blob/c84212a97df7bab464fbdc8a3a3368785c94af70/app/src/components/list-tabular.tsx#L58-L108).
This supports bounding row work. It does not justify replacing Tern's native
List with a fixed-height virtualizer.

## Responsive scrolling and height measurements

MishMail's [WebKit subclass](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Sources/MishMail/Support/WebViewPool.swift#L16)
declares responsive-scrolling compatibility and forwards wheel input to its
parent. Tern instead preserves internal horizontal overflow and locks direction
through momentum. That routing must remain intact.

[Apple's compatibility documentation](https://developer.apple.com/documentation/appkit/nsview/iscompatiblewithresponsivescrolling)
identifies the NSScrollView, NSClipView, and embedded document view. It does not
establish that every incompatible nested descendant disables the outer scroller.
The recovered reader on macOS 27.2 has one outer SwiftUI.HostingScrollView whose
compatibility value is false, a HostingClipView reporting true, and a document
view reporting true. The nested ContentSizedWebView reports false but is not the
outer document view. Its complete ancestry was nonhidden with alpha one in the
key, visible window. Adding an override only to ContentSizedWebView would leave
the outer scroll view's false value unchanged. No override has been added.

This public-property inspection does not prove the effective asynchronous state
or explain observed hitches. It used a main-thread idle debugger stop, not a
timing run. Evidence: `/tmp/tern-list-guard-reader-hierarchy/hierarchy-valid.txt`.
Real vertical, horizontal, diagonal and momentum input under controlled load
remains a separate behavioral check.

Tern's current realization gate uses viewport intersection, Find targets, and
bounded hidden retention. It has no explicit surrounding realization margin.
[Apple's content-preparation API](https://developer.apple.com/documentation/appkit/nsview/preparecontent(in:))
describes rendering beyond the visible region. The static hierarchy snapshot's
prepared rectangles were zero; that alone does not establish missing pixels.
Compare prepared coverage,
readable body rectangles and placeholder exposure with hitches before changing
the realization policy. A margin must remain bounded by existing budgets.

MishMail's [height stabilizer](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Sources/MishMail/Support/HTMLBodyPerformance.swift#L297)
and [tests](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Tests/MishMailTests/HTMLBodyPerformanceTests.swift)
detect alternating heights, hold the larger value, and require repeated matching
measurements to release it. Tern's duplicate suppression can prevent those
repeated reports, so that release rule would be inappropriate here.

The proposed audit records anonymous renderer generation, time, width, raw/applied
height, measurement source, activity, and genuine document/font/image/expansion
changes. A-B-A-B-A at unchanged width and generation is a diagnostic signal,
not permission to clamp content. Genuine shrinking and resizing must survive.

## Reader and calendar reuse

MishMail [prepaints neighbors into parked WebKit views](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Sources/MishMail/Support/HTMLBodyPrerender.swift)
after the selected body settles, blocking speculative remote images. Tern already
prepares neighbors and retains recently used identity-bound readers. Prepainting
would be a distinct experiment only if the remaining delay is in WebKit rendering.
Any view assigned to a message/account identity must keep that identity for its
lifetime. Cross-message live-view recycling is excluded.

MishMail's [detail cache](https://github.com/ronboger/mishmail/blob/7f4720692f84188fbaa5def97e3748dcaa84cc40/Sources/MishMail/Support/ThreadDetailCache.swift#L543)
initially hydrates a subset of bodies. Tern currently loads locally stored thread
bodies. Large-thread bytes and first-visible latency could justify selective
hydration later, with unread expansion, Find and printing preserved.

Mailspring's [body processor](https://github.com/Foundry376/Mailspring/blob/c84212a97df7bab464fbdc8a3a3368785c94af70/app/src/flux/stores/message-body-processor.ts#L25-L92)
debounces reprocessing and avoids unchanged publications. Tern already keys body,
resource and policy revisions separately and suppresses unchanged WebKit loads.
The accepted Tern run measured preparation p95 at 0.527 ms, versus retained
selection feedback at 308.83 ms. Another cache or a 250 ms debounce is unsupported
by that evidence.

Mailspring's [EventRangeSubscription](https://github.com/Foundry376/Mailspring/blob/c84212a97df7bab464fbdc8a3a3368785c94af70/app/internal_packages/main-calendar/lib/core/calendar-data-source.ts#L272-L312)
retains an expanded query until requested dates leave its coverage. Tern already
retains current and locally prepared adjacent ranges, coalesces refreshes and
avoids unchanged presentation publications. Existing tests cover repeated warm
activation without further requests. Remaining mode-switch cost requires layout
measurement; there is no demonstrated range-retention gap.

A separate toolbar-placement control kept declarations and geometry unchanged
while comparing the clipped content owner with an outer owner. Its background
CPU medians rose across normal-before, outer, normal-after: Mail 193.15, 289.05,
382.45 ms; Calendar 199.05, 296.10, 400.00 ms. This sequence drift prevents a
causal comparison. Four strict cross-window assertions also failed because
generated calendar subitem UUIDs differed; other geometry, corpus and visibility
checks passed. No toolbar change is adopted. The exact experiment and failures
are archived under `evidence/tern-outer-toolbar-owner-verification/`; these are
diagnostic CPU measurements, not accepted visible-switch timings.

## Future transport shortlist: SwiftMail

[Cocoanetics/SwiftMail](https://github.com/Cocoanetics/SwiftMail) is shortlisted
for a future IMAP transport experiment. Reference version: **1.16.0**
([versioned source](https://github.com/Cocoanetics/SwiftMail/tree/1.16.0),
[documentation](https://swiftpackageindex.com/Cocoanetics/SwiftMail/1.16.0/documentation/swiftmail)).
Status: documented candidate only. No dependency, prototype or migration is being
introduced as part of this entry.

Potential benefits to evaluate:

- Resilient IMAP IDLE connections for earlier mailbox-change detection.
- Pipelined body-part retrieval for uncached messages.
- Partial `BODY.PEEK` retrieval that preserves unread state.
- Gmail message/thread IDs and labels that can map to existing Gmail API data;
  verify the actual public API support and mapping in the reviewed version.

Proposed future experiment:

1. Assess authentication scopes, account lifecycle, reconnect behavior and Gmail
   identifier/label mapping, including account isolation and sign-out cleanup.
2. Compare uncached loading against Tern's existing **batched Gmail API** path
   using identical messages, cache states and network conditions.
3. Measure time to readable content in the visible viewport, new-mail detection
   latency, transferred bytes, CPU and memory. Separate retrieval time from
   local preparation/rendering, and report reconnect and failure cases.
4. Evaluate a hybrid in which IDLE notifications trigger the existing Gmail
   synchronization process, preserving its reconciliation and action queue.
5. Before implementation, define numeric adoption thresholds for latency gains,
   detection latency, bandwidth, CPU and memory, plus correctness and reconnect
   requirements. Promote the candidate only when assessment and measurements
   justify a bounded prototype; adoption requires evidence against Tern's baseline.

The upstream “3–5× faster” source comment compares pipelined with sequential
**IMAP fetching**. It does not demonstrate an advantage over Tern's batched Gmail
API implementation.

This transport candidate is separate from the ongoing cached-navigation and
scrolling fixes. IMAP cannot remove expensive local list updates, reader
recreation or layout work. Existing performance work and cache/identity/policy
constraints remain in place.

## Measurement and adoption

Keep source revisions, cache tiers, memory and renderer counts with every report.
Accepted navigation scenarios require at least 100 warm interactions and visible,
readable viewport content. Native drawing commits and display-link gaps are
proxies; actual presented-frame hitches remain a separate verification requirement.
Record rejected candidates and incomplete runs alongside successful measurements.
No upstream comment or implementation is treated as a performance result for Tern.
