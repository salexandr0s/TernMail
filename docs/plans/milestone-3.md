# Milestone 3 plan: organize

Status: approved 2026-10-29 after a plan review. Research input: the search, labels and snooze notes in `docs/research/mimestream-behavior.md` (behavior only). Branch `feat/milestone-3`, cut from `feat/milestone-2` at `56bfa59`. Milestone 2 has since moved to `1a0bbb9`: its compose lane is in and its app phases have started. Gate A below handles merging.

## Scope

In scope:

- Search over cached mail with a local SQLite FTS5 index, plus Gmail's own search for mail outside the cache. Both take Gmail's search syntax.
- A "Load older conversations" row at the end of a mailbox or label list that pages in older mail from Gmail, so a label isn't limited to what the cache holds.
- Labels: create, rename, recolor and delete; nested labels shown as an outline; Edit Labels and Move to for selected conversations.
- Snooze: Tern keeps its own snooze records, archives the conversation, and moves it back to the Inbox at the chosen time.
- Several Google accounts at once, with combined mailboxes.
- Menu shortcuts for the new commands, a Go menu, and optional Gmail-style single-key shortcuts.

Out of scope: downloading every message body in the background so local search covers all bodies (answered question 1), saved searches, search history and suggestions, filters, label visibility settings, reporting spam, syncing snoozes with Gmail's own snooze (the API has none), notifications, send-as aliases (milestone 4), and audit item A24 (`cid:` images).

## Gmail API facts this plan relies on

Checked against Google's reference pages (`developers.google.com/workspace/gmail/api/reference/rest/v1/…`) and the guides they link on 2026-10-29:

- `labels.create` (`POST users/me/labels`, returns the new Label), `labels.patch`, `labels.update` and `labels.delete` accept `gmail.modify`, as do `threads.list`, `messages.list`, `threads.get`, `threads.modify` and `messages.batchModify`. The labels guide says label management needs `gmail.labels`, but every reference page lists `gmail.modify` as sufficient. Live testing confirms it.
- `labels.delete` "Immediately and permanently deletes the specified label and removes it from any messages and threads that it's applied to." There is no restore call.
- Label `color` applies to user labels only. Setting it needs both `textColor` and `backgroundColor`, each one of 102 allowed hex values (one list for both).
- System labels can't be created, changed or deleted, and creating a label with a system label's name fails with 400. Users can add and remove INBOX and UNREAD but not SENT or DRAFT. A mailbox holds at most 10,000 labels.
- `labelListVisibility` is `labelShow`, `labelShowIfUnread` or `labelHide`; `messageListVisibility` is `show` or `hide`.
- `messages.list` and `threads.list` take `q`, which "supports the same query format as the Gmail search box", and `maxResults` up to 500 (default 100). `q` isn't available with `gmail.metadata`, which Tern doesn't use.
- The filtering guide says dates in `q` are read as midnight Pacific time and recommends epoch seconds for other time zones (`after:1388552400`). The API supports most, not all, of the web search syntax and doesn't expand aliases.
- `threads.modify` takes up to 100 label IDs per list and changes every message in the thread.
- Quota is 6,000 units per user per minute. `threads.list` costs 10, `messages.list` 5, `threads.get` 10, `threads.modify` 10, and `labels.create`, `labels.update` and `labels.delete` 5 each. `labels.patch` isn't listed.
- The API has no snooze call and no SNOOZED label. `in:snoozed` appears only in the web search help.

Not stated on the current pages, so checked in live testing (the plan works either way): the status Gmail returns for a duplicate label name (409 expected), whether a `labels.patch` with only `name` leaves the color alone, whether `"color": null` in a patch removes a color, whether renaming a parent label renames its `Parent/child` labels, and whether `in:snoozed` works through the API.

## Decisions

### Search

| Area | Choice | Why |
|---|---|---|
| Scope | No new OAuth scope | `gmail.modify` covers every call in this plan |
| Local index | An FTS5 table over a `messageText` content table with subject, sender, To, Cc, snippet and body text. `unicode61` tokenizer with diacritics removed, prefix indexes of 2 and 3 characters | FTS5 works with GRDB 7.11.1 here (a throwaway test on 2026-10-29 covered prefix, phrase, column filter, diacritics and cascade deletes). Separate columns turn `from:`, `to:`, `cc:` and `subject:` into column filters |
| Metadata in the index | Plain SQL triggers copy metadata when a `message` row is inserted, and on update only `WHEN` an indexed column actually changed. Deletes cascade from `message` | Every metadata write path, including history sync, updates the index. GRDB's `update` and `upsert` write every column, so without the `WHEN` guard each mark-read would re-index the whole row, body included |
| Body in the index | `saveBodies`, the only code that writes `messageBody`, also writes the body text into `messageText` in the same transaction. The migration's backfill does the same for stored bodies | Keeps Swift out of triggers: GRDB registers functions without `SQLITE_INNOCUOUS`, so a trigger calling one could fail under `trusted_schema=OFF`, and any connection lacking the function couldn't write bodies |
| Body text | The plain text part when there is one, otherwise the HTML with `script`, `style` and `head` contents dropped, tags turned into spaces and entities decoded. Capped at 100,000 characters per message | A linear pass is cheap enough for the write transaction; SwiftSoup would build a DOM per message |
| Body coverage | Bodies are indexed when a conversation is opened, as they're stored now. Local search covers metadata for all cached mail and bodies of opened messages; Gmail's results fill in the rest | Fetching every body would multiply sync traffic. See answered question 1 |
| Query syntax | One parser for Gmail's syntax: words, quoted phrases, `-`, `OR`, `{ }`, `( )`, `AND` and operators, with `OR` binding tighter than the implied `AND` as in Gmail. Only known operator names count as operators, so `10:30` stays a word | A single parser keeps the local and Gmail sides reading the same query |
| Local or Gmail only | A query runs locally only when every part has an exact local meaning. Gmail alone answers queries with an operator outside the local list, or with a negated word or phrase (`-invoice`), since an unopened message's body isn't indexed and would wrongly match | Gmail's results only add to the list, so a wrong local match would stay visible. The local side answers a whole query or none of it |
| Local operators | `from:`, `to:`, `cc:`, `subject:`, `label:`, `category:`, `is:unread`, `is:read`, `is:starred`, `is:important`, `in:inbox`, `in:sent`, `in:drafts`, `in:trash`, `in:spam`, `in:anywhere`, `after:`, `before:`, `newer:`, `older:`, `newer_than:`, `older_than:` | These map exactly onto cached columns and labels. `has:attachment` stays on Gmail because attachment rows exist only for opened messages, and `size:`, `larger:` and `smaller:` would only have Gmail's size estimate |
| Matching | Message level, as in Gmail: a conversation matches when one of its messages matches. Label operators read each message's labels as Gmail last reported them, so a queued change shows in results after the next sync pass confirms it (the poll runs every 60 seconds) | Thread labels are a union over messages and would over-match `from:a is:unread` |
| Trash and spam | Left out unless the query has `in:trash`, `in:spam` or `in:anywhere`, as in Gmail. The Gmail request sets `includeSpamTrash` by the same rule | Same results on both sides |
| Dates | `after:`, `before:` and the relative forms use the Mac's time zone. Tern rewrites them to epoch seconds before sending `q` to Gmail | Otherwise Gmail reads them as Pacific midnight and the two sides disagree near day boundaries |
| Prefix matching | The last bare word matches as a prefix while typing ("tra" finds "trail"). Other words and operator values match whole words | Search as you type needs it. Gmail doesn't do it, so local results can include a few extra conversations |
| Gmail search | `threads.list` with `q`, 25 conversations per page, then batched `threads.get` in metadata format for conversations not in the cache and not already fetched for this search. Later pages load from a "Load more from Gmail" row. Gmail is asked on Return, or 1 second after typing stops once the query has 3 characters; a newer query cancels an older request. A 429 shows "Gmail is busy" and isn't retried automatically | The brief named `messages.list`. `threads.list` pages by conversation, which is what the list shows; `messages.list` would need grouping and can split a conversation across pages. A page costs at most 260 units, so search can't use up the 6,000-unit quota that sync and the queue share |
| Merging | Results are a set of (account, thread) keys: local matches plus Gmail's. The list shows each conversation once, from the cache, newest first. Gmail's results only add to the list | Both sides point at the same cached rows, so a conversation can't appear twice |
| Mail fetched for search | Stored like synced mail, with a `cacheHold` row (reason `search`) that expires 24 hours after the last Gmail page that returned it. Full sync's prune skips held conversations, and full sync refetches their messages along with its own list (404 means gone). After each sync pass, conversations with expired holds lose their messages unless an open search or list shows them, or full sync would keep them: Inbox, Drafts, the last 30 days, a queued change, a local draft or another hold | Without a hold, the next full sync deletes results the user is looking at; without the refetch, a held conversation could keep stale labels; without expiry, every search grows the cache for good |
| Search scope | The whole account, or every account in a combined mailbox, as in Gmail, not the selected label. `label:` and `in:` narrow it | The same query then means the same thing locally and on Gmail |
| Search privacy | Search terms are never logged or stored, and there's no search history. `GmailClient`'s default transport becomes an ephemeral `URLSession` with no URL cache | `q` travels in a GET URL, and `URLSession.shared`'s cache may write responses, keyed by URL, to disk. This also keeps message bodies out of that cache |

### Labels

| Area | Choice | Why |
|---|---|---|
| Label changes | `createLabel`, `updateLabel` and `deleteLabel` are new kinds in the existing queue, in the labels lane. Each label row goes out on its own, never merged with other rows | One path for every Gmail change (project rule). The queue orders rows only within a lane. The current delivery merges rows with the same kind and label lists and sends only the first, which would drop all but one label change |
| Displayed labels | The `label` table keeps Gmail's labels as last listed. What the sidebar and pickers show is that list with queued, sending and sent label rows applied on top, computed when read. A sent row stays until a sync pass that started after it was sent commits, as label changes on conversations already do | Mirrors `messageLabel` plus the thread overlay. A `labels.list` response fetched before a change finished can't revert it, and a failed change just drops its row, so a later rename stacked on it still shows what Gmail will have |
| New label IDs | A new label gets a temporary ID (`TERN_PENDING_…`) until Gmail answers. Rows that add or remove it wait behind the create. On success one transaction records the pair in `labelAlias`, swaps the real ID into queued rows and live undo receipts, and rebuilds the affected conversations. Queuing a row or an undo resolves label IDs through `labelAlias`, and delivery never sends an ID with the temporary prefix. Aliases are cleared at launch. The sidebar shows a pending label dimmed and not selectable | Undo builds its inverse from the receipt once the row is gone, and an Edit Labels popover may still hold the temporary ID after the swap. The alias table covers both, and the delivery check is the last line of defense |
| Ordering | Label rows take an exclusive key on their label. Changes to conversations take a shared key on each user label they add or remove. A child's rename row also takes a shared key on its parent's label. Shared keys don't block each other; exclusive keys block both kinds | Applying one label to many conversations still goes out together, while a rename or delete waits for older uses of that label, and children are renamed after their parent |
| Create failures | Only a definite refusal (`400`, `409`, or a `403` that isn't a rate limit) leads to adoption or revert: Tern lists labels and adopts one whose name matches ignoring case; otherwise it drops the row and the queued uses of the label and shows Gmail's message. A retry after an unclear response also tries adoption first. Sign-in, rate limit, server and network errors retry as other rows do | A create repeated after a lost response must not end in an error or a second label, and a rate limit must never discard the user's changes |
| Names | Create and rename check that the name isn't empty, isn't a system label's name and isn't taken, ignoring case | Gmail rejects these; checking first gives a clear message without a round trip |
| Rename | `labels.patch` with the new name. Renaming `Work` also renames the `Work/…` labels, one row each, under one undo | Gmail stores nesting in the name. If Gmail already renames children itself, the extra patches change nothing |
| Color | The picker offers the 64 colors of the documented 8×8 grid (the first 64 allowed values). Text is black or white, whichever contrasts more; both are allowed values. "No color" sends `"color": null` | Gmail rejects other values. Removal is unverified: if it fails in live testing, "No color" goes, and so does undo of a label's first color |
| Undo | Create: undo deletes the new label. Rename and color: undo patches the old values back. Delete: no undo, and a confirmation names the label and says Gmail can't restore it | `labels.delete` is permanent |
| Delete | The label leaves the sidebar and the conversations at once. On success its `messageLabel` rows go, queued rows that used it drop it, and a row left with no labels to change is deleted rather than sent. On failure the label comes back | Gmail may not send history records for a deleted label, so the cache cleans up itself |
| Edit Labels | One `modifyThreads` row per conversation, as the queue already does, under one undo. A label on some but not all selected conversations shows a mixed state; leaving it mixed changes nothing | Mixed states need a different change per conversation |
| Move to | Adds the target and removes the label of the mailbox being viewed when that is the Inbox or a user label, otherwise INBOX. Targets are the Inbox and user labels | The conversation leaves the list it was moved from, which is what moving means in a label-based mailbox |

### Snooze

| Area | Choice | Why |
|---|---|---|
| Where snoozes live | The working copy is a `cacheHold` row with reason `snooze` and the wake time. A `snooze` table in `config.sqlite` keeps a durable copy. The Snoozed list reads the cache only | `config.sqlite` survives a cache reset; reading one database keeps the list a single query |
| Snoozing | One cache transaction queues the archive and writes the hold with its wake time. The config record is written next. At launch, a hold without a record gets one | Two databases can't share a transaction. With this order a crash between the writes loses nothing, since the hold already knows the wake time |
| Waking | One cache transaction checks the conversation's current labels (with queued changes applied), queues add-INBOX unless it's in Trash or Spam, writes a `wokenThread` row and drops the hold. The config record is deleted after. Waking twice adds INBOX twice, which changes nothing | A conversation trashed just before its wake time stays in Trash, and a crash between the two writes repeats a harmless step |
| Sorting woken mail | A `wokenThread` row sorts the conversation by its wake time, with a clock icon, until it leaves the Inbox | Otherwise an old conversation wakes far down the Inbox where nobody sees it |
| When to check | A `SnoozeKeeper` per account checks at launch, at the next wake time, after each sync pass and when the Mac wakes. Overdue snoozes wake at launch | Tern can't wake anything while it isn't running |
| Ending early | If a snoozed conversation is in the Inbox again before its wake time, reading labels with queued changes applied (new mail arrived, or it was moved there in Tern or in Gmail), the snooze ends. It also ends, without changes, if `threads.get` says the conversation is gone | Matches Gmail, where a reply brings a snoozed conversation back. Reading queued changes means a snooze whose archive hasn't reached Gmail yet isn't ended by mistake, and "gone" never means "missing from the cache" |
| After a cache reset | Records without a hold get their conversation fetched and held again before any check uses them | The first launch after a reset must not end every snooze |
| Gmail's snoozes | Snoozes made in Gmail look archived in Tern. Tern's snoozes don't show in Gmail or on other devices, and the Snoozed list says so | The API exposes neither direction |

### Accounts

| Area | Choice | Why |
|---|---|---|
| Engines | One `SyncEngine` and one `SnoozeKeeper` per account, sharing one `cache.sqlite` | Every cache table already has `accountID`, apart from `outgoingAttachment`, which hangs off `localDraft` |
| Sessions | `GoogleAuth` splits into a sign-in coordinator and an `AccountSession` per account that implements `AccessTokenProvider` and owns its Keychain item | One expired session then can't block the other accounts |
| Identity | `ThreadKey(accountID, threadID)` identifies rows and selection. A mailbox is `.combined(id)` or `.account(accountID, id)`, where `id` is a label ID or one of the virtual mailboxes (All Mail, Outbox, Snoozed), each with its own data source | Gmail IDs are only unique within one mailbox, and SwiftUI lists need stable IDs |
| Sidebar | Changed in phase 10d at the owner's request. With one account, a flat list as before. With more, one mailbox list: Inbox, Starred, Snoozed, Sent, Drafts, All Mail, Spam and Trash appear once each, plus the Outbox while it has items. Each row shows every account's mail and expands to a row per account. A collapsed row's badge is the total; an expanded row leaves it to the account rows. Tern remembers which rows are expanded, and Inbox starts expanded. Below the list, each account's section holds its header and labels. Each system mailbox has its own color. Account rows use the account's color, from a fixed palette stored by account ID, and the part of its address before the @. Labels Gmail gives a color have filled tags | A mailbox sits in one place however many accounts there are; labels belong to one account |
| Mixed selections | Actions are grouped by account and go through each account's queue, with one notice and one undo | Undo should reverse what the user did, not part of it |
| Sign-out | Per account. Stops that account's keeper, search tasks and engine, in that order. Reads its local draft IDs, closes its compose windows, then deletes its cache rows, Keychain item, snooze records and `Outgoing/<draft>` folders. The confirmation counts its Outbox items and snoozed conversations, which stay archived in Gmail. At launch, cache rows for accounts no longer in `config.sqlite` are deleted | The other accounts keep working. Outgoing folders can only be found through local drafts, and the launch cleanup finishes a sign-out interrupted by a crash |
| Compose From | Replies and forwards keep the conversation's account, and From isn't editable for them. A new message starts with the selected mailbox's account (the first account in a combined mailbox) and From is a menu. Changing it after a save moves the draft in one cache transaction: a new local draft in the new account and a discard of the old Gmail draft through the old account's queue | A Gmail draft belongs to one mailbox, and a reply's thread ID only means something in its own account |
| Opening the cache | `MailCache.open` runs off the main actor during the loading phase | The `search-v1` backfill would otherwise freeze the window on the first launch after updating |

### Shortcuts, UI plumbing and migrations

| Area | Choice | Why |
|---|---|---|
| Menu shortcuts | Search ⌥⌘F, Edit Labels ⌥⌘L, Move to ⌃⌘M, Snooze ⌃⌘B, New Label ⌥⌘N, and a Go menu with ⌘1 to ⌘5 (Inbox, Starred, Snoozed, Drafts, Sent) | None collides with milestone 1, milestone 2 or a standard macOS shortcut. ⌃⌘S is Toggle Sidebar and ⌥⌘M is Minimize All, so both are avoided |
| Single keys | Off by default, turned on in Settings. An `NSEvent` monitor acts only when the main window is key with no sheet, the first responder isn't text (a field editor or text view), there's no marked text, and ⌘, ⌥ and ⌃ aren't held. Keys match by character, not key code | A stray "e" must never archive while the user types. Compose windows are other windows, so they never qualify |
| Search field | Our own `NSSearchField` toolbar item | SwiftUI's `searchFocused` needs macOS 15, and ⌥⌘F has to focus the field on macOS 14 |
| Migrations | Cache: `search-v1`, `labels-v1`, `wake-v1`. Config: `snooze-v1`. All registered after milestone 2's `compose-v1` | GRDB tracks migrations by name, and no other branch uses these |

## Rules for new cache writes

Search, Load older and the snooze keeper add three paths that write Gmail data into the cache. Each one:

- writes through the engine's `write` gate, so nothing lands after `stop()`;
- skips message IDs in the engine's deletion tombstones, so a slow response can't bring deleted mail back;
- fetches with `SyncEngine.metadataHeaders`, so the threading headers milestone 2 added aren't overwritten with nothing;
- stores messages and their hold in one transaction, so a prune can't run between the two;
- when releasing holds, re-checks holds, queued changes and local drafts inside the same write that deletes.

## Data model

`cache.sqlite`:

- `search-v1`:
  - `messageText`: integer row ID, account, message ID, subject, sender, To, Cc, snippet, body. Unique on (account, message ID), with a foreign key to `message` that cascades deletes.
  - `messageSearch`: FTS5 with `messageText` as external content, kept in step by GRDB's synchronization triggers.
  - Triggers on `message`: after insert, and after update when subject, sender, recipients, Cc or snippet changed.
  - `cacheHold`: account, thread, reason (`search` or `snooze`), expiry (search), wake time (snooze). Primary key (account, thread, reason).
  - The migration fills `messageText` from existing messages and stored bodies.
- `labels-v1`: `pendingAction` gains `labelID` and `labelChange`, a JSON value with the new and old name, the new and old colors, and the label's record for a delete. New table `labelAlias`: account, temporary ID, real ID.
- `wake-v1`: `wokenThread`: account, thread, woke at. Primary key (account, thread).

`config.sqlite`:

- `snooze-v1`: `snooze`: account (foreign key to `account`, cascading), thread, wake at, created at. Primary key (account, thread).

`deleteAccountData` adds `cacheHold`, `labelAlias` and `wokenThread`; `messageText` and the index go with `message`.

The thread list query sorts by the later of a conversation's last message date and its wake time. In phase 9f it takes a list of account IDs, so combined mailboxes use one query.

## Search flow

1. ⌥⌘F or a click focuses the search field. While it has text, the list shows results; Escape clears it and returns to the mailbox.
2. Each edit parses the query. If it runs locally, the compiled SQL runs against the accounts in scope and the list updates as the user types.
3. On Return, or one second after typing stops, each account in scope sends `threads.list` with the rewritten query. Conversations missing from the cache are fetched with batched `threads.get` in metadata format, then stored and held together.
4. The list shows the union, newest first. Its last row shows the Gmail side: searching, a "Load more from Gmail" row when Gmail returned a page token, or an error that says the results come from this Mac only.
5. Opening a result works like opening any conversation: `threads.get` in full format stores the bodies, which also indexes them.
6. Actions on results go through the queue as anywhere else.

"Load older conversations" at the end of a mailbox or label list calls `threads.list` with that label's ID and no `q`, stores and holds the page the same way, and keeps the page token while the list stays open.

## Label flows

- New Label (a `+` in the Labels header, the Mailbox menu, or "Create label" in Edit Labels) asks for a name, an optional parent and a color, then queues `createLabel`.
- Rename and Color in a label's context menu queue `updateLabel` rows.
- Delete asks for confirmation, then queues `deleteLabel` with no undo hold. A label with nested labels deletes only itself; its children stay and show at the top level under their full names.
- Edit Labels (⌥⌘L) opens a filterable checklist of user labels for the selected conversations.
- Move to (⌃⌘M) opens a filterable list of the Inbox and user labels.

## Snooze flow

1. Snooze (⌃⌘B, the toolbar or the context menu) offers Later Today (6 PM, shown before 5 PM), Tomorrow (8 AM), This Weekend (8 AM on the first day of the next weekend in the user's calendar, shown before it starts), Next Week (8 AM on the next first day of the week) and Choose Date & Time.
2. The archive and the hold are written together, then the config record. One undo removes all three.
3. The Snoozed mailbox lists snoozed conversations by wake time, each showing when it returns, with Unsnooze. A note there says snoozes stay on this Mac.
4. On wake, the conversation goes back to the Inbox through the queue, sorted by its wake time with a clock icon.

## Accounts flow

- Add Account (File menu and Settings) runs the sign-in coordinator. Signing in to an account that's already added refreshes its session instead of adding it twice.
- When one account needs to sign in again, its sidebar section says so and offers to sign in, with its address passed to Google as `login_hint`. If the user signs in as a different account, Tern says so and changes nothing. The other accounts keep syncing.
- Sign Out is per account, in Settings and in the account's sidebar context menu.

## Gmail API additions

In `GmailAPI`:

- `createLabel(name:color:)`: `POST labels` with `labelListVisibility: labelShow` and `messageListVisibility: show`.
- `patchLabel(id:name:color:)`: `PATCH labels/{id}` with only the given fields; a null color clears it.
- `deleteLabel(id:)`: `DELETE labels/{id}`. A 404 counts as done.
- `listThreads(query:labelIDs:includeSpamTrash:pageToken:maxResults:)`: `GET threads`.
- `threads(ids:format:metadataHeaders:)`: batched `GET threads/{id}` through the existing `/batch` path. `batchDecode` becomes internal so an extension file can use it.
- `LabelColor`: the 102 allowed values, the 64-color grid and the text color pairing.
- The default transport becomes an ephemeral `URLSession` without a URL cache.

`GmailService` gains the five calls. `FakeGmail` in the SyncEngine tests and `AuditGmail` for `--ui-audit` implement them.

## UI

- Search: the toolbar field, the results list and its Gmail row. In combined mailboxes each row names its account.
- Sidebar: labels as an outline split on "/", pending labels dimmed, a context menu with Rename, Color and Delete, and a `+` for New Label. With several accounts, one mailbox list whose rows expand to each account, then one section of labels per account. Snoozed sits under Starred.
- Edit Labels and Move to are popovers from toolbar buttons; the menu commands open the same popovers.
- Snooze is a toolbar menu with the presets and a date and time sheet.
- Settings gains an Accounts pane (list, Add Account, Sign Out) and a single-key shortcuts switch.
- Help ▸ Keyboard Shortcuts lists both the menu shortcuts and the single keys.
- VoiceOver labels on the new controls, and an announcement when a conversation is snoozed or comes back.
- Spacing, radius and motion from `App/Design/Tokens.swift`; colors and type from macOS semantic styles. Label colors are the one exception, since they come from Gmail.

Single keys, when turned on:

| Key | Action |
|---|---|
| j, k | Next, previous conversation |
| o, Return | Move focus to the open conversation |
| e | Archive |
| # | Move to Trash |
| s | Star or unstar |
| I, U (with Shift) | Mark read, mark unread |
| l | Edit Labels |
| v | Move to |
| b | Snooze |
| / | Search |
| c | New message |
| r, a, f | Reply, reply all, forward |
| z | Undo |
| ? | Keyboard Shortcuts |
| g then i, s, b, d, t, a | Inbox, Starred, Snoozed, Drafts, Sent, All Mail (second key within 1.5 seconds) |

## Phases

The user approves this plan before phase 1 starts. Each phase touches at most five files, counting tests but not the regenerated `Tern.xcodeproj` or `Package.resolved`, and must build on its own. Each ends with its checks passing and gets its own commit. If a phase turns out to need a sixth file, it splits and the handoff records the split.

Checks: "Core" is `swift test --package-path Packages/Core`. "App" is `xcodegen generate`, the Debug build, `TernTests`, then `swift test` last. "Launch" adds a run of the Debug build with `--ui-audit` and a look at the feature, with screenshots.

Milestone 2 gates: before each phase that changes a file milestone 2 also changes, I check whether `refs/heads/feat/milestone-2` has moved since the last merge. If it has, I stop and ask whether to merge it now or wait. If it hasn't, there is nothing to merge and the phase goes ahead (answered question 5). After any merge, the full checks run before the phase starts. Phases 9 and 10 also wait until milestone 2's app phases (5a to 5d) are committed, since accounts and shortcuts change the same app files.

| # | Phase | Files | Check |
|---|---|---|---|
| 1 | `MessageContent`: query parser with the local and Gmail-only split and the date rewrite; HTML to index text | `SearchQuery.swift`, `SearchText.swift`, two test files (all new) | Core |
| 2 | `GmailAPI`: label calls, `threads.list`, batched `threads.get`, color palette, ephemeral transport | `GmailClient+Labels.swift`, `GmailClient+Search.swift`, `LabelColor.swift`, a test file (new); `GmailClient.swift` | App |
| 3a | App: single-key interpreter (pure) and snooze presets (pure) | `SingleKeyShortcuts.swift`, `SnoozeSchedule.swift`, two test files (all new) | App |
| 3b | App: label editor sheet, label picker for Edit Labels and Move to, snooze picker, as standalone views taking plain values | Three new view files | App |
| Gate A | The first phase that changes milestone 2's files. Merge or wait, as above | | Full checks after a merge |
| 4 | `MailStore` search: `search-v1`, body text in `saveBodies`, the query compiler, holds, prune skipping held conversations. Times a 10,000-message insert and a 1,000-change history pass with and without the index | `Schema.swift`, `MailCache.swift`; `SearchIndex.swift`, `CacheHolds.swift`, a test file (new) | Core |
| 5a | `GmailService` gains the five calls; the two fakes implement them; the cache opens off the main actor | `GmailService.swift`, `SyncEngineTests.swift`, `AuditGmail.swift`, `AppModel.swift` | App |
| 5b | `SyncEngine` search: Gmail search with fetch and hold, label pages, full sync refetching held conversations, releasing expired holds after a pass | `SyncEngine.swift`; `SyncEngine+Search.swift`, a test file (new) | Core |
| 6a | Label kinds: `labels-v1`, the new kinds and fields, claim keys, deleted labels in the thread overlay, and the cases the exhaustive switches need. No label row is queued yet | `Schema.swift`, `Records.swift`, `MailCache.swift`, `ActionQueue.swift`, `ComposeQueue.swift` | App |
| 6b | Label behavior: displayed-label overlay, aliases and the ID swap, delivery one row at a time, adoption and revert, Edit Labels and Move to actions, undo. Tests cover 6a's claim keys too | `Queries.swift`, `ActionQueue.swift`; `LabelRules.swift`, `LabelQueue.swift`, a test file (new) | App |
| 7a | Store for snooze: `snooze-v1`, `wake-v1`, the snooze hold's wake time, the wake sort in the thread list query | `Schema.swift`, `Queries.swift`, `MailCache.swift`; `SnoozeStore.swift`, a test file (new) | Core |
| 7b | `SyncEngine`: `SnoozeKeeper` | `SnoozeKeeper.swift`, a test file (new) | Core |
| 8a | App search: field, results, Gmail row, Load older, ⌥⌘F | `MainView.swift`, `ThreadListView.swift`, `MailboxModel.swift`, `MailCommands.swift`; `SearchModel.swift` (new) | Launch |
| 8b | App labels: sidebar outline and context menu, New Label, Edit Labels, Move to, toolbar buttons, menu items. The 3b views are used unchanged; if they need changes, the phase splits | `SidebarView.swift`, `ThreadListView.swift`, `MailboxModel.swift`, `MailCommands.swift` | Launch |
| 8c | App snooze: keeper per account, Mac wake, Snoozed mailbox, snooze menu, clock icon | `AppModel.swift`, `MailboxModel.swift`, `SidebarView.swift`, `ThreadListView.swift`, `MailCommands.swift` | Launch |
| Gate B | Milestone 2's app phases are committed; merge as above | | Full checks after a merge |
| 9a | Cleanup commit for `MailboxModel.swift` (over 300 lines): dead code, unused imports and exports, debug logs (workspace rule 9) | `MailboxModel.swift` | App |
| 9b | Split `MailboxModel` into a per-account `AccountMailbox` and the window model, behavior unchanged | `MailboxModel.swift`, `AccountMailbox.swift` (new), `MailboxModelTests.swift` | Launch |
| 9c | Sessions: sign-in coordinator and `AccountSession` | `GoogleAuth.swift`, `AppModel.swift`, `KeychainStore.swift`; `AccountSession.swift` (new) | Launch |
| 9d | `ThreadKey` in thread selection and actions, still one account | `MailboxModel.swift`, `ThreadListView.swift`, `MainView.swift`, `MailCommands.swift`, `MailboxModelTests.swift` | Launch |
| 9e | Mailbox IDs (`.combined` and `.account`) in sidebar selection, still one account | `MailboxModel.swift`, `SidebarView.swift`, `ThreadListView.swift`, `MailboxModelTests.swift` | Launch |
| 9f | Several accounts: engines and keepers per account, combined sources, grouped actions and undo, the account list in the thread query, two fake accounts (the same fake mail in both, which exercises duplicate IDs) | `AppModel.swift`, `AccountMailbox.swift`, `MailboxModel.swift`, `Queries.swift`, `MailboxModelTests.swift` | Launch |
| 9g | Sidebar sections, account names on rows, sign-in again per account, per-account sign-out with launch cleanup, Add Account, distinct mail for the second fake account | `SidebarView.swift`, `ThreadListView.swift`, `MainView.swift`, `MailCommands.swift`, `AuditGmail.swift` | Launch |
| 9h | Compose From menu for new messages and moving a draft between accounts; Accounts pane in Settings | Milestone 2's `ComposeModel.swift` and `ComposeView.swift`, its Settings view, `Drafts.swift`, `ComposeQueue.swift`; split if Settings needs more | Launch |
| 10 | Single keys: event monitor, Go menu, Keyboard Shortcuts window, Settings switch | `MailCommands.swift`, `TernApp.swift`, milestone 2's Settings view; `ShortcutMonitor.swift`, `KeyboardShortcutsView.swift` (new) | Launch |
| 10d | Added after phase 10 at the owner's request. Sidebar regroup: one mailbox list with rows per account, remembered expansion, mailbox and account colors, filled label tags. All Mail, Spam and Trash join the combined mailboxes. Split into the app change and its tests to stay within five files | `SidebarView.swift`, `MailboxModel.swift`, `MailCommands.swift`, `AccountAppearance.swift` (new); then `MailboxModelTests.swift` and a test file (new) | Launch |
| 11 | Review pass and fixes | As found | Full checks |

Phases 1 to 3b add files, apart from phase 2's small change to `GmailClient.swift`, which milestone 2 doesn't touch. They run before any merge. Core phases that change an API the app calls use "App" checks.

## Tests

Tests target failures that would hide mail, lose a change, send a wrong label ID or act on the wrong account:

- Query parser: `OR` binds tighter than the implied `AND`; `-` on words, phrases and groups; `{ }` as `OR`; quoted operator values; `label:` with spaces and slashes written as dashes; date forms (`2026/01/15`, `01/15/2026`, `newer_than:3d`, months and years); unknown `word:value` stays text; a Gmail-only operator or a negated word makes the whole query Gmail-only, while `-from:` stays local; the date rewrite gives the right epoch in a given time zone.
- Body text: `script` and `style` text dropped, entities decoded, adjacent blocks don't glue words together, the cap holds.
- Index: insert, upsert, delete and body save keep the index right; a label-only change doesn't rewrite the index row; the migration fills it from an existing cache; an FTS integrity check passes; one account's search never returns another's mail; diacritics fold; only the last word is a prefix; Trash and Spam are left out by default; `after:` and `before:` use the given time zone.
- Holds: full sync's prune keeps held conversations and refetches them; a held message Gmail deleted goes; expired holds release only conversations nothing else keeps, and never one an open search shows; deleting an account clears its holds.
- Gmail search: missing conversations are fetched and held in one write, cached ones aren't fetched again; tombstoned IDs aren't stored; `includeSpamTrash` follows the query; dates go out as epoch seconds; the merged list has no duplicates; a newer query cancels an older one.
- Labels:
  - A change that adds a just-created label waits behind the create, then goes out with the real ID.
  - Undo after the original row is gone sends the real ID, and a row queued with the temporary ID after the swap is resolved through the alias.
  - Two label rows due together reach Gmail as two calls, and a parent rename with two children as three patches, parent first.
  - A `labels.list` response fetched before a create, rename or delete finished, and committed after, doesn't undo it.
  - A failed rename A→B under a queued B→C leaves the label showing C.
  - A create refused with 409 adopts the existing label; a 429 retries without dropping anything; a 400 with no match reverts and drops queued uses.
  - A delete waits behind older uses of the label; once it succeeds, the label is gone from conversations and newer queued rows, and rows left empty are deleted. A failed delete restores the label.
  - Shared label keys don't hold back two conversations getting the same label.
  - Colors outside the palette are rejected before any request.
- Snooze: snoozing writes the archive and hold together; a hold without a record gets one at launch; waking queues INBOX, writes `wokenThread` and drops the hold together; waking twice is harmless; a snooze whose archive is still queued isn't ended; INBOX coming back ends the snooze; a conversation trashed before its wake time stays in Trash; a record without a hold after a cache reset refetches instead of ending; undo removes all parts.
- Accounts: the same thread ID in two accounts gives two rows; actions on a mixed selection reach each account's queue and undo together; signing out of one account leaves the other's cache rows, Keychain item and snoozes alone; launch cleanup removes rows of an account no longer in `config.sqlite`.
- Snooze presets and single keys: the presets around evening, weekend and week boundaries; the `g` prefix and its timeout; Shift characters; keys with ⌘, ⌥ or ⌃ ignored.

No UI snapshot tests. The text-focus rule for single keys is checked by hand at launch, since it depends on AppKit's responder chain.

## What you need to do

- Nothing new in Google Cloud for search, labels or snooze.
- For several accounts: while the OAuth consent screen is in Testing, add each Google account you'll sign in with as a test user.
- Once the OAuth client exists, live testing covers the unverified API behaviors listed above, the scope accepted for label calls, and search results compared with Gmail's web search for a handful of queries.

## Risks

- Merging with milestone 2. Gates A and B handle it; `Tern.xcodeproj` conflicts are resolved by regenerating it.
- FTS5 on macOS 14. It's confirmed only on this Mac (system SQLite 3.54). The plan uses only features older than macOS 14's SQLite: external content tables, `unicode61` with `remove_diacritics 2` (SQLite 3.27), prefix indexes and column filters. It can't be tested on macOS 14 here.
- Index writes slow down sync. Phase 4 times a 10,000-message insert and a 1,000-change history pass, with and without the index, and reports the numbers in the handoff.
- Deleting a large account holds the shared writer while its index rows go, which briefly blocks the other accounts' writes. If phase 9g measures more than a second for 10,000 messages, deletion moves to batches; the launch cleanup already handles a partial deletion.
- Local and Gmail results differ for some queries: tokenizing (CJK text, punctuation), prefix matching, bodies not yet downloaded. Queries that could over-match locally go to Gmail only, so the remaining differences add conversations rather than hide them.
- The unverified API behaviors above.
- The accounts work changes the most code from milestones 1 and 2. Phases 9b to 9f change one thing at a time, and `MailboxModelTests` cover selection, actions and undo.
- If milestone 2's app phases aren't done when phase 8c is, I stop and report phases 9 to 11 as blocked.
- Snoozes only wake while Tern runs. A Mac that's off at wake time brings them back at the next launch.
- `gmail.modify` is still a restricted scope, so public release still needs Google's verification.

## Answered questions

Answered on 2026-10-29:

1. No background body download in this milestone. Gmail's results cover bodies Tern hasn't downloaded.
2. Gmail search uses `threads.list`, not `messages.list`.
3. Single-key shortcuts are off by default.
4. Combined mailboxes: Inbox, Starred, Snoozed, Drafts, Sent and Outbox. All Mail, Spam, Trash and labels stay per account. Phase 10d changed this: All Mail, Spam and Trash are combined too, and only labels stay per account.
5. Gates: when milestone 2 hasn't moved since the last merge, the phase goes ahead without asking. Otherwise I ask each time.
6. The phases run back to back, each tested and committed, stopping only at the gates.
