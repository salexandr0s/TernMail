import AppKit
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine

/// Window state for the persistent attachment index and its detected categories.
@MainActor
@Observable
final class AttachmentLibraryModel {
    static let mailboxID = "TERN_ATTACHMENTS"
    let mailbox: MailboxModel
    private var loadedPage: AttachmentLibraryPage?
    private var loadedQuery: AttachmentLibraryQuery?
    private var currentPage: AttachmentLibraryPage? { loadedQuery == query ? loadedPage : nil }
    var isPageReady: Bool { currentPage != nil }
    private(set) var pagePresentationRevision = 0
    var items: [AttachmentLibraryItem] { currentPage?.items ?? [] }
    var totalCount: Int { currentPage?.totalCount ?? 0 }
    var hasMore: Bool { currentPage?.hasMore ?? false }
    private(set) var isLoading = true
    private(set) var isWorking = false
    private(set) var indexStates: [AttachmentIndexState] = []
    var selection: Set<String> = []
    var search = ""
    var sender = ""
    var accountID = ""
    var fileExtension = ""
    var category: AttachmentCategory?
    var startDate: Date?
    var endDate: Date?
    var minimumSize: Int?
    var maximumSize: Int?
    var label: AttachmentLibraryLabel?
    var sort: AttachmentLibrarySort = .newest
    var previewURL: URL? {
        didSet { if previewURL == nil { cancelPreviewPreparation() } }
    }
    /// The files Quick Look pages through, in list order.
    private(set) var previewURLs: [URL] = []
    /// The conversation Open Conversation in New Window loaded. The library
    /// opens its window and clears this.
    var sourceLink: MailLink?
    var errorMessage: String?
    var unavailableAccountIDs: Set<String> = [] {
        didSet {
            if oldValue != unavailableAccountIDs {
                dismissPresentation()
                selection.removeAll()
            }
        }
    }
    private(set) var pageOffset = 0
    private var reloadRevision = 0
    struct ObservationKey: Equatable { let query: AttachmentLibraryQuery; let revision: Int }
    var observationKey: ObservationKey { .init(query: query, revision: reloadRevision) }
    struct CoverageKey: Equatable { let accountIDs: [String]; let revision: Int }
    var coverageKey: CoverageKey { .init(accountIDs: availableAccounts.map(\.id), revision: reloadRevision) }
    var pageEnd: Int { min(pageOffset + items.count, totalCount) }
    var hasPreviousPage: Bool { pageOffset > 0 }
    /// The library's only count, shown in the status bar.
    var rangeSummary: String {
        if hasPreviousPage || hasMore { return "\(pageOffset + 1)–\(pageEnd) of \(totalCount.formatted()) attachments" }
        return totalCount == 1 ? "1 attachment" : "\(totalCount.formatted()) attachments"
    }
    @ObservationIgnored private var observationRevision = UUID()
    @ObservationIgnored private var coverageRevision = UUID()
    @ObservationIgnored private var presentationRevision = UUID()
    @ObservationIgnored private var previewRequest: UUID?
    @ObservationIgnored private var previewPreparation: Task<Void, Never>?
    @ObservationIgnored private var lastFilter: AttachmentLibraryQuery?
    @ObservationIgnored private var lastAction: Action?
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let openWithFile: @MainActor (URL) async throws -> Void
    /// Copies this window saved, or opened in Downloads, for Show in Finder.
    private var savedFiles: [AttachmentLibraryItem.ID: URL] = [:]
    private enum Action {
        case preview(AttachmentLibraryItem, [AttachmentLibraryItem]), open([AttachmentLibraryItem])
        case source(AttachmentLibraryItem), save(AttachmentLibraryItem)
        case saveSelection([AttachmentLibraryItem]), copy([AttachmentLibraryItem]), openWith(AttachmentLibraryItem)
        case category(AttachmentCategory, AttachmentLibraryItem), indexing
    }

    init(mailbox: MailboxModel, pasteboard: NSPasteboard = .general,
         openWithFile: @escaping @MainActor (URL) async throws -> Void = AttachmentActions.openWith) {
        self.mailbox = mailbox
        self.pasteboard = pasteboard
        self.openWithFile = openWithFile
    }

    var availableAccounts: [AccountRecord] { mailbox.accounts.map(\.account) }
    var availableLabels: [LabelRecord] { mailbox.accounts.flatMap(\.labels) }
    var query: AttachmentLibraryQuery {
        AttachmentLibraryQuery(
            accountIDs: availableAccounts.map(\.id).filter { accountID.isEmpty || $0 == accountID },
            search: search, sender: sender, startDate: startDate.map { Calendar.current.startOfDay(for: $0) },
            endDate: endDate.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: $0)) },
            fileExtension: fileExtension.isEmpty ? nil : fileExtension,
            category: category, minimumSize: minimumSize, maximumSize: maximumSize,
            label: label, sort: sort, limit: 100, offset: pageOffset
        )
    }

    /// The main area shows the same words while the first pass runs.
    var coverageSummary: String {
        if isBuildingIndex { return "Finding attachments in your mail…" }
        if hasCoverageGap { return "Some attachments may be missing" }
        if isUpdatingIndex { return "Updating attachments…" }
        return "Historical mail indexed"
    }

    var coverageDetail: String {
        let states = scopedStates
        let checked = states.reduce(0) { $0 + $1.indexedMessageCount }
        var detail = "\(checked.formatted()) attachment-bearing emails checked. Includes archived mail, Spam, and Trash."
        detail += " Categories are detected on this Mac from filenames, email subjects, and readable documents. Document checks can continue after indexing finishes. Your corrections take priority."
        if isBuildingIndex || isUpdatingIndex {
            detail += " Results are partial while indexing continues. You can leave this view."
        }
        if let error = states.compactMap(\.lastError).first { detail += " " + error }
        if !unavailableAccountIDs.intersection(scopedAccountIDs).isEmpty {
            detail += " Sign in again to update affected accounts or retrieve their files."
        }
        if mailbox.accounts.contains(where: { !$0.syncEnabled && scopedAccountIDs.contains($0.account.id) }) {
            detail += " Indexing is paused for accounts with Sync Mail off. Turn it on again in Settings."
        }
        if let updated = states.compactMap(\.updatedAt).min() {
            detail += " Last checked \(updated.formatted(date: .abbreviated, time: .shortened))."
        }
        return detail
    }

    /// Only accounts that index can retry a failed pass.
    var indexingNeedsRetry: Bool {
        let indexing = indexingAccountIDs
        return scopedStates.contains { $0.lastError != nil && indexing.contains($0.accountID) }
    }
    /// True while an account in scope that indexes hasn't finished its first
    /// pass over mail history. Accounts with Sync Mail off or waiting for sign-in
    /// don't index, and a failed pass waits for a retry, so neither counts.
    var isBuildingIndex: Bool {
        indexingAccountIDs.contains { id in
            guard let state = indexStates.first(where: { $0.accountID == id }) else { return true }
            return !state.isComplete && state.lastError == nil
        }
    }
    /// True when a failed pass, or an account that doesn't index, leaves part of
    /// mail history out.
    private var hasCoverageGap: Bool {
        let indexing = indexingAccountIDs
        return scopedAccountIDs.contains { id in
            guard let state = indexStates.first(where: { $0.accountID == id }) else { return !indexing.contains(id) }
            return state.lastError != nil || (!state.isComplete && !indexing.contains(id))
        }
    }
    /// True while an account that indexes has newer history or messages left to check.
    private var isUpdatingIndex: Bool {
        let indexing = indexingAccountIDs
        return scopedStates.contains {
            indexing.contains($0.accountID) && ($0.historyPageToken != nil || !$0.pendingMessageIDs.isEmpty)
        }
    }
    private var scopedAccountIDs: Set<String> { Set(query.accountIDs) }
    /// Accounts in scope whose index runs on its own: Sync Mail is on and the
    /// account is signed in.
    private var indexingAccountIDs: Set<String> {
        Set(mailbox.accounts.filter(\.syncEnabled).map(\.account.id))
            .intersection(scopedAccountIDs).subtracting(unavailableAccountIDs)
    }
    private var scopedStates: [AttachmentIndexState] { indexStates.filter { scopedAccountIDs.contains($0.accountID) } }

    func start() async {
        let revision = UUID()
        coverageRevision = revision
        let accountIDs = availableAccounts.map(\.id)
        do {
            for try await states in mailbox.cache.attachmentIndexStates(accountIDs: accountIDs) {
                guard !Task.isCancelled, coverageRevision == revision,
                      availableAccounts.map(\.id) == accountIDs else { return }
                indexStates = states
            }
        } catch {
            guard !Task.isCancelled, coverageRevision == revision,
                  availableAccounts.map(\.id) == accountIDs else { return }
            reportObservationError("Couldn't read indexing progress. Try again.")
        }
    }

    /// SwiftUI cancels this observation when the query changes. The revision
    /// also rejects late results from a database read already in flight.
    func reload() async {
        let revision = UUID()
        observationRevision = revision
        var filter = query
        filter.offset = 0
        let textChanged = lastFilter.map { $0.search != filter.search || $0.sender != filter.sender } ?? false
        if lastFilter != filter {
            lastFilter = filter
            selection.removeAll()
            pageOffset = 0
        }
        let request = query
        if currentPage == nil { isLoading = true }
        do {
            // Only typing needs a pause. Cached pages and discrete filter changes load immediately.
            if textChanged { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            guard observationRevision == revision, query == request else { return }
            for try await page in mailbox.cache.observeAttachmentLibrary(query: request) {
                guard !Task.isCancelled, observationRevision == revision, query == request else { return }
                let lastOffset = max(0, (page.totalCount - 1) / request.limit * request.limit)
                if request.offset > lastOffset {
                    // Changing the observation key starts the last remaining page in SwiftUI.
                    isLoading = true
                    selection.removeAll()
                    pageOffset = lastOffset
                    return
                }
                if loadedPage != page || loadedQuery != request {
                    if loadedPage != page { loadedPage = page }
                    if loadedQuery != request { loadedQuery = request }
                    pagePresentationRevision += 1
                }
                let retainedSelection = selection.intersection(page.items.map(\.id))
                if selection != retainedSelection { selection = retainedSelection }
                if isLoading { isLoading = false }
            }
        } catch {
            guard !Task.isCancelled, observationRevision == revision, query == request else { return }
            isLoading = false
            reportObservationError("Couldn't load attachments. Try again.")
        }
    }

    func loadMore() async { if hasMore { selection.removeAll(); pageOffset += 100 } }
    func previousPage() { selection.removeAll(); pageOffset = max(0, pageOffset - 100) }

    /// Refresh mail and the attachment index immediately, and restart cached observations.
    func refresh() async {
        mailbox.syncNow()
        reloadRevision += 1
        await retryIndexing()
    }

    func retryLastAction() async {
        guard !isWorking else { return }
        switch lastAction {
        case .preview(let item, let group): await preview(item, in: group)
        case .open(let items): await openFiles(items)
        case .openWith(let item): await openWith(item)
        case .copy(let items): await copyFiles(items)
        case .source(let item): await openSource(item)
        case .save(let item): await save(item)
        case .saveSelection(let items): await saveFiles(items)
        case .category(let category, let item): await setCategory(category, for: item)
        case .indexing: await retryIndexing()
        case nil: errorMessage = nil; reloadRevision += 1
        }
    }

    func retryIndexing() async {
        guard begin(.indexing) else { return }
        defer { isWorking = false }
        for owner in mailbox.accounts where owner.syncEnabled && !unavailableAccountIDs.contains(owner.account.id) {
            do { _ = try await owner.engine.indexAttachments(retryNow: true) }
            catch is CancellationError { lastAction = nil; return }
            catch { errorMessage = Self.message(for: error) }
        }
        if errorMessage == nil { lastAction = nil }
    }

    func clearFilters() {
        search = ""; sender = ""; accountID = ""; fileExtension = ""
        category = nil; startDate = nil; endDate = nil
        minimumSize = nil; maximumSize = nil; label = nil
    }

    func accountName(_ item: AttachmentLibraryItem) -> String {
        mailbox.account(id: item.accountID)?.account.email ?? "Removed account"
    }

    func setCategory(_ category: AttachmentCategory, for item: AttachmentLibraryItem) async {
        guard mailbox.account(id: item.accountID) != nil else { return }
        guard begin(.category(category, item)) else { return }
        defer { isWorking = false }
        do {
            if let accounts = mailbox.accountStore {
                let saved = try await accounts.saveAttachmentCategoryOverride(.init(accountID: item.accountID,
                    messageID: item.messageID, partID: item.partID, category: category))
                try await mailbox.cache.applyAttachmentCategoryOverrides([saved])
            } else {
                try await mailbox.cache.write { tx in
                    try tx.setAttachmentCategory(category, accountID: item.accountID, messageID: item.messageID, partID: item.partID)
                }
            }
            lastAction = nil
        } catch is CancellationError { lastAction = nil }
        catch { errorMessage = "Couldn't save the document category. Try again." }
    }

    /// The files a command on `item` acts on, in list order: the whole
    /// selection when the item is part of a multiple selection, else the item.
    func selectedItems(with item: AttachmentLibraryItem) -> [AttachmentLibraryItem] {
        guard selection.count > 1, selection.contains(item.id) else { return [item] }
        return items.filter { selection.contains($0.id) }
    }

    /// Quick Look opens on `item` first. Other selected files join in list
    /// order as they arrive; one that fails to download is left out.
    func preview(_ item: AttachmentLibraryItem) async {
        await preview(item, in: selectedItems(with: item))
    }

    private func preview(_ item: AttachmentLibraryItem, in group: [AttachmentLibraryItem]) async {
        guard !isWorking else { return }
        previewURL = nil
        guard begin(.preview(item, group)) else { return }
        let request = UUID()
        previewRequest = request
        let owners = Dictionary(group.compactMap { candidate in
            mailbox.account(id: candidate.accountID).map { (candidate.accountID, $0) }
        }, uniquingKeysWith: { first, _ in first })
        let preparation = Task { await preparePreview(item, in: group, request: request, owners: owners) }
        previewPreparation = preparation
        await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

    private func preparePreview(_ item: AttachmentLibraryItem, in group: [AttachmentLibraryItem],
                                request: UUID, owners: [String: AccountMailbox]) async {
        defer {
            if previewRequest == request {
                previewPreparation = nil
                if case .preview = lastAction {
                    isWorking = false
                    if Task.isCancelled { lastAction = nil }
                }
            }
        }
        do {
            try Task.checkCancellation()
            let selected = try await file(for: item)
            guard previewIsCurrent(request, owners: owners), !Task.isCancelled else { return }
            var files = [item.id: selected]
            previewURLs = [selected]
            previewURL = selected
            lastAction = nil
            isWorking = false
            // One secondary download at a time keeps speculative work bounded
            // and uses the same account budget as every attachment request.
            for candidate in group where files[candidate.id] == nil {
                guard previewIsCurrent(request, owners: owners), !Task.isCancelled else { return }
                do {
                    let url = try await file(for: candidate)
                    guard previewIsCurrent(request, owners: owners), !Task.isCancelled else { return }
                    files[candidate.id] = url
                    previewURLs = group.compactMap { files[$0.id] }
                } catch is CancellationError { return }
                catch {
                    guard previewIsCurrent(request, owners: owners), !Task.isCancelled else { return }
                }
            }
        } catch is CancellationError {
            if previewRequest == request, case .preview = lastAction {
                isWorking = false
                lastAction = nil
            }
        } catch {
            guard previewIsCurrent(request, owners: owners), !Task.isCancelled else { return }
            errorMessage = Self.message(for: error)
        }
    }

    private func previewIsCurrent(_ request: UUID, owners: [String: AccountMailbox]) -> Bool {
        guard previewRequest == request else { return false }
        guard owners.allSatisfy({ mailbox.account(id: $0.key) === $0.value }) else {
            previewURL = nil
            return false
        }
        return true
    }

    private func cancelPreviewPreparation() {
        if previewPreparation != nil, case .preview = lastAction {
            isWorking = false
            lastAction = nil
        }
        previewRequest = nil
        previewPreparation?.cancel()
        previewPreparation = nil
        previewURLs = []
    }

    func openFile(_ item: AttachmentLibraryItem) async {
        await openFiles([item])
    }

    /// Opens each file in turn and stops at the first one that fails.
    func openFiles(_ items: [AttachmentLibraryItem]) async {
        guard !items.isEmpty else { return }
        await perform(.open(items)) {
            for (index, item) in items.enumerated() {
                // Retry starts at the failed file, without reopening completed files.
                lastAction = .open(Array(items[index...]))
                let url = try await file(for: item)
                let opened = try await AttachmentActions.open(url)
                if opened != url { savedFiles[item.id] = opened }
            }
        }
    }

    /// Where Save or Open put a copy of the file, while that copy still exists.
    func savedFile(for item: AttachmentLibraryItem) -> URL? {
        guard let url = savedFiles[item.id], FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return url
    }

    func openWith(_ item: AttachmentLibraryItem) async {
        await perform(.openWith(item)) { try await openWithFile(file(for: item)) }
    }

    func copyFile(_ item: AttachmentLibraryItem) async {
        await copyFiles([item])
    }

    func copyFiles(_ items: [AttachmentLibraryItem]) async {
        guard !items.isEmpty, begin(.copy(items)) else { return }
        defer { isWorking = false }
        var urls: [URL] = []
        var firstFailure: (any Error)?
        for item in items {
            do { urls.append(try await file(for: item)) }
            catch is CancellationError { lastAction = nil; return }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if !urls.isEmpty, !AttachmentActions.copy(urls, to: pasteboard) {
            errorMessage = "Couldn't copy the files to the clipboard. Try again."
        } else if let firstFailure {
            let detail = Self.message(for: firstFailure)
            errorMessage = items.count == 1 ? detail
                : "Copied \(urls.count) of \(items.count) files. \(detail) Try again to copy the full selection."
        } else {
            lastAction = nil
        }
    }

    /// Loads the email the file came from, which may be older than the
    /// cached mail, then asks the library to open it in a window.
    @discardableResult
    func openSource(_ item: AttachmentLibraryItem) async -> Bool {
        guard begin(.source(item)) else { return false }
        let revision = presentationRevision
        defer { isWorking = false }
        do {
            let owner = try owner(for: item)
            try await owner.engine.loadAttachmentSource(item.threadID)
            guard try self.owner(for: item) === owner else { throw AttachmentActionError.accountUnavailable }
            guard presentationRevision == revision else { lastAction = nil; return false }
            sourceLink = MailLink(accountID: item.accountID, threadID: item.threadID, messageID: item.messageID)
            lastAction = nil
            return true
        } catch is CancellationError { lastAction = nil; return false }
        catch { errorMessage = Self.message(for: error); return false }
    }

    func dismissPresentation() {
        presentationRevision = UUID()
        previewURL = nil
        previewURLs = []
        sourceLink = nil
    }

    func save(_ item: AttachmentLibraryItem) async {
        await perform(.save(item)) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = AttachmentFileExport.safeFilename(item.filename)
            panel.canCreateDirectories = true
            let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
            guard response == .OK, let destination = panel.url else { return }
            let source = try await file(for: item)
            try await AttachmentFileExport.save(source, to: destination)
            savedFiles[item.id] = destination
        }
    }

    func saveSelection() async {
        await saveFiles(items.filter { selection.contains($0.id) })
    }

    private func saveFiles(_ selected: [AttachmentLibraryItem]) async {
        guard !selected.isEmpty else { return }
        if selected.count == 1, let item = selected.first { await save(item); return }
        guard begin(.saveSelection(selected)) else { return }
        defer { isWorking = false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Attachments"
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let directory = panel.url else { lastAction = nil; return }
        var failedIDs: Set<String> = []
        for item in selected {
            do {
                let source = try await file(for: item)
                savedFiles[item.id] = try await AttachmentFileExport.copyWithoutReplacing(source, to: directory)
            } catch is CancellationError { lastAction = nil; return }
            catch { failedIDs.insert(item.id) }
        }
        let failures = failedIDs.count
        if failures > 0 { selection = failedIDs }
        errorMessage = failures == 0 ? nil : "Saved \(selected.count - failures) of \(selected.count) files. \(failures) couldn't be saved. Check account access and folder permissions, then retry the failed files."
        lastAction = failures == 0 ? nil : .saveSelection(selected.filter { failedIDs.contains($0.id) })
    }

    private func owner(for item: AttachmentLibraryItem) throws -> AccountMailbox {
        guard !unavailableAccountIDs.contains(item.accountID), let owner = mailbox.account(id: item.accountID) else {
            throw AttachmentActionError.accountUnavailable
        }
        return owner
    }

    private func file(for item: AttachmentLibraryItem) async throws -> URL {
        let owner = try owner(for: item)
        let root = mailbox.downloadsDirectory.appending(path: item.accountID, directoryHint: .isDirectory)
        let file = try await owner.engine.downloadAttachment(item.attachment, into: root, protectedURLs: { @MainActor [weak self] in
            var protected = AttachmentPreviewRegistry.shared.activeURLs
            if let current = self?.previewURL { protected.insert(current) }
            return protected
        })
        guard try self.owner(for: item) === owner else { throw AttachmentActionError.accountUnavailable }
        try Task.checkCancellation()
        return file
    }

    /// Admission and retry identity change together, before any suspension or panel.
    private func begin(_ action: Action) -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        errorMessage = nil
        lastAction = action
        return true
    }

    private func perform(_ action: Action, _ operation: () async throws -> Void) async {
        guard begin(action) else { return }
        defer { isWorking = false }
        do { try await operation(); lastAction = nil }
        catch is CancellationError { lastAction = nil }
        catch { errorMessage = Self.message(for: error) }
    }

    private func reportObservationError(_ message: String) {
        guard !isWorking, case nil = lastAction else { return }
        errorMessage = message
    }

    static func message(for error: any Error) -> String {
        switch error {
        case AttachmentActionError.accountUnavailable, GmailError.unauthorized:
            "Sign in to this account again to retrieve the file."
        case AttachmentActionError.noApplication:
            "No application could open this file. Save it and choose an application in Finder."
        case GmailError.notFound:
            "This attachment is no longer available. Its email may have been deleted."
        case GmailError.rateLimited:
            "Gmail is limiting requests. Wait a moment, then try again."
        case let gmail as GmailError where gmail.isMissingScope:
            "Tern no longer has permission to read this account. Sign in again to restore access."
        default:
            "Couldn't retrieve or save this file. Check your connection and folder permissions, then try again."
        }
    }
}

private enum AttachmentActionError: Error { case accountUnavailable, noApplication }
