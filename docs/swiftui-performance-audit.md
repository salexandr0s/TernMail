Tern SwiftUI performance audit, 2026-11-02

This preventive audit covers the message list, thread reader and attachment library. The user reported no specific slowdown. Findings below distinguish repeated work established by source and controlled measurements from possible scrolling or latency problems that still need an Instruments capture. No end-to-end CPU, frame-drop or peak-memory improvement is claimed.

The audit follows `swiftui-performance-audit`. Local checks use Apple silicon, macOS 27.2 and Xcode 26.3. Verification runs against a frozen copy of commit `46c85a13575cd5e7a77f71d35142e979f0612eb7` with the audit changes overlaid, because other sessions are editing and building the shared checkout.

The fixes, ordered by expected impact:

1. Cached contact-photo preparation ran on the main actor. [ContactPhotoImages.swift](../App/Design/ContactPhotoImages.swift) called ImageIO to decode, downsample and re-encode warm cached data. This was a confirmed main-actor code path shared by message-list and reader avatars; its contribution to a real scrolling hitch is unmeasured. The fix moves cached preparation to a background task while retaining byte/pixel bounds, cancellation and the final account-access/photo-version checks. Final creation of the bounded `NSImage` remains on the main actor.

2. Reader DOM callbacks repeated layout measurements and bridge messages. [MessageWebView.swift](../App/Views/MessageWebView.swift) posted every hover/selection event and measured content separately for each resize/load/font callback. Controlled execution of the actual emitted scripts confirms the repeated work. The fix coalesces observer callbacks per animation frame and sends only changed values. Initial measurements and explicit native requests bypass frame coalescing and share the same last-reported-height state. Tests cover clearing hover/selection, growth, shrinkage and a return to a previously reported height. Navigation revision checks, isolated script execution and remote-content rules remain in place.

3. Message rows repeatedly derived labels and attachments. [MessageListItem.swift](../App/Mailbox/MessageListItem.swift) rebuilt the label union and deduplicated attachment array on every access; [MessageListRow.swift](../App/Views/MessageListRow.swift) filtered/sorted labels repeatedly for display and accessibility. The fix gives each immutable item a lazy metadata helper, reuses labels/date/font metrics within a row body, and captures the list selection once per list construction. Item equality compares source values, independent of whether metadata has been read. A benchmark rejected an earlier eager approach because it charged all offscreen rows during construction. Regression coverage checks attachment identity/order and metadata changes under a stable row identity.

4. Attachment page refreshes published unchanged selection. [AttachmentLibraryModel.swift](../App/Attachments/AttachmentLibraryModel.swift) mutated the observed selection with `formIntersection` even when the selected IDs survived. A controlled Observation check produces one callback for the original no-op mutation. The fix compares the intersection before assigning. The database-backed regression checks that adding a file preserves selection without notification and removing the selected file still clears and notifies.

Controlled measurements:

| Workload | Before | After | What it establishes |
| --- | ---: | ---: | --- |
| 206 synthetic hover/selection events | 206 bridge posts | 5 bridge posts | Duplicate values no longer cross the WebKit bridge. |
| Initial layout plus 201 unchanged resize/load/font callbacks in one frame | 202 measurements / 202 posts | 2 measurements / 1 post | Observer callbacks coalesce and unchanged heights stay local. |
| Unchanged attachment selection intersection | 1 observation callback | 0 callbacks | The no-op collection write no longer invalidates observers. |
| Construct 1,000 message-list items | 0.266 ms | 0.301 ms | Lazy metadata avoids the eager version's 104.8 ms construction cost. |
| First metadata read of 30 items | 2.599 ms | 0.715 ms | Repeated aggregate reads within each row reuse one derivation. |
| Ten warm metadata passes over 1,000 items | 2,891.466 ms | 168.941 ms | Repeated reads avoid rebuilding aggregates. |
| Ten cached 160-pixel photo preparations | 16.09–20.41 ms on caller | Same work moved off main | Measures the original conversion cost; no total CPU reduction claimed. |
| 1,000 system file-icon lookups | 2.715 ms first pass; 0.911–1.026 ms warm | Unchanged | The warm API cost did not justify adding an app icon cache. |
| UI CPU, dropped frames, peak memory | Not captured | Not captured | No runtime improvement can be inferred from the operation counts alone. |

The JavaScript workload runs against frozen before/after scripts in Node, with equivalent fixed-script regression assertions in JavaScriptCore. It measures calls, not browser layout duration. Icon and Observation probes use optimized Swift. Local benchmark sources and results are under `/tmp/tern-performance-audit-20261102/`; the reader workload can be replayed with `node /tmp/tern-performance-audit-20261102/reader/benchmark.js < /tmp/tern-performance-audit-20261102/reader/scripts.json`.

The list probe compiles the actual before/after item source with `-O`, linked to Debug Core dependencies. Its stress fixture has 1,000 conversations, 12 messages per conversation and four attachments per message. The table reports medians of seven trials after warmup; checksums match. This is a metadata workload, not a full Release app benchmark. Concurrent builds caused timing outliers, so these timings indicate where work changed, not expected user latency. The photo probe uses the actual thumbnail function with synthetic PNGs. Larger valid inputs were also tested, but normal saved thumbnails are bounded to 160 pixels; the fix retains validation for all cached input sizes.

Verification passed: the final Debug build and 44 hosted tests across MessageListTests, MessagePrefetchTests, MessageWebViewTests, AttachmentLibraryModelTests, ReadingPolicyTests, InFlightTasksTests, ContactPhotoImagesTests and AddressAvatarModelTests. This includes native WebKit growth/shrinkage, deferred image loading, image privacy, light/dark colors, cached-photo cancellation and contact-access behavior. All ten changed source/test files match the tested snapshot by SHA-256. Independent source review, report-link checks and scoped `git diff --check` passed. Logs and the result bundle are `/tmp/tern-swiftui-audit-20261102/final-tests.log` and `final-tests.xcresult`.

An earlier run sampled the dark-to-light transition before theme restoration and failed two color assertions. The test helper now waits for the root's applied theme to match the media query; every color and contrast assertion is unchanged. The original reader suite separately passed seven tests, and the final eight-suite run passed with the readiness guard. A method-specific baseline filter initially selected zero tests and was discarded in favor of the whole reader suite.

Verification excludes concurrent unrelated working-tree changes. No Core source, project settings or dependencies were changed by this audit. The installed Release app was not replaced.

Existing safeguards verified by source review include stable account/message/attachment identities, native message and attachment lists, a lazy attachment grid with 100-item pages, cached message projections, unchanged database snapshot suppression, and asynchronous attachment queries/exports. Reader HTML sanitization already runs in a detached task. Collapsed messages do not create WebKit views, and scroll geometry is held outside observable view state.

The following remain hypotheses, rather than measured runtime problems:

- A long unread thread can mount many expanded WebKit views in an eager stack. Conversation Find depends on those views being registered, so changing it to a lazy stack requires coordinated search behavior and evidence that the retained views are a bottleneck.
- The reader maps, sorts and compares inline resource records on the main actor. Large MIME resource collections could be expensive; no representative trace attributes a delay to that work.
- Attachment context/accessibility actions call `savedFile(for:)`, which synchronously checks previously chosen paths. A slow external or network volume could delay these actions. No slow-volume case was observed.
- Sender parsing, system type lookup and broad preference/account reads may contribute to update cost. The audit found no basis for blanket `equatable()` wrappers, additional icon caches or a wider observation rewrite.

To measure the remaining risks, capture the same interactions before and after in a Release build on the same Mac and dataset, using SwiftUI Instruments with Time Profiler. Record mailbox size, thread/message counts, attachment count, image policy, OS and build revision. Use separate captures for scrolling/selecting messages, scrolling and resizing a long thread with Find, and paging/filtering the attachment list and grid. Keep cold and warm runs separate. Compare SwiftUI body evaluations, main-thread samples, hitches and peak allocations. Retain the trace and interaction notes so a later change can be tied to a measured bottleneck.
