# F05: Today

Implementation is authorized after F06 Waiting for and follow-ups, and before F16 Meeting preparation. The lead must record F06 verification before starting F05 implementation. This plan covers the [roadmap](ai-and-features-roadmap.md) using the shared records introduced by [F06](follow-ups.md).

## Behavior

Today is a daily briefing of commitments the user tracks in Tern. Its scope description is "From follow-ups you track in Tern." It uses the active mail profile and shows work owed by the user, approaching deadlines, unanswered requests, and changes to tracked work since the previous visit. It does not claim to have inspected every email.

Use a native list with these sections. Each commitment appears once, in the first applicable section, and its row carries all relevant reasons.

| Section | Selection and explanation |
|---|---|
| Needs attention | Open commitments with an overdue or today's deadline, a due reminder, or direction I owe. Show the deadline, reminder condition, or person owed. |
| Coming up | Remaining open commitments due within the next seven calendar days. Show the date and person. |
| Waiting for | Remaining open commitments waiting on someone else. Distinguish an unanswered request from a reply received while the commitment remains open. |
| Since your last visit | Meaningful changed records not already above, including completed or dismissed work. Open rows above show their change reasons in place. |

Use the existing deadline conventions and the user's calendar and time zone. Within sections, sort overdue and due items first, then the nearest deadline or reminder, with a stable identity as the final tie-breaker. A minute clock refreshes time-based membership without changing stored records.

Each row includes the accepted description, account, person/direction, reason for appearing, relevant dates, and a source-email link. Examples of reasons are "You owe Anna a response or action," "Due tomorrow," "Reminder due," and "Reply received since your last visit." An I owe record can describe work beyond replying; do not label every such record an overdue email reply.

For unanswered requests, use F06's reply evidence and check state. A failed or unavailable read stays unknown. Receiving a reply does not complete the commitment. An empty briefing says there is no tracked work to show; it must not imply the mailbox has no outstanding obligations.

## Existing APIs and shared actions

- `CommitmentEntry` contains the canonical `CommitmentRecord` and its reminders. These remain the only editable commitment records.
- `AccountStore.commitmentEntries` and `observeCommitments` already supply durable data and updates. `FollowUpsModel.entries`, `hasLoadedEntries`, and `presentationRevision` expose it to the app.
- Select from `FollowUpsModel.entries` using `AccountPreferencesModel.visibleAccountIDs`. Do not use `FollowUpsModel.visibleEntries`, which also applies the Waiting for destination's search text. Today keeps any search query separate.
- Reuse `FollowUpsModel.setStatus`, `edit`, `openSource`, and `draftFollowUp`. Complete, dismiss, and edits must immediately agree across Today and Waiting for. Drafting opens an editable draft and leaves the commitment status unchanged.
- `AccountPreferencesModel.activeProfileID` supplies a stable visit scope: all accounts when nil, otherwise the specific profile. Capture the entry/account for an action so a later profile switch cannot retarget it.
- Reuse F06 reply reconciliation and notification lifecycle. Today adds no provider calls or mailbox scans. Opening a source or preparing a draft may use the existing mail-loading path.

## Snoozing attention

Add an optional `deferredUntil` date to `CommitmentRecord` through a new migration. Existing records default to nil. A shared account-scoped mutation sets or clears it using the existing expected-revision conflict checks. This is an extension of the F06 record, not a second task store.

Today offers Tomorrow morning, Friday morning, and Choose date, using the existing scheduling helpers. Snoozing works for any open commitment, including one without a reminder. It preserves the source, deadline, status, reminder condition, and reply baseline. The item leaves the normal briefing until the chosen time. A Snoozed filter shows deferred items and lets the user bring them back early; Waiting for retains the record and shows its deferral.

F06's current `snooze` method moves a reminder or opens its editor. Retain that reminder-specific behavior and give Today a shared defer action with the semantics above. Deferring attention must not re-arm a satisfied no-reply condition or pretend a new request was sent.

Reminder reconciliation continues while an item is deferred, so received replies can still satisfy no-reply conditions. Due-reminder queries, delivery revalidation, and delivery acknowledgement must all respect an active deferral. Cancel any submitted notification for the affected reminder when deferring. When deferral expires, the item becomes eligible again without requiring notification permission or an AI connection. Completing or dismissing a record cancels its reminders through the existing F06 action.

## Changes since the previous visit

Persist a small visit baseline in `config.sqlite`, scoped by profile identity and account. Keep it separate from read/unread mail labels and notification delivery state. An all-accounts visit and a named-profile visit have independent baselines. Accounts newly included in a profile get an initial baseline of their own.

Use two narrow tables: a visit record for each scope/account, and seen semantic snapshots for that visit's commitments. Account removal cascades through both; deleting a named profile removes its visit state. Commitment snapshots have a foreign key to the durable commitment, not to cached email. The tables are historical comparison data, never the source for editing a commitment.

The semantic snapshot contains title, owner, direction, status, deadline, deferral, and each reminder's kind, scheduled time, and received-reply evidence. Exclude record/reminder revisions, `updatedAt`, reminder `deliveredAt`, reply-check timestamps, and notification permission. In the current implementation, `markCommitmentReminderDelivered` increments both the record revision and `updatedAt`; neither can identify a meaningful change for Today.

Compare snapshots to explain changes such as newly tracked work, deadline changes, a received reply, completion, dismissal, or reopening. Routine notification delivery and repeated refreshes produce no change item. A change to the description or owner can use "Follow-up details changed" with the current source link. Preserve F06's explicit completion semantics.

At the start of a Today visit, capture its scope and load the previous baseline. Keep that baseline fixed in memory for the current visit, so the briefing does not erase its own change explanations as it is viewed. On the first successful visit for an account/scope, seed its existing records without claiming they all changed recently.

This first-visit initialization is the only exception to presented-only acknowledgement: seed all existing records for that account/scope, including pre-existing snoozed items. Later visits acknowledge only presented snapshots, so unseen changes stay available.

After a briefing has been presented, save the semantic snapshots represented in it. As visible briefing data changes, persist the newly presented snapshots while retaining the visit's original comparison baseline in memory. Defer acknowledgements until F06 entries and the visit baseline have loaded. Capture each acknowledgement's immutable scope and presented data before writing; cancelled or stale loads must not acknowledge unseen records. Older acknowledgements must not overwrite a newer seen snapshot. Hidden accounts and snoozed changes that were not presented remain unacknowledged.

If visit history cannot be loaded or saved, keep current work usable and report that recent-change tracking is unavailable. Do not replace a failed baseline read with an empty successful visit.

## Implementation sequence and ownership

1. Confirm the F06 verification gate and agree on the shared defer and visit-store API contracts.
2. The storage worker owns the Core migration, `deferredUntil` field/mutation, visit snapshots/store, and focused persistence tests. Extend existing migrations with a new version; do not rewrite the F06 migration.
3. The app-model worker owns the Today projection and visit lifecycle, shared defer action, reminder-delivery deferral guards, and focused model tests. Coordinate the Core API contract before these edits.
4. The view worker owns new Today views and rows, reasons/source links, snooze controls, and loading/error/empty states. Reuse native controls, semantic colors, and `Tokens` values.
5. The lead owns workspace navigation, `AppModel` lifecycle, project regeneration, integration review, and any shared-file changes outside those assignments. Run focused checks and a native workflow check before recording F05 verification and starting F16.

Workers must retain others' changes and keep ownership disjoint. Use the existing test fixtures and dependency injection; no new test framework, background service, or general-purpose event log is required.

## Acceptance checks

- A record with several reasons appears once. Overdue, today, and seven-day deadline boundaries use the supplied calendar, including a time-zone or daylight-saving boundary.
- Existing F06 corrections, status, and account scope appear consistently in both destinations. A Waiting for search query cannot filter Today.
- Notification delivery, reply checks, and reloads do not appear as changes. Changed deadlines, actual reply evidence, completion, dismissal, and reopening do.
- First visit and subsequent visits behave consistently after relaunch. Profile switches, newly included accounts, cancelled loads, and failed baseline reads cannot consume another scope's unseen changes.
- Snooze works without a reminder, preserves deadlines and reply baselines, suppresses delivery during deferral, expires correctly, and can be cleared early.
- A reply arriving during deferral satisfies only the no-reply condition. The commitment remains open and does not receive a redundant no-reply alert after deferral expires.
- Complete, dismiss, source opening, and draft preparation act on the same F06 record and original account. Draft preparation never sends mail or completes work.
- Account/profile removal cleans up visit state; cache reset preserves commitments and seen baselines.
- A synthetic native check covers each section, a row with multiple reasons, snooze/restore, complete/dismiss, source and draft actions, narrow-window layout, and unavailable visit history.

Core and app-model tests should target these state and lifecycle failures. Native checks should verify the user workflow without repeating every storage case. No live mailbox scan or email send is needed for F05 acceptance.
