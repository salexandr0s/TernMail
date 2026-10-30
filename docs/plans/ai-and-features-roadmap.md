# Tern feature roadmap

Updated: 2026-10-30.

This document collects the features requested in the October 30 discussion and the additions the owner accepted. The first build priority is the shared AI integration. Later features should use that same integration for reading, reasoning, drafting, and taking actions.

The feature list and AI-first priority reflect the owner's request. The owner subsequently placed F15 Calendar immediately after the F00/F01 foundation. The remaining delivery stages, first-release boundaries, and engineering approach below are recommendations. The first implementation now uses Sign in with ChatGPT and the connected account's model catalogue. See the [implementation plan](chatgpt-integration.md) and [assistant setup guide](../chatgpt-assistant.md) for current behavior and limits.

## Feature inventory

| ID | Feature | Intended result |
|---|---|---|
| F00 | Shared AI integration | One service that every AI feature can call, with mail access, attachment reading, source links, and controlled actions. Build first. |
| F01 | Personal assistant | A floating chatbot that can answer questions and prepare work across the mailbox. |
| F15 | Calendar | Apple Calendar-style views and interactions backed by Google Calendar, events detected in email, and calendar-aware assistant proposals. Build immediately after F00/F01. |
| F02 | Attachment library | All received attachments in list and card views, with search and filters. |
| F03 | Thread summaries and open tasks | An assistant summary bubble above the conversation, including decisions and unfinished work. |
| F04 | Bulk unsubscribe | Review subscriptions and unsubscribe from several at once, with an outcome for each. |
| F05 | Today | A briefing of replies owed, deadlines, outstanding requests, and recent changes. |
| F06 | Waiting for and follow-ups | Track commitments in both directions and remind the user when a response is overdue. |
| F07 | Natural-language search | Find messages and passages inside attachments using ordinary descriptions. |
| F08 | Project spaces | Collect related threads, files, decisions, and tasks across a project. |
| F09 | What changed? | Catch up on developments since the user last read a conversation. |
| F10 | Contact context | See a person's conversation history, files, commitments, and private notes. |
| F11 | Reply completeness check | Notice unanswered questions and missing information before sending. |
| F12 | Attachment versions and comparisons | Group duplicate files and compare revisions while keeping their source emails. |
| F13 | Plain-language automations | Describe a rule, inspect its proposed behavior, and track what it does. |
| F14 | Newsletter digests and preferences | Keep, mute, unsubscribe, or collect newsletters into a digest. |

F01 through F04 are the owner's original feature requests. F05 through F14 are the accepted additions. F15 is the subsequently approved calendar integration; its placement does not renumber existing features. Existing mail-client work remains covered by the milestone plans linked at the end.

## First build: shared AI integration

The first milestone should provide a working connection to an AI provider and a small assistant interface that proves it can use Tern's data. Summaries, search, task views, and automations will call the same services later.

### Provider connection and settings

- Support one selected provider initially, behind an interface that permits another provider later without rewriting each feature.
- Provide connection setup, model selection, a connection test, and a clear disconnected state. Store credentials in macOS Keychain and keep them out of logs and committed configuration.
- Describe which data the selected provider receives. Let the user enable AI per account and disable it without losing ordinary mail functionality.
- Support streaming responses, cancellation, timeouts, and useful errors for authentication failures, rate limits, and unavailable models.
- Track request usage where the provider reports it. Put bounds on tool calls and long scans, and expose progress and cancellation for lengthy work. Do not invent a monetary estimate when pricing is unavailable.

### Mail and attachment access

- Support the current thread, selected messages, one account, or all enabled accounts as context. Project scope can join this interface when project spaces exist.
- Search mail, fetch complete messages and threads, list attachments, and read supported attachment contents through Tern's existing data services.
- Fetch mail beyond the local cache when needed. Mailbox access must include archived and older messages, with the requested scope controlling whether Spam and Trash are included.
- Distinguish finding relevant messages from examining every message. An explicit request to read all mail should run as a bounded, resumable scan with coverage counts, progress, and a way to stop it. This larger scanning workflow can follow the initial integration.
- Return source references with retrieved content: account, thread, message, and attachment identity, plus a page or text location where available.
- Show which messages or files could not be fetched or read. A partial result must not claim complete mailbox coverage.
- Recommended first attachment readers: plain text and PDFs with extractable text. Scanned documents, images, and office files follow through the same extraction interface; the full supported-format list remains to be decided.

### Shared operations and data

Keep provider code and AI orchestration outside individual SwiftUI views. Views request operations such as answering a question, summarizing a thread, extracting open tasks, or preparing a reply.

Use shared structures for source references, summaries, decisions, commitments, and action results. A commitment needs an owner, description, optional due date, status, and supporting messages. Keep explicit statements separate from inferred dates or completion. Preserve user corrections when the assistant processes new mail.

Store durable user choices, accepted tasks, notes, and automation rules separately from disposable generated summaries and extracted text. Tie derived results to their source revisions so new messages can make a summary stale. Account removal and disabled access must stop background work and prevent reuse of excluded account data.

### Actions

- The initial useful action is creating an editable draft in Tern's existing composer, including replies to a selected message or thread.
- An explicit request to draft a reply authorizes preparing that draft. Sending remains a separate user action in the first release.
- Use typed, validated tools with explicit account and target IDs. Reuse the existing draft and action queues for Gmail changes, as required by the project conventions.
- Report actual outcomes: proposed, draft created, queued, completed, or failed. A queued operation must not be described as completed, and a retry must not create duplicate drafts or actions.
- Treat email bodies, quoted text, and attachments as source material. Instructions contained in them do not grant permission to send mail, change accounts, or perform other actions.
- Add mailbox organization, unsubscribe operations, and background rules to this action interface as their features ship.

### First release acceptance

The integration is ready for the next features when these workflows work end to end:

1. Connect the selected provider and receive a streamed answer; disconnecting or cancelling leaves Tern usable.
2. Ask about the open conversation and get an answer with links to supporting messages.
3. Ask a question requiring an older message outside the local cache and retrieve it within the selected account scope.
4. Ask about a supported attachment and see its source; an unreadable attachment produces a specific limitation.
5. Ask for a reply draft, open the editable draft in the existing composer, and verify that nothing was sent.
6. Request the same structured thread summary through an internal operation and through chat without duplicating provider or retrieval code.
7. Handle partial retrieval, provider failure, cancellation, and account removal without leaking data between accounts or reporting unfinished work as complete.

Use synthetic mail for repeatable checks and an explicitly enabled account for live provider verification. Prioritize tests for account boundaries, source references, action retries, and failed or cancelled requests. The full feature catalogue is not a prerequisite for this first release.

## Feature requirements

### F01. Personal assistant

- A floating entry point at the bottom right opens the chatbot.
- The conversation can expand to fullscreen or detach into a separate window, similar to a compose window. Preserve the same conversation when changing presentation.
- Answer questions such as "What are my priorities?", "What did we agree with Anna?", and "Which emails still need a reply?"
- Read entire threads, inspect attachments, and work across the selected mailbox scope. Support explicit full-mailbox analysis through the scanning workflow described in F00.
- Prepare new messages and replies on request, and use additional registered actions as they become available.
- Show the context in use, clickable sources, progress, and any gaps in what was read. Let the user start a new conversation or clear saved assistant history.

The initial integration includes compact chat, fullscreen, and a detached window. Broader mailbox analysis can follow through the same service layer.

### F15. Calendar

- Add a Calendar destination alongside Mail, retaining destination state and the same assistant. Match Apple Calendar's native Day, Week, Month and Year layout and interactions, including keyboard controls, drag/move/resize, a sidebar, mini-calendar, search and a shared event editor.
- Connect directly to Google Calendar through Tern's existing Google accounts. Support events, recurrence and exceptions, invitations, Google Meet links where supported, linked files, calendar management and sharing, reviewed `.ics` import/export, printing and local alerts.
- Keep the Google mirror separate from durable proposals, queued operations, corrections and email links. Support offline work, incremental sync, version conflicts, resumable series splits and explicit stale/incomplete states.
- Recognize structured invitations and ordinary dates locally without AI. Offer reviewed Add event and View event actions, reconcile updates and cancellations, and prevent duplicate events or RSVPs. Optional AI interpretation runs when an opted-in conversation opens.
- Give the assistant independent per-calendar Off, Availability only and Event details access, starting Off. The assistant can read allowed calendars and prepare editable proposals; the user saves calendar changes and sends email replies.
- For scheduling, calculate options from fresh availability across selected calendars, ask which times to suggest, recheck the choices and prepare an editable reply. Failed calendar reads remain unknown; selecting times neither reserves an event nor sends a reply.
- Exclude Apple Reminders, travel time and independent feed subscriptions. Existing Google subscriptions remain visible. Calendar-only accounts and hosted synchronization are later additions.

The approved scope, implementation contracts, Google setup and verification gates are in [Calendar integration](calendar-integration.md). Source implementation and automated tests are complete; live Google verification and the remaining Apple Calendar interaction comparison are explicit release gates.

### F02. Attachment library

- Add an Attachments destination showing all attachments ever received across enabled accounts, including archived and old mail.
- Offer list and card views, previews, opening, saving, and a link to each source message.
- Filter by sender, account, date, filename, size, project, and file format such as PDF, image, or spreadsheet.
- Separately filter by document category such as invoice, receipt, contract, proposal, or booking. Let the user correct inferred categories.
- Show extracted fields where relevant, including invoice amount, currency, and due date, with links to the supporting document. Payment status must remain unknown unless there is evidence or a user correction.
- Search filenames and supported file contents. Add OCR for scanned documents and images through F07.
- Show indexing coverage and progress while older attachments are discovered. Metadata discovery and content downloads can progress separately; a partial index must not look like the complete history.

Attachment versions and duplicate grouping are defined in F12.

### F03. Thread summaries and open tasks

- Add a bubble above the entire conversation, using the existing message-card layout from the owner's screenshot, with "Assistant summary" as its sender label.
- Include a concise account of the thread, decisions made, and remaining tasks. Support a single email as well as a conversation with many messages.
- Show a task's owner, due date when known, and the message supporting it.
- Reconcile later replies with earlier requests. Work already completed should leave the open-task list; a reply alone does not establish completion.
- Let the user correct a summary, dismiss or complete a task, and reopen a task that was marked complete incorrectly. Preserve these corrections during refreshes.
- Update after new messages and indicate stale or incomplete results. Keep the bubble collapsible and avoid implying that AI output is an email somebody sent.

### F04. Bulk unsubscribe

- List detected mailing lists with sender, subscription identity where available, recent volume, and last received date.
- Let the user select several subscriptions and inspect the intended changes together.
- Execute supported unsubscribe methods and report a separate outcome for each: request submitted, awaiting confirmation, completed when confirmed, failed, or website visit required.
- Track requests so retries do not submit the same request unnecessarily. Stop or cancel work that has not yet been submitted.
- Keep unsubscribing separate from blocking a sender, deleting old messages, and marking spam. Offer those as explicit choices where useful.

Newsletter delivery preferences and digests are in F14. A successful request submission is not proof that a sender has stopped delivery.

### F05. Today

- Show replies owed, approaching deadlines, unanswered requests, and important changes since the user's previous visit.
- Explain why an item appears and link to the relevant message or task.
- Let the user draft a reply, snooze, dismiss, or mark an item complete from the briefing.
- Use the same commitment records and corrections as thread summaries and Waiting for, so the views agree.

### F06. Waiting for and follow-ups

- Track both "I owe Anna a proposal" and "Anna owes me approval."
- Support "Remind me Friday if nobody replies" and reminders tied to unresolved commitments.
- Distinguish receiving a reply from resolving the request. Clear a no-reply reminder when a reply arrives; clear a commitment reminder when the commitment is resolved.
- Allow manual deadlines and status corrections. Offer a follow-up draft when a reminder becomes due.
- State the execution limits: reminders that require Tern to be running cannot promise delivery while the app or Mac is off. Hosted background execution remains a separate decision.

### F07. Natural-language search

- Accept requests such as "Find the quote for the kitchen renovation" directly in search and in the assistant.
- Search message contents and supported attachments, including OCR text from scanned PDFs and images as format support expands.
- Highlight matching passages and open the original message or document at the relevant location where possible.
- Combine ordinary descriptions with sender, date, account, attachment, and project filters.
- Make retrieval coverage visible and preserve regular mail search when the AI provider is unavailable.

### F08. Project spaces

- Create a space such as "Apartment purchase" or "Website launch" containing related conversations, files, decisions, deadlines, and tasks.
- Associate threads with different subjects and senders when they concern the same project.
- Let users add and remove items, correct suggested grouping, and ask the assistant questions within the project.
- Keep links to the underlying emails and reuse the shared task records. Moving an item between projects must not duplicate its commitments.

### F09. What changed?

- Summarize developments since the user last read a thread: changed dates, new decisions, revised documents, and newly outstanding requests.
- Keep this distinct from the full thread summary.
- Track a reading position separately from read/unread labels so marking a message unread does not erase the catch-up baseline.
- Offer the full conversation and supporting messages from each update.

### F10. Contact context

- Open a person's context from their sender or recipient identity.
- Show previous conversations, shared attachments, outstanding commitments, and private notes.
- Surface relevant prior agreements when replying, with sources for amounts, dates, and other quoted facts.
- Keep notes private and identify the account context. Let the user correct identity grouping when two addresses are incorrectly treated as the same person.

### F11. Reply completeness check

- Detect questions or requests in the conversation that the current draft has not addressed.
- Notice a promised attachment that is missing and dates or facts that conflict with the thread.
- Show specific suggestions beside the draft, with the original request linked.
- Let the user accept, dismiss, or edit suggestions. Preserve the user's wording unless an edit is requested.

### F12. Attachment versions and comparisons

- Group exact duplicates while retaining links to every source email.
- Suggest related revisions of a document and allow users to correct the grouping.
- Compare supported document versions and explain changes with references to each version's relevant passages.
- Preserve original files and expose which version was sent when and by whom.
- Mark incomplete comparisons, including unsupported formats or unreadable pages.

### F13. Plain-language automations

- Accept rules such as "When an invoice arrives from this supplier, label it Accounting and add it to my invoice collection."
- Translate the request into inspectable conditions and actions. Show matching examples and a preview before enabling a rule.
- Record what each run did and why, including failures and partial completion. Support pause, edit, and deletion.
- Use the shared action layer and prevent duplicate execution when mail is synced again or a job retries.
- Distinguish Gmail-hosted filters from rules that need Tern running. Always-on execution requires a separate hosting decision.

### F14. Newsletter digests and preferences

- Offer normal delivery, mute, unsubscribe, or inclusion in a periodic digest for each subscription.
- Let users set digest frequency, inspect the original messages, and change their preferences later.
- Summarize selected newsletters with links to the original emails and distinguish unread originals from digest reading state.
- Coordinate with F04 so subscription identity and unsubscribe outcomes are consistent.

## Recommended delivery order

The owner fixed the F00/F01 foundation first and F15 immediately after it. The rest is a proposed order based on shared dependencies, with no delivery dates assigned.

| Stage | Scope | Why this order |
|---|---|---|
| 1 | F00 and the F01 assistant | Establish provider access, retrieval, source links, structured output, draft creation, and shared chat presentations. |
| 2 | F15 | Deliver calendar connection/data, interaction, email recognition, assistant scheduling, then completion and parity verification. |
| 3 | F03 | Reuse the integration in the reader and establish shared commitments with user corrections. |
| 4 | F02 and F07, with broader attachment extraction and resumable indexing | Make historical files discoverable and searchable; extend mailbox analysis coverage. |
| 5 | F05, F06, and F09 | Use reliable commitments and reading history for daily priorities and follow-ups. |
| 6 | F04 and F14 | Add subscription management and newsletter delivery preferences. |
| 7 | F08, F10, F11, and F12 | Add project and contact context, reply checks, and document comparisons. |
| 8 | F13 | Build repeatable background rules on the established retrieval and action services. |

Features within later stages can move earlier once their dependencies are ready. The attachment library's metadata browser and subscription detection can be developed independently of AI reasoning.

## Existing plans and integration points

Tern is a native SwiftUI macOS Gmail client. Core logic lives in `Packages/Core`; app views and credential handling live in `App`. The AI integration should follow those boundaries and reuse existing mail, search, attachment, compose, and queue services.

- [Milestone 1](milestone-1.md): mail storage, sync, reading, and queued actions.
- [Milestone 2](milestone-2.md): compose, drafts, sending, and received attachments.
- [Milestone 3](milestone-3.md): search, labels, snooze, and multiple accounts.
- [Calendar integration](calendar-integration.md): approved F15 scope and implementation; Google Calendar replaces the older invitation-only API alternative and EventKit agenda proposal.
- [Milestone 4](milestone-4.md): Google service authorization, contacts, identities, filters, and existing invitation ingestion/iTIP delivery. F15 extends that foundation and uses Calendar RSVP for matched invitations.
- [Milestone 5](milestone-5.md): remaining reading and triage controls, attachment menus, templates, saved searches, profiles, notifications, window behavior, and maintenance. Its former EventKit invitation agenda is superseded by F15.

AI integration is the first feature priority in this roadmap, followed immediately by F15. Milestone 4's existing invitation ingestion and iTIP reply queue remain the reusable foundation for F15's email integration.

## First implementation decisions

- Use the official Sign in with ChatGPT flow, Tern's own registration and Keychain credentials, and the public Responses API. Discover models from the connected account. Other providers remain possible extensions.
- Read text-based files and PDFs with selectable text, with explicit size and extraction limits. OCR and office-file readers remain later work.
- Keep assistant history in memory. Scope and access changes clear retained conversation data; credentials and account opt-ins persist separately.
- Bound each foreground request by context size, tool calls, and rounds. Resumable full-mailbox scans and background indexing remain later work.
- Share provider, retrieval, source, structured-summary, and draft interfaces across features. The initial integration does not need a new database schema.
