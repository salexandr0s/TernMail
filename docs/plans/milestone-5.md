# Milestone 5 plan: Mimestream parity

Status: scope approved 2026-10-29. File-level phases are written and reviewed after milestone 4 merges. Branch `feat/milestone-5`, cut from `feat/milestone-4` at `5d4d385`.

Inputs: the owner's screenshots of Mimestream 1.10.8 (Inbox, Sent, Spam and every Settings pane), `docs/research/mimestream-behavior.md`, the milestone 1 to 3 plans, and milestone 4's plan (approved 2026-10-29 at `621772c` and amended at `36c6455`, on `feat/milestone-4`). The screenshots are a feature checklist only. Layout, wording, icons and sounds stay Tern's own (project rule).

## How the list was built

Every feature visible in the screenshots or named in the research notes was checked against milestones 1 to 4. Covered features are left out, and partly covered ones list only the missing part. Workstream J holds features next to milestone 4's scope that its plan leaves out. "Check against milestone 4" lists what this milestone builds on there and what is still open.

## Scope, by workstream

### A. Reading

1. Remote content: a setting to block remote images (on by default, today's behavior), Load Images per message, and Always Load for a sender. Allowed messages get a per-message content rule list, and the CSP opens to `https:` images only for them.
2. Tracker blocking: with remote content allowed, known tracking hosts and 1×1 images stay blocked, and the message says how many were blocked. The host list is an openly licensed list (license checked before adoption) or our own.
3. Dark message backgrounds: a setting (on by default) that adapts HTML mail to dark mode by rewriting colors at sanitize time (lightness inverted, hue kept, images untouched). Mail with its own dark styles keeps them. Show with Light Background per message.
4. Inline `cid:` images (audit A24): MIME image parts cached as resources. The sanitizer rewrites `cid:` to a Tern scheme served by a `WKURLSchemeHandler`, limited to the same message.
5. Conversation order: oldest first (today) or newest first.
6. Mark as read: immediately (today), after a delay, or by hand only. The delayed form queues mark-read only if the conversation is still open when the delay ends.
7. Text size: one scale for list and message text.
8. Conversation header: label chips with a remove button, and per message a star, Reply and a menu (Reply All, Forward, Forward as Attachment, Show Original, Print, Copy Link).
9. Avatars: the contact photo when there is one (J1), else initials on a color derived from the address.
10. Address menu: Copy Address, New Message, Search Messages From and To, Create Filter (milestone 4 filters).
11. Link destinations: hovering a link shows its URL under the message.
12. Show Original: the raw message (`messages.get format=raw`) with Copy and Save as `.eml`.
13. Print and Export as PDF for a conversation, from a print page built from the sanitized bodies.
14. Message size, shown when the View option is on.

### B. Message list

1. Row content: user label chips in Gmail colors; system labels other than the open mailbox as outlined chips; attachment chips (type icon, name, "+N more"); message count; draft marker; "To:" recipients in Sent and Drafts; optional importance marker; optional account badge in the account's color; star button.
2. Attachment data for unopened mail: the metadata fetch adds `Content-Type`. Messages whose type is `multipart/mixed` or `multipart/related` get a batched `format=full` read with a `fields` mask that returns only the part tree, without headers or body data. This fills milestone 2's `attachment` rows and a `hasAttachments` flag, which also lets milestone 3's local search answer `has:attachment`. If the mask fails in live testing, chips show for opened mail only.
3. List density: Default and Compact.
4. Quick filters in the list header: Unread, Starred, Has Attachments, Important, Addressed to Me.
5. Next selection after archive or trash: the row below (today), the row above, or none.
6. Swipe actions: two per edge, each one of Archive, Trash, Read/Unread, Star, Snooze, Move, Label, Spam or None.
7. Message mode (conversations off): one row per message, and actions change only that message. The queue gains message-scoped targets for archive, label and read changes.
8. Spam and Trash list headers show the count and the empty button (D4).

### C. Sidebar and mailboxes

1. Editable Favorites: add, remove and reorder mailboxes, labels and saved searches. A favorite that spans accounts expands into one row per account. Reset Favorites. This builds on milestone 3's mailbox list (its phase 10d): each mailbox appears once, in Tern's order (Inbox, Starred, Snoozed, Sent, Drafts, All Mail, Spam, Trash), and expands to one row per account.
2. Badge options: total count for Starred and Drafts, unread count for Spam.
3. A collapsible More group per account for system labels the main list doesn't show (Important, Chats, inbox categories), with a setting to hide it.
4. Label visibility: honor Gmail's `labelListVisibility` (show, hide, show if unread) and change it from the label menu with `labels.patch`.
5. Inbox categories per account: switches for Social, Promotions, Updates and Forums. A switched-on category leaves the Inbox list and becomes its own mailbox under Inbox. Kept locally, since the API exposes no inbox-tabs setting.
6. Saved searches: a name and a Gmail query, per account or combined, shown in the sidebar and Favorites and run through milestone 3's search. Search history stays off.
7. Go to Label: a type-to-filter switcher for every mailbox, label and saved search.
8. Search suggestions while typing: contacts (cached addresses and milestone 4's contacts), labels and operators.

### D. Triage

1. Report Spam and Not Spam, with undo.
2. Mark as Important and Not Important.
3. Mark All as Read for the open mailbox: `messages.list` for unread IDs, then `messages.batchModify` in chunks of 1,000 (its documented limit). Undo restores exactly the changed IDs.
4. Delete Forever in Trash and Spam, plus Empty Trash and Delete All Spam behind a confirmation that gives the count. `messages.batchDelete` accepts only the full `https://mail.google.com/` scope. Its page states no ID limit, so requests use chunks of 1,000. No undo. The scope is asked for as a Permanent Deletion feature through milestone 4's per-feature authorization. Accounts with Inbox Updates on already hold it and see no second consent screen.
5. Delete key: archive (in a user label, remove that label instead) or move to Trash.
6. Sound effects for archive, trash, send and new mail, using macOS system sounds, with an on/off setting.
7. Send and Archive: the archive is queued when the send succeeds, and Undo Send cancels both.
8. Send Again: opens a sent message as a new draft with its recipients, subject, body and attachments.
9. Forward as Attachment: the raw message attached as `message/rfc822`.
10. Block Sender: a Gmail filter that sends that address's mail to Trash, listed under Blocked in Settings. It uses milestone 4's `createFilter(criteria:action:)` through its settings queue lane and needs its Gmail Settings permission. The API has no block list, so this is Tern's design.
11. Filter Messages Like These: opens milestone 4's filter editor filled in from the selected messages (sender, recipients, subject).

### E. Compose

1. Templates: named rich-text snippets inserted from the compose window and a menu, managed in Settings.
2. Tern signatures: local rich-text signatures next to milestone 4's Gmail signatures, assigned per account or address for new messages and replies, with an option to place them above the quoted text without the "-- " line.
3. Default font: sans serif, serif or fixed width.
4. Quote selection: replying with text selected quotes only that text. Ask, Always or Never.
5. Recipient fields show names only or full addresses (option).
6. Suggestion blocklist: remove an address from suggestions, from the suggestion list or Settings.
7. Compose From default: automatic (the selected mailbox's account; in combined mailboxes the account that last exchanged mail with the first recipient, else the first account) or a fixed account. This extends the From menu of milestones 3 and 4.
8. Inline images: paste or drop an image into the body, sent as `multipart/related` with `cid:` references.
9. Markdown input: typed Markdown for lists, emphasis and links becomes formatting, and pasted Markdown converts to rich text. Our own converter into `ComposeDocument`, no new dependency.
10. Writing Tools in the editor on macOS 15.1 and later.
11. Show or hide the format bar from the View menu.
12. Default mail app: register for `mailto:`, a setting that makes Tern the default, and compose from `mailto:` URLs (RFC 6068 to, cc, bcc, subject, body).

### F. Accounts, profiles and notifications

1. Account details: a nickname, used for the account's sidebar section title and for its rows under each mailbox in place of milestone 3's short name (the part before the @, or the whole address when two accounts share that part); a color picker over the palette milestone 3 assigns from (its phase 10d keeps the choice in the `accountColors` defaults key, set in `App/Views/AccountAppearance.swift`); sync on or off without signing out; account order.
2. Notifications: alerts for mail that arrives after each account's last alerted history point, with Off, Inbox, Inbox without categories, or All Mail per account. Alerts group by conversation, show sender, subject and snippet, open the conversation on click and offer one action chosen in Settings (Archive, Trash, Mark as Read, Star). Alerts arrive within seconds for accounts with milestone 4's Inbox Updates on, and at the next 60-second poll otherwise. Dock badge with the unread Inbox count, an optional unread count in the menu bar, and a Send Test Notification button. The first sync, a cache rebuild and re-enabling an account never alert.
3. Background running: closing the last window keeps Tern syncing, watching for new mail, alerting and waking snoozes. Quit stops it (owner's choice).
4. Profiles: named groups of accounts with a color and a symbol, each account in one profile, plus an All profile. The window shows the active profile's accounts.
5. Notification schedule per profile: off, every day between two times, weekdays, or custom times per day.
6. Focus filter: an App Intents Focus filter that picks the active profile per Focus. This also clears the AppIntents build warning.

### G. Attachments, links and automation

1. Open attachments from Tern's folder (today) or Downloads. Downloads needs `com.apple.security.files.downloads.read-write`.
2. Attachment menu: Open, Open With, Quick Look, Save As, Copy, Save All.
3. Copy Link: `tern://` links to a conversation, which Tern opens and selects. Copy Gmail Link and Open in Gmail use Gmail's web URL for the account, checked in live testing.
4. AppleScript: a read-only dictionary exposing the selected conversations and messages (IDs, subject, sender, date, Tern and Gmail links).

### H. Windows and view

1. Hide the viewing pane (two columns). Double-click opens a conversation in its own window, and Open in New Window works in every layout.
2. Customizable toolbar.
3. View menu switches for account badges, message size, importance markers and quick filters.

### I. Cache and maintenance

1. Cache budget: past a size limit, bodies and downloaded attachments of the least recently opened conversations go first, then metadata outside the default sync window and outside holds. Settings shows the cache size.
2. Reset Cache: deletes and rebuilds `cache.sqlite` and keeps `config.sqlite`. Refused while the Outbox or queue holds work, since milestone 2 keeps unsent drafts and queued changes in the cache. The message says why.
3. Failed changes: a permanently failed queue row moves to a `failed` state instead of being deleted. It no longer changes what the list shows. Settings lists it with Gmail's message and offers Retry or Discard.

### J. Beyond milestone 4

Milestone 4's plan leaves these to milestone 5. This list first also held filters that forward and a vacation message with formatting. The owner moved both into milestone 4 on 2026-10-29 (its answered question 3), and that amendment still waits for the owner's approval.

1. Contact photos: People API photos for saved and other contacts, cached with the contact rows, used by A9.
2. Contact groups: a group name typed in a recipient field expands to its members' addresses.
3. Invitation agenda: the invitation banner shows the day's other events from the Mac's calendars through EventKit, read-only. This needs Calendars full access, since write-only access can't read events.

## Not included

- Subscription, trial and purchase screens, and signing in to a vendor account: Tern has no billing.
- Alerts while Tern is quit (Pub/Sub, a relay server and APNs): needs a hosted relay and a paid Apple Developer membership. Tern keeps running in the background instead (owner's choice, 2026-10-29).
- Self-updating and update channels: Tern is built from source (owner's choice).
- The server environment picker and other vendor debug settings.
- On-device model features: the research found the framework linked but no feature that uses it.

## Check against milestone 4

Milestone 4's plan (`docs/plans/milestone-4.md` on `feat/milestone-4`, approved 2026-10-29 and amended at `36c6455`) covers these, so they're left out here:

- Vacation dates, the contacts-only and domain-only options, and a formatted message edited in the compose editor.
- Gmail signatures per address, and replying from the address a message was sent to.
- Other contacts, RSVP, and Google permissions per feature.
- A filter editor with each action in Gmail's filter guide: skip the Inbox, mark as read, star, one user label, never send to Spam, always or never mark important, delete, and forward to a verified forwarding address. Categorize appears once live testing shows `filters.create` takes a `CATEGORY_*` label.

What milestone 5 builds on, as the milestone 4 session confirmed on 2026-10-29:

- Inbox updates use IMAP IDLE behind `https://mail.google.com/`, asked for per account when the user turns on Inbox Updates. Accounts without it pick up new mail at the 60-second poll.
- Per-feature authorization (its phase B3) keeps a set of features per account, each with its scopes, and counts a broader granted scope. D4 adds a Permanent Deletion feature to it.
- Block Sender and Filter Messages Like These use its `createFilter(criteria:action:)` call and the filter editor sheet from its phase B10b.

Still open:

- The owner's approval of milestone 4's amendment. Without it, filters that forward and the formatted vacation message return to workstream J.
- Gmail's web option to also apply a new filter to existing mail has no API equivalent, since filters act only on mail that arrives after they exist. It isn't planned here.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Scopes | No new scope apart from `https://mail.google.com/` for permanent deletion, asked for as a Permanent Deletion feature through milestone 4's per-feature authorization. Accounts with Inbox Updates on already hold it. J1 and J2 use milestone 4's contacts scopes | `messages.batchDelete` accepts only that scope. `batchModify` and everything else here accept `gmail.modify` |
| Gmail changes | Spam, importance, mark all read, permanent deletion, label visibility and block filters are new queue kinds | Every change to Gmail state goes through the action queue (project rule) |
| Where settings live | Display preferences (text size, density, order, sounds) in `UserDefaults`. Anything that must survive a cache reset (account details, profiles, favorites, saved searches, templates, Tern signatures, suggestion blocklist, allowed image senders, category switches, alert watermarks) in `config.sqlite` | Reset Cache must not lose user setup |
| Page scripts | Page JavaScript stays off. Link hover and quote selection use scripts in an isolated `WKContentWorld`, which `allowsContentJavaScript = false` doesn't disable. The first rendering phase confirms this | Keeps the milestone 1 security posture |
| Partial responses | Gmail supports the `fields` parameter on any request that returns data. The part-tree read uses it to leave out headers and body data | Attachment chips without downloading bodies |
| Clean room | Screenshots are a checklist. Tern uses its own layout, wording and icons, and macOS system sounds | Project rule |

## Data model sketch

Migrations are named in the phase plan.

- `config.sqlite`: `account` gains nickname, a sync switch, order, profile, alert rule and category switches. Account colors stay in `UserDefaults`, where milestone 3 keeps them. New tables: `profile`, `profileSchedule`, `favorite`, `savedSearch`, `template`, `signature`, `signatureUse`, `suggestionBlock`, `imageSenderAllow`, `alertMark`.
- `cache.sqlite`: `message` gains `contentType` and `hasAttachments`. `attachment` rows also come from the part tree. New `mimeResource` (account, message, content ID, type, data). `pendingAction` gains message-scoped targets, the new kinds and the `failed` state. Each conversation gets a last-opened time for the cache budget. Milestone 4's contact rows gain a photo.

## Order

The milestone starts after milestone 4 merges. Phases then follow the workspace rule of at most five files each.

| # | Workstream | Notes |
|---|---|---|
| 1 | Package groundwork in new files: color adaptation, `mailto:` parser, Markdown converter, tracker matcher, part-tree decoding, print page | No shared files, so these can run in parallel |
| 2 | A Reading | `cid:` resources first, since several items build on the resource path |
| 3 | B Message list | Message mode last, since it changes queue targeting |
| 4 | D Triage | Permanent deletion needs the full scope through milestone 4's authorization |
| 5 | C Sidebar and mailboxes | |
| 6 | E Compose | |
| 7 | G and H | |
| 8 | F Accounts, profiles and notifications | Prompt alerts need milestone 4's Inbox Updates |
| 9 | J Beyond milestone 4 | Items milestone 4 takes on drop out |
| 10 | I Cache and maintenance | |
| 11 | Review pass and fixes | |

## Tests

Aimed at failures that would delete the wrong mail, alert wrongly, leak remote loads or lose a change:

- Permanent deletion: nothing is sent without confirmation or without the full scope. Empty Trash deletes only the IDs counted at confirmation.
- Mark All as Read: 1,000-ID chunks. Undo restores exactly the changed IDs, and mail arriving meanwhile stays unread.
- Message mode: archiving one message leaves the others in its conversation unchanged.
- Alerts: none after the first sync, a cache reset or re-enabling an account; one per new message; schedules and Focus profiles suppress them.
- Remote content: blocked by default. Allowing one sender loads only that sender's images, and tracker hosts stay blocked when allowed.
- Color adaptation: adapted text keeps at least 4.5:1 contrast on fixture mail, and declared dark styles are untouched.
- `cid:` resolves only within its own message, and an unknown ID loads nothing.
- `mailto:` parsing, the Markdown subset and nested part trees.
- Reset Cache is refused with a non-empty Outbox and leaves `config.sqlite` alone.
- A failed row doesn't change the list, and Retry queues it once.

No UI snapshot tests.

## What you need to do

- Permanent deletion needs no change to the OAuth consent screen, since milestone 4 already adds `https://mail.google.com/` for Inbox Updates.
- Allow Tern's Calendars access when the invitation agenda first asks for it.
- Live testing: the part-tree `fields` mask, `cid:` mail, Gmail web links, and allowing alerts in System Settings.

## Risks

- Size: 72 items. The phase plan may split the milestone into 5a and 5b.
- The full mail scope is Gmail's broadest restricted scope, and a leaked token could delete mail for good. It works for personal use in testing mode. Public release needs Google's verification and possibly a security assessment.
- Color adaptation will misjudge some designs. The per-message light background is the fallback.
- Message mode changes queue targeting across many actions.
- Alerts need Tern running.
- The tracker list's license must allow bundling.
- If the owner doesn't approve milestone 4's amendment, two items return to workstream J.

## Answered questions

Answered on 2026-10-29:

1. No relay server. Tern keeps running in the background and alerts from its own sync, which milestone 4's IMAP IDLE speeds up for accounts with Inbox Updates on.
2. No self-updating.
3. This document sets scope. File-level phases follow once milestone 4 merges.
