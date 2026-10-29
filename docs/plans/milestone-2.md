# Milestone 2 plan: compose

Status: approved 2026-10-29 after a plan review, and built on `feat/milestone-2`. Where the build differs from this plan, see Deviations at the end. Research input: the "Compose and send" section and milestone list in `docs/research/mimestream-behavior.md`. Branch `feat/milestone-2`, cut from `feat/milestone-1` at `90f2bf2`.

## Scope

In scope:

- New message, reply, reply all and forward, each in its own compose window.
- Rich text: bold, italic, underline, links, bulleted and numbered lists.
- Draft autosave to Gmail, and editing drafts from the Drafts label, including drafts started in other clients.
- Sending through `drafts.send` behind an undo send delay.
- Attachments: add files with the file picker, drag and drop or paste. Forwarded messages keep their original attachments.
- To, Cc and Bcc fields that validate addresses and suggest addresses from cached mail.
- Discarding a draft, with undo.
- Received attachments: the thread view lists them, and each opens in Quick Look or saves to a folder you pick.
- An Outbox entry in the sidebar, shown only while drafts or sends are waiting to reach Gmail.

Out of scope: send-as aliases and signatures (they need the Gmail Settings scope, milestone 4), contact suggestions from the People API (milestone 4), inline images, templates, scheduled send, Markdown compose and search (milestone 3).

## Gmail API facts this plan relies on

Checked against Google's reference pages and guides on 2026-10-29:

- `drafts.create`, `drafts.update`, `drafts.send`, `drafts.delete` and `messages.send` all accept `gmail.modify`, the scope Tern already holds.
- Each has an upload URI under `/upload/gmail/v1/users/me/...` that takes `uploadType=multipart` (a JSON part, then a `message/rfc822` part) or `uploadType=resumable` (a session started with `X-Upload-Content-Type` and `X-Upload-Content-Length`, whose `Location` header is the URI the message is `PUT` to).
- `drafts.update` destroys the draft's message and stores a new one with a new ID. The draft ID stays the same.
- `drafts.send` can carry updated content. It deletes the draft and creates the sent message with a new ID.
- `drafts.delete` is immediate and permanent.

Not confirmed on the current pages: the 35 MB message size limit and whether Gmail keeps a client-supplied `Message-ID` on drafts. Both are checked in live testing; the plan works without either.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Scope | No new OAuth scope | `gmail.modify` covers every call above |
| Sending | A message always becomes a Gmail draft first and goes out with `drafts.send`. `messages.send` isn't used | `drafts.send` consumes its draft, so a repeated request fails with 404 instead of sending twice |
| Upload | `uploadType=multipart` up to 5 MB, `uploadType=resumable` above. The JSON part is `{"message":{"threadId":…}}` for `drafts.create`, with `"id"` added for `drafts.update` and `drafts.send` | Google's upload guide puts multipart at small files and resumable at large ones |
| Editor | `NSTextView` wrapped for SwiftUI, with a format bar and menu commands | SwiftUI's rich `TextEditor` needs macOS 26; `NSTextView` has lists and links on macOS 14 |
| Body model | A platform-neutral `ComposeDocument` in `MessageContent`: paragraphs, list items, styled runs and links. The app maps it to and from `NSAttributedString` | HTML output, plain text output and HTML import are testable with `swift test` |
| HTML import | Our own SwiftSoup walk into `ComposeDocument`, never `NSAttributedString(html:)` | The AppKit importer runs WebKit on the main thread and can fetch remote resources |
| MIME | Our own RFC 5322 writer: `multipart/alternative` with text and HTML, `multipart/mixed` around attachments, quoted-printable text, base64 attachments, RFC 2047 encoded words, RFC 2231 file names, CRLF line endings. A small raw MIME reader in the same target decodes what the writer produces | No new dependency. The existing `MIMEParts` reads Gmail's parsed JSON, not raw messages, so tests need the reader |
| Threading | Replies and forwards set `threadId`, `In-Reply-To` and `References` (built from the original's `References`, or its `In-Reply-To` when that is missing), and keep one "Re:" or "Fwd:" on the subject | Gmail threads a message only when the thread ID, headers and subject match |
| Quoting | The original HTML goes after the new text inside Gmail's `gmail_quote` blockquote markup, with scripts, frames, forms and event handlers removed and remote images kept. Plain text quotes with "> ". The quote is copied into the local draft when compose opens and shown as a collapsed, read-only preview | Recipients see the original as sent, and a later cache cleanup can't remove it |
| Local state | Compose state is written to `cache.sqlite` half a second after each edit. Send, close and discard write any pending edit in the same transaction as their queue row | A crash, quit or quick send never loses the last keystrokes |
| Autosave | Three seconds after typing stops, when the window closes, and never more than every 30 seconds once the encoded message passes 1 MB | Every `drafts.update` re-uploads the whole message, attachments included |
| Queue | Saving, sending and discarding are new action kinds in the existing queue. Rows for one draft go out in creation order. Compose rows drain in their own lane next to label changes, so a large upload doesn't hold up archive or star | One path for every Gmail change (project rule) |
| Undo send | The send row waits for the undo send delay, default 10 seconds, with 5, 20 and 30 in Settings. A separate `undoSend` either cancels the row and reopens the window or reports that the message already went | A send has no inverse, so the milestone 1 undo path doesn't apply |
| Attachments | Files are copied into `Application Support/Tern/Outgoing/<draft>/` when added. Attachments from a forwarded message or an existing draft are downloaded there when compose opens; a failed download blocks saving and says so rather than dropping the file. Received attachments download to `Caches/Tern/Attachments/` when opened. The sandbox gains `com.apple.security.files.user-selected.read-write`, for picking files to attach and folders to save into. Attachments are capped at 25 MB in total, and the encoded message is checked before upload | Gmail's attachment limit; Gmail references stop working once `drafts.update` replaces the message |
| Recipients | `NSTokenField` with RFC 5322 address parsing. Suggestions come from From, To and Cc addresses in cached mail, most recent first | No new scope until the People API in milestone 4 |
| Windows | Compose windows are a `WindowGroup(for:)` keyed by the local draft ID. A Gmail draft can belong to one local draft only | Opening a draft that is already open brings its window forward, and two windows can't overwrite each other |

## Data model

A new migration named `compose-v1`, distinct from any migration the milestone 1 audit adds, since GRDB tracks migrations by name:

- `message` gains `rfcMessageID`, `inReplyTo`, `referencesHeader` and `replyTo`. The metadata fetch adds those headers. Rows cached before the migration get them from one metadata fetch when a reply needs them.
- `draft`: account, Gmail draft ID, message ID, thread ID. Filled from `drafts.list` and from save responses.
- `localDraft`: local ID, account, Gmail draft ID (empty until the first save, unique per account when set), the Gmail message ID of our last save, thread ID, kind (new, reply, reply all, forward, edit), the message it replies to or forwards, To, Cc, Bcc, subject, the body as `ComposeDocument` JSON, the quoted HTML and plain text, any HTML tail kept from an imported draft, revision, last saved revision, state (editing, sending, sent), created and updated dates.
- `outgoingAttachment`: local draft ID, file name, MIME type, size and a path under `Outgoing/`.
- `attachment`: account, message ID, part ID, Gmail attachment ID, file name, MIME type and size, filled when a message body is stored. The part ID is the key, because Gmail may hand out a different attachment ID each time a message is fetched; a download that fails with a stale ID fetches the message again.
- `pendingAction` gains `localDraftID`. New kinds: `saveDraft`, `sendDraft`, `discardDraft`. Claiming treats a local draft like a thread, so rows for one draft never overlap or reorder.

The `MailCache` doc comment that calls the cache disposable changes: it now holds unsent drafts, and the resync paths keep them.

Thread rebuilding and the thread detail query hide a message when it carries DRAFT and belongs to a draft with a pending send or discard. After each save, one write stores the new draft message's metadata (fetched, since the save response has no history ID), deletes the replaced draft message, adds it to the tombstones that stop slow thread loads from restoring it, and updates `draft`. So a thread never shows two copies of a draft.

Full sync lists DRAFT along with INBOX and the last 30 days, so older drafts stay cached. `drafts.list` runs during full sync, when the Drafts label opens, and before editing a draft that isn't in `draft`.

## Compose flow

1. Opening a compose window creates a `localDraft` row. Reply, reply all and forward fill recipients, subject, quote and threading headers from the cached message, fetching missing headers, the body or attachments first.
2. Each edit updates the row and raises its revision.
3. Autosave queues `saveDraft` unless one is already queued. The row builds the MIME message from the newest revision when it runs, and queues another save if the revision changed during the upload.
4. The first save calls `drafts.create`, with `threadId` for replies and forwards. Later saves call `drafts.update`.
5. If a `drafts.create` attempt ends without a clear answer (timeout, cancellation, quit), the retry first lists the thread's drafts and adopts one whose content matches our last upload, so it doesn't leave a duplicate draft. The worst case is an extra draft, never an extra sent message.
6. Send writes pending edits, queues `sendDraft` with the undo send delay, drops queued saves for that draft, closes the window and shows a send notice in the main window for the whole delay. When the row runs, it saves the draft first if it never reached Gmail, then calls `drafts.send` with the newest content. On success the sent message's metadata is fetched into the cache and the local draft and its files are deleted.
7. `drafts.send` answering 404 means the draft is gone. After an earlier attempt or a relaunch, that means our send went through, and the row counts as sent. On a first attempt it means the draft was sent or deleted in another app, and the window reopens to say so. The milestone 1 rule that treats every 404 as success doesn't apply to compose rows.
8. Undo during the delay deletes the send row and reopens the window. Once the request has started, `undoSend` reports that it's too late.
9. Discard writes pending edits, drops queued saves, and queues `discardDraft` with a hold as long as its notice shows. When the row runs, it looks up the Gmail draft ID then, since a create may have finished meanwhile, and calls `drafts.delete` only if one exists. The local copy is deleted only after that.
10. Failures: network errors, rate limits and 5xx retry with backoff, and the window shows "Will save when Tern can reach Gmail". A permanent failure on send, such as an invalid recipient, reopens the window with Gmail's message.

Drafts edited elsewhere: before updating, and when a draft is reopened, Tern compares the draft's current message ID with the one from its last save. If they differ, the server copy is imported. If the local copy also has changes Gmail hasn't seen, those are kept as a new draft and the window says so.

Imported drafts: the thread view marks draft messages and shows Edit Draft. Opening one calls `drafts.get` in full format, imports the HTML part into `ComposeDocument` (or uses the plain text part), keeps a `gmail_quote` block and everything after it as a read-only tail, and downloads attachments. If the draft has formatting Tern can't keep, such as tables, fonts or inline images, the window warns before the first edit.

## Sign-out, expired sessions and quitting

- The sign-out confirmation counts what is in the Outbox, since signing out deletes it. Sign-out waits for a send that is already uploading, so its outcome is known.
- Open compose windows close on sign-out after the confirmation.
- When the session expires, the cache, the queue and open compose windows stay. Saves and sends wait until the user signs in again, as label changes do in milestone 1.
- Quitting while sends wait out their delay sends them at once and waits for them to finish. If Gmail can't be reached, Tern asks whether to quit and send at the next launch, or stay open.

## Gmail API additions

- `drafts.list` (all pages, `maxResults=500`, optional `q`), `drafts.get`, `drafts.create`, `drafts.update`, `drafts.send`, `drafts.delete`, `messages.attachments.get`.
- Upload requests use a second base path, `/upload/gmail/v1/users/me/`, next to the existing `Endpoint` base path.
- A failed resumable upload starts over rather than resuming; the attachment cap keeps a restart affordable.
- The existing 401 refresh and retry rules apply to the new calls.

## UI

- Compose window: From (the account, read-only), To, Cc and Bcc (Cc and Bcc hidden until used or shown from the View menu), Subject, format bar, editor, attachment strip, the collapsed quote preview, a status line (Saving, Saved to Drafts, Waiting for connection) and Send and Discard buttons.
- Menus and toolbar, following Apple Mail's shortcuts: New Message ⌘N, Reply ⌘R, Reply All ⇧⌘R, Forward ⇧⌘F, Send ⇧⌘D, Attach Files ⇧⌘A, bold ⌘B, italic ⌘I, underline ⌘U, add link ⌘K. The thread view gets Reply, Reply All and Forward on each message.
- Outbox: a sidebar entry with the virtual ID `TERN_OUTBOX`, shown while any local draft hasn't reached Gmail or any send is waiting or failed. Selecting it lists those drafts and sends instead of threads; opening one reopens its compose window.
- The send notice has its own slot, so an archive notice doesn't replace it. Undo Send is also on the Edit menu while the delay runs.
- A Settings window with the undo send delay.
- VoiceOver labels on every field and an announcement when a message is sent or the send is undone.

## Phases

The user approves this plan before phase 1 starts. Each phase touches at most five files, ends with its checks passing and gets its own commit.

| # | Phase | Check |
|---|---|---|
| 1 | `GmailAPI`: drafts and attachment calls, the upload base path, multipart and resumable upload | `swift test` |
| 2 | `MessageContent`: `ComposeDocument`, HTML and plain text output, HTML import, MIME writer and reader, reply and forward builders, attachment listing. Built as 2a (addresses, MIME writer and reader, attachment listing) and 2b (the rest) to stay within five files each | `swift test` |
| Gate | The milestone 1 audit finishes and, with your approval, `fix/milestone-1-audit` is merged into this branch. Then a cleanup commit for the files over 300 lines that phases 3 and 4 change (dead code, unused imports and exports, debug logs), as workspace rule 9 requires | Full build and tests |
| 3 | `MailStore`: `compose-v1` migration, draft and attachment tables, header columns, claiming by draft, hiding drafts being sent or discarded | `swift test` |
| 4a | `SyncEngine`: save, send and discard rows, revisions, the compose lane, 404 handling, undo send | `swift test` |
| 4b | `SyncEngine`: draft lookup and import, conflict handling, header backfill, DRAFT in full sync | `swift test` |
| 5a | App: compose window and editor bridge | Build, launch |
| 5b | App: recipient fields, attachments, entitlement | Build, launch |
| 5c | App: reply and forward commands, draft editing, Outbox, send notice, Settings, sign-out and quit handling | Build, launch |
| 5d | App: received attachments in the thread view, Quick Look and Save | Build, launch |
| 6 | Review pass and fixes | Full build and tests |

Phases 1 and 2 touch separate targets and don't depend on the audit, so they run first and can run in parallel. Phase 3 waits for the gate, because the audit is changing `MailCache.swift`, `ActionQueue.swift` and `SyncEngine.swift`.

## Tests

Tests cover failures that would send twice, send the wrong thing, lose a draft or break threading:

- MIME writer and reader: non-ASCII subjects, names and file names survive a round trip; long lines wrap within 998 characters; an attachment's bytes come back unchanged; Bcc is in the uploaded message; line endings are CRLF.
- Reply recipients: Reply-To wins over From; replying to your own sent message goes to its original recipients; reply all drops your address and duplicates.
- Threading headers: `References` grows from the original's, falling back to `In-Reply-To`; "Re:" and "Fwd:" aren't doubled.
- Attachment listing: parts with a file name or an attachment disposition are listed with their part ID; body parts aren't.
- HTML import: text inside `script` and `style` is dropped; remote image references don't survive; supported formatting survives a round trip; a `gmail_quote` block is kept as the tail.
- Upload: the multipart body for each method's metadata shape; the resumable start, `Location` and `PUT` sequence; the 5 MB switch.
- Queue:
  - A send row left in `sending` and requeued at launch sends once.
  - A 404 from `drafts.send` after an earlier attempt counts as sent; on a first attempt it reopens the draft.
  - A queued save uploads the newest revision, and a send waits behind a save in flight.
  - Undo during the delay sends nothing and restores the draft.
  - Discarding a draft that never reached Gmail makes no call, and a discard that runs after a create uses the new draft ID.
  - A draft whose server message ID changed is imported instead of overwritten.
  - A compose upload doesn't delay a queued archive.

No UI snapshot tests.

## What you need to do

Nothing new in Google Cloud. Live testing needs the OAuth client from milestone 1. Send test mail to yourself.

## Risks

- Merging with the milestone 1 audit. The gate above handles it, and phases 1 and 2 add files rather than changing shared ones.
- List editing in `NSTextView` (`NSTextList`) has rough edges. If lists misbehave, they move to a later milestone and bold, italic, underline and links ship first.
- Matching a draft after an unclear `drafts.create` relies on comparing content. If that proves unreliable in live testing, the fallback leaves at most one extra draft.
- `gmail.modify` is still a restricted scope, so public release still needs Google's verification.

## Answered questions

Answered on 2026-10-29:

1. Received attachments open with Quick Look and save to disk in this milestone (phase 5d).
2. The undo send delay defaults to 10 seconds.
3. The phases run back to back, each tested and committed, with no approval stops except the gate.
4. The audit branch is merged at the gate once you say the audit is done.

## Deviations

Recorded 2026-10-29, after phase 6.

### Process

- Phases 3 to 5 went out as more, smaller commits than the table lists. Six of them still touch more than five files: the compose lane in `SyncEngine` (7), recipient fields (6), attaching files (8), the undo notices (6), the Outbox (6) and received attachments (6).
- The phase 6 review found problems in both the app and `Packages/Core`. Each fix has its own commit. The core fixes were made on `fix/m2-core-review` and merged.

### Data model

- `LocalDraft.state` is editing, sending or discarding. A sent draft is deleted rather than marked sent, and discarding is a state of its own so that undo can bring the draft back.
- `localDraft` has no column for an imported draft's tail. The `gmail_quote` block and everything after it go into `quotedHTML`, which replies already use.
- A second migration, `compose-v2`, adds `hasUnrecordedUpload` and `sendRequested` to `localDraft`. The first is set before each upload and cleared when a save is recorded. The second is set before `drafts.send` and cleared when the draft returns to editing. They replace the queue row's attempt count, which was wrong in two cases: a send or discard that replaces a waiting save row starts again at one attempt, and claiming a row raises its count even if the app quits before the row starts.

### Compose flow

- Drafts edited elsewhere: when Gmail's copy of a draft holds a message Tern didn't upload, the next save creates a new draft instead of importing the other copy, and the main window says "Another app changed this draft, so Tern kept both versions." Neither version is lost.
- Edit Draft on a draft whose save is still uploading opens the copy that is already open, even when another app changed the draft in the meantime. That upload has already picked the Gmail draft, and importing the other version under the same draft ID made the save fail against the unique index on `localDraft`. If the other app's change lands after Tern's upload, the next save keeps both versions. If Tern's lands last, it replaces the other change, as with any two apps saving one Gmail draft at the same time.
- After an upload whose answer was lost, the retry looks for the draft by its `Message-ID` header, with a `drafts.list` query on `rfc822msgid:`, instead of comparing content, and a discard looks the same way. If Gmail doesn't keep a client-supplied `Message-ID`, the worst case is still one extra draft.
- A 404 from `drafts.send` counts as sent only when an earlier send request may have reached Gmail (`sendRequested`). A relaunch alone no longer counts.
- An address that doesn't parse stays in its field as plain text instead of a token, and Send shows an alert naming it. Saves leave such addresses out of the uploaded message.
- The thread view lists inline parts, such as images a message refers to by `cid:`, along with ordinary attachments, so each one can be opened or saved.

### Sign-out, expired sessions and quitting

- An expired session keeps the whole open mailbox, so compose windows, Undo Send and the Outbox keep working until the person signs in again.
- Signing in as a different Google account while the old one still has local data is refused, since replacing it would delete its drafts and unsent messages. The sign-in screen offers Sign Out for that case, with the same confirmation as the menu command.
- After signing in again, a save or send that failed while the session was expired waits out its retry backoff, up to five minutes, before it goes out. Signing in starts a sync but doesn't reset the backoff.
- Quitting stores what each open compose window shows and queues its save to Gmail, so no typing is lost.
- When quitting sends waiting messages and Gmail refuses one, its window opens again with the reason, the draft stays in the Outbox, and a separate alert asks before quitting. The alert for an unreachable Gmail still says the message goes out at the next launch.
- Sign-out waits for every send under way before it stops the engine, including one that a quit attempt started, not only one the compose queue started.

### UI

- Format commands and the format bar work only while the cursor is in the message, so ⌘B in Subject leaves the message's typing style alone.
- The To, Cc and Bcc fields align on a fixed baseline and are measured on an off-screen copy. Asking a token field that is being edited for its size or baseline made SwiftUI and AppKit lay each other out in a loop until AppKit raised an exception.

### Not done yet

- Live testing against Gmail. The work so far ran in unit tests and against the synthetic mailbox of `--ui-audit` mode, so the two unconfirmed API facts above, the 35 MB limit and whether Gmail keeps a client-supplied `Message-ID`, are still unchecked.
- In background screenshots of the audit app, thread message bodies looked blank. Milestone 2 didn't change `MessageWebView`, and WebKit pausing a hidden view is the likely cause, but nobody has checked with the window in front.
- Core review finding 6, deferred: when Edit Draft can't find a draft's message, Tern lists Gmail's drafts again to repair the stale entry, which costs one extra `drafts.list`. Preferring the local record would hide a newer edit made in another app, and a proper fix needs ordering that `drafts.list` doesn't return.
- `feat/milestone-3` and `feat/milestone-4` register the migrations `labels-v1` and `search-v1`. Their order relative to `compose-v1` and `compose-v2` needs settling when those branches take in this one.
