# F06: Waiting for and follow-ups

Implementation authorized on November 3, 2026, before F05 Today and F16 Meeting preparation. The accepted feature scope is in the [roadmap](ai-and-features-roadmap.md). Work uses the clean public repository's `codex/followups-today-meeting-prep` branch; private repository history and concurrent changes in other checkouts stay separate.

## Behavior

Track a conversation or accept an open task from its summary. Review the description, person, direction (I owe or Waiting for), optional deadline, and optional reminder before saving. Generated summaries remain suggestions; accepted commitments and user corrections persist separately.

A no-reply reminder stops when a subsequent relevant incoming reply is established. The commitment stays open. An unresolved-commitment reminder stops when the user completes or dismisses the commitment. Users can edit, reschedule, complete, dismiss, and reopen records. Reopening does not silently reactivate an old reminder.

The Waiting for destination shows both directions and closed history, with source links and editable follow-up drafts. Draft preparation uses the existing composer and account identities and never sends a message. Google Tasks and AI access are optional for manual tracking.

## Shared data and boundaries

- Store commitments and reminders in `config.sqlite`, with account deletion cascades and no foreign keys into disposable mail cache tables.
- Preserve source account, thread, message, date, and subject alongside accepted description, owner, deadline, direction, and status.
- Keep reminder kind, schedule, reply baseline/evidence, and delivery acknowledgement separate from commitment status. Use revisions for stale editor and notification protection.
- Deduplicate accepted summary suggestions without overwriting user corrections or reopening completed work.
- Filter presentation by the current account profile; hidden records remain saved. Reject writes for accounts pending removal and cancel their in-flight work.
- Reuse the same records and actions in F05 after F06 is verified.

## Reminders

Evaluate locally on startup, activation, wake, committed mail sync, and a bounded timer. Deliver immediate notifications only after checking the condition; conditional notifications are not scheduled to fire independently while Tern cannot check mail. Persist delivery acknowledgements to avoid repeats after relaunch.

No-reply checks must exclude the user's own verified addresses, drafts, unrelated threads, and messages preceding the reminder baseline. Reconcile the current thread to recover from missed sync events. A failed or incomplete read remains unknown and visible, rather than establishing that nobody replied. Due items remain available when notifications are denied.

Tern checks reminders while running and after it resumes. This feature does not promise alerts while the app or Mac is off.

## Implementation sequence

1. Add durable Core models, migrations, account-scoped queries/observation, atomic mutations, and regression tests.
2. Add the app model, conservative reply reconciliation, notification delivery, and lifecycle/account cleanup integration.
3. Add the editor and Waiting for destination, conversation/summary entry actions, source routing, and follow-up drafts.
4. Review integration and run focused Core and hosted app tests, an app build, and synthetic native workflow checks.
5. Record F06 verification before starting F05. Build Today from these records, then implement F16 using existing calendar and permitted mail retrieval.

Parallel work has separate ownership for Core storage, the app model, native follow-up views, and workspace navigation. The lead owns root lifecycle wiring, reader actions, integration, and project regeneration.

## Acceptance checks

- A reply satisfies a no-reply reminder without resolving its commitment or an unresolved reminder.
- Own sends, old mail, label changes, wrong accounts, and wrong threads do not satisfy a reminder.
- Re-arming establishes a new baseline; stale updates and acknowledgements cannot change a newer reminder.
- Corrections and closed status survive summary refresh, cache reset, and restart; repeated acceptance and sync delivery do not duplicate records or alerts.
- Account removal deletes its records and stops work; profile changes do not retarget an open editor.
- Denied notification permission and unavailable mail keep due work visible.
- Open email and Draft follow-up retain the original account/thread. Drafting does not send or change commitment status.
- The native interface supports tracking, editing either reminder mode, completing/reopening, source opening, and opening a draft, including a narrow window.

## Verification — November 3, 2026

F06 is implemented and verified. All 798 Core tests passed, including account cleanup, revision conflicts, reminder independence, participant corrections, and notification receipts. The 46 selected app tests passed across focused runs: follow-up model/source/date behavior, native editing and completion, workspace search, existing thread summaries, and mail notifications. The app compiled with Swift 6 concurrency checks.

The native workflow opened a captured record, changed its title, saved it without altering the source or reminder, and completed it. Light and dark list captures and the editor were inspected at a 720 × 480 window size. That check found and fixed a sheet accessibility grouping issue. No live mailbox access or email sending was used for verification.

F05 implementation may now begin using these records. Conditional alerts still require Tern to run or resume, as documented above.
