import Foundation
import MailStore
import MessageContent
import Observation
import SyncEngine

@MainActor @Observable
final class FollowUpsModel {
    private(set) var entries: [CommitmentEntry] = []
    private(set) var accounts: [AccountRecord] = []
    var searchText = ""
    var searchFocusRequest = 0
    private(set) var isLoading = false
    private(set) var hasLoadedEntries = false
    private(set) var presentationRevision = 0
    var errorMessage: String?
    var notice: String?
    private(set) var busyIDs: Set<String> = []
    private(set) var pendingEditor: FollowUpEditorRequest?
    var selectedEntryID: String?
    var notificationPermission: MailNotificationPermission = .notRequested
    var replyCheckStates: [String: FollowUpReplyCheckState] = [:]

    @ObservationIgnored let storeProvider: @MainActor () -> AccountStore?
    @ObservationIgnored let visibleAccountIDs: @MainActor () -> Set<String>
    @ObservationIgnored let canReadAccount: @MainActor (String) -> Bool
    @ObservationIgnored let loadThread: @MainActor (String, String) async throws -> FollowUpThreadSnapshot
    @ObservationIgnored let prepareDraft: @MainActor (CommitmentRecord) async throws -> String
    @ObservationIgnored let openMail: @MainActor (CommitmentRecord) -> Void
    @ObservationIgnored let scheduler: any FollowUpNotificationScheduling
    @ObservationIgnored let now: @MainActor () -> Date
    @ObservationIgnored var generation = 0
    @ObservationIgnored var stopped = false
    @ObservationIgnored var evaluating = false
    @ObservationIgnored var removedAccounts: Set<String> = []
    @ObservationIgnored var reconciliationOffset = 0
    @ObservationIgnored private var ownAddressesByAccount: [String: Set<String>] = [:]
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var observationAccountIDs: Set<String> = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    init(store: @escaping @MainActor () -> AccountStore?,
         visibleAccountIDs: @escaping @MainActor () -> Set<String>,
         canReadAccount: @escaping @MainActor (String) -> Bool,
         loadThread: @escaping @MainActor (String, String) async throws -> FollowUpThreadSnapshot,
         prepareDraft: @escaping @MainActor (CommitmentRecord) async throws -> String,
         openMail: @escaping @MainActor (CommitmentRecord) -> Void = { _ in },
         scheduler: any FollowUpNotificationScheduling = NativeFollowUpNotificationScheduler(),
         now: @escaping @MainActor () -> Date = { .now }) {
        storeProvider = store; self.visibleAccountIDs = visibleAccountIDs
        self.canReadAccount = canReadAccount; self.loadThread = loadThread
        self.prepareDraft = prepareDraft; self.openMail = openMail
        self.scheduler = scheduler; self.now = now
    }

    var visibleEntries: [CommitmentEntry] {
        let visible = visibleAccountIDs()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard visible.contains(entry.record.accountID), !removedAccounts.contains(entry.record.accountID) else { return false }
            return query.isEmpty || [entry.record.title, entry.record.ownerName ?? "", entry.record.ownerEmail ?? "",
                                     entry.record.sourceSubject].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func accountName(for id: String) -> String {
        accounts.first { $0.id == id }.map { $0.displayName ?? $0.email } ?? "Account unavailable"
    }

    func replyCheckState(for entry: CommitmentEntry) -> FollowUpReplyCheckState? { replyCheckStates[entry.id] }

    func start() async {
        stopped = false
        await refresh()
        guard timer == nil, !stopped else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, !stopped else { return }
                await refresh()
            }
        }
    }

    func resume() async { await start() }

    func stop() {
        stopped = true; generation += 1; refreshGeneration += 1
        timer?.cancel(); timer = nil; observation?.cancel(); observation = nil
        observationAccountIDs = []; isLoading = false
        hasLoadedEntries = false
    }

    func refresh(checkReminders: Bool = true) async {
        guard !stopped, let store = storeProvider() else { return }
        refreshGeneration += 1
        let request = refreshGeneration, epoch = generation
        isLoading = true
        defer { if request == refreshGeneration { isLoading = false } }
        do {
            let records = try await store.accounts()
            removedAccounts.formIntersection(Set(records.map(\.id)))
            let ids = Set(records.map(\.id)).subtracting(removedAccounts)
            let values = try await store.commitmentEntries(accountIDs: ids)
            var identities: [String: Set<String>] = [:]
            for record in records where ids.contains(record.id) {
                let aliases = try await store.identities(accountID: record.id)
                identities[record.id] = Set(aliases.filter(\.canSend).map { $0.address.lowercased() }).union([record.email.lowercased()])
            }
            guard isCurrent(epoch), request == refreshGeneration else { return }
            accounts = records.filter { ids.contains($0.id) }; ownAddressesByAccount = identities
            applyEntries(values); errorMessage = nil
            observe(store: store, accountIDs: ids)
            if checkReminders { await evaluateReminders() }
        } catch is CancellationError {} catch {
            if isCurrent(epoch), request == refreshGeneration { errorMessage = "Couldn't load follow-ups." }
        }
    }

    private func observe(store: AccountStore, accountIDs: Set<String>) {
        guard observation == nil || observationAccountIDs != accountIDs else { return }
        observation?.cancel(); observationAccountIDs = accountIDs
        let epoch = generation
        observation = Task { [weak self] in
            do {
                for try await values in store.observeCommitments(accountIDs: accountIDs) {
                    guard let self, isCurrent(epoch), observationAccountIDs == accountIDs else { return }
                    applyEntries(values.filter { !removedAccounts.contains($0.record.accountID) })
                }
            } catch is CancellationError {} catch {
                guard let self, isCurrent(epoch) else { return }
                errorMessage = "Couldn't keep follow-ups up to date. Refresh to try again."
            }
        }
    }

    func beginTracking(source: FollowUpSource, title: String? = nil, ownerName: String? = nil,
                       dueAt: Date? = nil, acceptanceKey: String? = nil, direction: CommitmentDirection? = nil) {
        guard !stopped, !removedAccounts.contains(source.accountID) else { return }
        let own = ownAddressesByAccount[source.accountID] ?? Set(accounts.filter { $0.id == source.accountID }.map { $0.email.lowercased() })
        let senders = EmailAddress.parseList(source.sender)
        let sentByMe = senders.contains { own.contains($0.normalized) }
        let person = (sentByMe ? EmailAddress.parseList(source.recipients) : senders).first { !own.contains($0.normalized) }
        let values = FollowUpEditValues(title: title ?? source.subject, ownerName: ownerName ?? person?.name ?? "",
            ownerEmail: person?.address ?? "", direction: direction ?? (sentByMe ? .waitingFor : .owedByMe),
            dueAt: dueAt, reminderKind: nil, remindAt: nil)
        pendingEditor = FollowUpEditorRequest(source: source, existing: nil, values: values, acceptanceKey: acceptanceKey)
        errorMessage = nil
    }

    func edit(_ entry: CommitmentEntry) {
        let record = entry.record, reminder = entry.reminders.first
        pendingEditor = FollowUpEditorRequest(source: FollowUpSource(commitment: record), existing: entry,
            values: FollowUpEditValues(title: record.title, ownerName: record.ownerName ?? "", ownerEmail: record.ownerEmail ?? "",
                direction: record.direction, dueAt: record.dueAt, reminderKind: reminder?.kind, remindAt: reminder?.remindAt),
            acceptanceKey: record.acceptanceKey)
        errorMessage = nil
    }

    func cancelEditor() { pendingEditor = nil }

    func saveEditor(_ request: FollowUpEditorRequest, values: FollowUpEditValues) async -> Bool {
        guard pendingEditor?.id == request.id, !stopped, let store = storeProvider(),
              !removedAccounts.contains(request.source.accountID) else { return false }
        let title = values.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = values.ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 2_000, (email.isEmpty || EmailAddress(address: email).isValid),
              (values.reminderKind == nil) == (values.remindAt == nil) else {
            errorMessage = "Enter a description, a valid email address if needed, and a time for the reminder."
            return false
        }
        let busyID = request.existing?.id ?? request.id.uuidString
        guard !busyIDs.contains(busyID) else { return false }
        busyIDs.insert(busyID)
        defer { busyIDs.remove(busyID) }
        let epoch = generation
        do {
            var record = request.existing?.record ?? CommitmentRecord(accountID: request.source.accountID,
                threadID: request.source.threadID, sourceMessageID: request.source.messageID,
                sourceMessageDate: request.source.date, sourceSubject: request.source.subject, title: title,
                direction: values.direction, acceptanceKey: request.acceptanceKey, createdAt: now())
            record.title = title; record.ownerName = Self.nonempty(values.ownerName)
            record.ownerEmail = Self.nonempty(email); record.direction = values.direction; record.dueAt = values.dueAt
            var reminders: [CommitmentReminderRecord] = []
            if let kind = values.reminderKind, let remindAt = values.remindAt {
                let previous = request.existing?.reminders.first { $0.kind == kind }
                var baselineID = previous?.baselineMessageID ?? request.source.messageID
                var baselineDate = previous?.baselineDate ?? request.source.date
                var baselineHistoryID = previous?.baselineHistoryID ?? (request.source.historyID > 0 ? request.source.historyID : nil)
                if kind == .noReply, request.existing != nil,
                   previous == nil || previous?.remindAt != remindAt {
                    let snapshot = try await loadThread(record.accountID, record.threadID)
                    guard snapshot.accountID == record.accountID, snapshot.threadID == record.threadID,
                          let latest = snapshot.messages.filter({ !(snapshot.labels[$0.id] ?? []).contains(SystemLabel.draft) })
                            .max(by: { ($0.date, $0.id) < ($1.date, $1.id) }) else { throw FollowUpModelError.invalidSource }
                    baselineID = latest.id; baselineDate = latest.date; baselineHistoryID = latest.historyID
                }
                reminders = [CommitmentReminderRecord(accountID: record.accountID, commitmentID: record.id, kind: kind,
                    remindAt: remindAt, baselineMessageID: baselineID, baselineDate: baselineDate,
                    baselineHistoryID: baselineHistoryID)]
            }
            guard isCurrent(epoch), pendingEditor?.id == request.id,
                  !removedAccounts.contains(record.accountID) else { return false }
            let saved: CommitmentEntry
            if let existing = request.existing {
                saved = try await store.saveCommitment(CommitmentEntry(record: record, reminders: reminders),
                    expectedRevision: existing.record.revision, now: now())
            } else { saved = try await store.createCommitment(record, reminders: reminders) }
            guard isCurrent(epoch), !removedAccounts.contains(record.accountID) else { return false }
            for previous in request.existing?.reminders ?? [] {
                let retained = saved.reminders.first { $0.kind == previous.kind }
                if retained?.notificationID != previous.notificationID || retained == nil {
                    await scheduler.remove(id: Self.notificationID(record, previous))
                }
            }
            guard isCurrent(epoch), !removedAccounts.contains(record.accountID) else { return false }
            selectedEntryID = saved.id
            if pendingEditor?.id == request.id { pendingEditor = nil }
            notice = "Follow-up saved."
            await refresh()
            return true
        } catch {
            if isCurrent(epoch) { errorMessage = Self.message(for: error) }
            return false
        }
    }

    func setStatus(_ entry: CommitmentEntry, status: CommitmentStatus) async {
        await mutate(entry) { store in
            _ = try await store.setCommitmentStatus(accountID: entry.record.accountID, id: entry.record.id,
                status: status, expectedRevision: entry.record.revision, now: now())
        }
    }

    func snooze(_ entry: CommitmentEntry, until: Date) async {
        guard let reminder = entry.reminders.first else { edit(entry); return }
        await mutate(entry) { store in
            if reminder.kind == .noReply {
                let snapshot = try await loadThread(entry.record.accountID, entry.record.threadID)
                guard !stopped, !removedAccounts.contains(entry.record.accountID),
                      snapshot.accountID == entry.record.accountID, snapshot.threadID == entry.record.threadID,
                      let latest = snapshot.messages.filter({ !(snapshot.labels[$0.id] ?? []).contains(SystemLabel.draft) })
                        .max(by: { ($0.date, $0.id) < ($1.date, $1.id) }) else { throw FollowUpModelError.unavailable }
                var edited = entry
                edited.reminders = entry.reminders.map { item in
                    guard item.kind == .noReply else { return item }
                    return CommitmentReminderRecord(accountID: item.accountID, commitmentID: item.commitmentID,
                        kind: item.kind, remindAt: until, baselineMessageID: latest.id,
                        baselineDate: latest.date, baselineHistoryID: latest.historyID)
                }
                _ = try await store.saveCommitment(edited, expectedRevision: entry.record.revision, now: now())
            } else {
                _ = try await store.snoozeCommitmentReminder(accountID: entry.record.accountID,
                    commitmentID: entry.record.id, kind: reminder.kind, until: until,
                    expectedRevision: entry.record.revision, now: now())
            }
        }
    }

    private func mutate(_ entry: CommitmentEntry, operation: (AccountStore) async throws -> Void) async {
        guard !stopped, !busyIDs.contains(entry.id), !removedAccounts.contains(entry.record.accountID),
              let store = storeProvider() else { return }
        busyIDs.insert(entry.id); defer { busyIDs.remove(entry.id) }
        let epoch = generation
        do {
            try await operation(store)
            guard isCurrent(epoch) else { return }
            for reminder in entry.reminders { await scheduler.remove(id: Self.notificationID(entry.record, reminder)) }
            await refresh()
        } catch { if isCurrent(epoch) { errorMessage = Self.message(for: error) } }
    }

    func openSource(_ entry: CommitmentEntry) {
        guard !removedAccounts.contains(entry.record.accountID) else { return }
        openMail(entry.record)
    }

    func draftFollowUp(_ entry: CommitmentEntry) async -> String? {
        guard !stopped, !busyIDs.contains(entry.id), !removedAccounts.contains(entry.record.accountID) else { return nil }
        busyIDs.insert(entry.id); defer { busyIDs.remove(entry.id) }
        let epoch = generation
        do {
            let id = try await prepareDraft(entry.record)
            guard isCurrent(epoch), !removedAccounts.contains(entry.record.accountID) else { return nil }
            return id
        } catch { if isCurrent(epoch) { errorMessage = "Couldn't prepare this follow-up. Check that its account and source email are available." }; return nil }
    }

    func openNotification(accountID: String, commitmentID: String) async {
        await refresh()
        guard let entry = entries.first(where: { $0.record.accountID == accountID && $0.record.id == commitmentID }) else { return }
        searchText = ""
        selectedEntryID = entry.id
    }

    func removeAccount(_ id: String) async {
        invalidateOperations()
        removedAccounts.insert(id)
        entries.removeAll { $0.record.accountID == id }; accounts.removeAll { $0.id == id }
        if pendingEditor?.source.accountID == id { pendingEditor = nil }
        await scheduler.removeAccount(id)
    }

    /// Called only after the root has opened a persisted, non-removing account.
    func restoreAccount(_ id: String) {
        guard removedAccounts.remove(id) != nil else { return }
        invalidateOperations()
    }

    private func invalidateOperations() {
        generation += 1; refreshGeneration += 1
        observation?.cancel(); observation = nil; observationAccountIDs = []
        isLoading = false; hasLoadedEntries = false
    }

    private func applyEntries(_ values: [CommitmentEntry]) {
        if entries != values || !hasLoadedEntries { presentationRevision += 1 }
        entries = values; hasLoadedEntries = true
    }

    func isCurrent(_ epoch: Int) -> Bool { !stopped && generation == epoch && !Task.isCancelled }
    static func nonempty(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
    static func message(for error: any Error) -> String {
        if case CommitmentStoreError.conflict = error { return "This follow-up changed. Close the editor and reopen it to review the latest version." }
        return "Couldn't save this follow-up. Check its account and try again."
    }
}
