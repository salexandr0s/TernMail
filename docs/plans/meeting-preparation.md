# F16: Meeting preparation

Implementation is authorized after F06 and F05. Start coding only after the lead records F05 verification. This plan implements the [roadmap](ai-and-features-roadmap.md) with existing calendar events, permitted mail retrieval, thread summaries, and accepted follow-ups.

## User workflow

Add Prepare for Meeting to an existing event's shared `CalendarEventEditor` and `CalendarEventMenuItems`. Prepare the selected occurrence; do not save unsaved event edits, change an invitation, or send mail. New unsaved events must be saved before preparation.

The preparation view shows the event and occurrence date, included conversations, each conversation's concise summary and decisions, unresolved work, and recent attachments. Every generated point opens its validated source. Show accepted F06 commitments with the user's corrected description, owner, deadline, and status. Completed or dismissed accepted work must not return as an open suggestion.

Users can include a conversation, exclude one, restore an exclusion, and refresh the preparation. Explain why a suggested conversation appears. Provide loading, cancellation, empty, partial, unavailable-source, provider-unavailable, and permission-disabled states. Source management and opening original mail use normal app permissions; AI analysis requires the additional access checks below.

## Source selection and durable corrections

Seed exact links from `CalendarStore.sourceLinks(accountID:calendarID:eventID:)`. `CalendarSourceLink` currently has one account ID; treat its mail source as belonging to that same account. Keep these existing provenance records unchanged.

Add a small durable preparation-preference table in `config.sqlite`. Each preference records the event account, calendar, occurrence identity, mail account, thread, include/exclude choice, and update date. The event and mail account IDs are distinct fields with account-removal cleanup for either side. References to events and mail are identifiers, not foreign keys into disposable mirror/cache tables. Exclusions take precedence over discovered or provenance-linked candidates until the user restores them.

Use event account and calendar plus the provider occurrence identity. For recurring instances, retain the series ID and `originalStartTime`, preserving the difference between all-day dates and timed starts. A moved occurrence keeps its original occurrence identity. Never use the event's current displayed start alone or share preferences across the whole series. A series master without a selected occurrence must ask the user to choose an occurrence.

The first implementation stores only source preferences durably. Generated preparation stays in memory and can be rebuilt; do not add a persistent AI report store or a generic relationship graph.

## Bounded discovery and reading

Use a dedicated `MailAssistantTools` session for `search_mail` and `read_thread`, restricted to the captured, eligible, AI-enabled mail accounts. Exact links and explicitly included conversations take priority. Search using distinctive event-title terms and relevant event context; require matching subject/content evidence for suggested relationships. A shared attendee alone is insufficient. Generic titles such as Meeting or Catch-up should offer manual source selection instead of broad person-based guesses.

Use explicit per-preparation limits: at most 20 distinct candidates and five full thread summaries, with a small fixed search-call budget. Deduplicate by mail account and thread ID. If the limit excludes linked or selected conversations, show how many were omitted and let the user narrow the selection; never present the result as complete. Cancellation stops further reads and provider calls.

Reuse `AssistantSummaryService.report(thread:)` for each included thread. Validate its account/thread ownership and every cited source ID before presenting a summary, decision, or task. Keep the reports per thread in the first version; no additional cross-thread synthesis call is required.

Show the newest attachment instances from the included conversations, ordered by source-message date, with filename, sender/date, and original message links. Use existing preview/open behavior on request. Describe them as recent files in the included conversations; do not infer document-version relationships, download every attachment, or introduce F12 comparisons.

Match generated task suggestions to accepted commitments using the existing acceptance identity from `FollowUpSuggestionRequest`, sharing that helper rather than duplicating its hashing rules. Accepted corrections and completed/dismissed status take precedence. Show other manual commitments from included threads as tracked work. Unaccepted AI tasks remain suggestions and require the existing review flow to become commitments.

## Independent scope and invalidation

`CalendarModel.readEvent` refreshes the event but does not enforce AI consent. Before provider use, require `calendar.assistantScope.allows(CalendarKey, details: true)` for this event's calendar. Availability-only access does not permit event titles, descriptions, attendees, or preparation prompts to reach the provider.

Add a dedicated meeting-summary/session factory. Do not call `AssistantModel.readerSummary` directly: it inherits chat's selected scope. Capture the event/occurrence, permitted mail-account IDs, selected model and provider connection revision, calendar access revision, mailbox runtime instance identities, and preparation generation. Do not change chat selection, conversation history, source registry, or draft state.

Check that captured scope before and after each asynchronous read and provider result, and while streaming. Disconnect, access revocation, account removal/replacement, cache reset, occurrence change, or a newer preparation cancels the old request. Drop retained generated content immediately when its access becomes invalid; a delayed response must not restore it. Chat-only selection changes should not retarget or cancel an otherwise valid meeting session.

Track the refreshed event version and included thread/message revisions. An event or supporting-mail change marks the displayed preparation stale and offers Refresh. Permission changes clear restricted content rather than leaving it under a stale label. Failed reads remain visible as gaps; retain usable permitted sections only when their scope remains valid.

## Ownership and integration

| Owner | Scope |
|---|---|
| Store worker | Occurrence/source preference models, migration, include/exclude queries and mutations, cleanup for both account IDs, and focused store tests. |
| Service worker | Captured meeting-session factory, bounded discovery/reading, validated per-thread reports, attachment metadata, and provider/tool boundary tests. |
| Model worker | Preparation lifecycle and cancellation, stale state, source selection, accepted-commitment overlay, and focused model tests. |
| UI worker | New preparation view and source picker, explanations/citations, source and file actions, and partial/unavailable states using native controls and `Tokens`. |
| Lead | Shared calendar entry points, root/lifecycle wiring, account cleanup integration, project regeneration, review, and native verification. |

Agree on occurrence identity and captured-scope types first. Keep worker file ownership disjoint; the lead coordinates shared `AssistantModel`, calendar, and root files. Reuse existing fixtures and injection seams. No meeting recording, hosted background work, automatic calendar edits, or automatic email sending is included.

## Acceptance checks

- Exact calendar source links seed the correct conversation; cross-account inclusion retains separate identities. Exclude/restore persists without modifying original provenance.
- Two occurrences in one series keep independent preferences; moving an occurrence retains its choices. Mirror/cache resets preserve choices, and removing either referenced account removes them.
- Off and Availability Only calendar access cause no provider request with event details. Revoked mail access, account replacement, cancellation, and delayed results cannot expose excluded content.
- Meeting preparation works with a chat scope narrowed to another thread and leaves chat state unchanged. A chat-only selection change does not retarget its captured session.
- Generic titles and attendee-only overlap do not produce guessed relationships. Candidate/read limits are enforced and omitted or failed sources produce explicit partial coverage.
- Invalid or cross-thread citations are rejected. Attachment links resolve to the original included message and do not claim a globally latest document version.
- Accepted task corrections survive refreshed summaries; completed/dismissed commitments are not shown as open. Tracking a new suggestion uses the existing F06 review action.
- Event and mail changes mark results stale; refresh replaces them. Permission revocation clears them immediately. Provider failure leaves source controls and permitted original-message access usable.
- A synthetic native check opens preparation from event details and a calendar context menu, includes/excludes/restores a conversation, opens a citation/file, and exercises narrow-window and partial/error states without changing a live calendar or sending mail.

Run focused store and service/model tests, an app build, and the native workflow check. Record actual F16 verification and any provider-dependent gaps before completing the three-feature goal.
