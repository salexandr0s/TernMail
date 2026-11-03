# Sender details and mail analytics

## Scope

Open sender details from the message avatar. Show links found in that sender's unquoted signature, the source of those links, and a summary of correspondence. A separate Analytics window provides account and sender scopes, date ranges, sent and received counts, first and latest contact dates, an activity chart, frequent contacts, and recent messages.

Keep a durable metadata index independent of the message body cache. Seed it from cached mail and offer a cancellable Gmail history import. State when history is partial or when a completed scan was taken. Exclude drafts, provisional sends, spam and trash. Match exact parsed addresses and keep all records account scoped.

The user chose standard read receipts. Requests are optional and off by default. Persist the request after a successful send, parse incoming disposition notifications, and report a read receipt only for a matching requested recipient and message. Absence of a receipt never means unread. Tern does not send receipts automatically.

## Implementation

1. Add bounded signature extraction and focused parsing regressions.
2. Add analytics storage, history import, observations, and ingestion/deletion hooks. Cache eviction must not delete analytics history.
3. Add receipt draft state, MIME header, durable request/event storage, and sync ingestion.
4. Build sender and analytics views with native SwiftUI controls and Charts. Add the avatar entry point, Go menu entry, analytics scene, and compose receipt option.
5. Verify core behavior and the app build. Review account isolation, cancellation, repeated imports, receipt matching, and metadata retention.

## Design passes

Both passes followed the functional build and used native renders of the shipped views:

1. Constrained the filter bar to its compact height, gave the three count cards equal widths, moved history coverage beside the totals, removed repeated website domains, and kept the sender card's Analytics button visible while scrolling. The corrected pass produced 10 native captures in `build/Verification/analytics/design-pass1-final/`.
2. Added an explanation and Settings shortcut when history loading is unavailable because sync is paused, formatted chart values by day/month/year, distinguished personal and company profile paths, qualified empty milestones, and bounded receipt details with scrolling and recipient counts. Receipt timestamps use semantic text color with a separate status icon. An empty chart no longer offers an inactive values toggle. The final pass produced 16 native captures in `build/Verification/analytics/design-pass2-verified/`.

Light/dark appearance, narrow windows, long names, distinct links on one platform, empty analytics and 18-recipient receipt lists were rendered. Source review covered loading/error states and accessibility labels. A native interaction test presses the sender avatar, checks the popover appears, and verifies that message expansion remains unchanged. Review also caught and removed a Settings destination write that could bypass unsaved-edit protection.

## Constraints

Signature links are extracted locally; they are not verified identities and no social accounts are scraped. Existing Google Contacts provide names and photos. Read receipts depend on recipient support and cannot recover past opens. Counts describe indexed messages, including separate copies in separate accounts; recipient-level counts cannot be summed into a global sent count. Received dates come from mail metadata.

Other chats had active reader, assistant, sidebar and Tasks edits. Their work was preserved and shared-file changes stayed small. The workspace agent roles configured for another model were unavailable; the available collaboration agents performed those roles with disjoint file ownership.

## Initial feature verification

- Core implementation is committed in `67f5535`. The full core suite passed: 649 tests in 110 suites (`build/Verification/analytics/core-full-final.log`). The final run includes a deterministic cancellation test after replacing an unreliable polling handshake.
- Native build-for-testing passed after the final design changes (`design-pass2-contrast-build.log`).
- The final Debug app build also passed in the canonical main checkout after concurrent changes landed (`canonical-build.log`). The build product is `build/AnalyticsIntegration/Build/Products/Debug/Tern.app`; this task does not replace the installed app.
- 50 app tests passed across MailAnalyticsModelTests, MessageListTests, ComposeModelTests and ComposeFeatureModelTests (`AnalyticsBehavior.xcresult`). The native header interaction test passed both initially-expanded cases (`AnalyticsHeaderInteraction.xcresult`).
- The final visual audit passed with 16 attachments (`DesignPass2Verified.xcresult`). Images and logs live under `build/Verification/analytics/`.
- Tests used synthetic mail and a fixed source snapshot while other chats changed the shared checkout. The tested analytics source and integration files match the workspace. No live email was sent to test receipts.
- Final source review found no remaining blockers. Whitespace checks pass; the new production files contain no forced casts, forced tries, or TODO/FIXME markers.

## Additional visual pass — 2026-11-02

The user requested a further pass focused on appearance, with substantial improvements to every chart and the surrounding components. The activity chart now uses coordinated teal/indigo series, rounded grouped bars, a zero-based integer scale, quieter horizontal gridlines, inward-aligned endpoint dates, and a fixed-height selection summary. A custom legend combines direction symbols and totals. The values table has aligned columns, consistent row spacing and a fixed header. Received and Sent cards use real bucket sparklines on a shared scale; Conversations remains a distinct-thread count. Large totals stay on one line with their exact values available to accessibility and help.

The dashboard has a stronger heading, consistent panel edges, and a larger default window. At wide widths, contact/profile information and receipt summaries form one column beside recent emails; narrow windows stack the same content. History loading is a compact status/action row with expandable account details. Errors, progress, cancellation and paused-sync guidance remain visible. Sender cards use paired metric tiles, aligned dates, structured destination rows and the fixed Analytics action. Recent email rows use direction tiles; multi-recipient receipt groups use native disclosures. Small labels use semantic text colors, with series/status color confined to icons and chart marks.

Verification passed in the main checkout: Debug build-for-testing (`visual-refinement-reviewed-build.log`) and four native tests in three suites (`VisualRefinementFinal.xcresult`, `visual-refinement-final-tests.log`). These include both header expansion cases and the existing analytics observation regressions. The visual audit produced 24 captures in `build/Verification/analytics/visual-refinement-final-images/`, covering light/dark, narrow and 760-point layouts, long names, sparse and dense daily activity, selected month values, the table, million-scale counts, empty states and long recipient lists. Render review caught and corrected faint axes, clipped endpoint labels and excess empty column space. Source review and whitespace checks passed.

The backend is unchanged, so the core suite was not repeated. SwiftPM restored the package-only lockfile. This pass does not push or replace the installed app.

## Final design pass: 2026-11-02

The sender card now puts its counts and history coverage in one compact row, with first/last dates below the profile links. Native renders show three complete links immediately, even with a long display name. The Analytics action stays fixed while the remaining details scroll. Selected chart periods spell out received and sent counts; the summary retains its height and can place the date above the counts when space is limited. These changes are committed in `935d99f`.

Debug compilation and the four selected native tests passed, including both header expansion cases (`FinalPass.xcresult`, `final-pass-tests.log`). A corrected visual capture waits for the synthetic LinkedIn link to load before rendering the sender card. That audit passed with 25 captures, including a narrow chart with large counts (`FinalPassReady.xcresult`, `final-pass-ready-images/`). Source and image review found no remaining blockers. Evidence is under `build/Verification/analytics/`.
