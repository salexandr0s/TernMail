import Foundation
import MailStore
import Observation

struct UnsubscribeAccount: Identifiable, Equatable {
    let id: String
    let title: String
    let email: String
}

enum UnsubscribeFilter: String, CaseIterable, Identifiable {
    case active, history, all
    var id: Self { self }
    var title: String {
        switch self { case .active: "Active"; case .history: "History"; case .all: "All" }
    }
}

enum UnsubscribeSort: String, CaseIterable, Identifiable {
    case mostMessages, newest, name
    var id: Self { self }
    var title: String {
        switch self { case .mostMessages: "Most messages"; case .newest: "Most recent"; case .name: "Sender name" }
    }
}

struct UnsubscribeConfirmation: Identifiable {
    let id = UUID()
    let subscriptions: [NewsletterSubscription]
}

/// Each operation resolves the current account before touching mail or local state.
@MainActor struct UnsubscribeClient {
    var snapshot: () async throws -> NewsletterSnapshot
    var scan: (_ restart: Bool) async throws -> NewsletterSnapshot
    var request: (_ id: String) async throws -> NewsletterSubscription
    var markOpened: (_ id: String) async throws -> Void
    var complete: (_ id: String) async throws -> Void
    var reset: (_ id: String) async throws -> Void
}

@MainActor @Observable final class UnsubscribeModel {
    private(set) var accounts: [UnsubscribeAccount] = []
    var selectedAccountID = "" { didSet { if selectedAccountID != oldValue { clearSelection(); stopScan() } } }
    var search = "" { didSet { if search != oldValue { clearSelection() } } }
    var filter = UnsubscribeFilter.active { didSet { if filter != oldValue { clearSelection() } } }
    var sort = UnsubscribeSort.mostMessages
    private(set) var selectedIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var isScanning = false
    private(set) var isWorking = false
    private(set) var isSendingRequests = false
    private(set) var batchCompleted = 0
    private(set) var batchTotal = 0
    var errorMessage: String?
    var notice: String?
    var confirmation: UnsubscribeConfirmation?
    var manualSubscription: NewsletterSubscription?
    private(set) var unavailableAccountIDs: Set<String> = []
    private(set) var snapshots: [String: NewsletterSnapshot] = [:]
    @ObservationIgnored private let client: (String) -> UnsubscribeClient?
    @ObservationIgnored private let available: (String) -> Bool
    @ObservationIgnored private let openManual: (NewsletterSubscription) async throws -> Void
    @ObservationIgnored private let openMessage: (NewsletterSubscription) -> Void
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var settlingBatchTask: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var scanID = UUID()
    @ObservationIgnored private var batchID = UUID()

    init(client: @escaping (String) -> UnsubscribeClient?, available: @escaping (String) -> Bool = { _ in true },
         openManual: @escaping (NewsletterSubscription) async throws -> Void = { _ in },
         openMessage: @escaping (NewsletterSubscription) -> Void = { _ in }) {
        self.client = client; self.available = available
        self.openManual = openManual; self.openMessage = openMessage
    }

    var subscriptions: [NewsletterSubscription] {
        accounts.filter { selectedAccountID.isEmpty || $0.id == selectedAccountID }
            .flatMap { snapshots[$0.id]?.subscriptions ?? [] }
    }

    var visibleSubscriptions: [NewsletterSubscription] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return subscriptions.filter { item in
            let finished = item.status == .requested || item.status == .completed
            let matchesStatus = filter == .all || (filter == .history ? finished : !finished)
            return matchesStatus && (query.isEmpty || [item.senderName, item.senderAddress, item.listID, item.latestSubject]
                .compactMap { $0 }.contains { $0.localizedStandardContains(query) })
        }.sorted { lhs, rhs in
            switch sort {
            case .mostMessages:
                if lhs.messageCount != rhs.messageCount { return lhs.messageCount > rhs.messageCount }
            case .newest:
                if lhs.latestDate != rhs.latestDate { return lhs.latestDate > rhs.latestDate }
            case .name: break
            }
            let order = (lhs.senderName ?? lhs.senderAddress).localizedStandardCompare(rhs.senderName ?? rhs.senderAddress)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    private var selectableIDs: Set<String> { Set(visibleSubscriptions.filter(isSelectable).map(\.id)) }
    var selectedCount: Int { selectedIDs.intersection(selectableIDs).count }
    var allVisibleSelected: Bool { !selectableIDs.isEmpty && selectableIDs.isSubset(of: selectedIDs) }
    var someVisibleSelected: Bool { selectedCount > 0 && !allVisibleSelected }
    var canSelectAll: Bool { !isWorking && !selectableIDs.isEmpty }
    var subscriptionCount: Int { subscriptions.count }
    var messageCount: Int { subscriptions.reduce(0) { $0 + $1.messageCount } }
    var requestedCount: Int { subscriptions.filter { $0.status == .requested }.count }
    var hasMoreToScan: Bool {
        accounts.contains { (selectedAccountID.isEmpty || selectedAccountID == $0.id) && snapshots[$0.id]?.isComplete != true }
    }

    var scanSummary: String {
        let ids = accounts.filter { selectedAccountID.isEmpty || $0.id == selectedAccountID }.map(\.id)
        let values = ids.compactMap { snapshots[$0] }
        let count = values.reduce(0) { $0 + $1.scannedMessageCount }
        if isLoading { return "Loading subscriptions…" }
        if isScanning {
            let refresh = values.contains(where: \.isRefreshing) ? " Previous results stay visible." : ""
            return "Checked \(count.formatted()) messages.\(refresh)"
        }
        if !ids.isEmpty && values.count == ids.count && values.allSatisfy(\.isComplete) {
            return "\(count.formatted()) messages checked. Counts include newsletter messages found in this scan."
        }
        return count > 0
            ? "\(count.formatted()) messages checked so far. Continue scanning for more subscriptions."
            : "Scan received mail to find newsletters and their unsubscribe options."
    }

    func isUnavailable(_ item: NewsletterSubscription) -> Bool {
        unavailableAccountIDs.contains(item.accountID) || !available(item.accountID)
            || !accounts.contains { $0.id == item.accountID }
    }

    func isSelectable(_ item: NewsletterSubscription) -> Bool {
        !isLoading && item.canUnsubscribeAutomatically && !isUnavailable(item)
    }

    func accountTitle(for id: String) -> String { accounts.first { $0.id == id }?.title ?? "Account unavailable" }

    /// Called when accounts or their access changes; any older task loses its publication rights.
    func configure(accounts: [UnsubscribeAccount], unavailable: Set<String>) {
        revision = UUID()
        stopScan(); stopBatch()
        if let batchTask { settlingBatchTask = batchTask }
        batchID = UUID(); batchTask = nil; isWorking = false
        isSendingRequests = false
        isLoading = false
        self.accounts = accounts; unavailableAccountIDs = unavailable
        let kept = Set(accounts.map(\.id))
        snapshots = snapshots.filter { kept.contains($0.key) }
        if !selectedAccountID.isEmpty && !kept.contains(selectedAccountID) { selectedAccountID = "" }
        clearSelection(); manualSubscription = nil; notice = nil; errorMessage = nil
    }

    func load() async {
        let current = revision
        isLoading = true; errorMessage = nil
        defer { if revision == current { isLoading = false } }
        // A canceled request stores its outcome before a replacement scope reads it.
        await settlingBatchTask?.value
        guard revision == current, !Task.isCancelled else { return }
        settlingBatchTask = nil
        for account in accounts {
            guard revision == current, !Task.isCancelled else { return }
            guard let service = client(account.id) else { continue }
            do {
                let snapshot = try await service.snapshot()
                guard revision == current, !Task.isCancelled else { return }
                snapshots[account.id] = snapshot
            } catch {
                guard revision == current, !Task.isCancelled else { return }
                errorMessage = "Couldn't load saved subscriptions for \(account.title). Try again."
            }
        }
        if revision == current, !Task.isCancelled { isLoading = false; startScan() }
    }

    func startScan(restart: Bool = false) {
        guard !isScanning, !isLoading, !isWorking else { return }
        let targets = accounts.filter {
            (selectedAccountID.isEmpty || $0.id == selectedAccountID)
                && !unavailableAccountIDs.contains($0.id) && available($0.id)
                && (restart || snapshots[$0.id]?.isComplete != true)
        }
        guard !targets.isEmpty else { return }
        let token = UUID(); scanID = token
        let current = revision
        isScanning = true; errorMessage = nil; notice = nil
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { if scanID == token { isScanning = false; scanTask = nil } }
            for account in targets {
                var firstPage = true
                while !Task.isCancelled, revision == current, scanID == token {
                    guard available(account.id), !unavailableAccountIDs.contains(account.id),
                          let service = client(account.id) else { break }
                    do {
                        let page = try await service.scan(restart && firstPage)
                        guard !Task.isCancelled, revision == current, scanID == token else { return }
                        snapshots[account.id] = page
                        pruneSelection()
                        firstPage = false
                        if page.isComplete { break }
                    } catch {
                        guard !Task.isCancelled, revision == current, scanID == token else { return }
                        errorMessage = "Couldn't finish scanning \(account.title). Your progress is saved. Try again to continue."
                        break
                    }
                }
            }
        }
    }

    func stopScan() {
        scanID = UUID(); scanTask?.cancel(); scanTask = nil; isScanning = false
    }

    func toggleSelection(_ item: NewsletterSubscription) {
        guard !isWorking, isSelectable(item) else { return }
        if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) }
    }

    func toggleAll() {
        guard canSelectAll else { return }
        if allVisibleSelected { selectedIDs.subtract(selectableIDs) } else { selectedIDs.formUnion(selectableIDs) }
    }

    func clearSelection() { selectedIDs.removeAll(); confirmation = nil }
    private func pruneSelection() { selectedIDs.formIntersection(selectableIDs) }

    func proposeSelection() {
        let items = visibleSubscriptions.filter { selectedIDs.contains($0.id) && isSelectable($0) }
        guard !isWorking, !items.isEmpty else { return }
        confirmation = UnsubscribeConfirmation(subscriptions: items)
    }

    func proposeUnsubscribe(_ item: NewsletterSubscription) {
        guard !isWorking, isSelectable(item) else { return }
        confirmation = UnsubscribeConfirmation(subscriptions: [item])
    }

    func confirmUnsubscribe() {
        guard !isWorking, let proposed = confirmation else { return }
        confirmation = nil
        let items = proposed.subscriptions.filter(isSelectable)
        guard !items.isEmpty else { return }
        stopScan()
        let current = revision, token = UUID(); batchID = token
        isWorking = true; isSendingRequests = true; batchCompleted = 0; batchTotal = items.count
        errorMessage = nil; notice = nil
        batchTask = Task { [weak self] in
            guard let self else { return }
            var succeeded = 0, failed = 0
            defer {
                if revision == current, batchID == token {
                    isWorking = false; isSendingRequests = false; batchTask = nil
                    if Task.isCancelled { notice = "Stopped. Requests already sent may still take effect." }
                }
            }
            for item in items {
                guard !Task.isCancelled, revision == current, batchID == token else { return }
                guard !isUnavailable(item), let service = client(item.accountID) else { failed += 1; continue }
                do {
                    let result = try await service.request(item.id)
                    guard revision == current, batchID == token else { return }
                    replace(result); selectedIDs.remove(item.id); succeeded += 1
                } catch {
                    guard revision == current, batchID == token else { return }
                    failed += 1
                    // The persisted outcome may be uncertain if cancellation happened after the POST.
                    let outcome = Task { try await service.snapshot() }
                    if let snapshot = try? await outcome.value, revision == current, batchID == token {
                        snapshots[item.accountID] = snapshot
                        pruneSelection()
                    }
                }
                batchCompleted += 1
                if Task.isCancelled { return }
            }
            guard revision == current, batchID == token else { return }
            notice = succeeded == 1 ? "Unsubscribe request sent. The sender may take a few days to stop emails."
                : "\(succeeded) unsubscribe requests sent. Senders may take a few days to stop emails."
            if failed > 0 { errorMessage = "\(failed) \(failed == 1 ? "request needs" : "requests need") attention. Review the status before trying again." }
        }
    }

    func stopBatch() {
        guard batchTask != nil else { return }
        batchTask?.cancel()
        // Keep the task's identity until its current request stores the outcome.
        notice = "Stopping after the current request. Requests already sent cannot be recalled."
    }

    func stop() { stopScan(); stopBatch() }

    func openSubscription(_ item: NewsletterSubscription) {
        guard !isLoading, !isWorking, !isUnavailable(item) else { return }
        manualSubscription = item
    }

    func openManualLink() async {
        guard !isWorking, let item = manualSubscription, !isUnavailable(item), let service = client(item.accountID) else { return }
        stopScan()
        let current = revision
        isWorking = true; errorMessage = nil
        defer { if revision == current { isWorking = false } }
        do {
            try await openManual(item)
            guard revision == current, !Task.isCancelled, !isUnavailable(item) else { return }
            try await service.markOpened(item.id)
            let snapshot = try await service.snapshot()
            guard revision == current, !Task.isCancelled else { return }
            snapshots[item.accountID] = snapshot
            if manualSubscription?.id == item.id {
                manualSubscription = snapshot.subscriptions.first { $0.id == item.id }
            }
        } catch {
            guard revision == current, !Task.isCancelled else { return }
            errorMessage = "Couldn't open this unsubscribe option. Check your connection and try again."
        }
    }

    func markManualComplete() async {
        guard let item = manualSubscription else { return }
        await updateStatus(item, complete: true)
    }

    func resetStatus(_ item: NewsletterSubscription) async { await updateStatus(item, complete: false) }

    private func updateStatus(_ item: NewsletterSubscription, complete: Bool) async {
        guard !isWorking, !isUnavailable(item), let service = client(item.accountID) else { return }
        stopScan()
        let current = revision
        isWorking = true; errorMessage = nil
        defer { if revision == current { isWorking = false } }
        do {
            if complete { try await service.complete(item.id) } else { try await service.reset(item.id) }
            let snapshot = try await service.snapshot()
            guard revision == current, !Task.isCancelled else { return }
            snapshots[item.accountID] = snapshot; manualSubscription = nil; pruneSelection()
        } catch {
            guard revision == current, !Task.isCancelled else { return }
            errorMessage = "Couldn't save this subscription's status. Try again."
        }
    }

    func openLatestMessage(_ item: NewsletterSubscription) {
        guard !isUnavailable(item) else { return }; openMessage(item)
    }

    private func replace(_ item: NewsletterSubscription) {
        guard let snapshot = snapshots[item.accountID] else { return }
        snapshots[item.accountID] = NewsletterSnapshot(accountID: snapshot.accountID,
            subscriptions: snapshot.subscriptions.map { $0.id == item.id ? item : $0 },
            scannedMessageCount: snapshot.scannedMessageCount, displayedScannedMessageCount: snapshot.displayedScannedMessageCount,
            isComplete: snapshot.isComplete, isRefreshing: snapshot.isRefreshing,
            lastScannedAt: snapshot.lastScannedAt, lastError: snapshot.lastError)
    }
}
