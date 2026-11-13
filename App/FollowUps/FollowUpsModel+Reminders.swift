import Foundation
import MailStore
import MessageContent
import SyncEngine

extension FollowUpsModel {
    func refreshNotificationPermission() async {
        notificationPermission = await scheduler.permission()
    }

    func requestNotificationPermission() async {
        do {
            _ = try await scheduler.requestPermission()
            notificationPermission = await scheduler.permission()
            await evaluateReminders()
        } catch { errorMessage = "Couldn't request notification permission." }
    }

    /// Sync events only identify affected threads. An authoritative metadata
    /// read also handles history gaps and replies received while Tern was off.
    func process(_ snapshot: MailSyncNotification) async {
        guard !stopped, !snapshot.messages.isEmpty, !removedAccounts.contains(snapshot.accountID),
              let store = storeProvider() else { return }
        let epoch = generation
        do {
            let items = try await store.commitmentEntries(accountIDs: [snapshot.accountID], includeClosed: false)
            guard isCurrent(epoch) else { return }
            let threads = Set(snapshot.messages.map(\.record.threadID))
            var reads: [String: FollowUpThreadSnapshot] = [:]
            var checks: [String: FollowUpReplyCheckState] = [:]
            for entry in items where threads.contains(entry.record.threadID) {
                guard isCurrent(epoch), visibleAccountIDs().contains(entry.record.accountID),
                      canReadAccount(entry.record.accountID) else { continue }
                guard entry.reminders.contains(where: { $0.kind == .noReply && $0.receivedReplyMessageID == nil }) else { continue }
                do {
                    let read = try await threadSnapshot(for: entry, cached: &reads)
                    guard isCurrent(epoch), visibleAccountIDs().contains(entry.record.accountID) else { return }
                    await reconcileReply(entry, snapshot: read, store: store, epoch: epoch, checks: &checks)
                } catch { if isCurrent(epoch) { checks[entry.id] = .unavailable } }
            }
            guard isCurrent(epoch) else { return }
            publishReplyChecks(checks)
            await refresh(checkReminders: false)
            await evaluateReminders(preloaded: reads)
        } catch is CancellationError {} catch {
            // Unknown coverage retains the commitment and pending reminder.
        }
    }

    func evaluateReminders(preloaded: [String: FollowUpThreadSnapshot] = [:]) async {
        guard !stopped, !evaluating, let store = storeProvider() else { return }
        evaluating = true
        defer { evaluating = false }
        let epoch = generation
        notificationPermission = await scheduler.permission()
        guard isCurrent(epoch) else { return }
        do {
            let active = try await store.commitmentEntries(accountIDs: visibleAccountIDs().subtracting(removedAccounts), includeClosed: false)
            guard isCurrent(epoch) else { return }
            var reads = preloaded
            var checks: [String: FollowUpReplyCheckState] = [:]
            // Bound each pass and rotate through the rest on subsequent ticks.
            // Already-delivered reminders still reconcile later replies.
            let candidates = active.filter { $0.reminders.contains { $0.kind == .noReply && $0.receivedReplyMessageID == nil } }
            if !candidates.isEmpty {
                let offset = reconciliationOffset % candidates.count
                let rotated = Array(candidates[offset...]) + Array(candidates[..<offset])
                for entry in rotated.prefix(20) {
                    guard isCurrent(epoch), visibleAccountIDs().contains(entry.record.accountID),
                          !removedAccounts.contains(entry.record.accountID) else { continue }
                    do {
                        let read = try await threadSnapshot(for: entry, cached: &reads)
                        guard isCurrent(epoch) else { return }
                        await reconcileReply(entry, snapshot: read, store: store, epoch: epoch, checks: &checks)
                    } catch { if isCurrent(epoch) { checks[entry.id] = .unavailable } }
                }
                reconciliationOffset = (offset + min(20, candidates.count)) % candidates.count
            }
            guard isCurrent(epoch) else { return }
            publishReplyChecks(checks)
            guard notificationPermission == .allowed else { return }
            let due = try await store.dueCommitmentReminders(accountIDs: visibleAccountIDs().subtracting(removedAccounts), now: now())
            for entry in due {
                for reminder in entry.reminders {
                    guard isCurrent(epoch), visibleAccountIDs().contains(entry.record.accountID),
                          !removedAccounts.contains(entry.record.accountID) else { continue }
                    if reminder.kind == .noReply {
                        let key = Self.threadKey(entry.record)
                        guard let read = reads[key], read.messages.contains(where: { $0.id == reminder.baselineMessageID }),
                              Self.reply(in: read, to: entry.record, reminder: reminder) == nil,
                              canReadAccount(entry.record.accountID) else { continue }
                    }
                    await deliver(entry, reminder: reminder, store: store, epoch: epoch)
                }
            }
        } catch is CancellationError {} catch {
            if isCurrent(epoch) { errorMessage = "Couldn't check follow-up reminders. Refresh to try again." }
        }
    }

    private func threadSnapshot(for entry: CommitmentEntry, cached: inout [String: FollowUpThreadSnapshot]) async throws -> FollowUpThreadSnapshot {
        let key = Self.threadKey(entry.record)
        if let value = cached[key] { return value }
        guard canReadAccount(entry.record.accountID) else { throw FollowUpModelError.unavailable }
        // A row that already shows a result keeps it until this read finishes,
        // so a recheck does not flip it to "Checking for replies" and back.
        if replyCheckStates[entry.id] == nil { replyCheckStates[entry.id] = .checking }
        let value = try await loadThread(entry.record.accountID, entry.record.threadID)
        guard value.accountID == entry.record.accountID, value.threadID == entry.record.threadID else { throw FollowUpModelError.invalidSource }
        cached[key] = value
        return value
    }

    /// Publishes one pass of reply checks with a single assignment, and only
    /// when a result differs, so observers update once per pass and not twice
    /// per thread.
    private func publishReplyChecks(_ checks: [String: FollowUpReplyCheckState]) {
        guard !checks.isEmpty else { return }
        let merged = replyCheckStates.merging(checks) { _, latest in latest }
        if merged != replyCheckStates { replyCheckStates = merged }
    }

    private func reconcileReply(_ entry: CommitmentEntry, snapshot: FollowUpThreadSnapshot, store: AccountStore, epoch: Int,
                                checks: inout [String: FollowUpReplyCheckState]) async {
        guard isCurrent(epoch), !removedAccounts.contains(entry.record.accountID),
              visibleAccountIDs().contains(entry.record.accountID), canReadAccount(entry.record.accountID),
              let reminder = entry.reminders.first(where: { $0.kind == .noReply && $0.receivedReplyMessageID == nil }) else { return }
        guard snapshot.messages.contains(where: { $0.id == reminder.baselineMessageID }) else {
            checks[entry.id] = .unavailable
            return
        }
        checks[entry.id] = .checked(snapshot.checkedAt)
        guard let reply = Self.reply(in: snapshot, to: entry.record, reminder: reminder) else { return }
        do {
            let changed = try await store.recordCommitmentReply(accountID: entry.record.accountID, commitmentID: entry.record.id,
                messageID: reply.id, receivedAt: reply.date, expectedReminderRevision: reminder.revision, now: now())
            if changed { await scheduler.remove(id: Self.notificationID(entry.record, reminder)) }
        } catch { if isCurrent(epoch) { errorMessage = "Couldn't update this follow-up's reply status." } }
    }

    static func reply(in snapshot: FollowUpThreadSnapshot, to record: CommitmentRecord,
                      reminder: CommitmentReminderRecord) -> MessageRecord? {
        guard snapshot.accountID == record.accountID, snapshot.threadID == record.threadID,
              let baseline = snapshot.messages.first(where: { $0.id == reminder.baselineMessageID }),
              baseline.accountID == record.accountID, baseline.threadID == record.threadID else { return nil }
        let own = Set(snapshot.ownAddresses.map { $0.lowercased() })
        let explicit = record.ownerEmail.map { $0.lowercased() }.flatMap { own.contains($0) ? nil : $0 }
        let participants = Set(EmailAddress.parseList([baseline.sender, baseline.recipients, baseline.cc ?? ""].joined(separator: ","))
            .map(\.normalized)).subtracting(own)
        return snapshot.messages.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.first { message in
            let labels = snapshot.labels[message.id] ?? []
            guard message.accountID == record.accountID, message.threadID == record.threadID,
                  message.id != reminder.baselineMessageID, message.date > reminder.baselineDate,
                  !labels.contains(SystemLabel.draft), !labels.contains(SystemLabel.sent),
                  let sender = EmailAddress.parseList(message.sender).first?.normalized, !own.contains(sender)
            else { return false }
            if let explicit { return sender == explicit }
            guard participants.contains(sender) else { return false }
            // Matching thread, known counterparty and a later received message
            // are useful evidence even when providers omit RFC References.
            return true
        }
    }

    private func deliver(_ entry: CommitmentEntry, reminder: CommitmentReminderRecord, store: AccountStore, epoch: Int) async {
        let identifier = Self.notificationID(entry.record, reminder)
        do {
            let automatic = try await store.automaticFollowUps(accountIDs: [entry.record.accountID])
                .first { $0.commitmentID == entry.record.id && $0.managed }
            guard automatic == nil || canDeliverAutomaticReminders() else { return }
            let current = try await store.commitmentEntries(accountIDs: [entry.record.accountID], includeClosed: false)
                .first { $0.record.id == entry.record.id }
            guard isCurrent(epoch), visibleAccountIDs().contains(entry.record.accountID),
                  !removedAccounts.contains(entry.record.accountID),
                  automatic == nil || canDeliverAutomaticReminders(),
                  current?.record.deferredUntil.map({ $0 <= now() }) ?? true,
                  current?.reminders.contains(where: { $0.kind == reminder.kind && $0.revision == reminder.revision && $0.isPending }) == true
            else { return }
            try await scheduler.schedule(FollowUpNotification(id: identifier, accountID: entry.record.accountID,
                commitmentID: entry.record.id, title: reminder.kind == .noReply ? "Follow up on an unanswered message" : "Follow-up reminder",
                body: entry.record.title))
            guard isCurrent(epoch), visibleAccountIDs().contains(entry.record.accountID),
                  !removedAccounts.contains(entry.record.accountID),
                  automatic == nil || canDeliverAutomaticReminders() else { await scheduler.remove(id: identifier); return }
            let saved = try await store.markCommitmentReminderDelivered(accountID: entry.record.accountID,
                commitmentID: entry.record.id, kind: reminder.kind, expectedReminderRevision: reminder.revision,
                notificationID: identifier, at: now())
            if !saved { await scheduler.remove(id: identifier) }
        } catch {
            await scheduler.remove(id: identifier)
            if isCurrent(epoch) { errorMessage = "Couldn't deliver a follow-up reminder. It remains in Waiting for." }
        }
    }

    static func notificationID(_ record: CommitmentRecord, _ reminder: CommitmentReminderRecord) -> String {
        reminder.notificationID ?? "tern.followup.\(Data(record.accountID.utf8).base64EncodedString()).\(record.id).\(reminder.kind.rawValue).\(reminder.revision)"
    }
    static func threadKey(_ record: CommitmentRecord) -> String { "\(record.accountID.utf8.count):\(record.accountID)\(record.threadID)" }
}
