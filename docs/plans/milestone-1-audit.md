# Milestone 1 audit

Baseline: `90f2bf2` on clean `feat/milestone-1`; fixes on `fix/milestone-1-audit`.
XcodeGen succeeds, the Debug app builds without source warnings, and all 20 package tests pass. Xcode emits an AppIntents metadata extraction warning because this app has no AppIntents dependency.

All files in `App/`, `Packages/Core/Sources/` and `Packages/Core/Tests/` were read. Package paths below are relative to `Packages/Core/Sources/`. Locations refer to the baseline unless a later revision is named. Findings are ordered by severity. A24 is open; the other findings are fixed.

| ID | Severity | Location | Failure, cause and proposed fix | Confidence |
|---|---|---|---|---|
| A01 | High | `GmailAPI/BatchCodec.swift:28`; `GmailClient.swift:179` | Nested request lines omit the HTTP version. Also, an outer 200 with inner 401 bypasses token refresh and can permanently reject queued changes. Encode complete HTTP request lines; refresh and retry unauthorized parts once. | High |
| A02 | High | `SyncEngine/ActionQueue.swift:190` | One multi-thread action returning both permanent and transient failures deletes the entire action, losing the retryable changes. Successful targets also lose their overlay. Preserve outcomes per target and keep undo tied to each target's outcome. | High |
| A03 | High | `MailStore/MailCache.swift:300` | A crash after Gmail receives a first attempt leaves `sending, attempts=0`. Recovery makes it queued with zero attempts, so undo removes it without sending an inverse. Count claimed attempts durably and recover existing interrupted rows conservatively. | High |
| A04 | High | `MailStore/MailCache.swift:107` | A thread fetch stores metadata at history 220; a slower history pass then applies a change at 210 despite keeping the stored history at 220. Old labels overwrite fresh state. Ignore changes older than the stored message; allow equal IDs for several changes in one history record. | High |
| A05 | High | `SyncEngine/SyncEngine.swift:282,310` | After 10,000 tombstones, a slow thread load can restore deleted mail. Filtering before an awaited database write also races with deletion. Retain deletion knowledge and check it inside serialized database writes. Handle thread 404s and metadata 404s as deletions. | High |
| A06 | High | `SyncEngine/SyncEngine.swift:162–183` | An action queued after the pass reads protected IDs keeps stale, unrefreshed metadata. Chunk writes also expose a half-applied full sync if a later fetch fails. Fetch all data first, recheck protected targets at commit, and commit metadata, pruning and cursor atomically. | High |
| A07 | High | `SyncEngine/SyncEngine.swift:201,272,361`; `GmailService.swift:50` | Invalid history IDs become zero or are silently skipped; absent batch parts are treated as deleted. A pass can advance its cursor while losing changes. Validate IDs and required metadata; fail incomplete responses without moving the cursor. | High |
| A16 | High | `SyncEngine/SyncEngine.swift:83,98` | `stop()` can return while a database write from another caller is still running, allowing account cleanup to race that write. Track all submitted writes and wait for them; reserve startup before awaiting recovery so concurrent starts cannot duplicate it. | High |
| A17 | High | `SyncEngine/ActionQueue.swift:199` | A rejected token or unreadable mutation response deletes the action as a permanent failure. Gmail may already have applied a response that could not be parsed. Retain intent, retry and preserve compensating undo for these outcomes. | High |
| A18 | High | `SyncEngine/ActionQueue.swift:98`; `MailStore/MailCache.swift:229` | A whole-thread mutation changes uncached messages, but undo knows only cached diffs. After confirmation drops the queue row, even a send-time extension would be lost. Snapshot all thread labels before mutation, preserve original entries across retries, and retain enriched snapshots in bounded UI-owned receipts. Keep the existing SQL schema and JSON diff shape. | High |
| A19 | High | `SyncEngine/SyncEngine.swift:180`; thread-404 handler at `d9ba149` | Full-sync pruning can delete a revision loaded after its listings. A delayed thread 404 can also delete messages ingested by a newer pass. Limit pruning to the held profile cursor and 404 deletion to unchanged starting versions. | High |
| A08 | Medium | `SyncEngine/SyncEngine.swift:243` | The shared listing helper caps recent mail at 5,000 as well as Inbox. Accounts with more recent mail silently miss messages. Apply the plan's cap to Inbox only; page the complete recent listing. | High |
| A09 | Medium | `SyncEngine/SyncEngine.swift:140,237` | An empty history page never refreshes labels, so renames, new labels and counts can remain stale indefinitely. Individual detail failures silently replace counts with nil. Refresh on every successful poll and preserve prior data on failed detail responses. | High |
| A10 | Medium | `App/Mailbox/MailboxModel.swift:136,254` | Async undo registration can group unrelated actions; the model retains entries even after UndoManager drops them. Undo is consumed before a failed write can be retried. Register explicit groups, bound retained entries, and consume undo only after persistence succeeds. | High |
| A11 | Medium | `App/Mailbox/MailboxModel.swift:139,228` | Archive advances selection in every label even when the thread stays visible; a label switch briefly retains the old rows and selection can outlive remote deletions. Advance only when membership changes and reconcile selection with the observed list. | High |
| A12 | Medium | `App/Auth/GoogleAuth.swift:106,133`; `App/AppModel.swift:72` | OAuth permits omitted token-response scope when unchanged, but sign-in treats it as no Gmail grant. A late refresh can also affect a replaced session. Read AppAuth's effective scope and reject obsolete refresh completions; await mailbox shutdown before replacing account data. | High |
| A13 | Medium | `MessageContent/MIMEParts.swift:38` | A multipart attachment is traversed before attachment detection; its contents appear as the message body. Reject attachments before walking multipart children. | High |
| A14 | Medium | `App/Views/MessageWebView.swift:75–111` | A zero-delta gesture start locks horizontal mail scrolling to vertical. Height measurement uses the current viewport, preventing shrink, and runs only at finish/width changes, missing late inline-image layout. Delay direction choice until movement and measure actual body layout as it changes. | High; height reproduced in WebKit tests |
| A20 | Medium | `MessageContent/MIMEParts.swift:58` | A readable text part represented by `attachmentId` has no inline data and displays as having no text. Retrieve only the readable body resources, decode their charset and cache the resulting body; continue excluding attached documents. | High |
| A21 | Medium | `SyncEngine/ActionQueue.swift:98` | Undoing Trash on a mixed thread untrashes messages that were already in Trash. Preserve their original IDs in the existing action payload, untrash the thread, then restore those messages' Trash labels through the queue. | High |
| A22 | Medium | `SyncEngine/SyncEngine.swift:293–302` | Opening reads unread state before a separate awaited enqueue. A user action can land between them and be overwritten. Read state and enqueue automatic mark-read in one transaction; preserve later intent during body loading. | High |
| A23 | Medium | `App/Commands/MailCommands.swift:10`; `MainView.swift:33` | Check for New Mail and Sign Out remain disabled with an active mailbox because focused-scene routing does not supply the command menu's mailbox. The app has one mailbox window; use `AppModel.mailbox` directly and remove the redundant focus route. | High, reproduced in UI |
| A24 | Medium, open | `MessageContent/MIMEParts.swift:58`; `App/Views/MessageWebView.swift:18` | HTML containing `<img src="cid:logo">` cannot resolve its MIME image resource. The text collector discards image parts, the body cache has no resource storage, and the web view has no CID resolver. Proposed follow-up: explicit cached MIME resources with a safe CID-to-data/resource mapping. This adds attachment-image rendering and a cache representation, so it is left for scope approval. | High from source; no live Gmail fixture |
| A15 | Low | `App/Views/SidebarView.swift:12`; `ThreadView.swift:64` | Only Inbox shows system-label unread counts. Collapsing every message is undone by the next observation because an empty expanded set is treated as uninitialized. Display available counts and track initial expansion separately. | High |

## Resolution and evidence

| Finding | Commits | Evidence |
|---|---|---|
| A01 | `08c19e6`, `12cd832` | Regressions for boundary text inside JSON, complete request lines, and one forced refresh of inner 401 parts without resending successes. |
| A02 | `ef6f669`, `1a60a93` | Mixed permanent/retryable/success outcomes remain independent; due rows share delivery batches. FIFO retry test preserves ordering per thread. |
| A03 | `2472a05` | Interrupted first-send recovery still sends the required inverse. |
| A04 | `60a9b86` | Older metadata and label changes cannot overwrite newer labels; equal-ID changes in one history record both apply. |
| A05 | `d9ba149` | More than 10,000 tombstones survive empty polls. Held thread responses cannot restore concurrently deleted mail; metadata and thread 404s remove stale records. |
| A06 | `5463c76` | Failed full sync publishes no partial message set; an action queued during metadata fetch gets its protected messages refreshed. |
| A07 | `8083071` | Invalid record/cursor/message history IDs and missing parts fail without advancing the cursor. |
| A08 | `0bb562e` | Recent listing continues through ten 500-message pages to the last message. |
| A09 | `6e49269` | Empty history refreshes labels; detail failures preserve prior labels and cursor. |
| A10 | `60b43fa` | Hosted app tests cover undo before persistence, separate groups, 100-entry bound and release on stop. Failure retry registration was inspected. |
| A11 | `b3fc991` | App tests cover archive in All Mail, label switches and selection after a remote deletion. |
| A12 | `b51bc87` | Builds cleanly; effective-scope behavior checked against the installed AppAuth implementation. Real OAuth and late-refresh execution remain unverified. |
| A13 | `e42b3d8` | Charset/attachment fixture now includes a multipart attachment, which stays excluded. |
| A14 | `da0124d`, `0c304af`, `f29c2c2` | WebKit test reproduces the 464-point height that would not shrink, then verifies shrink and later layout growth. Gesture-state test covers zero deltas, momentum and mouse wheels. |
| A15 | `a1b31d7` | UI shows Starred/Spam counts. Both replies remain collapsed after a read-state observation; accessibility values expose expansion state. |
| A16 | `335d9fe` | Stop cannot return while a held database write is still in flight. |
| A17 | `d748203`, `5dbb8be` | Rejected credentials and an unreadable post-mutation response retain queued intent and compensating undo. |
| A18 | `4e5c641` | Undo after confirmation restores the uncached Inbox message and leaves the originally Sent-only message alone. Receipts use a lock; engine references are weak. |
| A19 | `68f9fbf`, `63951e0` | Held 404 preserves newly synced mail; held resync preserves a thread load's newer revision. |
| A20 | `6516f8a` | Message-scoped endpoint/base64url test and a full-thread fixture with an external Latin-1 body; attached document is never requested. |
| A21 | `a2ef9c9`, `4e5c641` | Undo preserves preexisting Trash membership; send snapshots also cover uncached messages. |
| A22 | `6958f46` | Held body load preserves a later mark-unread action and concurrent deletion. |
| A23 | `0280ca1` | Commands retain the open mailbox without a first responder. UI menu entries enabled; synthetic sign-out returns to the signed-out screen. |
| A24 | Open | Requires approval for cached MIME resource/image rendering. No schema change was made. |

Supporting commits: `53fc48f` records the initial ranked findings; `ffedd53` removes dead mailbox code before the undo refactor; `3dc3c77` adds the isolated DEBUG-only UI mailbox.

## Verification and limits

The final verification results are recorded in `SESSION_HANDOFF.md`. The baseline passed all requested checks before changes. No dependency versions, SQL migrations, OAuth clients, credentials or macOS security/privacy settings were changed. Nothing was pushed.

UI exercised through the DEBUG fake: sidebar and counts, HTML and plain text, blocked-content notice, message expansion, archive/trash/read/star actions and their shortcuts, selection, notice Undo, Edit-menu Undo and sign-out. Dark appearance and accessibility labels were inspected. Closing and reopening the exact app bundle worked. The app test host also uses the fake argument and in-memory stores.

Not verified: real Gmail/OAuth, spoken VoiceOver, a physical trackpad gesture, large-mailbox UI throughput, light appearance, mailto routing, and the UI fallback after an actual content-rule compilation failure. A web link was clicked, but Work settings disabled local browser inspection, so the destination was not verified. Reopening specifically by clicking the Dock icon was not exercised; another checkout shares the bundle identifier, so the exact app path was used.

The remaining deliberate limits are unchanged: Inbox plus the last 30 days, remote images blocked without a load option, and plain-text rendering when no content rule list is available. App spacing, radii and motion use `App/Design/Tokens.swift`; the package's HTML page retains its documented token mirrors.

## API references

Request framing and per-part statuses: [Google batch guide](https://developers.google.com/workspace/gmail/api/guides/batch). History ordering and paging: [history.list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list). Manually applicable system labels: [Google label guide](https://developers.google.com/workspace/gmail/api/guides/labels). External body resources: [MessagePartBody](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments#MessagePartBody), [attachments.get](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages.attachments/get).
