import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine

struct MailAnalyticsRoute: Codable, Hashable {
    var accountID: String?
    var address: String?
    var name: String?

    init(accountID: String? = nil, address: String? = nil, name: String? = nil) {
        self.accountID = accountID
        self.address = address.map { EmailAddress(address: $0).normalized }
        self.name = name
    }
}

struct SenderProfileEvidence: Identifiable, Sendable {
    let link: SenderProfileLink
    let messageID: String
    let date: Date
    var id: String { link.id }
}

/// Each observation owns its results. Changing account or sender invalidates
/// suspended work before the next database snapshot reaches the interface.
@MainActor @Observable
final class MailAnalyticsModel {
    private(set) var snapshot: MailAnalyticsSnapshot?
    private(set) var profileLinks: [SenderProfileEvidence] = []
    private(set) var receipts: [ReadReceiptStatus] = []
    private(set) var isLoading = true
    private(set) var isLoadingHistory = false
    private(set) var historyPagesLoaded = 0
    private(set) var historyAccountName: String?
    private(set) var error: String?
    private(set) var receiptError: String?
    private(set) var historyError: String?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var receiptTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var receiptsByAccount: [String: [ReadReceiptStatus]] = [:]
    @ObservationIgnored private let historyPage: @MainActor (AccountMailbox, Bool) async throws -> MailAnalyticsCoverage

    init(historyPage: @escaping @MainActor (AccountMailbox, Bool) async throws -> MailAnalyticsCoverage = {
        try await $0.engine.loadAnalyticsHistoryPage(restart: $1)
    }) {
        self.historyPage = historyPage
    }

    func observe(cache: MailCache, query: MailAnalyticsQuery) async {
        stop()
        let request = UUID()
        revision = request
        snapshot = nil
        profileLinks = []
        receipts = []
        receiptsByAccount = [:]
        error = nil
        receiptError = nil
        historyError = nil
        isLoading = true
        observeReceipts(cache: cache, query: query, revision: request)
        var previousSources: [MailAnalyticsProfileSource] = []
        do {
            for try await value in cache.observeMailAnalytics(query: query) {
                guard revision == request, !Task.isCancelled else { return }
                snapshot = value
                isLoading = false
                if value.profileSources != previousSources {
                    previousSources = value.profileSources
                    let sources = value.profileSources
                    let links = await Task.detached(priority: .userInitiated) {
                        Self.extractLinks(sources)
                    }.value
                    guard revision == request, !Task.isCancelled else { return }
                    profileLinks = links
                }
            }
        } catch {
            guard revision == request, !Task.isCancelled else { return }
            isLoading = false
            self.error = "Couldn't load mail analytics. Try again."
        }
    }

    func loadHistory(accounts: [AccountMailbox], restart: Bool) {
        guard !isLoadingHistory, !accounts.isEmpty else { return }
        let request = revision
        isLoadingHistory = true
        historyError = nil
        historyPagesLoaded = 0
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == request {
                    isLoadingHistory = false
                    historyAccountName = nil
                    historyTask = nil
                }
            }
            var failures: [String] = []
            for owner in accounts {
                guard revision == request, !Task.isCancelled else { return }
                guard owner.syncEnabled else {
                    failures.append("\(owner.account.email): Mail sync is paused. Enable Sync Mail in Settings to load its history.")
                    historyError = failures.joined(separator: "\n")
                    continue
                }
                historyAccountName = owner.account.email
                do {
                    var firstPage = true
                    while true {
                        try Task.checkCancellation()
                        guard revision == request else { return }
                        let coverage = try await historyPage(owner, restart && firstPage)
                        guard revision == request, !Task.isCancelled else { return }
                        historyPagesLoaded += 1
                        firstPage = false
                        if coverage.isComplete { break }
                    }
                } catch is CancellationError {
                    // Completed pages remain available; cancellation stops every account.
                    return
                } catch {
                    guard revision == request, !Task.isCancelled else { return }
                    failures.append("\(owner.account.email): \(Self.historyFailureMessage(error))")
                    historyError = failures.joined(separator: "\n")
                }
            }
        }
    }

    private static func historyFailureMessage(_ error: any Error) -> String {
        switch error {
        case GmailError.unauthorized:
            "Sign in again to continue loading history."
        case let gmail as GmailError where gmail.isMissingScope:
            "Sign in again to restore permission to read mail history."
        case GmailError.rateLimited:
            "Gmail is limiting requests. Wait a moment, then try again."
        default:
            "Couldn't finish loading history. Loaded pages are saved. Try again to continue."
        }
    }

    func cancelHistory() {
        historyTask?.cancel()
    }

    func stop() {
        revision = UUID()
        historyTask?.cancel()
        historyTask = nil
        receiptTasks.forEach { $0.cancel() }
        receiptTasks = []
        isLoadingHistory = false
        historyAccountName = nil
    }

    private func observeReceipts(cache: MailCache, query: MailAnalyticsQuery, revision request: UUID) {
        receiptTasks = query.accountIDs.map { accountID in
            Task { [weak self] in
                do {
                    for try await statuses in cache.observeReadReceiptStatuses(accountID: accountID,
                        recipient: query.contactAddress, limit: 20) {
                        guard let self, self.revision == request, !Task.isCancelled else { return }
                        self.receiptsByAccount[accountID] = statuses
                        self.receipts = self.receiptsByAccount.values.flatMap { $0 }
                            .sorted { $0.sentAt > $1.sentAt }
                    }
                } catch {
                    guard let self, self.revision == request, !Task.isCancelled else { return }
                    self.receiptError = "Couldn't load read receipts."
                }
            }
        }
    }

    nonisolated private static func extractLinks(_ sources: [MailAnalyticsProfileSource]) -> [SenderProfileEvidence] {
        var seen = Set<String>()
        var result: [SenderProfileEvidence] = []
        for source in sources.sorted(by: { $0.date > $1.date }) {
            for link in SenderProfileLinks.extract(plainText: source.plainText, html: source.html)
                where seen.insert(link.id).inserted {
                result.append(SenderProfileEvidence(link: link, messageID: source.messageID, date: source.date))
                if result.count == 12 { return result }
            }
        }
        return result
    }
}
