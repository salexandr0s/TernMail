# Open-source performance comparisons

Research checkpoint: November 1, 2026. Work continues on
`codex/instant-navigation` in `/Users/developer/GitHub/REA_Mime-perf`.
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
| 1 | Separate selection updates from row construction | CPU samples reach list diffing and factories; native tests rebuild an entire page on every selection | Adapt the small selection-owning List and stable content boundary; preserve native selection tests, then measure Release latency |
| 2 | Verify effective responsive scrolling and rendered coverage | Tern overrides wheel routing and realizes bodies at viewport intersection; effective scroll-view compatibility is not yet measured | Inspect the actual scroll/clip/document hierarchy and readable coverage during scrolling before changing compatibility or realization margins |
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
and model-driven selection. This is structural evidence; the next Release
benchmark must establish visible latency on the large corpus. Evidence:
`/tmp/tern-list-selection-shell-verification/test.log`.

MishMail also has a cheap selection observer around an immutable visual row.
Tern currently observes selection inside the full visual row. Body-evaluation
counts and CPU measurements will decide whether that further separation is
needed after the list boundary works.

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
Tern's actual hierarchy needs inspection before adding an override. Record the
outer triplet, WebKit's ancestors/internal scrollers, compatibility values,
gesture phases, routing, and scroll bounds. Test vertical, horizontal, diagonal,
mouse-wheel and momentum behavior, including controlled main-thread load.

Tern's current realization gate uses viewport intersection, Find targets, and
bounded hidden retention. It has no explicit surrounding realization margin.
[Apple's content-preparation API](https://developer.apple.com/documentation/appkit/nsview/preparecontent(in:))
describes rendering beyond the visible region. Compare prepared coverage,
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

## Measurement and adoption

Keep source revisions, cache tiers, memory and renderer counts with every report.
Accepted navigation scenarios require at least 100 warm interactions and visible,
readable viewport content. Native drawing commits and display-link gaps are
proxies; actual presented-frame hitches remain a separate verification requirement.
Record rejected candidates and incomplete runs alongside successful measurements.
No upstream comment or implementation is treated as a performance result for Tern.
