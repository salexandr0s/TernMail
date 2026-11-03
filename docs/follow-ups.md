# Waiting for and follow-ups

Open **Settings → Follow-ups** to turn automatic reminders on or off and choose a delay from 1 to 365 days. The default is three days. Tern tracks sent conversations that are waiting for a reply and shows them in [Today](today.md).

Automatic tracking checks new sent mail and a bounded set of recent cached conversations. Existing overdue conversations are added quietly; they do not trigger a burst of old notifications or generated drafts. The settings describe the cache and history limits. A fresh message you send establishes a new waiting period while the follow-up remains automatically managed.

**Draft follow-ups automatically** is a separate opt-in, off by default. When an automatic reminder becomes due, Tern can use the permitted conversation context to prepare an editable draft. It requires a connected assistant and mail access. Drafts are never sent automatically, existing drafts are not overwritten, and deleting a generated draft does not cause it to be recreated on every check.

Editing, completing, dismissing, or rescheduling an automatically tracked commitment preserves your choice and stops automatic rewrites of that record. Turning automatic reminders off cancels their managed reminders while keeping the records and history. Manual reminders remain independent.

## Manual tracking

Choose **Track Follow-up…** from an email's actions menu or a conversation's context menu. You can also use the clock button beside an open task in an AI summary. Review the description, person, direction, deadline, and reminder before choosing **Track**.

Open **Waiting for** from the workspace section picker or the **Go** menu. **Waiting for** tracks someone else's commitment; **I owe** tracks yours. **All** shows both, and **History** contains completed or dismissed items. Search matches descriptions, people, and source subjects. The current account profile controls which records appear.

## Deadlines and reminders

A deadline is a calendar day and keeps its date across time zones. A reminder has an exact date and time. They can be changed independently.

- **If nobody replies** checks for a relevant incoming reply after the reminder's starting point. A reply stops that reminder, but leaves the commitment open.
- **While unresolved** reminds you until you complete or dismiss the commitment. Receiving a reply does not establish that the work is finished.

Use the editor to change either reminder rule or its schedule. Reopening a completed or dismissed commitment does not reactivate its old reminder; add a new reminder when needed. Editing a description or deadline preserves an already-recorded reply.

Tern checks reminders while running and when it resumes. It cannot promise alerts while the app or Mac is off. If mail cannot be checked, the follow-up stays visible with its reply-check status. **Allow Notifications** requests macOS permission; due work stays available when notifications are off.

## Working with a follow-up

Each item links to its original email. **Draft Follow-up** opens an editable reply using that account's sender identity and signature. Review and send it in the composer. Preparing a draft does not send mail or mark a commitment complete.

Complete a commitment when the work is finished, or dismiss it when you no longer want to track it. You can reopen either from History. Accepted descriptions, deadlines, and status are saved locally and survive summary refreshes and mail-cache cleanup. Removing an account also removes its follow-ups.

Manual tracking does not require ChatGPT or Google Tasks. AI summary tasks become tracked commitments only when you choose to track them.

[Today](today.md) uses these same commitments for a daily briefing. Snoozing attention in Today postpones its alerts without changing the deadline; Waiting for keeps the record visible and lets you restore it early.

See the [implementation plan](plans/follow-ups.md) for data boundaries and verification requirements.
