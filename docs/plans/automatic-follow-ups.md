# Automatic follow-ups

On November 3, the owner extended F06: Settings controls the reminder delay, and unanswered sent conversations are tracked automatically. Conversation-aware automatic drafting is a separate opt-in. This complements the manual commitments and reminders in [F06](follow-ups.md) and the full [Today dashboard](today.md).

## Tracking and settings

Use a three-day default, configurable from 1 to 365 days. Automatic reminders are enabled; automatic drafts are off by default. Settings, Today, and Waiting for share the same preferences and commitment records.

Consider verified own-address SENT messages with an external recipient. Exclude drafts, trash, and spam, including pending local exclusions. Before deciding a conversation is unanswered, read its authoritative current thread membership and relevant replies. A cache union must not restore a message that the server deleted. A reply satisfies the no-reply condition without establishing that the commitment is complete.

Startup considers at most 100 cached sent conversations per account from the preceding 30 days. Process at most 20 queued conversations per pass, retry failed reads on later passes, and enqueue affected threads after live sync. Describe this coverage in the interface. This is not an exhaustive historical mailbox scan.

Persist one automatic provenance record per account/thread, linked to the canonical commitment. Track policy, latest outgoing baseline, eligibility, and manual takeover independently. A newer outgoing message can advance a managed open reminder. Manual edits, status changes, snooze, cancellation, or deferral preserve the user's decision and stop automatic rewrites. Closed commitments do not reopen automatically.

Already-overdue conversations are adopted quietly on first use and when an account becomes eligible again. Per-account adoption boundaries prevent old notifications and drafts from appearing in a burst. Existing records remain visible in Today. A title or deadline edit preserves quiet suppression; explicitly rescheduling a reminder can activate it.

Apply policy before reminder evaluation, serialize policy writes, and reject stale settings or account scope. Disable managed reminders when automatic reminders are turned off, retaining records and history. Manual reminders stay independent. Local execution limits remain the same as F06.

## Draft preparation

Prepare drafts only for eligible, due, unanswered managed conversations when the user enables automatic drafting. Respect the current account profile, assistant mail permissions, provider connection, runtime identity, and cancellation before and after asynchronous work.

Use the existing compose session and permitted thread context, then the existing draft queue with a reserved stable draft ID. Preserve verified aliases and external To/Cc recipients. Do not send, overwrite an existing draft, or recreate a user-deleted draft on repeated checks. Durable claims and terminal receipts prevent duplicate work across restart and uncertain outcomes.

Failures remain visible, with the manual Draft Follow-up action available for review. Test and audit hosts do not use live provider credentials or native notifications.

## Verification

Focused Core tests cover adoption, reactivation, policy changes, manual takeover, stale operations, draft receipts, and candidate exclusions. App tests cover failed-read retry, serialized settings, reply and alias behavior, account/runtime cancellation, permitted context, stable drafts, and provider changes. The integrated checks and native settings inspection are recorded with the Today implementation when completed.

November 3, 2026: the integrated Core and app checks passed as recorded in [Today verification](today.md#verification-november-3-2026). The native settings check changed the delay from three to five days, verified that the stepper followed the field, and confirmed that turning reminders off disabled the delay and automatic-draft controls. These settings stayed in memory in the synthetic audit host. The final Debug build passed. No live provider request, notification permission change, or email send was used.
