# Milestone 5 execution checklist

Updated 2026-10-30. The owner authorized completing milestone 4, then all of [milestone 5](milestone-5.md). Milestone 4 passed its integration checkpoint before this implementation. All 72 A–J implementation items are integrated and reviewed. Core tests pass (471 in 82 suites), and the committed milestone snapshot passes 242 hosted tests in 44 suites. The universal Release build and strict signature verification pass for arm64 and x86_64. Milestone 5 implementation is complete. This checklist maps every scope item to its workflow. [Verification records](../milestone-5-verification.md) distinguish local implementation from live provider acceptance.

Work in `/Users/developer/GitHub/REA_Mime` on `codex/tern-unified`. Root owns `AppModel.swift`, package/project files, generated Xcode project and `SESSION_HANDOFF.md`. Workers own the subsystems below, coordinate shared-file transfers, and preserve each other's changes. Proposed new filenames may change; update this checklist when they do.

## Delivery phases and ownership

Each subphase is a verified commit of at most five source/test files. Split a table row further when its tests or wiring exceed that limit. Before structurally refactoring a file over 300 lines, remove dead code in a separate verified commit. Build and project-generation leases belong to root.

| Phase | Owner and files | Scope and dependencies |
|---|---|---|
| M4 gate | Root: existing milestone 4 changes, full test/build checkpoint | B7–B11 integrated before milestone 5 code |
| P1a | Compose: new `MailtoParser.swift`, `MarkdownConverter.swift`, focused tests in MessageContent | E9/E12 groundwork; no shared edits |
| P1b | Reading: new `TrackerMatcher.swift`, `PrintDocument.swift`, `InlineMIMEResources.swift`, then tests | A1/A2/A4/A13 groundwork; first-party tracker rules |
| P2a | Store: new `Milestone5ConfigSchema.swift`, `Milestone5Preferences.swift`, `MailPreferencesStore.swift`, tests; root registers migrations | Durable account/profile, favorites/searches, templates/signatures, blocklist, sender allowance, alert marks |
| P2b | Store: new `Milestone5CacheSchema.swift`, `ReadingResourceStore.swift`, `MailCache.swift`, tests | CID resources, opened dates, migration/account cleanup; depends P2a registration |
| P3a | Queue: new `GmailClient+Triage.swift`, `Models.swift`, `GmailService.swift`, endpoint tests | Raw mail, batch deletion and label visibility APIs |
| P3b | Queue: `Records.swift`, `ActionQueue.swift`, `ComposeQueue.swift`, `LabelQueue.swift`, `SettingsQueue.swift` | New deletion/failure types and exhaustive dispatch, before exposing actions |
| P3c | Queue: new `TriageQueue.swift`, `FailedChanges.swift`, `MailCache.swift`, tests; then `GoogleScopes.swift`, overlay/hold owners | D1–D5/I3; exact message targets, chunking, Undo, permanent-deletion scope, failure lifecycle |
| P4a | Reading after B9 releases files: document/sanitizer, `MessageWebView.swift`, new `InlineResourceHandler.swift`, tests | A1–A4; depends P1b/P2b |
| P4b | Reading: `ThreadView.swift`, new `ReadingPreferences.swift`, `ReadingSettingsView.swift`, tests | A5–A7/A14; focused Settings insertion coordinated with B10 owner |
| P4c | Reading: new `MessageActions.swift`, `OriginalMessageView.swift`, `ConversationPrintController.swift`; reader hooks, tests | A8/A10–A13/D9; depends P3a and shared link contract |
| P5a | List/sidebar after B8 releases mailbox files: new `MessageListQueries.swift`, `MessageListModels.swift`; query/model/view hooks, tests | B1/B2/B7; typed message/conversation rows, attachment projection; depends P3c for message actions |
| P5b | List/sidebar: `ThreadListView.swift`, new `MessageListPreferences.swift`, `QuickFiltersView.swift`; mailbox hooks | B3–B6/B8; selection, swipe and destructive-header integration |
| P5c | List/sidebar: `SidebarView.swift`, new `FavoritesView.swift`, `SavedSearchEditor.swift`, `MailboxSwitcher.swift`; tests | C1/C6/C7; depends P2a |
| P5d | List/sidebar: sidebar/mailbox/search hooks, new `SearchSuggestions.swift`, tests | C2–C5/C8; label visibility uses P3a/P3c queue |
| P6 | Triage: new `TriageControls.swift`, `DestructiveMailReview.swift`, `SenderFilterActions.swift`; toolbar/commands/filter hooks | D1–D6/D10/D11; depends P3 and B10 filter editor |
| P7a | Compose after B8: model/view, new `ComposePreferences.swift`, `TemplatesView.swift`, `LocalSignaturesView.swift`; tests in next checkpoint | E1–E3/E5–E7/E11; depends P2a |
| P7b | Compose: `RichTextEditor.swift`, model/view hooks, tests | E4/E9/E10; quote selection needs reader contract; Markdown uses P1a |
| P7c | Compose: document/draft/MIME writer, then queue/editor integration and tests | E8; persisted inline images, stable CIDs, related MIME |
| P7d | Compose: queue/model, new `ComposeActions.swift`, tests | D7/D8; archive only after confirmed send, Undo cancels intent |
| P8a | Native integration: new `MailLink.swift`, `MailURLRouter.swift`, `AttachmentActions.swift`; attachment hooks | G1–G3; Downloads entitlement owned by root |
| P8b | Native integration: new `DefaultMailApp.swift`, `MailScriptingBridge.swift`, `Tern.sdef`; root app/plist/project hooks | E12/G4; depends P1a/P8a |
| P8c | Native integration: new `ConversationWindow.swift`, `MailToolbarConfiguration.swift`; main/list/commands hooks | H1–H3; depends typed P5a row identity |
| P9a | Accounts: new `AccountPreferencesModel.swift`, `ProfilesModel.swift`, Settings views; root lifecycle hooks | F1/F3/F4; depends P2a |
| P9b | Accounts: new `MailNotificationCoordinator.swift`, `MailNotificationRouter.swift`, `NotificationPolicy.swift`; sync/account hooks, then tests | F2; depends P2a/P9a and B7 |
| P9c | Accounts: new `ProfileScheduleView.swift`, `MailFocusFilter.swift`, `MailBadgeController.swift`; root hooks | F2/F5/F6; depends P9b |
| P10 | Contacts: People models/client, new `ContactEnrichmentStore.swift`, `ContactImages.swift`; sync/avatar/recipient hooks, tests | A9/J1/J2; transfer recipient ownership from compose |
| P11 | Store/maintenance: new `CacheMaintenance.swift`, `CacheBudget.swift`, `MaintenanceSettingsView.swift`, `FailedChangesView.swift`; tests/root hooks | I1–I3; depends active/failed queue contract, resource/index cleanup |
| P12 | Root and independent reviewer | Full integrated tests/builds, native workflows, migration/relaunch/reset and external acceptance records |

## Scope completion

Checked items have an implemented workflow and passing local verification. They do not claim a live provider round trip or macOS permission grant; those acceptance gaps are recorded separately in [Milestone 5 verification](../milestone-5-verification.md). Scope labels match `milestone-5.md`.

### A. Reading

- [x] A1: Block remote images by default; Load Images per message; persistent Always Load sender; per-message rules/CSP allow HTTPS images only.
- [x] A2: Keep known tracker hosts and 1×1 pixels blocked when images are allowed; show blocked count; use own rules or verify bundled-list license.
- [x] A3: Default-on dark adaptation setting and per-message light fallback; preserve authored dark styles, contrast/hue handling and image pixels.
- [x] A4: Cache MIME CID resources; rewrite to a message-scoped scheme; reject cross-message and unknown resource IDs.
- [x] A5: Oldest-first/newest-first conversation order.
- [x] A6: Immediate, delayed or manual mark-read; delayed action requires the same conversation to remain open.
- [x] A7: Shared list/message text scale.
- [x] A8: Removable header label chips; per-message star, Reply and full action menu including attachment-forward/original/print/link.
- [x] A9: Cached contact photo, else stable address-colored initials.
- [x] A10: Address menu: Copy, New Message, Search From/To and Create Filter.
- [x] A11: Hovered link destination below the message.
- [x] A12: Raw original message with Copy and Save `.eml`.
- [x] A13: Conversation print and Export as PDF from sanitized bodies.
- [x] A14: Optional message-size display.

### B. Message list

- [x] B1: User/system/attachment chips, count, draft marker, Sent/Drafts recipients, optional importance/account badges and star action.
- [x] B2: Unopened attachment metadata using Content-Type and masked part-tree reads; accurate attachment search; visible fallback if provider mask fails.
- [x] B3: Default and Compact density.
- [x] B4: Unread, Starred, Has Attachments, Important and Addressed to Me quick filters.
- [x] B5: Next selection below, above or none after archive/trash.
- [x] B6: Two configurable swipe actions per edge, including None and all approved actions.
- [x] B7: Conversations-off message rows; every action targets only the selected messages.
- [x] B8: Spam/Trash counts and confirmed empty actions in their headers.

### C. Sidebar and mailboxes

- [x] C1: Add/remove/reorder/reset Favorites; cross-account expansion for mailboxes, labels and saved searches; preserve fixed mailbox order.
- [x] C2: Total Starred/Drafts badges and unread Spam badge options.
- [x] C3: Collapsible per-account More group with hide preference.
- [x] C4: Honor and queue changes to Gmail label visibility, including show-if-unread.
- [x] C5: Per-account local category switches; enabled categories leave Inbox and appear beneath it.
- [x] C6: Named per-account/combined saved Gmail searches in sidebar/Favorites; history remains off.
- [x] C7: Type-to-filter Go to Label switcher for mailboxes, labels and saved searches.
- [x] C8: Search suggestions from cached addresses/contacts, labels and operators.

### D. Triage

- [x] D1: Report Spam/Not Spam with Undo.
- [x] D2: Mark Important/Not Important.
- [x] D3: Mark All Read lists exact unread IDs, modifies chunks of 1,000 and undoes only changed IDs.
- [x] D4: Delete Forever/Empty Trash/Delete Spam confirm count and immutable target IDs; require full-mail feature scope; chunks of 1,000; no Undo.
- [x] D5: Delete-key archive/remove-current-user-label or Trash preference.
- [x] D6: Optional macOS sounds for archive, trash, send and new mail.
- [x] D7: Send and Archive queues archive only after successful delivery; Undo Send cancels both.
- [x] D8: Send Again creates a new draft retaining recipients, subject, body and attachments.
- [x] D9: Forward as Attachment uses raw `message/rfc822` bytes.
- [x] D10: Block Sender queues a Trash filter under Gmail Settings permission and lists it in Blocked Settings.
- [x] D11: Filter Messages Like These prefills B10's filter editor from selected sender/recipients/subject.

### E. Compose

- [x] E1: Named rich templates inserted from compose/menu and managed in Settings.
- [x] E2: Local rich signatures alongside Gmail signatures; per-account/address new/reply assignments; quote placement and separator preference.
- [x] E3: Sans-serif, serif or fixed-width default font.
- [x] E4: Quote selected text only with Ask/Always/Never behavior.
- [x] E5: Names-only/full-address recipient preference.
- [x] E6: Remove suggestions from picker or Settings using a durable blocklist.
- [x] E7: Automatic/fixed From; combined mailbox chooses most recent exchange with first recipient, else first account.
- [x] E8: Paste/drop inline images; durable draft resources; related MIME and CID references.
- [x] E9: Typed/pasted Markdown lists, emphasis and links become `ComposeDocument` formatting without a dependency.
- [x] E10: Writing Tools on macOS 15.1 and later.
- [x] E11: Format-bar visibility from View menu.
- [x] E12: Register/handle RFC 6068 `mailto:` fields; default-mail-app setting.

### F. Accounts, profiles and notifications

- [x] F1: Nickname, existing account palette, sync pause/resume without sign-out and account order.
- [x] F2: Mail alert rules, post-baseline history tracking, conversation grouping, click/action, Dock/menu-bar badge and test notification; no initial/rebuild/resume alerts.
- [x] F3: Last-window close keeps sync/watchers/alerts/snoozes running; Quit stops them.
- [x] F4: Named account profiles with color/symbol and All; one profile per account; active profile controls visible accounts.
- [x] F5: Per-profile Off, daily, weekdays or custom daily notification schedules.
- [x] F6: App Intents Focus filter selects profile and resolves the AppIntents build warning.

### G. Attachments, links and automation

- [x] G1: Open-file storage preference between Tern's folder and Downloads, with sandbox entitlement.
- [x] G2: Attachment Open/Open With/Quick Look/Save As/Copy/Save All menus.
- [x] G3: Copy/open account-qualified `tern://` conversation links; Copy Gmail Link/Open in Gmail with verified account routing.
- [x] G4: Read-only AppleScript selected conversation/message IDs, subject, sender, date and Tern/Gmail links.

### H. Windows and view

- [x] H1: Hide reader; double-click and Open in New Window work in every layout.
- [x] H2: Customizable toolbar.
- [x] H3: View switches for account badges, message size, importance and quick filters.

### I. Cache and maintenance

- [x] I1: Show cache size/budget; evict least recently opened bodies/downloads, then eligible metadata outside sync window/holds.
- [x] I2: Reset/rebuild only cache, preserving config; refuse while Outbox or queue holds recoverable work; explain refusal.
- [x] I3: Retain permanent failures and Gmail error; remove optimistic projection; Settings Retry/Discard; retry once per user request.

### J. Contacts and calendar

- [x] J1: Saved/other-contact People photos cached with contact data and used by A9.
- [x] J2: Typed contact group name expands to member addresses.
- [x] J3: Verify F15's connected Google agenda/availability and independent permissions; retain external acceptance gaps. EventKit is superseded.

## Shared integration contracts

- Store user setup in typed config records; keep reading resources and downloaded mail disposable. Names, colors and account identity retain existing behavior.
- Use account-qualified message/thread IDs and explicit action targets. A selected message never authorizes changing its siblings.
- Deletion approval captures immutable IDs/counts; execution rechecks feature scope and allowed mailbox. All Gmail writes use the queue.
- Separate active/failed action queries. Failed rows must not overlay labels, block ordering or claim keys, or disappear before Retry/Discard; retry atomically reactivates retained intent.
- Serve inline resources only from the captured account/message map. Policy changes rebuild document/CSP/rules; page scripts remain off, application scripts use the isolated world.
- Persist draft image/signature/font/archive intent with its revision; retry preserves Message-ID/CIDs. Archive follows confirmed delivery and Undo clears pending intent.
- Notifications start from a persisted history baseline; stable notification IDs avoid duplicate scheduling. Unknown/incomplete sync never establishes complete coverage. Profile/schedule rules apply before alerting.
- Sync pause quiesces account work; resume baselines alerts. Profiles filter presentation while all enabled accounts can sync in the background.
- Reset quiesces engines/watchers, rejects any recoverable draft/queue work, preserves config and durable Calendar data, then replaces cache streams/engines before restarting.
- Root supplies narrow hooks for URL routing, conversation windows, filter requests, focused editors, account lifecycle and reset. Transfer shared-file ownership before editing.

## Verification and completion

- [x] Focused tests catch message/account boundary mistakes, lost/duplicated queue work, scope bypass, resource leakage, wrong alert baselines and reset data loss; avoid styling-only tests.
- [x] Full Core and hosted suites, Debug and universal Release builds pass; generated project is current and committed Core package lock ends in SwiftPM's state.
- [ ] Complete broader native/system acceptance. Local checks cover the toolbar/layout/category paths described in the verification record; spoken accessibility, older macOS, permission-dependent flows and additional manual journeys remain unverified.
- [x] Live acceptance records Gmail masks/links/consent/deletion, CID/remote content, notification permissions/delivery, Focus/default-app/AppleScript and F15 setup/round trips accurately. Unverified checks stay explicit.
- [x] Independent review findings resolved, scope checklist reconciled, logical commits made and handoff updated. No item is complete solely because source compiles.
