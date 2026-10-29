# Milestone 1 plan: read and triage

Status: approved 2026-10-29, revised after plan review. Research input: `docs/research/mimestream-behavior.md`.

## Scope

In scope: Google sign-in for one account, a label sidebar, a thread list per label, a thread view, archive, trash, star, read and unread with undo, and incremental sync by polling `history.list`.

Out of scope for this milestone: compose, search, multiple accounts, snooze, IMAP IDLE, contacts, Gmail settings, notifications. The schema and module boundaries leave room for them.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Platform | macOS 14+, Swift 6 language mode, SwiftUI with AppKit where needed | Observation framework, strict concurrency |
| Project | XcodeGen `project.yml` for the app, one local Swift package for logic | Reviewable project file, logic testable with `swift test` |
| Auth | AppAuth 3.0.0 with `ASWebAuthenticationSession` (presenting window), auth state archived to the Keychain by our own small store | No URL handling in the app; avoids GTMAppAuth's data protection keychain, which needs a team-signed build |
| Scope | `gmail.modify` plus `openid email profile`; granted scopes checked after sign-in | Enough for read, labels, triage and trash |
| Storage | GRDB 7.11.1 `DatabasePool`, two SQLite files: `config.sqlite` and `cache.sqlite` | The cache can be deleted and rebuilt without losing the account |
| HTML | SwiftSoup 2.14.3 in a package target; raw parts stored, sanitized at render time | Sanitizer fixes apply to cached mail and are testable with `swift test` |
| Design | Spacing, radius and motion tokens mirrored from `~/.claude/uiux-contract/design_tokens.json`; macOS semantic colors and text styles for color and type | The contract targets web; native semantic colors handle dark mode, contrast and accent color |

Versions are the latest tags as of 2026-10-29 and are pinned by `Package.resolved`.

## Layout

```
project.yml                 XcodeGen spec
Config/                     Base.xcconfig, Secrets.example.xcconfig (Secrets.xcconfig is git-ignored)
App/                        App target: entry point, views, auth glue
Packages/Core/
  Sources/GmailAPI/         REST client, Codable models, multipart /batch, error mapping
  Sources/MailStore/        GRDB schema, migrations, queries, observation
  Sources/MessageContent/   MIME walk, charset decoding, HTML sanitizer, entity decoding
  Sources/SyncEngine/       Initial sync, history sync, action queue, scheduler
  Tests/                    Focused tests per target
```

`GmailAPI` imports only Foundation. `MailStore` depends on GRDB. `MessageContent` depends on SwiftSoup. `SyncEngine` depends on all three. Auth stays in the app target behind the `AccessTokenProvider` protocol from `GmailAPI`. GRDB record types live in the package so the app's actor isolation defaults never apply to them.

## Data model

`cache.sqlite`:

- `label`: account, Gmail label ID, name, type, color, unread and total thread counts from `labels.get`.
- `message`: account, ID, thread ID, history ID, internal date, snippet (entities decoded), from, to, subject, size. Index on (account, thread ID).
- `message_label`: account, message ID, label ID, cascading on message delete. Holds server state only.
- `pending_action`: ID, account, kind, target thread IDs and message IDs, labels to add and remove, the per-message diff it caused, state (`queued`, `sending`, `sent`), attempts, last error, created and sent dates.
- `thread`: account, ID, last date, subject, snippet, participants, message count, unread and starred flags.
- `thread_label`: account, thread ID, label ID, last date. Index on (account, label ID, last date DESC, thread ID).
- `message_body`: account, message ID, raw HTML and plain text parts (decoded to UTF-8), fetched date.
- `sync_state`: account, history ID, last full sync date.

`thread` and `thread_label` are derived. They are rebuilt from `message_label` with unconfirmed pending actions overlaid, so a revert or an undo before send is "delete the row, rebuild". A message in TRASH or SPAM lists its thread only under that label; every other message lists the thread under its own labels and All Mail. So a thread with one trashed reply shows in both Inbox and Trash. All Mail is virtual: every thread with a message outside TRASH and SPAM.

`config.sqlite` holds `account` (Google user ID, email, display name, granted scopes). The OAuth state lives in the Keychain.

## Sync

One `SyncEngine` actor per account runs one pass at a time. Each pass fetches from the network first, then applies all changes and the new cursor in one write transaction. The cursor only moves forward.

Initial sync:

1. `users.getProfile`, holding its history ID in memory.
2. `labels.list`, then `labels.get` for every label through `/batch` for counts.
3. `messages.list` for all of INBOX, capped at 5,000 messages, then `q=newer_than:30d` with `includeSpamTrash=true`.
4. Metadata through `/batch` (`format=metadata`, headers From, To, Cc, Subject, Date).
5. Commit messages, threads and the held history ID together. If the app quits first, the next launch starts the initial sync over.

Incremental sync runs at launch, on app activation and every 60 seconds while the app runs:

1. `history.list` from the stored cursor, all pages.
2. `messagesAdded`, and label changes on messages not in the cache: fetch metadata through `/batch`. `messagesDeleted`: delete. Label changes on cached messages: update `message_label`. Skip metadata older than the stored message history ID.
3. Store the response's `historyId`, also when the page had no records.
4. Drop `sent` pending rows whose send finished before this pass started, then rebuild affected threads.
5. A 404 from `history.list` means the cursor expired: rerun the initial sync, delete cached messages the listings did not return, and keep pending rows.
6. Refresh label counts with batched `labels.get`.

`/batch` rules: at most 25 calls per batch, one batch at a time, parts matched by `Content-ID`. A part 404 means the message is gone. Part 429 and 5xx responses are retried with backoff; other part errors fail the pass without moving the cursor.

Opening a thread calls `threads.get` in full format, stores the decoded body parts and queues a mark-read action.

## Action queue

1. A user action inserts a `pending_action` row in the `queued` state and rebuilds the affected threads in one transaction. It records the per-message label diff against server state, which undo uses.
2. A sender drains the queue after a 2-second hold, so a quick undo cancels the request. Archive, read, unread and label changes use `threads.modify`, so messages outside the cache change too. Trash uses `threads.trash`. Star adds STARRED to the newest message with `messages.batchModify`; unstar removes it from the whole thread with `threads.modify`. Several threads go out as one `/batch`.
3. Success marks the row `sent`. Rate limits, 5xx and network errors retry with backoff. A permanent error deletes the row, rebuilds and shows a message.
4. Undo: a `queued` row is deleted and the threads rebuilt. A `sending` or `sent` row gets an inverse action built from its recorded diff, with `threads.untrash` for trash.
5. When the token refresh fails with `invalid_grant` (testing-mode refresh tokens expire after 7 days), the app shows the signed-out state and keeps the cache and the queue.

## UI

- `NavigationSplitView` with three columns: sidebar, thread list, thread view.
- Sidebar: Inbox, Starred, Sent, Drafts, All Mail, Spam and Trash, then user labels, with unread counts from `labels.get`.
- Thread list: SwiftUI `List` backed by a GRDB observation, rows with sender, subject, snippet, date and unread and star markers. If scrolling large labels is slow, swap in an `NSTableView` behind the same model.
- Thread view: message headers in SwiftUI, each message body in its own WKWebView sized to its content. Page JavaScript is off, a Content-Security-Policy and a content rule list block remote loads, and link clicks open in the default browser. Older messages start collapsed.
- Toolbar and menu commands with keyboard shortcuts for archive, trash, star and read state. Undo through the Edit menu and a toast.
- States: signed out, first sync in progress, empty label, offline, error.

## Phases

The user asked for an end-to-end build without stops between phases. Each phase still ends with its checks passing and a commit.

| # | Phase | Check |
|---|---|---|
| 0 | Repo setup: git, `.gitignore`, project `CLAUDE.md`, `project.yml`, xcconfigs | `xcodegen dump` |
| 1 | App shell: entry point, three-pane window, design tokens | Build, launch, screenshot |
| 2 | `GmailAPI`: models, client, batch codec, tests | `swift test` |
| 3 | `MailStore`: schema, migrations, derived threads, queries, tests | `swift test` |
| 4 | Sign-in: AppAuth flow, Keychain store, token provider, account record | Build; live sign-in once the OAuth client exists |
| 5 | `MessageContent`: MIME walk, charsets, sanitizer, tests | `swift test` |
| 6 | `SyncEngine`: initial and history sync, action queue, scheduler, tests | `swift test` |
| 7a | UI: sidebar, thread list, commands, undo toast | Build, launch |
| 7b | UI: thread view and rendering | Build, live run |
| 8 | Code review pass and fixes | Full build and tests |

The phases depend on each other in order, so they run one at a time.

## Tests

Tests cover failures that would corrupt the cache or lose a user action:

- `/batch`: parts matched by `Content-ID` out of order, a 404 part, a 429 part, a missing part.
- Error mapping: 401 retried once with a forced refresh; 403 `rateLimitExceeded` treated as retryable.
- History application: label adds and removes, deletes, unknown messages, an empty page that still moves the cursor.
- Expired-cursor resync: stale rows removed, pending rows kept.
- Action queue: undo while queued, undo while the send is in flight, undo after trashing from a non-inbox label.
- Sanitizer: one fixture with a remote `img`, `srcset`, CSS `url()`, `meta refresh` and a script.

No UI snapshot tests and no tests for static views.

## What you need to do

Before live sign-in, in Google Cloud Console:

1. Create a project and enable the Gmail API.
2. Configure the OAuth consent screen in testing mode and add yourself as a test user.
3. Create an OAuth client of type iOS with bundle ID `dev.tern.mail`.
4. Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `GOOGLE_CLIENT_ID_PREFIX`.

## Risks

- Google may limit custom-scheme redirects for some client types. Fallback: a loopback redirect with a desktop client, which needs the `network.server` entitlement.
- Ad-hoc signed builds change signature on every build, so the Keychain asks for access after a rebuild. Setting `DEVELOPMENT_TEAM` in `Secrets.xcconfig` fixes that.
- SwiftUI `List` performance on labels with thousands of threads. Fallback noted under UI.
- `gmail.modify` is a restricted scope, which is fine for personal testing but blocks public release until Google's verification.
