# Milestone 1 plan: read and triage

Status: draft, awaiting approval. Research input: `docs/research/mimestream-behavior.md`.

## Scope

In scope: Google sign-in for one account, a label sidebar, a thread list per label, a thread view, archive, trash, star, read and unread with undo, and incremental sync by polling `history.list`.

Out of scope for this milestone: compose, search, multiple accounts, snooze, IMAP IDLE, contacts, Gmail settings, notifications. The schema and module boundaries leave room for them.

## Decisions

| Area | Choice | Why |
|---|---|---|
| Platform | macOS 14+, Swift 6 language mode, SwiftUI with AppKit where needed | Observation framework, strict concurrency |
| Project | XcodeGen `project.yml` for the app, one local Swift package for logic | Reviewable project file, logic testable with `swift test` |
| Auth | AppAuth 3.0.0 + GTMAppAuth 6.0.0, custom-scheme redirect, tokens in Keychain | Google's supported path for native apps |
| Scope | `gmail.modify` plus `openid email profile` | Enough for read, labels and triage |
| Storage | GRDB 7.11.1, two SQLite files: `config.sqlite` and `cache.sqlite` | The cache can be deleted and rebuilt without losing accounts |
| HTML | SwiftSoup 2.14.3 to sanitize, WKWebView to render | Remote content blocked by default |
| Design | Spacing, radius and motion tokens mirrored from `~/.claude/uiux-contract/design_tokens.json`; macOS semantic colors and text styles for color and type | The contract targets web; native semantic colors handle dark mode, contrast and accent color |

Versions are the latest tags as of 2026-10-29 and get pinned in `Package.resolved`.

## Layout

```
project.yml                 XcodeGen spec
Config/                     Base.xcconfig, Secrets.example.xcconfig (Secrets.xcconfig is git-ignored)
App/                        App target: entry point, views, auth glue, Info.plist, entitlements
Packages/Core/
  Sources/GmailAPI/         REST client, Codable models, multipart /batch, error mapping
  Sources/MailStore/        GRDB schema, migrations, queries, observation
  Sources/SyncEngine/       Initial sync, history sync, action queue
  Tests/                    Focused tests per target
```

`GmailAPI` depends on nothing but Foundation. `MailStore` depends on GRDB. `SyncEngine` depends on both. The app target depends on all three plus AppAuth, GTMAppAuth and SwiftSoup. Auth stays in the app target behind an `AccessTokenProvider` protocol that `GmailAPI` defines, so the package never imports AppAuth.

## Data model (cache.sqlite)

- `label`: account, Gmail label ID, name, type (system or user), color, counts.
- `message`: account, ID, thread ID, history ID, internal date, snippet, from, to, subject, size.
- `message_label`: account, message ID, label ID. Indexed on (account, label ID).
- `thread`: account, ID, last date, subject, snippet, participants, message count, unread flag. Rebuilt from its messages whenever they change.
- `thread_label`: account, thread ID, label ID, last date. Indexed on (account, label ID, last date DESC) for the list query.
- `message_body`: account, message ID, sanitized HTML, plain text, fetched date. Filled on demand.
- `pending_action`: ID, account, kind, message IDs, labels to add, labels to remove, state, attempts, last error, created date.
- `sync_state`: account, history ID, last full sync date.

`config.sqlite` holds `account` (Google user ID, email, display name, granted scopes). Tokens live in the Keychain through GTMAppAuth, not in SQLite.

## Sync

Initial sync:

1. `users.getProfile` to record the current history ID first, so nothing that changes during the listing is missed.
2. `labels.list`.
3. `messages.list` with `q=newer_than:30d`, paged at 500.
4. Message metadata through `/batch`, 50 requests per batch, `format=metadata` with From, To, Subject and Date headers.
5. Write messages and rebuild the affected threads in one transaction per batch.

Incremental sync runs on app activation and every 60 seconds while the app is active:

1. `history.list` from the stored history ID, all pages.
2. `messagesAdded`: fetch metadata through `/batch`. `messagesDeleted`: delete. `labelsAdded` and `labelsRemoved`: update `message_label`.
3. Re-apply pending actions on top, so a server snapshot never hides a local change that has not been sent yet.
4. Rebuild affected threads, store the new history ID.
5. A 404 from `history.list` means the cursor expired: run the initial sync again.

Opening a thread calls `threads.get` in full format, stores sanitized bodies and queues a mark-read action.

## Action queue

1. A user action writes the label change to `message_label`, rebuilds the thread and inserts a `pending_action` row in one transaction. The UI updates from the database.
2. A sender drains the queue with `messages.batchModify`. Success deletes the row. Rate limits and 5xx errors retry with backoff. A permanent error reverts the local change and shows a message.
3. Undo within the toast window: if the action has not been sent, delete the row and revert. If it was sent, queue the inverse change.
4. Sends wait 2 seconds before draining, so a quick undo usually cancels the request.

Trash uses `batchModify` adding TRASH and removing INBOX, which matches Gmail's trash semantics for this scope without needing the delete permission.

## UI

- `NavigationSplitView` with three columns: sidebar, thread list, thread view.
- Sidebar: system labels (Inbox, Starred, Sent, Drafts, All Mail, Spam, Trash) then user labels, with unread counts.
- Thread list: SwiftUI `List` backed by a GRDB observation, rows with sender, subject, snippet, date and unread and star markers. If scrolling large labels is slow, swap in an `NSTableView` behind the same model.
- Thread view: one WKWebView per thread. Sanitized HTML, a Content-Security-Policy that blocks remote loads, and a content rule list as a second layer.
- Toolbar and menu commands with keyboard shortcuts for archive, trash, star and read state. Undo through the standard Edit menu and a toast.
- States: signed out, first sync in progress, empty label, offline, error.

## Phases

Each phase ends with its checks passing and your approval before the next starts. No phase touches more than five source files plus generated files.

| # | Phase | Files | Check |
|---|---|---|---|
| 0 | Repo setup: `git init`, `.gitignore`, project `CLAUDE.md`, `project.yml`, xcconfigs | 5 | `xcodegen generate` |
| 1 | App shell: entry point, three-pane window with sample data, design tokens, Info.plist, entitlements | 5 | `xcodebuild build`, launch and screenshot |
| 2 | `GmailAPI`: package manifest, models, client, batch codec, tests | 5 | `swift test` |
| 3 | Sign-in: auth service, Keychain session, token provider, sign-in view | 4 | Build; live sign-in once the OAuth client exists |
| 4 | `MailStore`: schema and migrations, queries, observation, tests | 4 | `swift test` |
| 5 | `SyncEngine`: initial and history sync, tests | 3 | `swift test`, live sync |
| 6 | Action queue and undo, tests | 3 | `swift test`, live triage |
| 7 | Wire the UI to the store, thread view with sanitizer | 5 | Build, live run |
| 8 | Code review pass and fixes | varies | Full build and tests |

The phases depend on each other in order, so they run one at a time rather than in parallel sessions.

## Tests

Tests cover failures that would corrupt the cache or lose a user action:

- Multipart `/batch` response parsing, including a failed part inside a successful batch.
- History application: label adds and removes, deletes, and the expired-cursor fallback.
- Pending actions surviving a history apply.
- Undo before and after send.

No UI snapshot tests and no tests for static views.

## What you need to do

- Pick the app name and bundle ID prefix.
- Before phase 3: in Google Cloud Console, create a project, enable the Gmail API, configure the OAuth consent screen in testing mode with yourself as a test user, and create an OAuth client of type iOS with the bundle ID. Put the client ID in `Config/Secrets.xcconfig`. Exact steps come with phase 3.

## Risks

- Google may limit custom-scheme redirects for some client types. Fallback: a loopback redirect with a desktop client.
- SwiftUI `List` performance on labels with thousands of threads. Fallback noted under UI.
- `gmail.modify` is a restricted scope, which is fine for personal testing but blocks public release until Google's verification.
