import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine

/// The search field's query and its results in the accounts it searches. Local
/// matches update as the user types. Gmail is asked on Return, or a second
/// after typing stops once the query has three characters, and its
/// conversations join the list. Search terms are never logged or stored.
@MainActor
@Observable
final class SearchModel {
    /// An account to search: its ID and the engine that asks Gmail.
    struct Source {
        let accountID: String
        let engine: SyncEngine
    }

    static let gmailDelay: Duration = .seconds(1)
    static let gmailMinimumLength = 3
    static let pageSize = 200

    private(set) var text = ""
    /// An operator such as `in:inbox` that every result must also match, from
    /// the scope bar. Nil searches all mail.
    private(set) var restriction: String?
    /// The one account the scope bar picked, or nil for every account searched.
    private(set) var accountID: String?
    /// Local matches plus Gmail's conversations, newest first.
    private(set) var results: [ThreadRecord] = []
    /// Gmail's side of the current query. Nil while the field is empty.
    private(set) var gmail: GmailPager?
    /// Reading the cache failed for an account being searched.
    var readFailed: Bool { !failedAccountIDs.isEmpty }
    /// Changes when ⌥⌘F or / asks the toolbar field for focus.
    private(set) var fieldFocusRequest = 0
    /// Changes when Escape hands focus back to the list.
    private(set) var listFocusRequest = 0
    private(set) var usesMessageMode = false

    var matchingMessageIDs: [String: Set<String>] {
        _ = gmail?.revision
        return Dictionary(activeSources.map { ($0.accountID, gmail?.messageIDs(in: $0.accountID) ?? []) }, uniquingKeysWith: { first, _ in first })
    }

    /// The query the cache and Gmail answer: the field's text, narrowed by
    /// the scope bar's restriction.
    var queryText: String {
        guard let restriction else { return text }
        return "\(restriction) \(text)"
    }

    /// Whether more results wait past the listed ones: another local page,
    /// or another page from Gmail.
    var hasMoreResults: Bool {
        results.count >= limit || gmail?.state == .more
    }

    func setMessageMode(_ enabled: Bool) {
        guard usesMessageMode != enabled else { return }
        usesMessageMode = enabled
        restart()
    }

    var isActive: Bool { !trimmedText.isEmpty }

    /// Tells the mailbox the results changed, so it can trim the selection.
    @ObservationIgnored var onResultsChange: (() -> Void)?

    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private var sources: [Source]
    @ObservationIgnored private var query = SearchQuery("")
    @ObservationIgnored private var limit = pageSize
    /// Each account's latest results for the current query.
    @ObservationIgnored private var found: [String: [ThreadRecord]] = [:]
    private var failedAccountIDs: Set<String> = []
    @ObservationIgnored private var resultsTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var delayTask: Task<Void, Never>?

    init(cache: MailCache, sources: [Source]) {
        self.cache = cache
        self.sources = sources
    }

    /// Searches these accounts from now on, running the current query again.
    func setSources(_ sources: [Source]) {
        self.sources = sources
        if let accountID, !sources.contains(where: { $0.accountID == accountID }) { self.accountID = nil }
        restart()
    }

    /// Runs the new query locally at once and asks Gmail after a pause.
    func update(_ newText: String) {
        guard newText != text else { return }
        text = newText
        // The next search starts from all mail in every account again.
        if !isActive {
            restriction = nil
            accountID = nil
        }
        restart()
    }

    /// Limits results to mail that also matches `restriction`, or searches
    /// all mail again for nil.
    func restrict(to restriction: String?) {
        guard restriction != self.restriction else { return }
        self.restriction = restriction
        restart()
    }

    /// Searches one of the sources, or all of them again for nil.
    func restrict(toAccount accountID: String?) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        restart()
    }

    /// Return in the field: asks Gmail now, unless it has already answered.
    func submit() {
        guard gmail?.state != .more else { return }
        askGmail()
    }

    /// Asks Gmail for its next page, or again after a failure.
    func askGmail() {
        delayTask?.cancel()
        gmail?.next { [weak self] _ in self?.observeResults() }
    }

    /// Shows more of the local results once the list scrolls to its end.
    func loadMoreResults() {
        guard results.count >= limit else { return }
        limit += Self.pageSize
        observeResults()
    }

    /// Empties the field, which returns the list to the selected mailbox.
    func clear() {
        update("")
    }

    /// Escape in the field: clears it and gives the list focus.
    func cancel() {
        clear()
        listFocusRequest += 1
    }

    func focusField() {
        fieldFocusRequest += 1
    }

    func stop() {
        delayTask?.cancel()
        resultsTasks.forEach { $0.cancel() }
        gmail?.cancel()
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The sources the scope bar leaves in.
    private var activeSources: [Source] {
        guard let accountID else { return sources }
        return sources.filter { $0.accountID == accountID }
    }

    private func restart() {
        query = SearchQuery(queryText)
        limit = Self.pageSize
        delayTask?.cancel()
        gmail?.cancel()
        gmail = nil
        // Results for another query or other accounts no longer count.
        found = [:]
        failedAccountIDs = []
        results = []
        onResultsChange?()
        guard isActive else {
            resultsTasks.forEach { $0.cancel() }
            resultsTasks = []
            results = []
            onResultsChange?()
            return
        }
        let query = query
        let messageMode = usesMessageMode
        gmail = GmailPager(sources: Dictionary(uniqueKeysWithValues: activeSources.map { source in
            let engine = source.engine
            return (source.accountID, { token in
                if messageMode { return try await engine.searchGmailMessages(query, timeZone: .current, pageToken: token) }
                return try await engine.searchGmail(query, timeZone: .current, pageToken: token)
            })
        }))
        observeResults()
        guard trimmedText.count >= Self.gmailMinimumLength else { return }
        delayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.gmailDelay)
            guard !Task.isCancelled else { return }
            self?.askGmail()
        }
    }

    /// Watches each account's matches. An account keeps its last results
    /// until new ones arrive, so a Gmail page or a longer list doesn't drop
    /// another account's conversations, or the selection among them.
    private func observeResults() {
        resultsTasks.forEach { $0.cancel() }
        let query = query
        resultsTasks = activeSources.map { source in
            let accountID = source.accountID
            let stream = cache.searchResults(
                query, including: gmail?.threadIDs(in: accountID) ?? [], accountID: accountID,
                timeZone: .current, now: .now, limit: limit
            )
            return Task { [weak self] in
                do {
                    for try await threads in stream {
                        guard let self, !Task.isCancelled, self.query == query else { return }
                        found[accountID] = threads
                        failedAccountIDs.remove(accountID)
                        publish()
                    }
                } catch {
                    guard let self, !Task.isCancelled, self.query == query else { return }
                    found[accountID] = nil
                    failedAccountIDs.insert(accountID)
                    publish()
                }
            }
        }
    }

    /// Merges the accounts' results in the order each account's list uses,
    /// once every account has answered the query, so the list never shows
    /// one account's matches alone while another's are on the way.
    private func publish() {
        guard activeSources.allSatisfy({ found[$0.accountID] != nil || failedAccountIDs.contains($0.accountID) }) else {
            return
        }
        let merged = found.values.joined().sorted { lhs, rhs in
            lhs.lastDate != rhs.lastDate ? lhs.lastDate > rhs.lastDate : lhs.key < rhs.key
        }
        results = Array(merged.prefix(limit))
        onResultsChange?()
    }
}

/// Pages through one Gmail listing in one or more accounts, a page per
/// account per request, and remembers the conversations it returned. A
/// different listing gets a new pager.
@MainActor
@Observable
final class GmailPager {
    enum State: Hashable {
        /// Not asked yet.
        case ready
        case loading
        /// Gmail has another page.
        case more
        case finished
        /// Gmail refused for too many requests. Tern doesn't retry on its own.
        case busy
        case failed
    }

    typealias Fetch = @Sendable (_ pageToken: String?) async throws -> GmailResultPage

    private struct Source {
        let fetch: Fetch
        var pageToken: String?
        var state: State = .ready
        var task: Task<Void, Never>?
    }

    /// The accounts' states together: loading while any loads, then busy or
    /// failed if any is, then more if any has more.
    private(set) var state: State = .ready
    private(set) var revision = 0
    @ObservationIgnored private var sources: [String: Source]
    /// Every conversation Gmail returned so far, by account.
    @ObservationIgnored private var returned: [String: Set<String>] = [:]
    @ObservationIgnored private var returnedMessages: [String: Set<String>] = [:]

    init(sources: [String: Fetch]) {
        self.sources = sources.mapValues { Source(fetch: $0) }
        updateState()
    }

    convenience init(accountID: String, fetch: @escaping Fetch) {
        self.init(sources: [accountID: fetch])
    }

    func threadIDs(in accountID: String) -> Set<String> {
        returned[accountID] ?? []
    }

    func messageIDs(in accountID: String) -> Set<String> { returnedMessages[accountID] ?? [] }

    /// Asks each account for its next page, or again for a page that
    /// failed, then passes each page's conversations to `onPage`.
    func next(onPage: @escaping @MainActor ([ThreadKey]) -> Void) {
        let due: Set<State> = switch state {
        case .ready, .more: [.ready, .more]
        case .busy, .failed: [.busy, .failed]
        case .loading, .finished: []
        }
        for (accountID, source) in sources where due.contains(source.state) {
            start(accountID, from: source, onPage: onPage)
        }
        updateState()
    }

    func cancel() {
        for accountID in sources.keys {
            sources[accountID]?.task?.cancel()
            sources[accountID]?.task = nil
        }
    }

    private func start(_ accountID: String, from source: Source, onPage: @escaping @MainActor ([ThreadKey]) -> Void) {
        sources[accountID]?.state = .loading
        let token = source.pageToken
        let fetch = source.fetch
        sources[accountID]?.task = Task { [weak self] in
            do {
                let page = try await fetch(token)
                guard let self, !Task.isCancelled else { return }
                returned[accountID, default: []].formUnion(page.threadIDs)
                returnedMessages[accountID, default: []].formUnion(page.messageIDs)
                revision += 1
                sources[accountID]?.pageToken = page.nextPageToken
                sources[accountID]?.state = page.nextPageToken == nil ? .finished : .more
                updateState()
                onPage(page.threadIDs.map { ThreadKey(accountID: accountID, threadID: $0) })
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case .rateLimited? = error as? GmailError {
                    sources[accountID]?.state = .busy
                } else {
                    sources[accountID]?.state = .failed
                }
                updateState()
            }
        }
    }

    private func updateState() {
        let states = sources.values.map(\.state)
        state = if states.contains(.loading) {
            .loading
        } else if states.contains(.busy) {
            .busy
        } else if states.contains(.failed) {
            .failed
        } else if states.contains(.more) {
            .more
        } else if states.allSatisfy({ $0 == .finished }) {
            .finished
        } else {
            .ready
        }
    }
}
