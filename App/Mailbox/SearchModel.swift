import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine

/// The search field's query and its results. Local matches update as the
/// user types. Gmail is asked on Return, or a second after typing stops once
/// the query has three characters, and its conversations join the list.
/// Search terms are never logged or stored.
@MainActor
@Observable
final class SearchModel {
    static let gmailDelay: Duration = .seconds(1)
    static let gmailMinimumLength = 3
    static let pageSize = 200

    private(set) var text = ""
    /// Local matches plus Gmail's conversations, newest first.
    private(set) var results: [ThreadRecord] = []
    /// Gmail's side of the current query. Nil while the field is empty.
    private(set) var gmail: GmailPager?
    private(set) var readFailed = false
    /// Changes when ⌥⌘F or / asks the toolbar field for focus.
    private(set) var fieldFocusRequest = 0
    /// Changes when Escape hands focus back to the list.
    private(set) var listFocusRequest = 0

    var isActive: Bool { !trimmedText.isEmpty }

    /// Tells the mailbox the results changed, so it can trim the selection.
    @ObservationIgnored var onResultsChange: (() -> Void)?

    @ObservationIgnored private let accountID: String
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let engine: SyncEngine
    @ObservationIgnored private var query = SearchQuery("")
    @ObservationIgnored private var limit = pageSize
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var delayTask: Task<Void, Never>?

    init(accountID: String, cache: MailCache, engine: SyncEngine) {
        self.accountID = accountID
        self.cache = cache
        self.engine = engine
    }

    /// Runs the new query locally at once and asks Gmail after a pause.
    func update(_ newText: String) {
        guard newText != text else { return }
        text = newText
        query = SearchQuery(newText)
        limit = Self.pageSize
        delayTask?.cancel()
        gmail?.cancel()
        gmail = nil
        guard isActive else {
            resultsTask?.cancel()
            results = []
            readFailed = false
            onResultsChange?()
            return
        }
        let engine = engine
        let query = query
        gmail = GmailPager { token in try await engine.searchGmail(query, timeZone: .current, pageToken: token) }
        observeResults()
        guard trimmedText.count >= Self.gmailMinimumLength else { return }
        delayTask = Task { [weak self] in
            try? await Task.sleep(for: Self.gmailDelay)
            guard !Task.isCancelled else { return }
            self?.askGmail()
        }
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
        resultsTask?.cancel()
        gmail?.cancel()
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func observeResults() {
        resultsTask?.cancel()
        let stream = cache.searchResults(
            query, including: gmail?.threadIDs ?? [], accountID: accountID,
            timeZone: .current, now: .now, limit: limit
        )
        let query = query
        resultsTask = Task { [weak self] in
            do {
                for try await threads in stream {
                    guard let self, !Task.isCancelled, self.query == query else { return }
                    results = threads
                    readFailed = false
                    onResultsChange?()
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.readFailed = true
            }
        }
    }
}

/// Pages through one Gmail listing, a page per request, and remembers the
/// conversations it returned. A different listing gets a new pager.
@MainActor
@Observable
final class GmailPager {
    enum State: Equatable {
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

    private(set) var state: State = .ready
    /// Every conversation Gmail returned so far.
    @ObservationIgnored private(set) var threadIDs = Set<String>()
    @ObservationIgnored private var pageToken: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let fetch: @Sendable (_ pageToken: String?) async throws -> GmailResultPage

    init(fetch: @escaping @Sendable (_ pageToken: String?) async throws -> GmailResultPage) {
        self.fetch = fetch
    }

    /// Asks for the next page, or again for the page that failed, then
    /// passes the page's conversations to `onPage`.
    func next(onPage: @escaping @MainActor ([String]) -> Void) {
        switch state {
        case .ready, .more, .busy, .failed: break
        case .loading, .finished: return
        }
        state = .loading
        let token = pageToken
        let fetch = fetch
        task = Task { [weak self] in
            do {
                let page = try await fetch(token)
                guard let self, !Task.isCancelled else { return }
                threadIDs.formUnion(page.threadIDs)
                pageToken = page.nextPageToken
                state = page.nextPageToken == nil ? .finished : .more
                onPage(page.threadIDs)
            } catch {
                guard let self, !Task.isCancelled else { return }
                if case .rateLimited? = error as? GmailError {
                    state = .busy
                } else {
                    state = .failed
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
