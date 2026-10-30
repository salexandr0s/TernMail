# Milestone 5 store contracts

Accepted by the integration lead on 2026-10-30. These contracts support the [execution checklist](milestone-5-execution.md) and [approved scope](milestone-5.md). The store implementation is integrated and covered by the Core suite. This document records the shared API contract; the source defines the complete methods and migrations.

All public records are `Codable`, `Sendable` and `Equatable`, with public initializers and explicit defaults. Account-scoped config tables have cascading foreign keys to `account`. Keep `AccountRecord` unchanged. Store user setup in config; reading resources and downloaded mail remain disposable.

## Account preferences and profiles

```swift
struct AccountMailPreferences {
    var accountID: String
    var nickname: String?                    // nil
    var sortOrder: Int                       // 0; ties use account.addedAt
    var syncEnabled: Bool                    // true
    var profileID: String?                   // nil = visible in All
    var inboxCategories: Set<InboxCategory>   // []
    var notificationRule: MailNotificationRule // .off
}
enum InboxCategory { case social, promotions, updates, forums }
enum MailNotificationRule { case off, inbox, inboxWithoutCategories, allMail }

struct MailProfile {
    var id: String
    var name: String
    var colorIndex: Int
    var symbol: String
    var sortOrder: Int
    var notificationSchedule: ProfileNotificationSchedule
}
enum ProfileNotificationSchedule {
    case unrestricted
    case off
    case everyDay([DailyTimeRange])
    case weekdays([DailyTimeRange])
    case custom([ISOWeekday: [DailyTimeRange]])
}
struct DailyTimeRange { var startMinute: Int; var endMinute: Int }
enum ISOWeekday: Int {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
}
```

Ranges satisfy `0 <= startMinute < endMinute <= 1440`. Split overnight schedules into adjacent-day ranges. Times follow the Mac's current local timezone. `unrestricted` preserves ordinary alert behavior until the user configures a schedule; `off` suppresses alerts. All is a virtual profile, never a persisted `MailProfile`.

`AccountStore` methods:

```swift
func mailPreferences(accountID: String) async throws -> AccountMailPreferences
func allMailPreferences() async throws -> [AccountMailPreferences]
func observeMailPreferences() -> AsyncThrowingStream<[AccountMailPreferences], any Error>
func observeMailProfiles() -> AsyncThrowingStream<[MailProfile], any Error>
func updateMailPreferences(accountID: String,
    _ change: @escaping @Sendable (inout AccountMailPreferences) -> Void
) async throws -> AccountMailPreferences
func mailProfiles() async throws -> [MailProfile]
func saveMailProfile(_ profile: MailProfile) async throws
func deleteMailProfile(id: String) async throws
```

Preference reads supply defaults for an existing account and throw `MailPreferencesError.accountMissing` after removal. Updates read, mutate and write atomically so separate preference edits cannot overwrite each other. Deleting a profile atomically clears its account assignments. Account colors continue using the existing defaults key. Sync pause quiesces account work; resume baselines alerts. Profiles filter presentation while all enabled accounts can sync in the background.

## Searches and favorites

```swift
enum MailSearchScope { case allAccounts, accounts([String]) }
struct SavedMailSearch {
    var id: String; var name: String; var query: String
    var scope: MailSearchScope; var sortOrder: Int
}
enum MailFavoriteTarget {
    case mailbox(labelID: String, scope: MailSearchScope)
    case label(accountID: String, labelID: String)
    case savedSearch(id: String)
}
struct MailFavorite {
    var id: String; var target: MailFavoriteTarget; var sortOrder: Int
}

// AccountStore
func savedMailSearches() async throws -> [SavedMailSearch]
func saveSavedMailSearch(_ search: SavedMailSearch) async throws
func deleteSavedMailSearch(id: String) async throws
func mailFavorites() async throws -> [MailFavorite]
func saveMailFavorites(_ ordered: [MailFavorite]) async throws
func resetMailFavorites() async throws
```

Saving favorites atomically replaces/reorders the list. Deleting a saved search removes favorites referencing it. Scope and target identities remain account-qualified; Core types do not depend on the app's `MailboxID`.

## Templates and signatures

```swift
struct ComposeTemplate {
    var id: String; var name: String; var document: ComposeDocument; var sortOrder: Int
}
struct LocalSignature {
    var id: String; var name: String; var document: ComposeDocument; var sortOrder: Int
}
enum SignatureSelection { case none, gmail, local(id: String) }
struct SignatureAssignment {
    var accountID: String
    var address: String                    // lowercase; empty = account default
    var newMessages: SignatureSelection
    var replies: SignatureSelection
    var placeAboveQuote: Bool               // true
    var includeSeparator: Bool              // true
}

// AccountStore
func composeTemplates() async throws -> [ComposeTemplate]
func saveComposeTemplate(_ template: ComposeTemplate) async throws
func deleteComposeTemplate(id: String) async throws
func localSignatures() async throws -> [LocalSignature]
func saveLocalSignature(_ signature: LocalSignature) async throws
func deleteLocalSignature(id: String) async throws
func signatureAssignments(accountID: String) async throws -> [SignatureAssignment]
func saveSignatureAssignment(_ assignment: SignatureAssignment) async throws
```

Deleting a local signature changes affected selections to `.none` atomically. No assignment preserves existing Gmail-signature behavior, including `account.signatureOnReplies`; an exact-address assignment overrides the account default. Persist the selected signature snapshot with the draft revision so later settings changes cannot silently rewrite a pending message.

## Sender permissions and suggestions

```swift
// AccountStore
func allowedImageSenders(accountID: String) async throws -> Set<String>
func setImageSenderAllowed(_ allowed: Bool, address: String, accountID: String) async throws
func blockedSuggestionAddresses(accountID: String) async throws -> Set<String>
func setSuggestionBlocked(_ blocked: Bool, address: String, accountID: String) async throws
```

Normalize valid email addresses once at the boundary. These choices are account-scoped and survive cache reset.

## Alert watermarks

```swift
struct MailAlertWatermark {
    var accountID: String
    var historyID: Int64
    var baselineAt: Date
}

// AccountStore
func mailAlertWatermark(accountID: String) async throws -> MailAlertWatermark?
func setMailAlertBaseline(accountID: String, historyID: Int64, at date: Date) async throws
func advanceMailAlertWatermark(accountID: String, expectedHistoryID: Int64, to historyID: Int64)
    async throws -> Bool
```

Advance is a compare-and-swap and never moves backward. First sync, reset and resume explicitly set a baseline without alerting. Stable notification IDs derive from account/message identity. A watermark records processing progress, not proof of notification delivery. Unknown or incomplete sync does not establish complete coverage. Profile/schedule rules apply before scheduling.

## Inline resources and opened dates

```swift
struct MIMEInlineResourceRecord {
    var accountID: String; var messageID: String
    var contentID: String; var partID: String
    var mimeType: String; var data: Data
}

// CacheTransaction: commit resources with the corresponding body.
func replaceMIMEResources(_ resources: [MIMEInlineResourceRecord], messageID: String, accountID: String) throws
func mimeResources(messageID: String, accountID: String) throws -> [MIMEInlineResourceRecord]
func markThreadOpened(threadID: String, accountID: String, at date: Date) throws

// MailCache convenience reads/writes.
func mimeResources(messageID: String, accountID: String) async throws -> [MIMEInlineResourceRecord]
func markThreadOpened(threadID: String, accountID: String, at date: Date) async throws
```

Replacement validates every record belongs to the named account/message and rejects duplicate normalized CIDs. Limits are 32 resources, 5 MiB each and 20 MiB per message; allowed types are PNG, JPEG, GIF and WebP. Normalization strips outer whitespace and enclosing brackets while preserving CID case. Reading returns bytes and types only. WebKit receives an immutable message-scoped map; unknown/cross-message resources fail closed. Policy changes rebuild document, CSP and content rules. Page scripts remain off; application scripts use the isolated world.

## Cache maintenance

```swift
struct CacheResetReadiness {
    var localDraftCount: Int
    var activeActionCount: Int
    var failedActionCount: Int
    var canReset: Bool                      // true only when all counts are zero
}
struct CacheUsage {
    var databaseBytes: Int64
    var bodyBytes: Int64
    var resourceBytes: Int64
    var downloadedAttachmentBytes: Int64    // supplied by the app coordinator
}
struct CacheThreadReference: Hashable { var accountID: String; var threadID: String }
struct CacheEvictionCandidate {
    var thread: CacheThreadReference
    var lastOpenedAt: Date?
    var disposableBytes: Int64
    var canEvictMetadata: Bool
}

// MailCache
func cacheResetReadiness() async throws -> CacheResetReadiness
func disposableContentUsage() async throws -> CacheUsage
func evictionCandidates(keeping: Set<CacheThreadReference>, now: Date)
    async throws -> [CacheEvictionCandidate]
func evictContent(for threads: [CacheThreadReference], keeping: Set<CacheThreadReference>, now: Date)
    async throws -> CacheEvictionResult
func evictMetadata(for threads: [CacheThreadReference], keeping: Set<CacheThreadReference>, now: Date)
    async throws -> CacheEvictionResult
func resetDisposableCache() async throws
func compactDisposableCache() async throws
```

All `localDraft` states count as recoverable work. Eviction rechecks holds, queue targets, local drafts and visible threads inside its write transaction. Body/resource eviction preserves attachment-library metadata and user categories. Metadata eviction also preserves Inbox, Drafts and the normal sync window. Root owns download-file deletion and reset orchestration: quiesce engines/watchers, reject recoverable work, preserve config and durable Calendar data, then replace cache streams/engines before restarting. The store never deletes a live database file.

`CacheEvictionResult` returns `evictedThreads`, `releasedContentBytes`, `deletedMessageCount` and `messageIDsByAccount` for managed-file cleanup. Reset rechecks readiness and purges disposable rows in one transaction. Compaction is a separate VACUUM outside that transaction. Usage reports database/body/resource bytes; root adds downloaded-file sizes.

Separate active and failed action queries. Failed rows must not affect label projections or block ordering/claim keys; retain payload and error until Retry/Discard. Retry atomically reactivates the retained intent. Queue implementation belongs to its worker, not the preference store.

## Attachment category corrections

```swift
struct AttachmentCategoryOverride {
    var accountID: String; var messageID: String; var partID: String
    var category: AttachmentCategory
    var revision: Int64 // default 0; store assigns positive revisions
}
// AccountStore
func attachmentCategoryOverrides(accountID: String, messageIDs: [String]? = nil)
    async throws -> [AttachmentCategoryOverride]
func saveAttachmentCategoryOverride(_ value: AttachmentCategoryOverride)
    async throws -> AttachmentCategoryOverride
func importAttachmentCategoryOverrides(_ values: [AttachmentCategoryOverride]) async throws
// MailCache; CacheTransaction also exposes applyAttachmentCategoryOverrides.
func attachmentCategorySnapshot(accountID: String? = nil) async throws -> [AttachmentCategoryOverride]
func applyAttachmentCategoryOverrides(_ values: [AttachmentCategoryOverride]) async throws
```

Root persists a manual edit first, then applies the returned committed revision to cache. Older indexing snapshots cannot overwrite a newer projected choice. Legacy snapshots include non-Uncategorized cache choices; import preserves any existing config correction, including an explicit Uncategorized choice, and ignores removed accounts. Corrections cascade with account removal and survive a real cache rebuild. Indexing applies stored corrections in its metadata/checkpoint transactions. The cache's applied-revision table is disposable.

## Files and registration

Store ownership: `Milestone5Preferences.swift`, `Milestone5ConfigSchema.swift`, `MailPreferencesStore.swift`, `Milestone5CacheSchema.swift`, `ReadingResourceStore.swift`, `CacheMaintenance.swift` and focused tests. Split implementation into verified checkpoints of at most five source/test files. Root registers the migration helpers in the existing schema builders:

```swift
Milestone5ConfigSchema.register(in: &migrator)
Milestone5CacheSchema.register(in: &migrator)
```

No broader roadmap records belong in these migrations. Root supplies narrow hooks for URL routing, conversation windows, filter requests, focused editors, account lifecycle and reset; coordinate shared-file ownership before edits.
