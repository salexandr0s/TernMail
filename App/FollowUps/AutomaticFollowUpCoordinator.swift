import Foundation
import MailStore
import MessageContent
import Observation
import SyncEngine

@MainActor @Observable
final class AutomaticFollowUpCoordinator {
    typealias PrepareDraft = @MainActor (CommitmentEntry, AutomaticFollowUpDraftReceipt, AutomaticFollowUpDraftAuthorization) async throws -> Void
    typealias ConfigurePolicy = @MainActor (AccountStore, Set<String>, Set<String>, Bool, Int, Date, Date) async throws -> Set<String>
    let preferences: FollowUpPreferences
    let followUps: FollowUpsModel
    private(set) var isChecking = false
    private(set) var errorMessage: String?
    private(set) var draftErrorMessage: String?
    private(set) var appliedPreferencesRevision: Int?
    private(set) var appliedAccountIDs: Set<String>?
    private(set) var stopped = true
    var settingsReady: Bool { !stopped && appliedPreferencesRevision == preferences.revision && appliedAccountIDs == activeAccounts }
    var coverageMessage: String { FollowUpPreferences.coverageMessage }

    @ObservationIgnored let storeProvider: @MainActor () -> AccountStore?
    @ObservationIgnored let accountIDs: @MainActor () -> Set<String>
    @ObservationIgnored let cachedCandidates: @MainActor (String, Date, Int) async throws -> [ThreadKey]
    @ObservationIgnored let canDraft: @MainActor (String) -> Bool
    @ObservationIgnored let prepareDraft: PrepareDraft
    @ObservationIgnored let now: @MainActor () -> Date
    @ObservationIgnored let configurePolicy: ConfigurePolicy
    @ObservationIgnored var generation = 0
    @ObservationIgnored private var queue: [ThreadKey] = []
    @ObservationIgnored private var queued: Set<ThreadKey> = []
    @ObservationIgnored private var seededAccounts: Set<String> = []
    @ObservationIgnored private var removedAccounts: Set<String> = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var preferenceApplication: PreferenceApplication?

    private struct PreferenceApplication {
        let id: UUID
        let epoch: Int
        let revision: Int
        let accountIDs: Set<String>
        let task: Task<Void, Never>
    }

    init(preferences: FollowUpPreferences, followUps: FollowUpsModel,
         store: @escaping @MainActor () -> AccountStore?, accountIDs: @escaping @MainActor () -> Set<String>,
         cachedCandidates: @escaping @MainActor (String, Date, Int) async throws -> [ThreadKey],
         canDraft: @escaping @MainActor (String) -> Bool = { _ in false },
         prepareDraft: @escaping PrepareDraft = { _, _, _ in throw AutomaticFollowUpError.unavailable },
         now: @escaping @MainActor () -> Date = { .now },
         configurePolicy: @escaping ConfigurePolicy = { store, all, active, enabled, days, since, date in
             try await store.configureAutomaticFollowUps(accountIDs: all, activeAccountIDs: active,
                 enabled: enabled, delayDays: days, enabledSince: since, now: date)
         }) {
        self.preferences = preferences; self.followUps = followUps
        storeProvider = store; self.accountIDs = accountIDs; self.cachedCandidates = cachedCandidates
        self.canDraft = canDraft; self.prepareDraft = prepareDraft; self.now = now; self.configurePolicy = configurePolicy
    }

    /// Applies persisted policy before returning. Root calls this before F06's
    /// reminder evaluation; provider discovery proceeds in a bounded task.
    func start() async {
        stopped = false
        await applyPreferences()
        guard settingsReady else { return }
        await enqueueKnownThreads()
        kick()
        guard timer == nil, !stopped else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, !stopped else { return }
                if !settingsReady { await applyPreferences() }
                await enqueueKnownThreads()
                kick()
            }
        }
    }

    func resume() async { await start() }

    func stop() {
        stopped = true; generation += 1; appliedPreferencesRevision = nil
        appliedAccountIDs = nil
        // Keep the task handle until it finishes; a following start must wait
        // for an older store write before applying the new policy.
        preferenceApplication?.task.cancel()
        worker?.cancel(); worker = nil; timer?.cancel(); timer = nil
        queue = []; queued = []; seededAccounts = []; isChecking = false
    }

    func preferencesChanged() async {
        generation += 1; worker?.cancel(); worker = nil; isChecking = false
        seededAccounts = []
        appliedPreferencesRevision = nil
        guard !stopped else { return }
        await applyPreferences()
        guard settingsReady else { return }
        await enqueueKnownThreads()
        kick()
    }

    func process(_ snapshot: MailSyncNotification) async {
        guard settingsReady, preferences.automaticRemindersEnabled, !snapshot.messages.isEmpty,
              activeAccounts.contains(snapshot.accountID) else { return }
        enqueue(snapshot.messages.map { ThreadKey(accountID: snapshot.accountID, threadID: $0.record.threadID) })
        kick()
    }

    func removeAccount(_ id: String) async {
        generation += 1; worker?.cancel(); worker = nil; isChecking = false
        removedAccounts.insert(id); seededAccounts.remove(id)
        queue.removeAll { $0.accountID == id }; queued = Set(queue)
        await followUps.scheduler.removeAccount(id)
        kick()
    }

    func restoreAccount(_ id: String) {
        removedAccounts.remove(id); seededAccounts.remove(id)
        appliedPreferencesRevision = nil
    }

    private var activeAccounts: Set<String> { accountIDs().subtracting(removedAccounts) }

    private func applyPreferences() async {
        while !stopped && !Task.isCancelled {
            let application: PreferenceApplication
            if let current = preferenceApplication { application = current }
            else {
                let epoch = generation, revision = preferences.revision, ids = activeAccounts
                let task = Task { await performPreferenceApplication(epoch: epoch, revision: revision, ids: ids) }
                application = PreferenceApplication(id: UUID(), epoch: epoch, revision: revision, accountIDs: ids, task: task)
                preferenceApplication = application
            }
            await application.task.value
            if preferenceApplication?.id == application.id { preferenceApplication = nil }
            // A failed current request is retried on the next tick. A changed
            // request is replayed now, after the older write has completed.
            if generation == application.epoch, preferences.revision == application.revision,
               activeAccounts == application.accountIDs { return }
        }
    }

    private func performPreferenceApplication(epoch: Int, revision: Int, ids: Set<String>) async {
        guard !stopped, let store = storeProvider() else { return }
        do {
            let all = Set(try await store.accounts().map(\.id)).subtracting(removedAccounts)
            guard isCurrent(epoch, preferencesRevision: revision), activeAccounts == ids else { return }
            let removed = try await configurePolicy(store, all, ids, preferences.automaticRemindersEnabled,
                preferences.delayDays, preferences.enabledSince, now())
            for id in removed { await followUps.scheduler.remove(id: id) }
            guard isCurrent(epoch, preferencesRevision: revision), activeAccounts == ids else { return }
            seededAccounts.formIntersection(ids)
            appliedPreferencesRevision = revision; appliedAccountIDs = ids; errorMessage = nil
            await followUps.refresh(checkReminders: false)
        } catch is CancellationError {} catch {
            if generation == epoch { errorMessage = "Couldn't apply automatic follow-up settings. Automatic alerts are paused until this succeeds." }
        }
    }

    private func enqueueKnownThreads() async {
        guard settingsReady, preferences.automaticRemindersEnabled, let store = storeProvider() else { return }
        let epoch = generation, revision = preferences.revision, ids = activeAccounts
        do {
            let managed = try await store.automaticFollowUps(accountIDs: ids)
            guard isCurrent(epoch, preferencesRevision: revision) else { return }
            enqueue(managed.filter { $0.managed && $0.scheduleEnabled }.map { ThreadKey(accountID: $0.accountID, threadID: $0.threadID) })
            for id in ids.subtracting(seededAccounts).sorted() {
                let candidates = try await cachedCandidates(id, now() - 30 * 86_400, 100)
                guard isCurrent(epoch, preferencesRevision: revision), activeAccounts.contains(id) else { return }
                enqueue(candidates.filter { $0.accountID == id })
                seededAccounts.insert(id)
            }
        } catch is CancellationError {} catch {
            if generation == epoch { errorMessage = "Some cached sent conversations couldn't be checked. New mail will still be checked as it syncs." }
        }
    }

    private func enqueue(_ keys: [ThreadKey]) {
        for key in keys where activeAccounts.contains(key.accountID) && queued.insert(key).inserted { queue.append(key) }
    }

    private func kick() {
        guard worker == nil, settingsReady, preferences.automaticRemindersEnabled, !queue.isEmpty else { return }
        let epoch = generation, revision = preferences.revision
        worker = Task { [weak self] in
            guard let self else { return }
            await runPass(epoch: epoch, preferencesRevision: revision)
            if generation == epoch { worker = nil }
        }
    }

    /// Exposed internally so synthetic tests can wait for a bounded pass.
    func waitForCurrentPass() async { await worker?.value }

    private func runPass(epoch: Int, preferencesRevision: Int) async {
        guard let store = storeProvider(), isCurrent(epoch, preferencesRevision: preferencesRevision) else { return }
        isChecking = true
        defer { if generation == epoch { isChecking = false } }
        var reads: [String: FollowUpThreadSnapshot] = [:]
        var retry: [ThreadKey] = []
        defer { if isCurrent(epoch, preferencesRevision: preferencesRevision) { enqueue(retry) } }
        var drafts = 0
        for _ in 0..<20 {
            guard isCurrent(epoch, preferencesRevision: preferencesRevision), !queue.isEmpty else { break }
            let key = queue.removeFirst(); queued.remove(key)
            guard activeAccounts.contains(key.accountID) else { continue }
            guard followUps.canReadAccount(key.accountID) else { retry.append(key); continue }
            do {
                let snapshot = try await followUps.loadThread(key.accountID, key.threadID)
                guard isCurrent(epoch, preferencesRevision: preferencesRevision), activeAccounts.contains(key.accountID) else { return }
                guard snapshot.accountID == key.accountID, snapshot.threadID == key.threadID else { throw AutomaticFollowUpError.staleConversation }
                let probe = CommitmentRecord(accountID: key.accountID, threadID: key.threadID, sourceMessageID: "",
                    sourceMessageDate: now(), sourceSubject: "", title: "", direction: .waitingFor)
                reads[FollowUpsModel.threadKey(probe)] = snapshot
                let candidate: AutomaticFollowUpCandidate
                switch Self.evaluate(snapshot) {
                case .candidate(let found): candidate = found
                case .automatedRecipients:
                    // Removes a follow-up Tern made before it skipped this kind of mail.
                    for id in try await store.removeAutomaticFollowUp(accountID: key.accountID, threadID: key.threadID) {
                        await followUps.scheduler.remove(id: id)
                    }
                    continue
                case .noFollowUp: continue
                }
                let due = candidate.outgoingDate + TimeInterval(preferences.delayDays) * 86_400
                let mutation = try await store.reconcileAutomaticFollowUp(candidate, delayDays: preferences.delayDays,
                    eligibleForAlerts: due > preferences.enabledSince, now: now())
                for id in mutation.removedNotificationIDs { await followUps.scheduler.remove(id: id) }
                guard isCurrent(epoch, preferencesRevision: preferencesRevision), let entry = mutation.entry else { continue }
                if drafts < 2, preferences.automaticDraftsEnabled, due <= now(),
                   followUps.visibleAccountIDs().contains(key.accountID), canDraft(key.accountID),
                   !snapshot.labels.values.contains(where: { $0.contains(SystemLabel.draft) }) {
                    if await draft(entry, store: store, epoch: epoch, preferencesRevision: preferencesRevision) { drafts += 1 }
                }
            } catch is CancellationError { return } catch {
                if isCurrent(epoch, preferencesRevision: preferencesRevision) {
                    retry.append(key)
                    errorMessage = "Some sent conversations couldn't be checked. Their reply status remains unknown."
                }
            }
        }
        guard isCurrent(epoch, preferencesRevision: preferencesRevision) else { return }
        await followUps.refresh(checkReminders: false)
        await followUps.evaluateReminders(preloaded: reads)
    }

    private func draft(_ entry: CommitmentEntry, store: AccountStore, epoch: Int, preferencesRevision: Int) async -> Bool {
        guard let reminder = entry.reminders.first(where: { $0.kind == .noReply && $0.receivedReplyMessageID == nil }) else { return false }
        var receipt: AutomaticFollowUpDraftReceipt?
        do {
            guard isCurrent(epoch, preferencesRevision: preferencesRevision), canDraft(entry.record.accountID) else { return false }
            receipt = try await store.claimAutomaticFollowUpDraft(accountID: entry.record.accountID, commitmentID: entry.record.id,
                expectedReminderRevision: reminder.revision, now: now())
            guard let receipt else { return false }
            let authorization = AutomaticFollowUpDraftAuthorization(isValid: { [weak self] in
                guard let self, isCurrent(epoch, preferencesRevision: preferencesRevision), preferences.automaticDraftsEnabled,
                      preferences.automaticRemindersEnabled, activeAccounts.contains(entry.record.accountID),
                      followUps.visibleAccountIDs().contains(entry.record.accountID), canDraft(entry.record.accountID) else { return false }
                return (try? await store.validateAutomaticFollowUpDraftClaim(receipt, now: now())) == true
            })
            guard await authorization.isValid() else { throw CancellationError() }
            try await prepareDraft(entry, receipt, authorization)
            _ = try await store.finishAutomaticFollowUpDraft(receipt, state: .prepared, now: now())
            draftErrorMessage = nil
            return true
        } catch {
            if let receipt {
                // A reserved ID remains terminal even if a draft save committed
                // immediately before cancellation or an account-access change.
                let state: AutomaticFollowUpDraftState = error is CancellationError ? .uncertain : .failed
                _ = try? await store.finishAutomaticFollowUpDraft(receipt, state: state, now: now())
            }
            if isCurrent(epoch, preferencesRevision: preferencesRevision) {
                draftErrorMessage = "An automatic follow-up draft couldn't be prepared. You can use Draft Follow-up to review it manually."
            }
            return receipt != nil
        }
    }

    func isCurrent(_ epoch: Int, preferencesRevision: Int) -> Bool {
        !stopped && !Task.isCancelled && generation == epoch && preferences.revision == preferencesRevision
    }

    /// What a sent conversation asks of automatic follow-up.
    enum Evaluation: Equatable {
        /// Wait for a reply to the latest sent message.
        case candidate(AutomaticFollowUpCandidate)
        /// The latest sent message asked a mailing list to unsubscribe, or
        /// went only to mailboxes nobody answers from, such as a no-reply
        /// address, so there is nothing to wait for.
        case automatedRecipients
        /// Nothing to track: no verified sent message, no outside recipient, or a reply came.
        case noFollowUp
    }

    static func candidate(in snapshot: FollowUpThreadSnapshot) -> AutomaticFollowUpCandidate? {
        if case .candidate(let candidate) = evaluate(snapshot) { return candidate }
        return nil
    }

    static func evaluate(_ snapshot: FollowUpThreadSnapshot) -> Evaluation {
        let own = Set(snapshot.ownAddresses.map { $0.lowercased() })
        let outgoing = snapshot.messages.filter { message in
            let labels = snapshot.labels[message.id] ?? []
            guard message.accountID == snapshot.accountID, message.threadID == snapshot.threadID,
                  labels.contains(SystemLabel.sent), labels.isDisjoint(with: [SystemLabel.draft, SystemLabel.trash, SystemLabel.spam]),
                  let sender = EmailAddress.parseList(message.sender).first?.normalized, own.contains(sender) else { return false }
            return true
        }.max { ($0.date, $0.id) < ($1.date, $1.id) }
        guard let outgoing else { return .noFollowUp }
        let outside = (EmailAddress.parseList(outgoing.recipients) + EmailAddress.parseList(outgoing.cc ?? ""))
            .filter { $0.isValid && !own.contains($0.normalized) }
        let recipients = asksToUnsubscribe(outgoing.subject) ? [] : outside.filter { !$0.isAutomatedMailbox }
        guard !recipients.isEmpty else { return outside.isEmpty ? .noFollowUp : .automatedRecipients }
        let participants = Set(recipients.map(\.normalized))
        let replied = snapshot.messages.contains { message in
            let labels = snapshot.labels[message.id] ?? []
            guard message.accountID == snapshot.accountID, message.threadID == snapshot.threadID, message.date > outgoing.date,
                  !labels.contains(SystemLabel.draft), !labels.contains(SystemLabel.sent),
                  let sender = EmailAddress.parseList(message.sender).first?.normalized, !own.contains(sender) else { return false }
            return participants.contains(sender)
        }
        guard !replied else { return .noFollowUp }
        let title = outgoing.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return .candidate(AutomaticFollowUpCandidate(accountID: snapshot.accountID, threadID: snapshot.threadID,
            outgoingMessageID: outgoing.id, outgoingDate: outgoing.date, sourceSubject: outgoing.subject,
            title: title.isEmpty ? "Follow up on sent email" : String(title.prefix(2_000)),
            ownerName: recipients.count == 1 ? recipients.first?.name : "Recipients",
            ownerEmail: recipients.count == 1 ? recipients.first?.address : nil, baselineHistoryID: outgoing.historyID))
    }

    /// A subject that starts with "unsubscribe", as a list's unsubscribe link
    /// fills it in. The list may read these requests at any address.
    /// "Re: unsubscribe" is a conversation.
    private static func asksToUnsubscribe(_ subject: String) -> Bool {
        subject.lowercased().split { !$0.isLetter }.first == "unsubscribe"
    }
}
