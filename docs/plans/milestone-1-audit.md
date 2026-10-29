# Milestone 1 audit

Baseline: `90f2bf2` on clean `feat/milestone-1`; fixes on `fix/milestone-1-audit`.
XcodeGen succeeds, the Debug app builds without source warnings, and all 20 package tests pass. Xcode emits an AppIntents metadata extraction warning because this app has no AppIntents dependency.

All files in `App/`, `Packages/Core/Sources/` and `Packages/Core/Tests/` were read. Locations below refer to the baseline. Findings are ordered by severity; status and evidence are added as work proceeds.

| ID | Severity | Location | Failure, cause and proposed fix | Confidence |
|---|---|---|---|---|
| A01 | High | `GmailAPI/BatchCodec.swift:28`; `GmailClient.swift:179` | Nested request lines omit the HTTP version. Also, an outer 200 with inner 401 bypasses token refresh and can permanently reject queued changes. Encode complete HTTP request lines; refresh and retry unauthorized parts once. | High |
| A02 | High | `SyncEngine/ActionQueue.swift:190` | One multi-thread action returning both permanent and transient failures deletes the entire action, losing the retryable changes. Successful targets also lose their overlay. Preserve outcomes per target and keep undo tied to each target's outcome. | High |
| A03 | High | `MailStore/MailCache.swift:300` | A crash after Gmail receives a first attempt leaves `sending, attempts=0`. Recovery makes it queued with zero attempts, so undo removes it without sending an inverse. Count claimed attempts durably and recover existing interrupted rows conservatively. | High |
| A04 | High | `MailStore/MailCache.swift:107` | A thread fetch stores metadata at history 220; a slower history pass then applies a change at 210 despite keeping the stored history at 220. Old labels overwrite fresh state. Ignore changes older than the stored message; allow equal IDs for several changes in one history record. | High |
| A05 | High | `SyncEngine/SyncEngine.swift:282,310` | After 10,000 tombstones, a slow thread load can restore deleted mail. Filtering before an awaited database write also races with deletion. Retain deletion knowledge and check it inside serialized database writes. Handle thread 404s and metadata 404s as deletions. | High |
| A06 | High | `SyncEngine/SyncEngine.swift:162–183` | An action queued after the pass reads protected IDs keeps stale, unrefreshed metadata. Chunk writes also expose a half-applied full sync if a later fetch fails. Fetch all data first, recheck protected targets at commit, and commit metadata, pruning and cursor atomically. | High |
| A07 | High | `SyncEngine/SyncEngine.swift:201,272,361`; `GmailService.swift:50` | Invalid history IDs become zero or are silently skipped; absent batch parts are treated as deleted. A pass can advance its cursor while losing changes. Validate IDs and required metadata; fail incomplete responses without moving the cursor. | High |
| A08 | Medium | `SyncEngine/SyncEngine.swift:243` | The shared listing helper caps recent mail at 5,000 as well as Inbox. Accounts with more recent mail silently miss messages. Apply the plan's cap to Inbox only; page the complete recent listing. | High |
| A09 | Medium | `SyncEngine/SyncEngine.swift:140,237` | An empty history page never refreshes labels, so renames, new labels and counts can remain stale indefinitely. Individual detail failures silently replace counts with nil. Refresh on every successful poll and preserve prior data on failed detail responses. | High |
| A10 | Medium | `App/Mailbox/MailboxModel.swift:136,254` | Async undo registration can group unrelated actions; the model retains entries even after UndoManager drops them. Undo is consumed before a failed write can be retried. Register explicit groups, bound retained entries, and consume undo only after persistence succeeds. | High |
| A11 | Medium | `App/Mailbox/MailboxModel.swift:139,228` | Archive advances selection in every label even when the thread stays visible; a label switch briefly retains the old rows and selection can outlive remote deletions. Advance only when membership changes and reconcile selection with the observed list. | High |
| A12 | Medium | `App/Auth/GoogleAuth.swift:106,133`; `App/AppModel.swift:72` | OAuth permits omitted token-response scope when unchanged, but sign-in treats it as no Gmail grant. A late refresh can also affect a replaced session. Read AppAuth's effective scope and reject obsolete refresh completions; await mailbox shutdown before replacing account data. | High |
| A13 | Medium | `MessageContent/MIMEParts.swift:38` | A multipart attachment is traversed before attachment detection; its contents appear as the message body. Reject attachments before walking multipart children. | High |
| A14 | Medium | `App/Views/MessageWebView.swift:75–111` | A zero-delta gesture start locks horizontal mail scrolling to vertical. Height measurement uses the current viewport, preventing shrink, and runs only at finish/width changes, missing late inline-image layout. Delay direction choice until movement and measure actual body layout as it changes. | High for scroll; medium for height until UI reproduction |
| A15 | Low | `App/Views/SidebarView.swift:12`; `ThreadView.swift:64` | Only Inbox shows system-label unread counts. Collapsing every message is undone by the next observation because an empty expanded set is treated as uninitialized. Display available counts and track initial expansion separately. | High |

## Items needing evidence

- Undo on a thread with both already-trashed and newly-trashed messages currently untrashes every message (`ActionQueue.swift:98`). Check against the recorded per-message diff and preserve original Trash membership.
- Text parts represented by `attachmentId` have no inline data and are currently shown as having no text. Determine a contained correction or report the gap.
- Real Gmail, OAuth consent and token expiry cannot be exercised without an owner-configured OAuth client. No credentials or security settings will be changed.
- Closing the sign-in window and reopening the application worked. Mailbox UI, dark mode, links, undo menus and scrolling still need exercise through an isolated DEBUG fake.

## API references

Request framing and per-part statuses: [Google batch guide](https://developers.google.com/workspace/gmail/api/guides/batch). History ordering and paging: [history.list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list). Manually applicable system labels: [Google label guide](https://developers.google.com/workspace/gmail/api/guides/labels).
