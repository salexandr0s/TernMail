import AppKit
import GmailAPI
import MailStore
import Observation
import SyncEngine

/// Window state for the persistent metadata index. File bytes are fetched only
/// for an explicit preview, open, or save action.
@MainActor
@Observable
final class AttachmentLibraryModel {
    static let mailboxID = "TERN_ATTACHMENTS"
    let mailbox: MailboxModel
    private(set) var items: [AttachmentLibraryItem] = []
    private(set) var totalCount = 0
    private(set) var hasMore = false
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
    var sourceThreadKey: ThreadKey?
    var errorMessage: String?
    var unavailableAccountIDs: Set<String> = [] {
        didSet {
            if oldValue != unavailableAccountIDs {
                previewURL = nil
                sourceThreadKey = nil
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
    var rangeSummary: String { totalCount == 0 ? "0 attachments" : "\(pageOffset + 1)–\(pageEnd) of \(totalCount.formatted())" }
    @ObservationIgnored private var observationRevision = UUID()
    @ObservationIgnored private var lastFilter: AttachmentLibraryQuery?
    @ObservationIgnored private var lastAction: Action?
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

    var coverageSummary: String {
        let states = scopedStates
        if states.isEmpty { return "Preparing attachment index…" }
        if states.contains(where: { $0.lastError != nil }) { return "Some attachments may be missing" }
        if states.count < scopedAccountIDs.count || states.contains(where: { !$0.isComplete }) {
            return "Finding older attachments…"
        }
        if states.contains(where: { $0.historyPageToken != nil || !$0.pendingMessageIDs.isEmpty }) {
            return "Updating attachments…"
        }
        return "Historical mail indexed"
    }

    var coverageDetail: String {
        let states = scopedStates
        let checked = states.reduce(0) { $0 + $1.indexedMessageCount }
        var detail = "\(checked.formatted()) attachment-bearing emails checked. Includes archived mail, Spam, and Trash."
        if states.count < scopedAccountIDs.count || states.contains(where: { !$0.isComplete || $0.historyPageToken != nil || !$0.pendingMessageIDs.isEmpty }) {
            detail += " Results are partial while indexing continues. You can leave this view."
        }
        if let error = states.compactMap(\.lastError).first { detail += " " + error }
        if !unavailableAccountIDs.intersection(scopedAccountIDs).isEmpty {
            detail += " Sign in again to update affected accounts or retrieve their files."
        }
        if let updated = states.compactMap(\.updatedAt).min() {
            detail += " Last checked \(updated.formatted(date: .abbreviated, time: .shortened))."
        }
        return detail
    }

    var indexingNeedsRetry: Bool { scopedStates.contains { $0.lastError != nil } }
    private var scopedAccountIDs: Set<String> { Set(query.accountIDs) }
    private var scopedStates: [AttachmentIndexState] { indexStates.filter { scopedAccountIDs.contains($0.accountID) } }

    func start() async {
        do {
            for try await states in mailbox.cache.attachmentIndexStates(accountIDs: availableAccounts.map(\.id)) {
                guard !Task.isCancelled else { return }
                indexStates = states
            }
        } catch {
            guard !Task.isCancelled else { return }
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
        if lastFilter != filter {
            lastFilter = filter
            selection.removeAll()
            items = []
            pageOffset = 0
        }
        let request = query
        isLoading = true
        do {
            try await Task.sleep(for: .milliseconds(150))
            for try await page in mailbox.cache.observeAttachmentLibrary(query: request) {
                guard !Task.isCancelled, observationRevision == revision else { return }
                items = page.items
                totalCount = page.totalCount
                hasMore = page.hasMore
                selection.formIntersection(page.items.map(\.id))
                isLoading = false
            }
        } catch {
            guard !Task.isCancelled, observationRevision == revision else { return }
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
        case .source(let item): _ = await openSource(item)
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
        for owner in mailbox.accounts where !unavailableAccountIDs.contains(owner.account.id) {
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

    func preview(_ item: AttachmentLibraryItem) async {
        lastAction = .preview(item)
        await perform { previewURL = try await file(for: item) }
    }

    func openFile(_ item: AttachmentLibraryItem) async {
        lastAction = .open(item)
        await perform {
            let url = try await file(for: item)
            try await AttachmentActions.open(url)
        }
    }

    func openWith(_ item: AttachmentLibraryItem) async {
        await perform { try await AttachmentActions.openWith(file(for: item)) }
    }

    func copyFile(_ item: AttachmentLibraryItem) async {
        await perform { AttachmentActions.copy(try await file(for: item)) }
    }

    func openSource(_ item: AttachmentLibraryItem) async -> Bool {
        guard !isWorking else { return false }
        errorMessage = nil
        lastAction = .source(item)
        isWorking = true
        defer { isWorking = false }
        do {
            let owner = try owner(for: item)
            try await owner.engine.loadAttachmentSource(item.threadID)
            guard try self.owner(for: item) === owner else { throw AttachmentActionError.accountUnavailable }
            sourceThreadKey = ThreadKey(accountID: item.accountID, threadID: item.threadID)
            lastAction = nil
            return true
        } catch { errorMessage = Self.message(for: error); return false }
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
                _ = try await AttachmentFileExport.copyWithoutReplacing(source, to: directory)
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
