# Mimestream behavior study

Studied 2026-10-29 against Mimestream 1.10.8 (build 398, macOS 12+), installed at `/Applications/Mimestream.app`. The goal is to inform an original native Gmail client. Nothing here is copied code; the findings describe what the app does, what it sends to Google and how its data is shaped.

## Method and limits

Static and UI inspection:

- REA 6.8.0 (`rea capabilities`, `rea inspect-signature`, and `rea inspect-sqlite-database` for the schema only)
- `codesign`, `plutil` and `otool -L` for entitlements, Info.plist and linked frameworks
- A small Swift loader that reads the bundled compiled CoreData model (`Mimestream.momd`) and prints entity and attribute names
- The desktop app's accessibility capture and menu listing for UI structure
- The German string table, whose keys are the English UI strings, as a feature inventory

Runtime inspection examined the SQLite schema, file layout and plist key names without querying message rows. Socket sampling and a process-scoped request-shape capture recorded methods, hosts, paths with IDs replaced, query parameter names, statuses, sizes, timing, and IMAP command/response names. The capture excluded bodies, tokens, search terms and user label names. It covered launch, idle, reading, triage, search, compose and send. These research tools are not required to build or run Tern.

Not done:

- No disassembly or decompilation of `Mimestream` or `MimestreamCore`.
- No LLDB call tracing. The app is notarized with the hardened runtime, so REA's `observe-native-calls` cannot attach without disabling SIP, which stayed on.
- No message content was recorded.
- The inner requests of Google `/batch` calls were not recorded because of a line-ending bug in the addon, fixed afterward. Their sizes were logged.
- Click times were not logged, so delays such as undo send were not measured.
- Private Push was not observed.

## Stack

| Area | What Mimestream uses | Evidence |
|---|---|---|
| Language and UI | Swift, SwiftUI plus AppKit (storyboards, nibs) | Linked frameworks, `MainMenu` storyboard, `MessageListRowView.nib` |
| Core logic | Separate `MimestreamCore.framework` | Bundle layout |
| Google API client | Google APIs Client for REST (Objective-C) with GTMSessionFetcher | Acknowledgements, resource bundles |
| Auth | AppAuth and GTMAppAuth, custom URL scheme redirect | Acknowledgements, `CFBundleURLTypes` holds a `com.googleusercontent.apps.*` scheme |
| Local store | CoreData | `Mimestream.momd`, `libswiftCoreData` |
| HTML handling | SwiftSoup, Linkify, tinycolor | Acknowledgements |
| Message view | WKWebView with bundled JS and CSS | `ThreadContentView.js`, `Message.css`, `ThreadContentView.css` |
| Compose body | Web editor | `ComposeBodyController.js`, `HTMLEditor` bundle, Swift Markdown |
| Updates and billing | Sparkle (direct download), StoreKit (subscription) | Frameworks, `Products.storekit` |
| System integration | App Intents (Focus filter), AppleScript (exposes the selection only), UserNotifications, EventKit, Contacts, QuickLook, FoundationModels | `Metadata.appintents`, `Mimestream.sdef`, linked frameworks |

The app is sandboxed. Entitlements include network client, contacts, calendars, Downloads read-write, user-selected files, an app group, push notifications (`aps-environment: production`) and associated domains for `links.mimestream.com`.

## Google services and authorization

Mimestream treats Google access as separate connections the user enables one at a time: Gmail, Gmail Settings, Google Calendar and Google Contacts. Strings such as "Connect Gmail Settings to modify filters" and the `Account.authorizationScopeList` attribute point to incremental authorization: the app asks for extra scopes only when a feature needs them.

Features behind the Gmail Settings connection are filters, the vacation responder, send-as identities with signatures, and forwarding addresses. Calendar access powers the invitation banner and replies to invites. Contacts access feeds recipient autocomplete through the People API.

The app holds an authenticated IMAP session (see Real-time updates). Gmail accepts OAuth over IMAP only with the full `https://mail.google.com/` scope, so the Gmail connection must include it.

## Local data

The data container is `~/Library/Containers/com.mimestream.Mimestream/Data/Library/Application Support/Mimestream/`.

- `Mimestream.sqlite` is the CoreData cache, accompanied by a write-ahead log. It has 20 tables, and `ZMESSAGE` has 35 columns. The 26 indexes cover foreign keys only. There is no index on date or flags and no full-text table, which matches search going to the server.
- `Attachments/` holds downloaded attachments in numbered subfolders.
- `Persistence.plist` (version 23, data version 41) holds what must survive a cache reset: each account's user ID, granted scopes, send-as identities with signature defaults, inbox category toggles and profile, plus the profiles themselves and snoozed items.
- The preferences plist holds window and split-view frames (the main split view has three panes), toolbar layouts, Sparkle update keys and the trial expiration date.

Because accounts, signatures and snoozes live outside the database, the cache can be thrown away and rebuilt from Gmail without losing user setup.

## Sync design

These points come from the CoreData model and the network capture.

- `Account.historyId` stores the Gmail history cursor, and incremental sync runs on `users.history.list` with `maxResults=500`.
- `Mailbox.syncWindowEndDate` gives each label its own date-bounded sync window. The "Adaptive Cache Management" setting manages how far back the cache reaches.
- `Message` holds metadata and flags. Bodies, headers and attachments live in a separate `MessageContent` entity, so bodies can load on demand.
- Label state is denormalized into booleans on `Message`: `isInInbox`, `isUnread`, `isFlagged`, `isImportant`, `isSpam`, `isTrashed`, `isDraft`, `isSent`, plus one flag per inbox category. This makes list queries cheap.
- `UserAction` is an outbound action queue. Each row stores a type, old and new values, status, retry count, execution date and last error. The app applies a change locally first and replays it to Gmail, which also supports undo and offline work.
- `SnoozedItem` exists because the Gmail API has no snooze endpoint. The app keeps its own snooze records. The string "Snoozing can't sync with Gmail" suggests a sync mechanism across devices, but this study did not identify it.
- `Profile` groups accounts. It ties into the Focus filter intent and per-profile notification schedules.
- Other entities: `Identity` (send-as and signatures), `Filter`, `ForwardingAddress`, `Contact`, `ContactGroup`, `ContactEmailAddress`, `Attachment`, `MessageThread`, `UserMailbox` (user labels with tag colors).

## Network behavior

### Launch and refresh

At launch the app ran the same refresh pass twice within three seconds, and again when the user switched back to it about three and a half minutes later. Each pass took about a second:

- `history.list` from the stored cursor
- `labels.list`
- Gmail settings: `settings/vacation`, `settings/forwardingAddresses`, `settings/filters` and `settings/sendAs`
- People API: `otherContacts` and `people/me/connections` with sync tokens (names, email addresses, metadata and photos), `contactGroups` with a sync token, and `people/me` for the user's name and photo
- `POST accounts.mimestream.com/api/auth/login`
- At launch only, `POST users/me/watch`, which registers a Cloud Pub/Sub topic for the account and is the likely hook for Private Push

With a warm cache there was no `messages.list` or `threads.list` call. The history cursor brought the cache up to date, plus one `threads.get`.

### Real-time updates

While idle the app sent nothing over HTTPS. It kept one IMAP connection to `imap.gmail.com:993`: `AUTHENTICATE`, `SELECT INBOX`, then `IDLE`. It never sent `FETCH`, so IMAP serves only as a change signal.

When the server pushed `EXISTS`, `EXPUNGE` or `FETCH` notices, the app made these calls within about 200 ms:

1. `labels/INBOX` for counts
2. `history.list` from the stored cursor
3. `threads.get` for the changed thread
4. one `/batch` request, sized for a few metadata reads

It then ended the idle with `DONE` and started a new `IDLE`. Only INBOX is watched, so a change that touches only other labels waits for the next history call.

Private Push over APNs needs a Mimestream server, most likely receiving the Pub/Sub notifications that `users.watch` sets up. That side was not observed.

For our build: IMAP with OAuth requires the full `https://mail.google.com/` scope, the broadest restricted Gmail scope. Polling `history.list` needs only `gmail.modify` and is enough for a first version.

### Triage actions

Every label change went out as `POST messages/batchModify`, even for a single message. Bodies were 52 to 57 bytes, the size of one message ID and one label. The call returns an empty 204, and the app followed each one with `messages.get format=metadata` for that message.

- Opening an unread thread: `threads.get` in full format, then `batchModify` to remove UNREAD.
- Star and unstar: one `batchModify` each.
- Archive: one `batchModify`. Selection moved to the next thread, which was fetched and marked read the same way.
- Undo: a second `batchModify` with the inverse change, about five seconds after the archive. The archive had already been sent, so undo reverses a change instead of cancelling a held request.

### Search

Search runs on the server. Each query, three of them about a second apart as the user typed, sent:

- `people:searchDirectoryPeople` over domain profiles and domain contacts, for people suggestions
- `messages.list` with `q` and `maxResults=500`

The first query's results came back through one `/batch` call (1.4 KB request, 64 KB response). The later queries matched few or no new messages and needed no batch call. Opening a result called `messages.get format=full`.

### Compose and send

- Recipient autocomplete used `people:searchDirectoryPeople`.
- The first autosave created the draft with a resumable upload: `POST /resumable/upload/gmail/v1/users/me/drafts`, then a `PUT` carrying the MIME message, about 24 KB.
- Later autosaves used the same two-step upload against `drafts/{id}`, about 2 KB each, 2 to 7 seconds apart while typing.
- After each save the app read the draft's metadata with `messages.get` and refreshed `drafts.list` with `maxResults=500`.
- Sending was `POST drafts/send` with a 71-byte body naming the draft. No SMTP connection was opened.
- The app then read the sent message's metadata and its thread.

### Remote content

Opening messages loaded their images and web fonts straight from the senders' servers through the Mimestream process, with no proxy. Senders can see the user's IP address and when a message was opened. This observation depends on the remote-content settings; the app does block known tracking pixels (see Message rendering).

## Message rendering

Each thread renders in a single WKWebView. The page talks to native code through 18 `webkit.messageHandlers`, covering:

- Selection and view state: `updateMessageSelection`, `updateViewState`, `firstPaintCompleted`, `domContentLoaded`
- Read state: `markMessagesRead`
- Attachments: QuickLook, download, open and copy, plus a context menu
- Links: `openURL`, `displayURL`
- Context menus for messages and addresses, and label chip removal
- Tracker info: `showBlockedTrackerInfo`, `showPossibleTrackerInfo`

The app blocks common tracking pixels and tells the user when it did. Info.plist allows arbitrary loads in web content only.

## UI structure

The main window has three panes.

- Sidebar: a Favorites section with Inbox, Starred, Drafts, Sent, All Mail, Spam and Trash, then a section per account listing user labels with unread counts.
- Message list: sender, date, subject, snippet, attachment chips, colored label chips and a star button per row. A filter button sits in the list header.
- Thread view: subject with removable label chips, sender avatar, recipients, attachment list and body.
- Toolbar: compose, archive, trash, move, label, reply, reply all, forward and a search field.

Menu commands:

- File: New Message, New Label, Attach Files, Export as PDF, Print.
- Message: Mark as Unread, Mark All as Read, Add Star, Mark as Important, Archive, Move to Trash, Report Spam, Edit Labels, Label, Move to, Reply, Reply All, Forward, Forward as Attachment, Open in Gmail, Copy Link, Copy Gmail Link, Filter Messages Like These, Send Again, Send and Archive.
- View: Raw Source, Collapse Messages, Show with Light Background, Show Format Bar, Cc and Bcc fields, Filter, Show Message Account, Show Message Size, Show Importance Marker, toolbar, sidebar and viewing pane toggles.
- Go: the system mailboxes and Go to Folder.

Other features named in the UI strings: profiles, smart lists, saved filters, templates, signatures, snooze, swipe actions, inbox categories, undo send delay, vacation responder, blocked addresses, an address suggestions blocklist, notification schedules, the calendar invitation banner, Writing Tools and Markdown compose. The app links FoundationModels, Apple's on-device model, but no summarization strings appeared, so what it uses the model for is unknown.

## Implications for our client

1. Build natively in Swift 6 and SwiftUI, dropping to AppKit for the message list and window chrome where SwiftUI falls short. Target macOS 14 or later so the Observation framework is available.
2. Use AppAuth and GTMAppAuth with a custom-scheme redirect. Start with `gmail.modify` and add settings, contacts and calendar scopes when those features ship. Ask for the full mail scope only if we adopt IMAP IDLE.
3. Store the message cache in SQLite through GRDB, in our own schema. Keep accounts, identities and snoozes in a separate small store so the cache can be rebuilt without losing them.
4. Add an FTS5 index over cached subjects, senders, snippets and bodies. Mimestream has no local index and sends every search to Gmail, so local search is a place to do better. Fall back to `messages.list` with `q` for mail outside the cache.
5. Sync with `history.list` from a stored cursor, fetch metadata first, read many messages in one `/batch` request, and load bodies on demand. Gmail settings change rarely and can refresh less often than every pass.
6. Route every label change through a local action queue that applies it to the UI first and replays it with `messages.batchModify`, with retries. Undo sends the inverse change. Since `batchModify` returns no body, confirm the new state with a metadata read or the next history call.
7. Autosave drafts on a typing pause with `drafts.create` and `drafts.update`, and send with `drafts.send`. Mimestream uses resumable uploads; a multipart upload is enough for messages under 5 MB.
8. Detect changes in version 1 by polling `history.list` on app activation and on a timer. IMAP IDLE on INBOX, used only as a signal, is the next step and costs the full mail scope.
9. Render each thread in one WKWebView with our own bridge, sanitize HTML with SwiftSoup, and block remote images by default with a per-sender opt-in.
10. Use an original name, icon and visual design.

Google treats `gmail.modify` as a restricted scope. Personal use works with an OAuth client in testing mode (up to 100 test users). Public release requires Google's app verification and a yearly security assessment.

## Proposed milestones

1. Read and triage: sign-in, sidebar with labels, thread list, thread view, archive, trash, star, read and unread with undo, incremental sync by polling `history.list`.
2. Compose: new message, reply, reply all, forward, draft autosave and send through the Gmail drafts API, attachments, undo send.
3. Organize: search (local FTS5 plus Gmail queries), label management, multiple accounts, snooze, keyboard shortcuts.
4. Integrations: IMAP IDLE as a new-mail signal, Gmail settings (filters, vacation, signatures), contacts autocomplete, calendar invitation banner.
