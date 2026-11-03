# Tern design and functionality review

Reviewed 2026-11-02, checkout `d05663c`, using the `swiftui-pro` skill. Target: macOS 26; installed toolchain: Xcode 26.3 / Swift 6.2.4, Swift 6 language mode. The review does not recommend iPhone-only APIs, UIKit replacements, or a deployment-target change.

Tern has built an impressive number of ways to start work and too many ways to lose control of finishing it. You can compose a message but cannot remove its signature or trim its forwarded history. You can review AI categories but cannot reject one bad match. You can retry a calendar conflict through a button that sends you back to the same dead end. These are failures in the product's basic interaction contracts.

The visual system is more consistent than those behaviors. Semantic surfaces, shared spacing, native toolbar groups, reduced-motion handling, and adaptive layouts already exist. Another round of rounded corners will not fix missing mail, lost edits, or recovery controls that do the wrong thing. The strongest design criticism is that the interface repeatedly presents certainty and control that the implementation does not provide.

This report contains 42 findings, organized by file. P1 means a high-impact workflow or preservation failure; P2 means a concrete functional, usability, privacy, or accessibility problem; P3 means maintenance or an unmeasured efficiency issue. Confidence is high unless stated otherwise. The original findings and their suggested snippets describe the reviewed `d05663c` baseline. The follow-up fixes are recorded below; baseline line references may shift in the working tree. Concurrent application edits were preserved.

## Fix goal and verification

The follow-up goal covers every finding below. Implementation began on 2026-11-02 with the existing uncommitted work preserved in `/tmp/tern-review-fixes-2026-11-02/preexisting-work.patch`. The original findings remain as the review record; the table records their subsequent resolution. A finding is complete only after its fix and applicable checks pass.

The work reconciled the current source, implemented each feature batch, reviewed the integrated changes, ran regression checks, and inspected the changed native interfaces. The deployment target remains macOS 26. No commit, installation, or publishing was performed.

All 42 findings are resolved in the working tree. Applicable regression, build, source-review, and hosted native checks are complete. The table maps each fix to its evidence; the system UI automation limitation and the scope of verification are stated below.

| Finding | Fix | Verification evidence |
| --- | --- | --- |
| F01 | All Mail sends no app-only Gmail label ID. | SyncEngineSearchTests |
| F02 | Browsing follows authoritative server cursors and refreshes partial cached threads. | SyncEngineSearchTests; MailPaginationTests |
| F03 | Combined and scoped mailboxes retain independent account cursors and errors. | MailPaginationTests |
| F04 | Inbox exposes continuation beyond the initial cap and explains incomplete coverage. | SyncEngineSearchTests; MessageListTests |
| F05 | Active quick filters remain visible and filtered search explains hidden matches. | MessageListTests |
| F06 | Bcc flows through metadata, migration, local sent records, reader details and analytics; backfill respects deletion tombstones. | RecipientHeaderTests; MailAnalyticsTests; metadata/reader review |
| F07 | Sidebar and favorite values include the visible count's unread/total/outgoing meaning and expansion state. | MailSidebarBadgeTests; native accessibility check |
| F08 | A separate export error alert leaves original-message content available. | OriginalMessageView save/error branch review; app build |
| F09 | Queued sends may be cancelled until delivery is requested; claimed and uncertain sends remain protected. | ComposeRecoveryTests; shared store/Outbox predicate review |
| F10 | Attachment limits use the latest editor content and only referenced inline parts; Undo retains the bytes. | ComposeRecoveryTests; ComposeModelTests |
| F11 | Attachment sizes are checked before bounded copying; teardown waits for copying, writes and cleanup. | ComposeRecoveryTests |
| F12 | Contact groups reserve pending work synchronously and block send, move, close and quit until resolved. | ComposeFeatureModelTests; ComposeModelTests; QuitTests |
| F13 | Failed discard reports the failure and resumes draft persistence. | ComposeModelTests |
| F14 | Quoted text can be edited or removed without losing reply headers. | ComposeModelTests; native quote-editor captures |
| F15 | Each message can use None, Gmail, a saved signature or edited text; explicit choices beat delayed defaults. | ComposeModelTests; ComposeIdentityTests; native signature-editor captures |
| F16 | Template/signature selection, New, account/source changes, navigation and closing preserve unsaved work; native editing stops during saves. | SettingsEditorTests; native unsaved-template flow; editor path review |
| F17 | Calendar recovery reviews current versions, reconciles satisfied work, preserves series checkpoints and atomically completes receipts/cache changes; uncertainty survives relaunch. | CalendarOperationRecoveryTests; CalendarRecoveryStoreTests; native recovery captures |
| F18 | Task conflict review keeps local edits and explicitly adopts the reviewed remote version before saving. | GoogleTaskEditingSessionTests |
| F19 | Read-only calendar events retain working meeting and attachment links. | CalendarEventEditor disabled-scope review; app build |
| F20 | Recurrence reads date/UTC UNTIL values and retains exact untouched provider cutoffs. | RecurrenceSelectionTests |
| F21 | Fresh task creation skips account-wide scans while uncertain retries still reconcile. | GoogleTasksModelTests |
| F22 | Activity identifies event titles and dates, including the occurrence a following-series request affects. | CalendarRecoveryVisualAudit normal tests; CalendarOperationPresentation review |
| F23 | Assistant citations preserve account/thread/message/part identity and validate permissions after asynchronous mail/calendar loading. | NativeMailActionTests; AssistantCalendarNavigationTests; MailLinkTests |
| F24 | Navigation preserves chat and unfinished input under the original scope; users choose whether to keep it or start a new chat. | AssistantModelTests; native scope-review captures |
| F25 | Copy includes visible result details, qualifications and deduplicated validated source links, including prose-only citations. | AssistantResultExportTests |
| F26 | Readiness requires an available model in the current catalogue; retry retains the prompt. | AssistantModelTests |
| F27 | Organization review supports individual message exclusions, source opening and revalidated future-rule eligibility. | MailOrganizationModelTests; MailOrganizationSamplesTests; action-queue review |
| F28 | Older email cards include the year and a full localized date tooltip. | AssistantEmailCard review; Assistant results captures |
| F29 | Each lazy transcript entry has one stable enclosing row. | AssistantConversationView review; AssistantScrollTrackingTests |
| F30 | Settings routes request navigation before changing editor identity and use shared dirty-editor confirmation. | SettingsEditorTests; native template edits through New → Cancel/Discard; navigation/account/source route review |
| F31 | Expired accounts retain the cached workspace and expose reconnect controls, including cold restoration. | native single-account expiry flow; startup/runtime path review |
| F32 | New-mail sounds use the system notification request's sound field. | MailNotificationScheduler review; notification suites |
| F33 | Cache trimming protects individual threads while allowing unrelated evictions; full reset remains strict. | CacheBudgetTests; CacheResetLifecycleTests |
| F34 | Failed changes show meaningful targets, account, time, counts and validated source/draft actions. | FailedChangePresentationTests |
| F35 | Spotlight deletion intent persists and retries after failure/relaunch; account removal preserves unrelated index fingerprints. | MailSpotlightRemovalTests; MailSpotlightTests |
| F36 | Attachment commands acquire busy state and retry identity together, retaining the original requested files. | AttachmentLibraryActionTests |
| F37 | Removing the last page clamps the offset and restarts observation. | AttachmentLibraryModelTests |
| F38 | Copy operates on the selected files, writes the clipboard once and reports partial failure. | AttachmentLibraryActionTests |
| F39 | One account's history failure does not prevent other accounts from loading; cancellation stops the pass. | MailAnalyticsModelTests |
| F40 | Company-logo website requests default off; existing explicit choices persist and onboarding explains the choice. | DomainLogoPreferencesTests; onboarding disclosure and all call-site review |
| F41 | Reviewed coordinate-space and background overloads use supported modern SwiftUI forms. | app build; API search; native captures |
| F42 | The summary test explicitly chooses the selected-thread scope it intends to test. | ThreadSummaryTests |

### Follow-up verification evidence

Evidence for the fix goal is in `/tmp/tern-review-fixes-2026-11-02/`. Tests use the existing macOS 26 target and isolated development build; the installed app was not replaced.

- Core: **715 tests in 118 suites passed**, including calendar recovery/checkpoint reconciliation, cancellation and attachment I/O, Bcc migration/backfill, provider pagination, and citation identities. Log: `core-tests-final.log`.
- Hosted app: **668 tests passed, zero failed, eight opt-in tests skipped**, across 105 suites (676 total reported by Swift Testing). Seven skipped native/visual tests passed in their separate enabled runs; the performance benchmark remained disabled. The preceding full run failed the existing attachment-sidebar restoration check because it read widths before deferred native layout finished. Diagnostic reruns restored the exact original geometry. That test now waits up to three seconds for restoration and retains its one-point assertions. Final log: `app-tests-complete.log`; exact counts: `app-tests-summary.json`; result bundle: `/tmp/tern-design-review-2026-11-02/DerivedData/Logs/Test/Test-Tern-2026.11.02_18-16-48-+0100.xcresult`.
- Native controls and accessibility: `MailSidebarBadgeTests` checks actual rendered unread/total counts, hidden badges, and expansion values in single- and multiple-account fixtures. `ComposeSettingsInteractionTests` enters text through native editors and verifies New → Cancel preserves it and Discard resets it. Both passed in `native-visuals-final.log`.
- Cached account access: `CachedWorkspaceTests` passed after expiring its single synthetic account through the production handler. It verifies the cached Inbox count, mail table, subject heading, visible native message header, and account-specific reconnect control together. Log: `cached-workspace-verified.log`; capture: `cached-workspace-capture/`.
- Native renders: the Assistant, Calendar sidebar, and analytics suites passed with 44 captures (`visuals-third.log`). The new quote/signature editors, scope notice, and recovery review passed with 14 final light/dark captures, including narrow layouts and recovery scroll positions (`native-visuals-final.log`, `captures-final/named/`). Selected captures were inspected for legibility, clipping, control placement, and retained draft content. The cached-workspace bitmap confirms rendered mail and reconnect content, but does not faithfully composite every sidebar material; its accessibility and native-view assertions provide the workspace evidence.
- Independent cross-feature review caught additional races in send teardown, recipient loading, signature defaults, Bcc backfill, Spotlight fingerprints, calendar checkpoints, and asynchronous Assistant calendar authorization. Those corrections are included in the passing regression suites. New Swift files are registered in the project; `git diff --check` passes. `verified-source-manifest.json` records the tested source hashes.

The system XCUITest runner could not enable automation mode (`native-tests-third.log`). The new end-to-end Settings navigation and expired-account scripts therefore remain unexecuted, as does the attempted onboarding UI rerun. Hosted native controls, model regression tests, source review, and captures supply the checks described above; they do not establish that those system UI scripts passed. Template picker/navigation confirmation is covered by shared-guard tests and route review, while the native interaction test covers New/Cancel/Discard. Provider failure and recovery scenarios use controlled services; live-account delivery, external notification playback, and every provider permission combination were not exercised.

Earlier failures in the new native assertions came from SwiftUI exposing spoken values through `accessibilityValueDescription` and the hosted reader exposing a message header instead of the expected menu label. The assertions now read the observed accessibility properties and require the actual native message view. The cached-account test passed separately after that correction; the earlier combined native log retains its failed attempt.

## Coverage and evidence

| Surface | Review coverage |
| --- | --- |
| Mail | Sidebar, unified/account lists, search, pagination, message/thread reader, read state, labels, snooze, destructive actions, original source, routing |
| Compose | Recipients/groups, identities, rich text, quotes, signatures/templates, attachments, draft lifecycle, send/discard queues, Outbox, assistant proposals |
| Calendar and Tasks | Navigation/grids, recurrence, event editing, time zones/DST, gestures, invitations, import/export, conflicts, tasks, creation reconciliation |
| Assistant and organization | Scope, conversation preservation, model readiness, source navigation, result cards, copying, summaries, AI review, provider/tool boundaries |
| Attachments and analytics | Filters/pages, selection, file actions/retry/export, contacts, history coverage, charts, receipts, avatars/company logos |
| Settings and integration | Onboarding/auth, preferences, profiles, notifications, unsaved editors, cache maintenance, Spotlight, commands, Services, system routing |
| SwiftUI skill checks | API deprecations, view structure, state flow, navigation, Mac design/accessibility, resizing, localization/formatting, performance, Swift/concurrency, hygiene |

Original findings came from source/caller/test tracing. The recurrence round-trip was reproduced with the actual Swift type. Native inspection of the installed app corroborated missing accessible mailbox counts against the source at review time. The installed app was revision `f827c6b`, so those Mail/Calendar/Attachments screenshots are not current-build verification. The follow-up uses separately built native fixtures and tests; its evidence is recorded with the fix status above.

## Packages/Core/Sources/SyncEngine/SyncEngine+Search.swift

### F01 · P2 · Lines 85–90: Send valid provider identifiers

All Mail's Load Older action passes the app-only label `TERN_ALL_MAIL` to Gmail. `SystemLabel.allMail` defines that value in `MailStore/Records.swift:16`; `GmailClient.swift:83` forwards it unchanged. Gmail's endpoint filters by actual Gmail label IDs, so this request cannot fetch All Mail correctly. The existing query/label test covers Trash, Sent, and a user label but misses this case. [Gmail threads.list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.threads/list)

```swift
// Before
labelIDs: [labelID]

// After, retaining includeSpamTrash: false for All Mail
labelIDs: labelID == SystemLabel.allMail ? [] : [labelID]
```

## App/Mailbox/MailboxModel.swift

### F02 · P2 · Lines 587–589: Track downloaded coverage explicitly

Load Older treats the oldest cached message as proof that everything newer is downloaded. The cache is sparse: it contains recent mail, old Inbox messages, and held search results. A label with cached mail from 2020 and 2026 can have uncached archived mail from 2024. Asking Gmail for `before:2020` skips that entire interval.

The list can look complete while quietly omitting years of mail.

```swift
// Before
let cutoff = threads.map(\.lastDate).min()
try await engine.loadOlder(labelID: labelID, before: cutoff, pageToken: token)

// After: start with the server listing and deduplicate stored results
try await engine.loadOlder(labelID: labelID, pageToken: token)
```

An optimized implementation needs a persisted coverage watermark, not a minimum timestamp.

### F03 · P2 · Lines 570–575, 582–584: Preserve browsing capability in unified mailboxes

Only `.account` mailboxes can request older conversations. Combined/scoped Sent, Starred, and All Mail stop at the cache without a completion warning or a continuation action. This is a documented limitation, but it is still a product defect: changing account scope removes archive browsing.

```swift
// Before
guard case .account(let accountID, let labelID)? = selectedMailbox else { return }

// After: structural sketch; retain one cursor per account
guard let labelID = selectedLabelID else { return }
older = GmailPager(sources: selectedAccounts.pageSources(for: labelID))
```

The existing pager supports multiple sources. Show coverage and account-specific failures while filling them.

### F04 · P2 · Lines 567–575: Do not claim Inbox is complete when sync is capped

`SyncEngine.swift:64,501,705–706` caps initial Inbox loading at 5,000 messages and drops the remaining page token. The UI excludes Inbox from older pagination on the assumption that all Inbox mail is cached. A mailbox with more than 5,000 Inbox messages and an old tail cannot browse that tail. Search is a workaround; the Inbox itself never explains the omission.

```swift
// Before
let inbox = try await listMessageIDs(..., limit: Self.inboxCap)
// Inbox is always excluded from Load Older.

// After: behavior sketch
let page = try await loadInitialInboxPage(limit: Self.inboxCap)
try await saveInboxCoverage(nextPageToken: page.nextPageToken)
// Offer continuation until the server reports exhaustion.
```

Keep initial sync bounded, but make that bound resumable and visible.

## App/Views/ThreadListView.swift

### F05 · P2 · Lines 147–159: Distinguish no matches from hidden matches

Search results are filtered by the quick filters (`MessageListItem.swift:252–260`), but the empty state can announce no matches on this Mac or in Gmail when matching results exist. View → Quick Filters can also hide the controls without clearing their active state (`MessageListSettingsView.swift:87`; `MessageListHeader.swift:12,27`).

Trigger: enable Unread, hide Quick Filters, and search for a known read message. The app hides the result, hides the reason, and tells you the message was not found.

```swift
// Before
if preferences.showsQuickFilters { filterControls }

// After
if preferences.showsQuickFilters || !preferences.filters.isEmpty {
    filterControls
}
```

```swift
// Before: empty state depends only on search status
switch search.status { /* ... */ }

// After
if !preferences.filters.isEmpty, !search.results.isEmpty {
    Text("No Results Match Your Filters")
    Button("Clear Filters") { preferences.filters = [] }
} else {
    searchStatusView
}
```

## App/Views/MessageHeader.swift

### F06 · P2 · Lines 156–159: Preserve the sender's Bcc information

Details shows From, To, Cc, and Reply-To, but never Bcc. The data pipeline also omits it: `MessageRecord` has no field (`Records.swift:57–107`), metadata does not request it (`SyncEngine.swift:63`), and full-message mapping discards it. After sending a Bcc-only message, the normal reader cannot tell you who received it.

The same omission corrupts contact-level completeness: `MailAnalyticsStore.swift:48–51` indexes only To and Cc, so Bcc correspondence is absent from that contact's sent count and last-contact date even after full history loading. This limitation exists in developer documentation but not beside the affected metrics.

```swift
// Before
addresses("To", message.record.recipients)
if let cc = message.record.cc { addresses("Cc", cc) }

// After, following a nullable column migration and header mapping
addresses("To", message.record.recipients)
if let cc = message.record.cc { addresses("Cc", cc) }
if let bcc = message.record.bcc, !bcc.isEmpty { addresses("Bcc", bcc) }
```

Index Bcc recipients in sender analytics too. Display only Bcc data Gmail actually supplies; do not infer recipients for received mail.

## App/Views/SidebarView.swift and App/Views/FavoritesView.swift

### F07 · P2 · Sidebar lines 462–465, 605–608; Favorites lines 132–140: Expose visible counts to accessibility

Rows ignore their children after applying a badge, then expose only the mailbox name and expansion state. Native inspection showed visible Drafts and Spam counts absent from their accessibility rows. The affected code is identical between the installed build and this checkout.

```swift
// Before
.accessibilityElement(children: .ignore)
.accessibilityLabel(box.title)
.accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

// After: a single value containing both pieces of information
.accessibilityElement(children: .ignore)
.accessibilityLabel(box.title)
.accessibilityValue(mailboxBadgeDescription + ", " + expansionDescription)
```

Use the configured unread/total semantics, not a universal “unread” label. Update `SidebarDisclosureAccessibility` so it does not overwrite the combined value. A sighted user's glance at the sidebar must have a VoiceOver equivalent.

## App/Views/OriginalMessageView.swift

### F08 · P2 · Lines 22–25, 80–81: Show export failures without removing the document

Save requires nonnil `bytes`. A failed write sets `failure`, but the body always takes the `if let bytes` branch first. The error is unreachable for every Save failure. Disk full or a removed destination volume therefore looks like a completed export.

```swift
// Before
catch { failure = "The original message could not be saved." }

// After: separate load and save failures
@State private var saveError: String?
// ...
catch { saveError = "The original message could not be saved." }
// Present saveError in an alert over the existing source view.
```

## Packages/Core/Sources/MailStore/Drafts.swift

### F09 · P1 · Lines 515–520: Keep an unsent message cancellable

`cancelExit` requires zero attempts. The send queue consumes an attempt before draft lookup/upload, while `sendRequested` is set only immediately before `gmail.sendDraft` (`ComposeQueue.swift:290–313`). An offline lookup/upload failure can remove cancellation even though sending has never been requested. `OutboxView.swift:49–50` repeats the zero-attempt restriction; the `.sending` draft is also locked in the composer.

Trigger: queue mail, fail its first pre-send request offline, then try to stop it before reconnecting. The interface leaves it committed to sending when connectivity returns.

```swift
// Before
guard row.state == .queued, row.attempts == 0 else { return false }

// After: preserve uncertainty handling for requests that may have sent
let canCancel = kind == .sendDraft
    ? !draft.sendRequested
    : row.attempts == 0
guard row.state == .queued, canCancel else { return false }
```

Expose the same state predicate in Outbox as Cancel Send. Keep in-flight and uncertain sends protected until reconciled.

## Packages/Core/Sources/SyncEngine/ComposeQueue.swift

### F10 · P2 · Lines 201–204: Validate the attachments that will actually be sent

Deleting an inline image removes its editor reference but retains its attachment row. Size validation sums every row, although message preparation skips unused inline parts at lines 384–390. The attachment strip hides inline parts, so the deleted image can exhaust the allowance without leaving anything visible to remove.

```swift
// Before
let total = existingAttachments.reduce(size) { $0 + $1.size }

// After: use the same referenced-CID set as message preparation
let included = existingAttachments.filter {
    $0.contentID.map(referencedInlineIDs.contains) ?? true
}
let total = included.reduce(size) { $0 + $1.size }
```

Flush pending editor changes before resolving references from body/quote state transactionally; the stored draft can trail the editor by 500 ms. Retain data needed for editor Undo, but exclude unused parts from the send budget.

### F11 · P2 · Lines 125–133, 190–204: Reject oversized files before copying them

The app copies an entire selected file before checking the message size limit. A multi-gigabyte video can consume disk space and block the account's sync actor during a synchronous copy, then be rejected. The file picker invites an operation the implementation could reject immediately.

```swift
// Before
try FileManager.default.copyItem(at: url, to: destination)
// Check size afterward.

// After
let info = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
guard info.isDirectory != true else { throw ComposeError.folder(name) }
guard let size = info.fileSize,
      Self.encodedSize(size) <= Self.maxMessageSize else {
    throw ComposeError.fileTooLarge(name)
}
// Copy using a bounded file-I/O worker; validate final size again.
```

Preflight the remaining attachment budget too. A final check remains necessary because files can change during copying. No performance duration is claimed here; the unnecessary full-file copy is established by control flow.

## App/Compose/ComposeModel.swift

### F12 · P2 · Lines 443–454, 623–635, 661–671: Include pending recipients in close and move decisions

Sending is blocked while a contact group expands; closing, quitting, and changing account lack that guard. `RecipientField.swift:384–402` immediately removes the group token before its members arrive, and teardown cancels expansion at lines 217–223. Close or move a draft during a slow expansion and its intended recipients disappear.

```swift
// Before: close/move checks attachment work only
if let hold = attachmentHold { /* block close */ }

// After: shared close/move/quit prerequisite
if expandingGroups > 0 {
    alert = Problem(title: "Recipients Are Still Loading",
        message: "Wait for the contact group to finish loading.")
    return
}
if let hold = attachmentHold { /* existing handling */ }
```

A better long-term implementation persists unresolved group tokens so closing does not depend on network speed.

### F13 · P2 · Lines 424–437: Restore persistence and explain a failed Discard

Discard cancels both persistence timers, suppresses store errors with `try?`, and returns false without an alert or restarting persistence. A transient local-store failure leaves a button that appears to do nothing and pending edits whose scheduled saves have been cancelled.

```swift
// Before
(try? await engine.discardDraft(id, content: content, hold: Self.discardHold)) ?? false

// After, inside the serialized operation
do {
    return try await engine.discardDraft(id, content: content, hold: Self.discardHold)
} catch {
    alert = Problem(title: "Couldn't Discard Draft",
        message: "The draft is still open. Try again.")
    return false
}
// If not queued, restore pending persistence scheduling.
```

## App/Compose/ComposeView.swift

### F14 · P2 · Lines 612–648: Let users control their outgoing quoted content

Replies and forwards show a read-only quote with a show/hide toggle. Hiding it does not exclude it: `ComposeQueue.swift:620–626` always appends it. A user forwarding an email cannot trim confidential history below the relevant paragraph. Selected-text replies exist, but exclude forwards and cannot revise a quote after composition starts.

```swift
// Before
Text(quote).textSelection(.enabled)

// After: an editable quotation with an explicit removal action
QuotedMessageEditor(text: quote,
    onReplace: model.replaceQuote,
    onRemove: model.removeQuote)
```

The engine already has a quote-replacement path. Connect it to model-owned edits, preserve threading headers, and represent removal in both HTML and plain text. A show/hide control does not provide a way to edit or remove outgoing content.

## App/Compose/ComposeSignatureView.swift

### F15 · P2 · Lines 12–40: Treat a signature as an editable per-message choice

The signature is separate from the editable body and can only be previewed. There is no per-message None/Choose/Remove control. Changing defaults does not update an existing draft (`LocalSignaturesPane.swift:80`). Removing a phone number from one reply should not require rebuilding the draft or changing sending identity.

```swift
// Before
ComposeSignatureView(html: html)

// After
ComposeSignatureView(html: html,
    onRemove: { model.content.signatureHTML = nil },
    onChoose: model.chooseSignature)
```

Offer None and saved signatures without changing global defaults.

## App/Compose/ComposeTemplatesPane.swift and LocalSignaturesPane.swift

### F16 · P2 · Templates lines 27, 56–59; signatures lines 30, 87–90: Protect explicit-save editors from selection changes

The picker and New button replace the editor's name/document immediately, even though these panes have explicit Save buttons. Switching to inspect another template or signature destroys the unsaved version.

```swift
// Before
.onChange(of: selection) { _, id in loadIntoEditor(id) }

// After: keep actual selection unchanged until the request is resolved
Picker("Template", selection: $editor.requestedSelection)
.confirmationDialog("Save Changes?", isPresented: $editor.showsUnsavedChanges) {
    Button("Save Changes") { editor.saveAndSwitch() }
    Button("Discard Changes", role: .destructive) { editor.discardAndSwitch() }
    Button("Cancel", role: .cancel) { editor.cancelSwitch() }
}
```

Keep a saved baseline and route New, selection changes, pane navigation, and closing through the same editing-session guard.

## App/Calendar/CalendarModel+Proposals.swift

### F17 · P1 · Lines 162–166, 183–185: Give every conflict a working recovery path

Every conflicted operation enters `reviewOperation`, but `.move`, `.respond`, `.splitSeries`, and `.deleteFollowing` fall into a branch that tells the user to retry without opening a review. Review and Retry therefore repeats itself forever. Activity closes, no editor opens, and the event remains blocked by `CalendarPendingEvents.swift:9–17`. Attempted conflicts cannot be cancelled (`CalendarStore.swift:300–304`).

Trigger: move an event after another client has changed its ETag. The conflict detection works; the recovery design does not. Permanent failures also retry unchanged invalid input without an edit route.

```swift
// Before
if operation.status == .conflicted {
    reviewOperation(operation)
    return
}

// After: operation-specific reconciliation/review
if operation.status == .conflicted {
    switch operation.mutation {
    case .move: await reviewMoveConflict(operation)
    case .respond: await reviewResponseConflict(operation)
    case .splitSeries, .deleteFollowing:
        await reconcileAndReviewSeriesConflict(operation)
    default: reviewOperation(operation)
    }
    return
}
```

Provide discard only when reconciliation establishes that it is safe. Do not blindly replace ETags or forget partially completed series operations. Root-cause confidence is high; the full recovery design needs careful implementation and has medium fix-design confidence.

## App/Tasks/GoogleTaskEditingSession.swift

### F18 · P2 · Lines 8, 46–51: Refresh the editing baseline after conflict review

The editor's immutable `context.task` retains its original ETag. On a 412 conflict, the model refreshes the task list but never updates that editing session; Save sends the stale ETag again (`GoogleTasksModel+Editing.swift:138,144–149`). The user must cancel and manually recreate their edits.

```swift
// Before
let context: GoogleTaskEditorContext
if let task = context.task {
    saved = await model.update(task, update: update, location: context.location)
}

// After: preserve local fields while reviewing a new server baseline
var baseline: GoogleTask
var conflict: TaskEditConflict?
conflict = TaskEditConflict(base: baseline, local: localDraft, remote: latest)
// After explicit review, save against the reviewed remote version.
```

Preserving draft text is already implemented. Finish the flow with a comparison/reload/reapply decision; automatically adopting a new ETag would merely hide the conflict.

## App/Calendar/CalendarEventEditor.swift

### F19 · P2 · Line 207, affecting 157–160 and 199–202: Disable mutations, not useful reading actions

The entire Form is disabled for a read-only calendar. That disables Join Meeting and attachment links along with editing fields. Permission to change a calendar should not decide whether a user can join its meeting. Opening Google Calendar is an unnecessary escape route for a native action already on screen.

```swift
// Before
Form { editableFields; meetingLink; attachmentLinks }
    .disabled(!editable || isSaving)

// After
Form {
    editableFields.disabled(!editable || isSaving)
    meetingLink
    attachmentLinks
}
.disabled(isSaving)
```

## App/Calendar/RecurrenceSelection.swift

### F20 · P2 · Lines 23–30: Read the recurrence rules the editor writes

Ends → On Date writes `UNTIL`, but the parser's supported-field set omits it. Create a weekly event with an end date and reopen it: the structured controls become a raw Custom Rule editor. A normal calendar operation turns into an RRULE editing task.

Reproduced with the actual source: `RRULE:FREQ=WEEKLY;UNTIL=20270115T235959Z` reopened with frequency `CUSTOM` and end mode `never`.

```swift
// Before
let supported = Set(["FREQ", "INTERVAL", "BYDAY", "COUNT"])

// After: parser must handle date-only and UTC forms
let supported = Set(["FREQ", "INTERVAL", "BYDAY", "COUNT", "UNTIL"])
if let raw = fields["UNTIL"] {
    if let date = parseUntil(raw, eventTimeZone: timeZone) {
        until = date
        endMode = "until"
    } else {
        frequency = "CUSTOM"
    }
}
```

Pass the event time zone/all-day context into parsing; retain raw custom rules for genuinely unsupported cases.

## App/Tasks/GoogleTasksModel+Editing.swift

### F21 · P2 · Lines 61–72: Keep first-time task creation proportional to the task

Every Add scans every task from every list sequentially before inserting. The client includes completed and hidden tasks and pages at 100. A large archive delays a tiny operation; a failure in an unrelated list prevents creation in a healthy destination.

For a new quick task, its reference is a fresh UUID, so that scan cannot find a pre-existing duplicate. Broad reconciliation belongs to uncertain retries and stable mail-derived references.

```swift
// Before
for list in availableLists {
    let existing = try await client.allTasks(listID: list.id)
    // Search for the request marker.
}

// After: retain reconciliation where identity can already exist
if wasUncertain || request.source != nil || request.deduplicationKey != nil
    || confirmedTasks[request.reference] != nil {
    try await reconcileExistingTask(request, in: availableLists)
}
```

Also account for any previously confirmed reference and preserve the uncertainty marker before POST. This is verified request amplification, not a claimed timing benchmark.

## App/Calendar/CalendarActivityView.swift

### F22 · P2 · Lines 87–97: Identify the event a recovery action concerns

Rows say Update event, Delete event, or Move event, followed by when the operation was created. Several failures in the same calendar become indistinguishable. The operation already retains event snapshots, but the UI hides the title and scheduled date needed to choose safely.

```swift
// Before
case .update: "Update event"

// After
case .update:
    "Update \(operation.resultEvent?.title ?? operation.beforeEvent?.title ?? "event")"
```

Show the event's scheduled time separately from the change-request time. Persist a useful display summary when a snapshot is unavailable.

## App/Assistant/AssistantNavigation.swift

### F23 · P1 · Lines 15–18, 27–28: Make evidence links open their evidence

Open Source drops the message/part identity and selects the thread in All Mail. A citation cannot focus its supporting message. If the thread is outside the loaded page or excluded by filters, `MailboxModel.listChanged()` can remove the selection and leave an empty reader.

The app validates evidence carefully, then loses it on the click intended to verify it. `MailURLRouter` already handles message focus, off-page conversations, Spam/Trash, and presentation scope.

```swift
// Before
mailbox.selectedMailbox = .account(source.accountID, SystemLabel.allMail)
mailbox.selectedThreadIDs = [ThreadKey(accountID: source.accountID, threadID: source.threadID)]

// After, retaining the assistant's authorization checks
mailURLs.openConversation(MailLink(accountID: source.accountID,
    threadID: source.threadID, messageID: source.messageID))
```

Preserve message identity in detached windows too; reveal the cited attachment when attachment-target navigation is supported.

## App/Assistant/AssistantModel.swift

### F24 · P1 · Lines 33–34, 189–193, 596–600: Separate context changes from permission revocation

`refreshAccess()` clears the entire conversation and unfinished prompt whenever effective scope changes. The composer scope picker binds directly to that behavior. In Selected conversations scope, selecting another thread does it too; in Mailbox accounts scope, changing accounts can do the same. Settings confirms access changes, but ordinary navigation bypasses that protection. New Chat also clears unfinished input immediately (`AssistantView.swift:144–148`).

```swift
// Before
if previous != snapshot { clearConversation() }

// After: state-flow sketch
if permissionsWereRevoked(from: previous, to: snapshot) {
    clearConversation()
} else if previous != snapshot {
    stop()
    pendingScope = snapshot
    // Require a deliberate keep/start-new decision before more requests.
}
```

Keep strict revocation handling. Preserve unfinished input on normal navigation, and never carry old context into new requests without a defined, visible scope decision.

## App/Assistant/AssistantMessageView.swift

### F25 · P2 · Lines 208–224: Copy the answer, including its cards

Copy Response omits `emailResults`. The model is explicitly instructed to put subjects, senders, dates, and reasons in cards instead of repeating them in prose. A useful five-card answer can therefore copy as only an introductory sentence. Task/event export also drops significant fields and usable source links.

```swift
// Before
var parts = message.text.isEmpty ? [] : [message.text]
// Only abbreviated task/event rows follow.

// After: move visible-result serialization out of the view
var parts = message.text.isEmpty ? [] : [message.text]
parts += message.emailResults.map(AssistantResultExport.email)
parts += message.taskResults.map(AssistantResultExport.task)
parts += message.eventResults.map(AssistantResultExport.event)
```

Include the visible qualifications, dates, owners, locations, and validated source links. Copy should not quietly strip the reasons a result can be trusted.

## App/Assistant/AssistantView.swift

### F26 · P2 · Lines 96–114: Show actual model readiness and recovery

The setup state checks only whether a model ID is saved. A failed catalogue refresh clears `models` while retaining that ID (`AssistantModel.swift:255–260`), so the composer looks ready. Submission then rejects the unavailable model and tells the user to choose one; the actual catalogue error is buried in Settings.

```swift
// Before
if model.selectedModelID.isEmpty { return chooseModelPrompt }

// After
if !model.models.contains(where: { $0.id == model.selectedModelID }) {
    return modelsUnavailablePrompt(error: model.modelErrorMessage,
        isLoading: model.isLoadingModels)
}
```

Offer an inline refresh and preserve the typed prompt. A saved choice is not evidence that the service is ready.

## App/Organization/MailOrganizationCategoryRow.swift

### F27 · P2 · Lines 195–209; MailOrganizationModel.swift:146–151: Make review capable of correcting a bad match

The review screen allows accepting a category, changing its name, or enabling future filters. Individual messages are read-only examples, and Apply always sends the immutable full `proposal.messageIDs`. One misclassification forces the user to accept it or discard the whole useful category. The snippets are truncated and lack an Open Message action (`MailOrganizationExampleRow.swift:44–52`).

```swift
// Before
messageIDs: category.proposal.messageIDs

// After
messageIDs: category.proposal.messageIDs.filter {
    category.selectedMessageIDs.contains($0)
}
```

Add per-message inclusion controls and source navigation. Recompute counts and future-rule eligibility after edits. Calling a bulk yes/no screen “review” does not give users enough control over AI mistakes.

## App/Assistant/AssistantEmailCard.swift

### F28 · P2 · Lines 25–28: Disambiguate historical dates

Results always show month and day without a year, even though searches can return years-old mail. The tooltip does not provide the missing date. “Oct 12” is inadequate context for a follow-up decision.

```swift
// Before
Text(date, format: .dateTime.month(.abbreviated).day())

// After, or conditionally include year for older mail
Text(date, format: .dateTime.year().month(.abbreviated).day())
    .help(date.formatted(date: .complete, time: .shortened))
```

The organization example row has the same short date, but already offers a complete-date tooltip.

## App/Assistant/AssistantConversationView.swift

### F29 · P3 · Lines 63–84: Give each lazy message one stable top-level container

Each `ForEach` element emits a conditional day separator, a message, and optional calendar actions directly into the lazy stack. The varying number/shape of top-level children defeats the fixed-row structure recommended by the skill. This is an efficiency finding; no measured lag is claimed.

```swift
// Before
ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
    messageRow(message, at: index)
}

// After
ForEach(model.messages.enumerated(), id: \.element.id) { index, message in
    VStack(alignment: .leading, spacing: Tokens.Space.s2) {
        messageRow(message, at: index)
    }
}
```

Preserve any scroll anchors and intentional separator spacing when extracting a dedicated message-row type.

## App/Settings/IntegrationSettingsView.swift

### F30 · P1 · Lines 17–19, 100: Guard account changes before replacing unsaved editors

Vacation Responder's unsaved-change protection covers Settings sidebar navigation and closing, but not its Account picker. That picker immediately changes `selectedAccount`; `.id(owner.account.id)` destroys the editor, and `VacationPane.swift:52` clears the dirty flag. Edit account A, switch to B, return to A: the unsaved responder is gone.

An external Settings destination write can bypass the same guard: Calendar management changes the `@AppStorage` destination directly instead of calling `SettingsView.leave(for:)` (`CalendarView.swift:159`; `SettingsView.swift:7,17`).

```swift
// Before
Picker("Account", selection: $selectedAccount)

// After: intercept before mutation
Picker("Account", selection: Binding(
    get: { selectedAccount },
    set: { requested in
        if unsaved.subject != nil { pendingAccount = requested }
        else { selectedAccount = requested }
    }
))
```

Resolve `pendingAccount` through save/discard/cancel. Route external navigation requests through the same guard. This custom binding is justified: observing the destructive change afterward is too late.

## App/TernApp.swift and App/AppModel.swift

### F31 · P1 · TernApp lines 355–365; AppModel lines 555–561, 973–976: Keep cached work accessible during reauthentication

For a single expired account, RootView replaces the entire workspace with Sign In. Runtime expiry retains the mailbox but hides it; launch-time restoration returns before opening it. Cached mail, drafts, Outbox, Calendar, and attachment navigation become inaccessible until Google authentication succeeds. The screen says the downloaded mail is still there while refusing access to it.

```swift
// Before
} else if case .signedIn = model.phase {
    if let mailbox = model.mailbox { WorkspaceView(mailbox: mailbox) }
}

// After: also restore the cache-backed mailbox without a valid token
} else if let mailbox = model.mailbox {
    WorkspaceView(mailbox: mailbox)
        .safeAreaInset(edge: .top) { ReconnectAccountBanner(app: model) }
}
```

Retain authorization checks on network actions. Reauthentication should interrupt synchronization, not confiscate access to local work.

## App/Accounts/MailNotificationScheduler.swift

### F32 · P2 · Lines 38–46: Let macOS control notification audio

With Tern's two sound settings enabled, new mail calls `NSSound.play()` after adding a notification. That playback bypasses the notification system's separate sound permission and delivery decision. Turning notification sounds off in macOS can still leave Tern playing Ping. Apple documents that system sound authorization is respected by `UNNotificationContent.sound`. [Notification sound](https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent/sound), [sound setting](https://developer.apple.com/documentation/usernotifications/unnotificationsettings/soundsetting)

```swift
// Before
try await center.add(request)
if usesEffect { await MainActor.run { MailSounds.play(.newMail) } }

// After
content.sound = delivery.playsSound ? .default : nil
try await center.add(UNNotificationRequest(identifier: delivery.id,
    content: content, trigger: nil))
```

Use a bundled `UNNotificationSound(named:)` for a custom tone. Explicit archive/trash/send action sounds can remain separate.

## App/Integration/CacheMaintenanceModel.swift

### F33 · P2 · Lines 96–100, 109–110, 132–133: Keep ordinary drafts from disabling the whole storage budget

Trimming reuses the whole-cache-reset prerequisite: no drafts or pending/failed actions anywhere. One saved draft disables automatic trimming and Trim Now, even if gigabytes of unrelated content are disposable. An existing test explicitly codifies this behavior (`CacheBudgetTests.swift:35–53`).

The store already protects affected threads and rechecks those protections during eviction (`MailStore/CacheMaintenance.swift:142–168`). A mail client should not require an empty Drafts folder to manage storage.

```swift
// Before
guard readiness?.canReset == true else { return }
let candidates = try await cache.evictionCandidates(keeping: initialProtection, now: now())

// After
let candidates = try await cache.evictionCandidates(
    keeping: try await protectedThreads(), now: now())
// Preserve transactional draft/action/hold protection during eviction.
```

Keep `canReset` on destructive reset. Replace the blanket-refusal test with one proving protected content survives while unrelated content is evicted.

## App/Settings/FailedChangesView.swift

### F34 · P2 · Lines 54–85: Identify what Retry and Discard will affect

Failed changes show an action category, account, and error. Two failed Change message labels operations in one account are indistinguishable. There is no subject, relevant label/filter name, operation time, or source-opening action; accessibility repeats the same ambiguity.

```swift
// Before
Text(title(row.kind))
Text(row.lastError ?? "Gmail refused this change.")

// After: resolve presentation from the queued intent and cached source
Text(failure.actionTitle)
Text(failure.targetDescription)
Text(failure.createdAt, format: .dateTime)
Button("Show Affected Mail") { failure.openSource() }
```

Use a meaningful fallback and affected-item count if the source no longer exists. Raw IDs are not an adequate primary explanation. Recovery requires the user to recognize the work being recovered.

## App/Integration/MailSpotlightIndexer.swift

### F35 · P2 · Lines 60–61, 111–117, 235–236: Make privacy-related deletion durable

Disabling Show Mail in Spotlight makes one deletion attempt and swallows its error. Future launches return early while indexing is disabled, so a failed removal is never retried. Indexed subjects, sender names, and previews use `.distantFuture` expiry. The preference can say Off while old indexed content remains searchable.

```swift
// Before
indexed = [:]
try? await Self.removeEverything()

// After: persist intent before asking Spotlight to remove data
defaults.set(true, forKey: pendingRemovalKey)
do {
    try await Self.removeEverything()
    indexed = [:]
    defaults.set(false, forKey: pendingRemovalKey)
} catch {
    removalError = "Mail could not yet be removed from Spotlight."
}
```

Retry pending removal on launch even when indexing is disabled, and expose Retry in Reading settings. Account-specific removal has the same error suppression. The failure path is source-proven; an OS deletion failure was not injected.

## App/Attachments/AttachmentLibraryModel.swift

### F36 · P2 · Lines 280–303, 327–332, 421–427: Retry the operation that actually failed

Copy and Open With never set `lastAction`, so Try Again reloads the index or retries an unrelated previous action. Preview/Open set it before the busy guard; a second ignored context-menu command can replace the retry target for a first operation that later fails.

```swift
// Before
await perform { AttachmentActions.copy(try await file(for: item)) }

// After
await perform(action: .copy(item)) {
    AttachmentActions.copy(try await file(for: item))
}

// Inside perform, claim work and retry identity together:
guard !isWorking else { return }
isWorking = true
lastAction = action
```

Add Copy/Open With action cases and retry branches. Disable unavailable commands while work runs. A retry button that merely clears the error is false reassurance.

### F37 · P2 · Lines 61–63, 198–207: Clamp the current page when live results shrink

Navigate to page two of 101 attachments, then let a deletion or classification change remove its last result. Observation returns zero items and total 100, but offset remains 100. The UI can show No Attachments Yet and “101–100 of 100 attachments” while 100 files still exist.

```swift
// Before
loadedPage = page // pageOffset remains unchanged

// After, before publishing
let lastOffset = max(0, (page.totalCount - 1) / request.limit * request.limit)
if pageOffset > lastOffset {
    pageOffset = lastOffset
    return // Restart observation using the corrected key.
}
loadedPage = page
```

Existing pagination and deletion tests do not combine these conditions.

## App/Attachments/AttachmentLibraryView.swift

### F38 · P2 · Lines 217–232: Make Copy honor the visible selection

Select multiple files and choose Copy from a selected row's context menu: only one selected file is copied. Open, Quick Look, Share, and Show in Finder use the selection. The implementation's Finder-like presentation promises consistent bulk behavior and then silently changes the rule for Copy.

```swift
// Before
Button("Copy", systemImage: "doc.on.doc") {
    Task { await model.copyFile(item) }
}

// After
Button("Copy", systemImage: "doc.on.doc") {
    Task { await model.copyFiles(files) }
}
```

Capture the selection, prepare its URLs, and write them to the pasteboard together. Report partial failures explicitly.

## App/Analytics/MailAnalyticsModel.swift

### F39 · P2 · Lines 96–118: Isolate history-loading failures between accounts

One `do/catch` wraps the entire account loop. A reauthentication or rate-limit failure in the first account prevents every later healthy account from loading. Retrying hits the same first failure; the generic error does not identify it.

```swift
// Before
do {
    for owner in accounts { try await loadAllPages(owner) }
} catch { historyError = "Couldn't finish loading history…" }

// After
for owner in accounts {
    do { try await loadAllPages(owner) }
    catch is CancellationError { return }
    catch { failedAccounts.append(owner.account.id) }
}
```

Retain successful coverage and offer account-specific recovery. One account's outage should not make the entire analytics window incomplete indefinitely.

## App/Design/AddressAvatar.swift and DomainLogoAvatar.swift

### F40 · P2 · AddressAvatar line 30; DomainLogoAvatar line 10: Make privacy promises match network defaults

Onboarding says “Load images only when you choose to” (`OnboardingPreferencesStep.swift:52`), but company-logo fetching defaults on independently of blocked message images. `DomainLogoImages.swift:239–243` contacts sender websites for visible-avatar fallbacks, including mail the user has not opened. Those sites receive the network connection's IP address. Reading settings discloses this separately; onboarding does not offer the choice.

This finding does not claim that message bodies, tokens, email addresses, or cookies are transmitted. The defect is a broad privacy promise paired with a narrower implementation.

```swift
// Before, repeated across avatar/compose/settings views
@AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = true

// After: use one consistent opt-in default
@AppStorage(DomainLogoImages.preferenceKey)
private var showsLogos = DomainLogoPreferences.defaultEnabled // false
```

Offer company logos explicitly with the network disclosure. Clarify the other option as “Load images inside messages only when you choose to.” Update all default call sites together, including recipient and sender avatars.

## SwiftUI API maintenance by file

### F41 · P3 · Replace confirmed soft-deprecated overloads

The installed macOS SDK marks these overloads `deprecated: 100000.0`, so a warning-free build does not clear them. All replacements fit the existing macOS 26 target.

| File | Lines | Replacement |
| --- | --- | --- |
| `App/Assistant/AssistantConversationView.swift` | 54 | `coordinateSpace(.named(...))` |
| `App/Calendar/CalendarTimeGrid.swift` | 73 | `coordinateSpace(.named(...))` |
| `App/Calendar/CalendarMonthGrid.swift` | 55 | `coordinateSpace(.named(...))` |
| `App/Compose/ComposeView.swift` | 42–44 | Builder-form `background` |
| `App/Calendar/CalendarTimeGrid.swift` | 83, 127–128 | Builder-form `background` |
| `App/Calendar/CalendarMonthGrid.swift` | 48–52, 65 | Builder-form `background` |

```swift
// Before
.coordinateSpace(name: "assistant-scroll")
.background(WindowEditedMarker(isEdited: isEdited))

// After
.coordinateSpace(.named("assistant-scroll"))
.background { WindowEditedMarker(isEdited: isEdited) }
```

Apply the same builder conversion to the other listed view arguments. Do not mechanically replace `BarMark.cornerRadius`: that is a Charts API, not the deprecated SwiftUI View modifier.

## Tests/AppTests/ThreadSummaryTests.swift

### F42 · P2 · Lines 106–113: Make a scope-security test choose its scope explicitly

The hosted test suite fails because this test expects selected-thread scope while the model now defaults to all enabled accounts. Changing `selectedThreads` does not restrict that default scope, so returning the cached summary is correct. Commit `5a5171f` changed the default; the test setup did not follow it.

```swift
// Before
let fixture = Fixture(provider: provider)
await fixture.model.refreshConnection()

// After
let fixture = Fixture(provider: provider)
fixture.model.selectedScope = .selectedThreads
await fixture.model.refreshConnection()
```

This is a stale test and lost specificity in a security-boundary check, not evidence of unauthorized access. `readerSummary` validates authorization before cache lookup. Fix the setup and retain the assertion.

## What the design needs beyond isolated patches

The screen-by-screen problems share a few causes. Save/discard protection is implemented around some navigation routes but bypassed by others. Completion and empty states describe local arrays as if they represented the whole server. Recovery buttons are connected to generic queues without enough information about the operation they are recovering. Outgoing and AI-generated content is presented as reviewable while the user lacks the controls to correct it.

Fix those interaction rules across features. Give each editor one guarded session lifecycle. Give mail, attachments, search, and analytics explicit coverage and filter state. Make failures identify their target and offer an operation-specific next step. Make previews editable or provide clear exclusion controls wherever their contents will be sent or applied.

Visually, keep the semantic colors and native controls. The main toolbar already groups related actions and folds them as space narrows; the evidence does not justify a blanket custom-toolbar rewrite. Apple recommends grouping commands by function and frequency, which is a useful constraint for future simplification. [Apple's toolbar guidance](https://developer.apple.com/design/human-interface-guidelines/toolbars)

The retained Mail sidebar beside the global attachment library can confuse scope, but the library explicitly has its own account filter and documented global behavior. Treat that as a usability question for observation, not an authorization leak. Likewise, the installed app's duplicate hidden accessibility tree and unhelpful sort-menu AX name need current-build reproduction before becoming defects. They are excluded from the 42 findings.

## Original review verification and limits

- Core: `swift test --package-path Packages/Core` passed 686 tests in 114 suites.
- Hosted app: built successfully in isolated DerivedData; 615 tests in 92 suites ran with one failure, F42. The ordinary build-directory attempt was blocked by a concurrent build's database lock; the isolated run avoided it.
- Focused rerun: the same summary test failed again; the other summary tests passed. All three opt-in visual tests passed, producing 44 native captures: 12 assistant, four calendar sidebar, and 28 analytics/contact/receipt views. Selected light/dark and narrow captures were inspected. The combined focused run was 15 tests in four suites with the one known test-setup failure; it is not a clean test run.
- Recurrence: the actual `RecurrenceSelection.swift` was compiled in a temporary harness and reproduced F20.
- Native inspection: installed Mail, Calendar, and Attachments were inspected without sending mail or creating/modifying tasks or events. The count-accessibility evidence was checked against unchanged current source.
- API status: checked the installed SwiftUI declarations for soft deprecations and primary Apple/Google documentation for provider and notification behavior.
- Evidence logs and exported captures: `/tmp/tern-design-review-2026-11-02/`. The full hosted result is `DerivedData/Logs/Test/Test-Tern-2026.11.02_16-24-56-+0100.xcresult`; the focused/visual result is `Test-Tern-2026.11.02_16-29-43-+0100.xcresult` in the same directory. These are local verification artifacts, not a permanent archive. Tests do not validate later concurrent application edits.
- The review did not attempt every combination of window size, locale, accessibility setting, provider failure, or real-account permission state. Synthetic checks and source tracing establish specific findings, not universal certification. No timing claims are made without measurement, and no speculative security finding is counted.

Useful safeguards were preserved in the assessment: account-qualified identities, send-uncertainty reconciliation, attachment failure guards, assistant evidence validation, consent before task/event saves, DST-aware calendar mapping, stale-gesture invalidation, accessible chart tables, honest partial-history labels, export collision handling, and Reduce Motion support. Files with no substantiated issues are omitted.

## Prioritized changes

1. Protect user control and unfinished work: cancellable pre-send failures (F09), calendar conflict recovery (F17), reliable evidence navigation (F23), scope-change preservation (F24), guarded settings navigation (F30), and cached access during reauthentication (F31).
2. Make mail discoverable and results truthful: pagination/coverage (F01–F04), hidden quick filters (F05), Bcc metadata and analytics (F06), and live attachment pagination (F37).
3. Finish composing: pending recipients (F12), discard recovery (F13), quote/signature control (F14–F15), editor protection (F16), and attachment validation/I/O (F10–F11).
4. Make recovery and review useful: task conflicts and recurrence (F18, F20), operation context (F22, F34), AI copy/readiness/corrections (F25–F27), attachment retry/bulk Copy (F36, F38), and per-account history loading (F39).
5. Honor system and privacy choices: notification audio (F32), durable Spotlight removal (F35), and explicit company-logo consent (F40). Restore effective storage budgeting (F33) and visible-count accessibility (F07).
6. Repair the failing test (F42), then address the smaller date/export/link issues (F08, F19, F28), task request amplification (F21), lazy-row structure (F29), and API maintenance (F41). The cosmetic work comes after these interaction failures.
