import Foundation
import GmailAPI
import MailStore
import MessageContent
import Observation
import SyncEngine

@MainActor @Observable
final class MeetingPreparationModel: Identifiable {
    typealias SessionFactory = @MainActor (CalendarDisplayEvent, Set<String>, MeetingPreparationGeneration) throws -> MeetingPreparationSession
    let id = UUID()
    private(set) var event: CalendarDisplayEvent
    let occurrence: MeetingPreparationOccurrence?
    let followUps: FollowUpsModel
    private(set) var state: MeetingPreparationState = .idle
    private(set) var isLoading = false
    private(set) var isStale = false
    private(set) var statusMessage = ""
    private(set) var errorMessage: String?
    private(set) var sources: [MeetingPreparationSourceRow] = []
    private(set) var omittedSourceCount = 0
    private(set) var partialNotes: [String] = []
    var sourceSearchText = ""
    private(set) var searchResults: [MeetingPreparationSourceRow] = []
    private(set) var isSearching = false
    private(set) var searchError: String?
    private var reports: [MeetingPreparationThreadReport] = []
    private var acceptedEntries: [CommitmentEntry] = []
    private var acceptedWorkReady = false
    private var generatedAccess: MeetingPreparationAccess?

    @ObservationIgnored let storeProvider: @MainActor () -> AccountStore?
    @ObservationIgnored let mailAccountIDs: @MainActor () -> Set<String>
    @ObservationIgnored let access: @MainActor (Set<String>) -> MeetingPreparationAccess
    @ObservationIgnored let makeSession: SessionFactory
    @ObservationIgnored let readEvent: @MainActor (CalendarDisplayEvent) async throws -> CalendarDisplayEvent
    @ObservationIgnored let sourceLinks: @MainActor (CalendarDisplayEvent) async throws -> [CalendarSourceLink]
    @ObservationIgnored let sourceTitle: @MainActor (ThreadKey) async throws -> String?
    @ObservationIgnored let search: @MainActor (String, Set<String>) async throws -> [MeetingPreparationSourceRow]
    @ObservationIgnored let threadRevision: @MainActor (ThreadKey) async throws -> String?
    @ObservationIgnored let openMail: @MainActor (MailLink) -> Void
    @ObservationIgnored let previewFile: @MainActor (AssistantSource) async throws -> URL
    @ObservationIgnored let acceptSuggestion: @MainActor (FollowUpSuggestionRequest) -> Void
    @ObservationIgnored private var preferences: [ThreadKey: MeetingPreparationSourcePreference] = [:]
    @ObservationIgnored private var capturedMailAccountIDs: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var commitmentObservation: Task<Void, Never>?
    @ObservationIgnored private var preferenceObservation: Task<Void, Never>?
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var changingSources = 0
    @ObservationIgnored private var pendingThreads: Set<ThreadKey> = []
    @ObservationIgnored private var changedWhilePreparing: Set<ThreadKey> = []

    init(event: CalendarDisplayEvent, followUps: FollowUpsModel, store: @escaping @MainActor () -> AccountStore?,
         mailAccountIDs: @escaping @MainActor () -> Set<String>, access: @escaping @MainActor (Set<String>) -> MeetingPreparationAccess,
         makeSession: @escaping SessionFactory,
         readEvent: @escaping @MainActor (CalendarDisplayEvent) async throws -> CalendarDisplayEvent,
         sourceLinks: @escaping @MainActor (CalendarDisplayEvent) async throws -> [CalendarSourceLink],
         sourceTitle: @escaping @MainActor (ThreadKey) async throws -> String? = { _ in nil },
         search: @escaping @MainActor (String, Set<String>) async throws -> [MeetingPreparationSourceRow] = { _, _ in [] },
         threadRevision: @escaping @MainActor (ThreadKey) async throws -> String? = { _ in nil },
         openMail: @escaping @MainActor (MailLink) -> Void = { _ in },
         previewFile: @escaping @MainActor (AssistantSource) async throws -> URL = { _ in throw MeetingPreparationServiceError.sourceUnavailable },
         acceptSuggestion: @escaping @MainActor (FollowUpSuggestionRequest) -> Void = { _ in }) {
        self.event = event; self.followUps = followUps; storeProvider = store; self.mailAccountIDs = mailAccountIDs
        self.access = access; self.makeSession = makeSession; self.readEvent = readEvent; self.sourceLinks = sourceLinks
        self.sourceTitle = sourceTitle; self.search = search; self.threadRevision = threadRevision
        self.openMail = openMail; self.previewFile = previewFile; self.acceptSuggestion = acceptSuggestion
        do { occurrence = try MeetingPreparationOccurrence(eventAccountID: event.accountID, calendarID: event.calendarID, event: event.event) }
        catch {
            occurrence = nil; state = .unavailable
            statusMessage = "Choose a saved meeting occurrence before preparing it."
        }
    }

    var coverageMessage: String {
        "Up to 20 related conversations and 5 full summaries from this profile's accounts with assistant access. Files come from included conversations."
    }

    private var generatedContentAllowed: Bool {
        guard let generatedAccess else { return false }
        return !stopped && mailAccountIDs() == capturedMailAccountIDs && access(capturedMailAccountIDs) == generatedAccess
    }

    var sections: [MeetingPreparationSection] {
        guard generatedContentAllowed else { return [] }
        return reports.filter { !isExcluded($0.candidate.thread) }.map { prepared in
            let tracked = acceptedEntries.filter { $0.record.accountID == prepared.candidate.thread.accountID && $0.record.threadID == prepared.candidate.thread.threadID }
            var suggestions: [MeetingPreparationTaskSuggestion] = []
            var suppressed = 0
            if acceptedWorkReady {
                for task in prepared.report.summary.openTasks {
                    guard let request = FollowUpSuggestionRequest.make(task, report: prepared.report, detail: prepared.detail) else { continue }
                    if tracked.contains(where: { $0.record.acceptanceKey == request.acceptanceKey }) { continue }
                    let cited = prepared.report.sources.filter { task.sourceIDs.contains($0.id) }
                    let messageIDs = Set(cited.compactMap(\.messageID))
                    if tracked.contains(where: { messageIDs.contains($0.record.sourceMessageID) }) { suppressed += 1; continue }
                    suggestions.append(MeetingPreparationTaskSuggestion(task: task, sources: cited, request: request))
                }
            }
            return MeetingPreparationSection(candidate: prepared.candidate, report: prepared.report,
                suggestions: suggestions, trackedWork: tracked, suppressedSuggestionCount: suppressed)
        }
    }

    var trackedWork: [CommitmentEntry] {
        let keys = Set(sources.filter { !$0.isExcluded }.map(\.key))
        let available = mailAccountIDs()
        return acceptedEntries.filter { available.contains($0.record.accountID) && keys.contains(ThreadKey(accountID: $0.record.accountID, threadID: $0.record.threadID)) }
    }

    var recentFiles: [MeetingPreparationAttachment] {
        guard generatedContentAllowed else { return [] }
        var seen: Set<String> = []
        return reports.filter { !isExcluded($0.candidate.thread) }.flatMap(\.attachments)
            .filter { seen.insert($0.id).inserted }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    func start() async {
        guard !stopped, state == .idle else { return }
        await refresh()
    }

    func refresh() async {
        guard !stopped, occurrence != nil else { return }
        invalidateOperation(clearReports: true)
        let epoch = generation
        capturedMailAccountIDs = mailAccountIDs()
        let capturedAccess = access(capturedMailAccountIDs)
        generatedAccess = capturedAccess
        isLoading = true; state = .loading; isStale = false; errorMessage = nil
        partialNotes = []; omittedSourceCount = 0; statusMessage = "Loading meeting sources…"
        changedWhilePreparing = []; pendingThreads = []
        observeAccess()
        let task = Task { await prepare(epoch: epoch, capturedAccess: capturedAccess) }
        operation = task
        await task.value
        if generation == epoch { operation = nil; isLoading = false }
    }

    func cancel() {
        invalidateOperation(clearReports: false)
        state = .cancelled; statusMessage = "Preparation cancelled. Refresh to try again."
    }

    func stop() {
        stopped = true; observationGeneration += 1
        invalidateOperation(clearReports: true)
        commitmentObservation?.cancel(); commitmentObservation = nil
        preferenceObservation?.cancel(); preferenceObservation = nil
        searchGeneration += 1; isSearching = false; searchResults = []
    }

    func revalidateAccess() {
        guard !stopped else { return }
        let available = mailAccountIDs()
        sources.removeAll { !available.contains($0.key.accountID) }
        searchResults.removeAll { !available.contains($0.key.accountID) }
        acceptedEntries.removeAll { !available.contains($0.record.accountID) }
        guard let generatedAccess, available != capturedMailAccountIDs || access(capturedMailAccountIDs) != generatedAccess else { return }
        invalidateOperation(clearReports: true)
        state = .permissionDisabled; statusMessage = "Access changed. Refresh after checking assistant and calendar permissions."
    }

    func eventChanged(_ updated: CalendarDisplayEvent?) {
        guard !stopped, let updated, let occurrence,
              let key = try? MeetingPreparationOccurrence(eventAccountID: updated.accountID, calendarID: updated.calendarID, event: updated.event),
              key == occurrence, updated.event != event.event else { return }
        markStale("The meeting changed. Refresh this preparation.")
    }

    func eventUnavailable() {
        guard !stopped, state != .idle else { return }
        markStale("The saved event is unavailable. Refresh to check the meeting.")
    }

    func process(_ snapshot: MailSyncNotification) async {
        guard !stopped else { return }
        revalidateAccess()
        let epoch = generation
        let changed = Set(snapshot.messages.map { ThreadKey(accountID: snapshot.accountID, threadID: $0.record.threadID) })
        if isLoading {
            changedWhilePreparing.formUnion(changed)
            let included = pendingThreads.union(sources.filter { !$0.isExcluded }.map(\.key))
            if !included.isDisjoint(with: changed) { markStale("Supporting mail changed. Refresh this preparation."); return }
        }
        for report in reports where report.candidate.thread.accountID == snapshot.accountID {
            if changed.contains(report.candidate.thread) { markStale("Supporting mail changed. Refresh this preparation."); return }
            do {
                let revision = try await threadRevision(report.candidate.thread)
                guard generation == epoch, !stopped else { return }
                if revision != report.revision { markStale("Supporting mail changed or became unavailable. Refresh this preparation."); return }
            } catch { markStale("Supporting mail could not be checked. Refresh this preparation."); return }
        }
    }

    private func prepare(epoch: Int, capturedAccess: MeetingPreparationAccess) async {
        guard let occurrence, let store = storeProvider() else { fail("Source preferences are unavailable.", epoch: epoch); return }
        do {
            let choices = try await store.meetingPreparationPreferences(for: occurrence)
            guard current(epoch) else { return }
            preferences = Dictionary(choices.map { (ThreadKey(accountID: $0.mailAccountID, threadID: $0.threadID), $0) }, uniquingKeysWith: { _, last in last })
            var eventIsFresh = true
            do {
                let updated = try await readEvent(event)
                guard current(epoch) else { return }
                guard try MeetingPreparationOccurrence(eventAccountID: updated.accountID, calendarID: updated.calendarID, event: updated.event) == occurrence else {
                    throw MeetingPreparationServiceError.eventChanged
                }
                event = updated
            } catch {
                guard current(epoch) else { return }
                partialNotes.append("The meeting couldn't refresh; its saved occurrence is shown.")
                isStale = true
                eventIsFresh = false
            }
            let links: [CalendarSourceLink]
            do { links = try await sourceLinks(event) }
            catch { links = []; partialNotes.append("Event-linked conversations couldn't be loaded.") }
            guard current(epoch) else { return }
            let linked = links.filter { $0.accountID == event.accountID && $0.calendarID == event.calendarID && $0.eventID == event.event.id }
                .map { MailLink(accountID: $0.accountID, threadID: $0.threadID, messageID: $0.messageID) }
            await populateSources(linked: linked, epoch: epoch)
            guard current(epoch) else { return }
            do { acceptedEntries = try await store.commitmentEntries(accountIDs: capturedMailAccountIDs); acceptedWorkReady = true }
            catch { acceptedEntries = []; acceptedWorkReady = false; partialNotes.append("Tracked-work status is unavailable; task suggestions are hidden.") }
            guard current(epoch) else { return }
            observeStore(store, occurrence: occurrence)
            guard eventIsFresh else { fail("The meeting couldn't refresh. Source choices are available; refresh before generating preparation.", epoch: epoch); return }
            guard mailAccountIDs() == capturedMailAccountIDs, access(capturedMailAccountIDs) == capturedAccess else { revalidateAccess(); return }
            guard event.event.status != "cancelled" else { fail("This meeting was cancelled. Its source conversations remain available.", epoch: epoch); return }
            let token = MeetingPreparationGeneration(isCurrent: { [weak self] in
                guard let self else { return false }
                return current(epoch) && mailAccountIDs() == capturedMailAccountIDs
            })
            let session = try makeSession(event, capturedMailAccountIDs, token)
            guard current(epoch), session.access == capturedAccess, session.isValid() else { revalidateAccess(); return }
            let included = choices.filter { $0.choice == .include }.map { MailLink(accountID: $0.mailAccountID, threadID: $0.threadID) }
            let excluded = Set(choices.filter { $0.choice == .exclude }.map { ThreadKey(accountID: $0.mailAccountID, threadID: $0.threadID) })
            let discovery = try await session.discover(event, included, linked, excluded)
            guard current(epoch), session.isValid() else { revalidateAccess(); return }
            merge(discovery.candidates)
            pendingThreads = Set(discovery.candidates.prefix(MeetingPreparationService.reportLimit).map(\.thread))
            guard pendingThreads.isDisjoint(with: changedWhilePreparing) else { markStale("Supporting mail changed. Refresh this preparation."); return }
            omittedSourceCount = discovery.omittedCount + max(0, discovery.candidates.count - MeetingPreparationService.reportLimit)
            partialNotes += discovery.failures
            if discovery.hasMoreSearchResults { partialNotes.append("More matching mail may exist beyond these search results.") }
            if discovery.requiresManualSelection { partialNotes.append("This meeting title is too general for reliable suggestions. Include the conversations you need.") }
            if let unavailable = session.providerUnavailableMessage {
                state = .providerUnavailable; statusMessage = unavailable; return
            }
            for candidate in discovery.candidates.prefix(MeetingPreparationService.reportLimit) {
                guard current(epoch), session.isValid() else { revalidateAccess(); return }
                statusMessage = "Preparing \(candidate.title)…"
                do {
                    let report = try await session.summarize(candidate)
                    guard current(epoch), session.isValid(), report.candidate.thread == candidate.thread else { revalidateAccess(); return }
                    try MeetingPreparationService.validate(report: report.report, detail: report.detail, thread: candidate.thread)
                    let latestRevision = try await threadRevision(candidate.thread)
                    guard current(epoch), session.isValid() else { revalidateAccess(); return }
                    guard latestRevision == report.revision else { markStale("Supporting mail changed or became unavailable. Refresh this preparation."); return }
                    reports.append(report)
                    if report.report.hasPartialCoverage { partialNotes.append("Some content in \(candidate.title) was unavailable or shortened.") }
                } catch is CancellationError { return } catch {
                    guard current(epoch), session.isValid() else { revalidateAccess(); return }
                    setSourceFailure(candidate.thread, message: "This conversation couldn't be prepared.")
                    partialNotes.append("A conversation couldn't be prepared; its original source remains available.")
                }
            }
            guard current(epoch), session.isValid() else { revalidateAccess(); return }
            partialNotes = Array(Set(partialNotes)).sorted()
            state = .ready
            statusMessage = reports.isEmpty ? "No prepared conversations to show. Include a conversation or refresh to try again." : "Preparation ready."
        } catch is CancellationError {} catch {
            guard current(epoch) else { return }
            if let error = error as? MeetingPreparationServiceError, error == .calendarDetailsRequired || error == .noMailAccess {
                state = .permissionDisabled; statusMessage = error.localizedDescription
            } else { fail("Couldn't prepare this meeting. Source choices have been kept; refresh to try again.", epoch: epoch) }
        }
    }

    private func current(_ epoch: Int) -> Bool {
        !stopped && !Task.isCancelled && generation == epoch && mailAccountIDs() == capturedMailAccountIDs
    }
    private func isExcluded(_ key: ThreadKey) -> Bool { preferences[key]?.choice == .exclude }
    private func invalidateOperation(clearReports: Bool) {
        generation += 1; operation?.cancel(); operation = nil; isLoading = false
        pendingThreads = []
        if clearReports { reports = []; generatedAccess = nil }
    }
    private func markStale(_ message: String) {
        isStale = true
        if isLoading { invalidateOperation(clearReports: false); state = reports.isEmpty ? .cancelled : .ready }
        statusMessage = message
    }
    private func fail(_ message: String, epoch: Int) {
        guard current(epoch) else { return }
        state = .unavailable; errorMessage = message; statusMessage = message
    }
}

extension MeetingPreparationModel {
    func searchSources() async {
        guard !stopped else { return }
        searchGeneration += 1
        let request = searchGeneration, query = sourceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let accounts = mailAccountIDs()
        searchError = nil; searchResults = []
        guard !query.isEmpty else { isSearching = false; return }
        isSearching = true
        defer { if request == searchGeneration { isSearching = false } }
        do {
            let values = try await search(query, accounts)
            guard !stopped, !Task.isCancelled, request == searchGeneration, sourceSearchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            var seen: Set<ThreadKey> = []
            searchResults = values.filter { accounts.contains($0.key.accountID) && mailAccountIDs().contains($0.key.accountID) && seen.insert($0.key).inserted }
                .prefix(20).map { row in
                    sourceRow(key: row.key, link: row.link, title: row.title, reason: "Cached conversation", unavailable: row.unavailableMessage)
                }
        } catch is CancellationError {} catch {
            if request == searchGeneration { searchError = "Couldn't search cached conversations. Try a different query or reconnect the account." }
        }
    }

    func include(_ key: ThreadKey) async { await setChoice(.include, for: key) }
    func exclude(_ key: ThreadKey) async { await setChoice(.exclude, for: key) }

    func restore(_ key: ThreadKey) async {
        await setChoice(.include, for: key)
    }

    private func setChoice(_ choice: MeetingPreparationSourceChoice, for key: ThreadKey) async {
        guard !stopped, let occurrence, let store = storeProvider(), mailAccountIDs().contains(key.accountID) else { return }
        invalidateOperation(clearReports: true); isStale = true
        let epoch = generation, expected = preferences[key]?.revision, editingAccounts = mailAccountIDs()
        changingSources += 1
        defer { changingSources -= 1 }
        do {
            let saved = try await store.setMeetingPreparationPreference(occurrence: occurrence, mailAccountID: key.accountID,
                threadID: key.threadID, choice: choice, expectedRevision: expected)
            guard !stopped, !Task.isCancelled, generation == epoch, mailAccountIDs() == editingAccounts else { return }
            preferences[key] = saved
            await refresh()
        } catch {
            if !stopped, !Task.isCancelled, generation == epoch, mailAccountIDs() == editingAccounts {
                state = .unavailable; errorMessage = "Couldn't save this source choice. Refresh to review its saved state."
            }
        }
    }

    func openConversation(_ key: ThreadKey) {
        guard !stopped, mailAccountIDs().contains(key.accountID),
              let row = (sources + searchResults).first(where: { $0.key == key }) else { return }
        openMail(row.link)
    }

    func openSource(_ source: AssistantSource) {
        guard !stopped, !source.isCalendar, mailAccountIDs().contains(source.accountID),
              sources.contains(where: { $0.key == ThreadKey(accountID: source.accountID, threadID: source.threadID) }) else { return }
        openMail(MailLink(accountID: source.accountID, threadID: source.threadID, messageID: source.messageID))
    }

    func previewAttachment(_ file: MeetingPreparationAttachment) async -> URL? {
        guard !stopped, recentFiles.contains(where: { $0 == file }), mailAccountIDs().contains(file.source.accountID) else { return nil }
        let epoch = generation
        do {
            let url = try await previewFile(file.source)
            guard current(epoch), recentFiles.contains(where: { $0 == file }), mailAccountIDs().contains(file.source.accountID) else { return nil }
            return url
        } catch {
            if current(epoch) { errorMessage = "Couldn't preview this file. Open its source email to try again." }
            return nil
        }
    }

    func trackSuggestion(_ suggestion: MeetingPreparationTaskSuggestion) {
        guard !stopped, sections.flatMap(\.suggestions).contains(where: { $0.id == suggestion.id }) else { return }
        acceptSuggestion(suggestion.request)
    }

    private func populateSources(linked: [MailLink], epoch: Int) async {
        var links: [ThreadKey: MailLink] = [:]
        for link in linked { links[ThreadKey(accountID: link.accountID, threadID: link.threadID)] = link }
        for key in preferences.keys where links[key] == nil { links[key] = MailLink(accountID: key.accountID, threadID: key.threadID) }
        var rows: [MeetingPreparationSourceRow] = []
        for (index, key) in links.keys.sorted().enumerated() {
            guard current(epoch), let link = links[key] else { return }
            let allowed = capturedMailAccountIDs.contains(key.accountID) && mailAccountIDs().contains(key.accountID)
            let title = index < 20 && allowed ? (try? await sourceTitle(key)) : nil
            guard current(epoch) else { return }
            let reason = preferences[key]?.choice == .include ? "Included by you" : preferences[key]?.choice == .exclude ? "Excluded by you" : "Linked to this event"
            rows.append(sourceRow(key: key, link: link, title: title ?? "Conversation", reason: reason,
                unavailable: mailAccountIDs().contains(key.accountID) ? nil : "This mail account is unavailable."))
        }
        sources = rows
    }

    private func sourceRow(key: ThreadKey, link: MailLink, title: String, reason: String, unavailable: String? = nil) -> MeetingPreparationSourceRow {
        MeetingPreparationSourceRow(key: key, link: link, title: title, reason: reason,
            isExcluded: preferences[key]?.choice == .exclude, isExplicitlyIncluded: preferences[key]?.choice == .include,
            unavailableMessage: unavailable)
    }

    private func merge(_ candidates: [MeetingPreparationCandidate]) {
        var rows = sources
        for candidate in candidates {
            let existing = rows.first { $0.key == candidate.thread }
            let title = candidate.reason == .titleMatch ? candidate.title : existing?.title ?? candidate.title
            let row = sourceRow(key: candidate.thread, link: candidate.source, title: title, reason: candidate.reason.explanation)
            if let index = rows.firstIndex(where: { $0.key == candidate.thread }) { rows[index] = row }
            else { rows.append(row) }
        }
        sources = rows
    }

    private func setSourceFailure(_ key: ThreadKey, message: String) {
        sources = sources.map { row in
            row.key == key ? sourceRow(key: key, link: row.link, title: row.title, reason: row.reason, unavailable: message) : row
        }
    }

    private func observeAccess() {
        observationGeneration += 1
        registerAccessObservation(observationGeneration)
    }

    private func registerAccessObservation(_ epoch: Int) {
        guard !stopped, observationGeneration == epoch else { return }
        withObservationTracking {
            _ = access(capturedMailAccountIDs)
            _ = mailAccountIDs()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped, self.observationGeneration == epoch else { return }
                self.revalidateAccess()
                self.registerAccessObservation(epoch)
            }
        }
    }

    private func observeStore(_ store: AccountStore, occurrence: MeetingPreparationOccurrence) {
        commitmentObservation?.cancel(); preferenceObservation?.cancel()
        let ids = capturedMailAccountIDs
        commitmentObservation = Task { [weak self] in
            do {
                for try await entries in store.observeCommitments(accountIDs: ids) {
                    guard let self, !stopped, !Task.isCancelled else { return }
                    acceptedEntries = entries; acceptedWorkReady = true
                }
            } catch is CancellationError {} catch {
                guard let self, !stopped else { return }
                acceptedWorkReady = false
                partialNotes.append("Tracked-work status is unavailable; task suggestions are hidden.")
            }
        }
        preferenceObservation = Task { [weak self] in
            do {
                for try await choices in store.observeMeetingPreparationPreferences(for: occurrence) {
                    guard let self, !stopped, !Task.isCancelled else { return }
                    let updated = Dictionary(choices.map { (ThreadKey(accountID: $0.mailAccountID, threadID: $0.threadID), $0) }, uniquingKeysWith: { _, last in last })
                    guard updated != preferences else { continue }
                    preferences = updated
                    sources = sources.map { sourceRow(key: $0.key, link: $0.link, title: $0.title, reason: $0.reason, unavailable: $0.unavailableMessage) }
                    if changingSources == 0 {
                        invalidateOperation(clearReports: true); isStale = true
                        state = .ready; statusMessage = "Source choices changed. Refresh this preparation."
                    }
                }
            } catch is CancellationError {} catch {
                guard let self, !stopped else { return }
                invalidateOperation(clearReports: true)
                state = .unavailable; errorMessage = "Source preferences couldn't be checked. Refresh before preparing again."
            }
        }
    }
}
