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
    var previewURL: URL?
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
    @ObservationIgnored private var lastFilter: AttachmentLibraryQuery?
    @ObservationIgnored private var lastAction: Action?
    /// Copies this window saved, or opened in Downloads, for Show in Finder.
    private var savedFiles: [AttachmentLibraryItem.ID: URL] = [:]
    private enum Action {
        case preview(AttachmentLibraryItem), open(AttachmentLibraryItem), source(AttachmentLibraryItem), save(AttachmentLibraryItem), saveSelection
        case category(AttachmentCategory, AttachmentLibraryItem), indexing
    }

    init(mailbox: MailboxModel) { self.mailbox = mailbox }

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
            lastAction = nil
            errorMessage = "Couldn't read indexing progress. Try again."
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
            lastAction = nil
            errorMessage = "Couldn't load attachments. Try again."
        }
    }

    func loadMore() async { if hasMore { selection.removeAll(); pageOffset += 100 } }
    func previousPage() { selection.removeAll(); pageOffset = max(0, pageOffset - 100) }

    func retryLastAction() async {
        switch lastAction {
        case .preview(let item): await preview(item)
        case .open(let item): await openFile(item)
        case .source(let item): await openSource(item)
        case .save(let item): await save(item)
        case .saveSelection: await saveSelection()
        case .category(let category, let item): await setCategory(category, for: item)
        case .indexing: await retryIndexing()
        case nil: errorMessage = nil; reloadRevision += 1
        }
    }

    func retryIndexing() async {
        errorMessage = nil
        lastAction = .indexing
        for owner in mailbox.accounts where owner.syncEnabled && !unavailableAccountIDs.contains(owner.account.id) {
            do { _ = try await owner.engine.indexAttachments(retryNow: true) }
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
        errorMessage = nil
        lastAction = .category(category, item)
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
        } catch { errorMessage = "Couldn't save the document category. Try again." }
    }

    /// The files a command on `item` acts on, in list order: the whole
    /// selection when the item is part of a multiple selection, else the item.
    func selectedItems(with item: AttachmentLibraryItem) -> [AttachmentLibraryItem] {
        guard selection.count > 1, selection.contains(item.id) else { return [item] }
        return items.filter { selection.contains($0.id) }
    }

    /// Quick Look opens on `item` and pages through the rest of the selection,
    /// so those files download first. One that fails to download is left out.
    func preview(_ item: AttachmentLibraryItem) async {
        let revision = presentationRevision
        lastAction = .preview(item)
        let group = selectedItems(with: item)
        await perform {
            var urls: [URL] = []
            var shown: URL?
            for candidate in group {
                if candidate.id == item.id {
                    let url = try await file(for: candidate)
                    urls.append(url)
                    shown = url
                } else if let url = try? await file(for: candidate) {
                    urls.append(url)
                }
            }
            guard presentationRevision == revision, let shown else { return }
            previewURLs = urls
            previewURL = shown
        }
    }

    func openFile(_ item: AttachmentLibraryItem) async {
        lastAction = .open(item)
        await perform {
            let url = try await file(for: item)
            let opened = try await AttachmentActions.open(url)
            if opened != url { savedFiles[item.id] = opened }
        }
    }

    /// Opens each file in turn and stops at the first one that fails.
    func openFiles(_ items: [AttachmentLibraryItem]) async {
        for item in items {
            await openFile(item)
            if errorMessage != nil { return }
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
        await perform { try await AttachmentActions.openWith(file(for: item)) }
    }

    func copyFile(_ item: AttachmentLibraryItem) async {
        await perform { AttachmentActions.copy(try await file(for: item)) }
    }

    /// Loads the email the file came from, which may be older than the
    /// cached mail, then asks the library to open it in a window.
    @discardableResult
    func openSource(_ item: AttachmentLibraryItem) async -> Bool {
        guard !isWorking else { return false }
        let revision = presentationRevision
        errorMessage = nil
        lastAction = .source(item)
        isWorking = true
        defer { isWorking = false }
        do {
            let owner = try owner(for: item)
            try await owner.engine.loadAttachmentSource(item.threadID)
            guard try self.owner(for: item) === owner else { throw AttachmentActionError.accountUnavailable }
            guard presentationRevision == revision else { return false }
            sourceLink = MailLink(accountID: item.accountID, threadID: item.threadID, messageID: item.messageID)
            lastAction = nil
            return true
        } catch { errorMessage = Self.message(for: error); return false }
    }

    func dismissPresentation() {
        presentationRevision = UUID()
        previewURL = nil
        previewURLs = []
        sourceLink = nil
    }

    func save(_ item: AttachmentLibraryItem) async {
        guard !isWorking else { return }
        lastAction = .save(item)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentFileExport.safeFilename(item.filename)
        panel.canCreateDirectories = true
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let destination = panel.url else { return }
        await perform {
            let source = try await file(for: item)
            try await AttachmentFileExport.save(source, to: destination)
            savedFiles[item.id] = destination
        }
    }

    func saveSelection() async {
        let selected = items.filter { selection.contains($0.id) }
        guard !selected.isEmpty, !isWorking else { return }
        if selected.count == 1, let item = selected.first { await save(item); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Attachments"
        let response = if let window = NSApp.keyWindow { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK, let directory = panel.url else { return }
        lastAction = .saveSelection
        isWorking = true
        defer { isWorking = false }
        var failedIDs: Set<String> = []
        for item in selected {
            do {
                let source = try await file(for: item)
                savedFiles[item.id] = try await AttachmentFileExport.copyWithoutReplacing(source, to: directory)
            } catch { failedIDs.insert(item.id) }
        }
        let failures = failedIDs.count
        if failures > 0 { selection = failedIDs }
        errorMessage = failures == 0 ? nil : "Saved \(selected.count - failures) of \(selected.count) files. \(failures) couldn't be saved. Check account access and folder permissions, then retry the failed files."
        if failures == 0 { lastAction = nil }
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
        let file = try await owner.engine.downloadAttachment(item.attachment, into: root)
        guard try self.owner(for: item) === owner else { throw AttachmentActionError.accountUnavailable }
        try Task.checkCancellation()
        return file
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do { try await operation(); lastAction = nil }
        catch { if !(error is CancellationError) { errorMessage = Self.message(for: error) } }
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
