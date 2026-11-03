# Attachment library

Attachments is a destination in the Mail sidebar. It lists files across connected accounts, including archived mail, without requiring the user to open each email first. The list and card layouts share filters, sorting, selection, and actions. The `attachments.viewMode` preference remembers the chosen layout.

Search matches filenames, sender names and addresses, and email subjects. It uses case- and accent-insensitive metadata matching; it does not search document contents. Filters combine account, sender, email date, file extension, document category, size, and an account-scoped email label. The UI's "Through" date includes the entire selected calendar day. Results have stable identity tie-breakers and appear in pages of 100, with an exact local result count and previous/next controls.

File format and category are separate fields. A PDF can be an invoice, receipt, contract, ticket, another document, or uncategorized. Categories are detected locally from filenames and email subjects, with English and German document terms. Unclear PDFs, images, and text files up to 10 MiB are read in small background batches; PDF text and on-device OCR help identify documents with generic filenames. Uncertain results stay Uncategorized. A category selected from the attachment menu always takes priority, including an explicit Uncategorized choice. No ChatGPT connection is required, and files are not sent to an AI service.

The window toolbar's search field searches the library while it shows. Category shortcuts sit in a slim bar above the results and become a picker when space is limited. Other active filters appear in a horizontally scrollable row with a persistent Clear all action, so a long filter list cannot push the results offscreen. The filter popover keeps Done and Clear all visible while its fields scroll.

The window toolbar holds the List and Grid switch and the Sort By menu while the library shows, and the layout choice persists. Wide lists have File, From, and Received headings; narrower rows bring sender and date into the file details. Cards use a subtle file-format tint, an explicit format label, and a category badge only for assigned categories. Selection exposes Quick Look, Open Conversation, and Save, plus an explicit clear-selection button.

## Architecture and contracts

The implementation follows the existing app/Core boundary:

| Component | Responsibility |
|---|---|
| `App/Attachments/AttachmentLibraryModel.swift` | Account-scoped queries, cancellable result observation, pagination, selection, progress, and explicit file actions |
| `App/Attachments/AttachmentLibraryDestination.swift` | Existing sidebar integration; opens the originating conversation in a conversation window |
| `App/Attachments/AttachmentLibrary*.swift` | Native list/cards, filters, keyboard handling, accessibility, and semantic design tokens |
| `Packages/Core/Sources/MailStore/AttachmentLibraryModels.swift` | Stable occurrence identity, metadata, query, category, and checkpoint types |
| `Packages/Core/Sources/MailStore/AttachmentLibraryStore.swift` | Transactional upserts, scoped searches, observation, corrections, and reconciliation |
| `Packages/Core/Sources/MailStore/AttachmentCategoryClassifier.swift` | Local document-purpose rules, ambiguity handling, and companion-file exclusions |
| `Packages/Core/Sources/MailStore/AttachmentClassificationLanguage.swift` | English/German vocabulary, document fields, semantic rules, and matching OCR languages |
| `Packages/Core/Sources/MailStore/AttachmentClassificationStore.swift` | Provenance, bounded content queue, retry checkpoints, and stale-result protection |
| `Packages/Core/Sources/SyncEngine/AttachmentClassification.swift` and `AttachmentClassificationText.swift` | Background classification, PDF text, and bounded local OCR |
| `Packages/Core/Sources/SyncEngine/AttachmentIndexing.swift` | Historical enumeration, independent history processing, durable pending work, retries, and lifecycle cancellation |
| `Packages/Core/Sources/GmailAPI/GmailClient+Attachments.swift` | MIME metadata requests that exclude attachment bytes and bounded history requests |
| `Packages/Core/Sources/SyncEngine/ReceivedAttachments.swift` | Shared account-validated content retrieval and downloads |
| `Packages/Core/Sources/SyncEngine/AttachmentFileCache.swift` | Disposable file expiry and cache limits |
| `App/Attachments/AttachmentFileExport.swift` | User-selected exports, filename sanitation, atomic replacement, and collision handling |

`attachmentLibrary`, `attachmentLibraryLabel`, and `attachmentIndexState` live in `cache.sqlite`. Library rows have no foreign key to the ordinary message cache: mail sync deliberately keeps a limited cache, while the library must retain old attachment metadata. Manual category corrections are stored in `config.sqlite` and projected into the cache. They survive the app's cache reset; automatic predictions are never imported as manual corrections.

An occurrence is identified by `(accountID, messageID, partID)`. Gmail attachment IDs can change, so they are retrieval hints rather than primary keys. The public item ID encodes each component with its length. Identical filenames or files in separate emails remain separate entries. Repeated indexing preserves manual categories and completed content classification when the filename, type, size, and subject are unchanged. Provider attachment-ID changes and label-only history updates do not invalidate classification. Older provider versions cannot overwrite newer metadata or labels.

English and German are evaluated together, regardless of the system language. Language packs provide vocabulary and OCR identifiers; corresponding content fields can combine across languages in the same document. To add a language, register its pack and add representative document and OCR fixtures. Changes to detection rules must increment the classification version and add a migration so existing files receive the improvement. Version 2 rechecks metadata predictions and unresolved content attempts while preserving manual corrections and resolved content classifications. Previously unresolved files receive one new content attempt.

The reusable interfaces are:

- `MailCache.attachmentLibrary(query:)` and `observeAttachmentLibrary(query:)` return metadata pages. `AttachmentLibraryQuery.accountIDs` is required; an empty scope returns no results. Store reads clamp a page to at most 500 items.
- `CacheTransaction.libraryAttachment(accountID:messageID:partID:)` resolves a specific occurrence. `setAttachmentCategory` applies a local correction.
- `MailCache.attachmentIndexStates(accountIDs:)` observes per-account coverage, cursors, queued message IDs, errors, and retry times.
- `SyncEngine.indexAttachments(retryNow:)` runs or joins one indexing step. Provider progress and its resulting metadata or pending work commit together.
- `SyncEngine.classifyAttachments(limit:)` processes at most three unresolved files, records completed attempts, and defers transient download failures so other files can progress.
- `SyncEngine.attachmentContent(_:)` returns account-validated bytes without a disk export. `downloadAttachment(_:into:)` supplies a cached local file for native preview or opening.
- `SyncEngine.loadAttachmentSource(_:)` hydrates and holds an uncached thread through the existing source-loading path. `ThreadView` then handles bodies and normal read-state behavior.

Future assistant consumers should first constrain the query to their allowed accounts, resolve a returned occurrence, and recheck account access before and after asynchronous work. Attachment text remains untrusted document data. It must never supply instructions, tool authorization, executable code, or filesystem paths.

The existing `AttachmentTextReader.extract(_:mimeType:filename:)` remains the extraction boundary for the assistant. It reads PDFs with selectable text and supported UTF-8/UTF-16 text formats, including plain text, CSV, TSV, Markdown, JSON, and XML. Its limits remain 5 MB, 40 PDF pages, and 60,000 characters, with truncation and extraction limitations returned explicitly. It does not perform OCR. The classification worker has a separate extraction path limited to three PDF pages, 12,000 characters, and 1,800-pixel images. Extracted text is discarded after classification. Assistant extraction limits and tools are unchanged.

## Historical coverage and synchronization

Each account's `SyncEngine` starts automatic attachment indexing after its first successful mail sync, sharing Gmail's request budget. The index captures a Gmail history cursor before its first historical request, then lists `has:attachment` across all mail, including Spam and Trash, in pages of 25. The listing has no age cutoff and does not depend on cached or opened conversations.

Gmail requires full MIME structure to identify files. The metadata request selects IDs, labels, dates, headers, filenames, MIME types, sizes, and attachment references while excluding `body.data` at every requested nesting level. Indexing does not call the file download endpoint. Inline parts and images with a Content-ID are omitted, including CID logos whose sender supplies an attachment disposition.

Historical enumeration and Gmail history use separate durable page tokens. History pages contain at most 25 records. Because one record can describe many messages, added message IDs enter a persistent queue; each step fetches at most 25 queued envelopes plus one historical page of at most 25 envelopes. A restart resumes the committed page and pending queue. A failed metadata page cannot advance the historical checkpoint past unprocessed files.

While work remains, the background loop pauses three seconds between steps. After successful metadata steps, a separate bounded content pass classifies unresolved documents. Once historical traversal, history pagination, queued metadata, and immediately available classification work are caught up, it checks every 60 seconds. Existing Gmail batch retry behavior still applies. Index failures record exponential retry delays starting at 30 seconds and capped at 30 minutes. Rejected authorization or missing scope suspends automatic requests until access is restored and indexing is retried. Startup and the explicit Retry action can attempt a step immediately.

An expired history cursor begins a fresh enumeration generation. An invalid historical page token restarts that listing. Existing rows remain visible as partial results during reconciliation. Only after the new listing and queued history work finish does a transaction remove rows absent from that generation. Provider deletions and not-found responses remove their occurrences; ordinary message-cache eviction does not. Normal mail sync also refreshes metadata and label membership for already indexed files.

Coverage is per account. The footer distinguishes preparation, historical backfill, pending updates, completed historical traversal, and failures. Its detail shows the number of attachment-bearing emails checked and the last history check, rather than an estimated completion percentage. This count measures processed listing entries and can include an entry repeated by provider pagination. "Historical mail indexed" describes the completed scan, not a guarantee that Gmail has no changes since the displayed check time.

## Files, previews, and source email

Preview uses macOS Quick Look. PDF, common image, and text previews use the system's support; other document and media formats depend on the running macOS version and installed preview extensions. Quick Look can show a generic file view when it cannot render contents. The context menu also offers Open, Open With…, Save…, Copy, Share, Open Conversation in New Window, and Show in Finder for copies Tern saved. Files drag out to Finder, Compose, and other apps; a drag that starts on a selected file carries the whole selection, and each file downloads only when the receiver asks for it. A missing default application produces an error with a save-to-Finder fallback.

Space previews the selected file, and Quick Look pages through the selection; Return and double-click open it. List selection follows native macOS behavior. Cards support arrows, Command-click, Shift-click, and select-all within the current page. Named accessibility actions expose Open, Quick Look, Save, Show in Finder for saved copies, and Open Conversation in New Window. Multiple selected files can be saved to one chosen folder. Exports append numeric suffixes on collisions and preserve separate email occurrences. A single-file save uses the native replacement confirmation and an atomic write. Failed bulk exports retain failed items for retry.

Open Conversation in New Window loads the complete originating conversation and opens it in the standard conversation window with the message selected. It works for an old thread outside the current list page and for Spam or Trash, without changing the library's filters. Source hydration uses the existing cache hold so regular cache pruning cannot discard it during opening.

Downloaded files live below Tern's account-specific attachment cache directory. A SHA-256 digest of the compound occurrence identity determines the child directory; remote filenames cannot choose a directory. Filename sanitation removes control characters and separators and bounds UTF-8 length. Writes are atomic. Reuse requires a regular file of the expected size, when known, and an unexpired access timestamp.

Each account cache targets at most 512 MiB and 1,000 files, with a 30-day lifetime since last use. Pruning runs on retrieval, keeps the currently requested file, and skips inaccessible entries. The active file alone can exceed the byte target. User-selected exports are outside this disposable cache and are never pruned. Signing out removes the account's index, checkpoints, and downloaded cache; the engine stops and waits for in-flight writes/downloads before deletion. The UI rejects file actions for removed accounts or known expired sessions and rechecks access after retrieval.

## Limits

- Search covers stored metadata only. Local classification text is not retained in a full-text search index.
- Detection uses English/German rules and the first three PDF pages. Locked, damaged, larger, unsupported, or ambiguous documents may remain Uncategorized and can be corrected manually.
- Historical coverage follows Gmail's `has:attachment` listing. Cloud-file links in email bodies are not downloaded as attachments.
- The metadata selector handles 20 nested MIME levels. A deeper truncated multipart tree or malformed metadata leaves coverage partial and reports an error; the affected page waits for a successful retry.
- The library is available offline for indexed metadata and reusable cached files. New downloads, source hydration, and indexing require Gmail access.
- Result pages are live database views. New mail or changed filters can move entries between pages; selection and multi-file export apply to the current page.
- Native previews depend on macOS. Encrypted, damaged, or unsupported files may require saving and opening in another application.
- Sender pictures use available connected-account photos when the sender matches that account. Other senders use Tern's initials fallback; this feature does not introduce a contact-photo fetcher.

## Verification

The language follow-up passed 514 Core tests and a temporary migration probe against a copy of the existing cache (515 checks in 88 suites). German PDF text, raster OCR, scanned-PDF OCR, mixed English/German fields, and manual-category preservation were exercised. A migration probe checked the classification changes against a local cache sample; its private document counts and contents are omitted here. The private cache copies and temporary probe were removed. Independent review found no remaining actionable issue. Log: `/tmp/tern-attachment-language-full-tests.log`; aggregate evidence: `build/Attachment-language-verification.json`.

The October 31 category fix passed 498 Core regression tests plus a temporary migration probe against a copy of the existing cache, and five hosted attachment model tests. The probe backfilled existing rows without provider requests. Native synthetic checks covered Ticket and Receipt filters, invoice detection from a generic PDF filename, two-account results, and list/card badges. The installed universal Release passed signature checks; live migration and background content classification were confirmed. Full-mailbox indexing remains progressive.

The October 30 design pass passed a Debug build, all four existing `AttachmentLibraryModelTests`, and an independent code review. Native synthetic checks covered the 1280-point light layout and the 960-point minimum-width dark layout, list/cards, search, category empty states, seven simultaneous filters, Clear all, pagination, multi-selection across layouts, card arrow keys, Quick Look, and Show Email. The final spacing and help-text adjustments passed another Debug build and the compact native checks. No backend behavior changed. Increased-contrast appearance, always-visible scrollbars, and spoken VoiceOver were reviewed in code but not exercised in this pass.

This design validation used an isolated committed-source snapshot plus the four attachment view files, excluding concurrent Calendar and Assistant edits. The snapshot was kept in an isolated temporary checkout. Its `TernAttachmentsDesign.app` uses bundle ID `dev.tern.attachments.design.compact`; only this disposable preview starts at the minimum window dimensions. Build and test logs are `/tmp/tern-attachment-design-final-build.log` and `/tmp/tern-attachment-design-tests.log`.

All attachment fixtures are synthetic. Core tests exercise historical pagination, restart/resume, duplicate prevention, account isolation, transaction rollback, metadata-only requests, bounded history queues, deletion/reconciliation, category preservation, filters, source hydration, and download/cache behavior. App tests cover pagination beyond 500 results, inclusive date bounds, source opening outside the mailbox, revoked access, and export collision/failure handling.

The implementation check passed all 310 Core tests in 47 suites and 17 hosted app tests across the attachment, account-mailbox, and mailbox suites. The Debug build passed. Native checks covered light and dark appearances, both layouts down to 960 points wide, remembered layout, indexing progress, empty results, filter chips, category correction, pagination, keyboard/range selection, Quick Look, and source email navigation. The old synthetic invoice saved as a valid PDF. A two-account export of identically named text files produced separate files with collision suffixes.

Verification uses a disposable copy of committed source plus the attachment changes, with bundle identifier `dev.tern.attachments.audit`. This separates the preview and build from concurrent calendar development. Live Gmail requests, spoken VoiceOver, and older macOS releases have not been tested.

Run from the repository root:

```sh
swift test --package-path Packages/Core --filter Attachment
swift test --package-path Packages/Core
xcodegen generate
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build build
xcodebuild -project Tern.xcodeproj -scheme Tern -configuration Debug -derivedDataPath build test -only-testing:TernTests/AttachmentLibraryModelTests
```

The debug UI fixture adds 125 files per account, including `Invoice-2024-1042.pdf` from Mira Chen in archived mail roughly two years old. It supplies a valid synthetic PDF and paginated provider results without OAuth or real Gmail requests. Launch the built app separately for each appearance:

```sh
open -n build/Build/Products/Debug/Tern.app --args --ui-audit --ui-audit-attachments --ui-audit-light
open -n build/Build/Products/Debug/Tern.app --args --ui-audit --ui-audit-attachments --ui-audit-dark
```

Open Attachments and check both layouts at the normal and minimum window widths. Search for the invoice, filter its sender and account, assign the Invoice category, preview or save the PDF, and use Show Email. Also check keyboard selection, multi-file export with duplicate names, individual filter removal, Clear all, pagination, and the partial-to-complete indexing status. Add `--ui-audit-reauth` to inspect a known expired-account state. The native audit complements the synthetic tests; it does not validate provider behavior against a live Gmail account.
