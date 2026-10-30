import Foundation
import GmailAPI
import MailStore
import Observation
import SyncEngine

enum DeleteKeyBehavior: String, CaseIterable {
    case archive, trash
}

enum MailTriagePreferences {
    static let deleteKey = "mailDeleteKeyBehavior"
    static var deleteBehavior: DeleteKeyBehavior {
        DeleteKeyBehavior(rawValue: UserDefaults.standard.string(forKey: deleteKey) ?? "") ?? .archive
    }
}

struct MailDeletionReview: Identifiable {
    let id = UUID()
    let title: String
    let approvals: [PermanentDeletionApproval]
    var count: Int { approvals.reduce(0) { $0 + $1.count } }
}

/// Shared by commands, row menus and the mail toolbar.
@MainActor @Observable
final class MailTriageModel {
    var deletionReview: MailDeletionReview?
    var filterRequest: SenderFilterRequest?
    var error: String?
    private(set) var isPreparing = false
    private(set) var isDeleting = false
    @ObservationIgnored private weak var mailbox: MailboxModel?
    @ObservationIgnored private var queuedApprovals: Set<UUID> = []

    init(mailbox: MailboxModel) { self.mailbox = mailbox }

    func perform(_ action: TriageAction, targets: [(accountID: String, target: MailActionTarget)]? = nil) {
        guard let mailbox else { return }
        let targets = targets ?? mailbox.selectedActionTargets
        let name: String
        switch action {
        case .spam: name = "Report Spam"
        case .notSpam: name = "Not Spam"
        case .important: name = "Mark as Important"
        case .notImportant: name = "Mark as Not Important"
        }
        mailbox.undoManager?.beginUndoGrouping()
        for (accountID, target) in targets {
            guard let owner = mailbox.account(id: accountID) else { continue }
            mailbox.queueUndoable(name, confirmation: name, in: owner) { engine in
                try await engine.performTriage(action, target: target)
            }
        }
        mailbox.undoManager?.endUndoGrouping()
    }

    func markAllRead() {
        guard let mailbox, let labelID = mailbox.selectedLabelID,
              !mailbox.search.isActive, labelID != MailboxModel.outboxID, labelID != MailboxModel.snoozedID else { return }
        mailbox.undoManager?.beginUndoGrouping()
        for owner in mailbox.selectedAccounts {
            mailbox.queueUndoable("Mark All as Read", confirmation: "Unread messages marked as read", in: owner) { engine in
                try await engine.markAllRead(labelID: labelID)
            }
        }
        mailbox.undoManager?.endUndoGrouping()
    }

    func preparePermanentDeletion(entireMailbox: Bool = false) async {
        guard !isPreparing, !isDeleting, let mailbox, !mailbox.search.isActive,
              let labelID = mailbox.selectedLabelID, [SystemLabel.spam, SystemLabel.trash].contains(labelID) else { return }
        isPreparing = true
        error = nil
        defer { isPreparing = false }
        let targets: [(accountID: String, target: MailActionTarget?)] = entireMailbox
            ? mailbox.selectedAccounts.map { ($0.account.id, nil) }
            : mailbox.selectedActionTargets.map { ($0.accountID, $0.target) }
        do {
            var approvals: [PermanentDeletionApproval] = []
            for (accountID, target) in targets {
                guard let owner = mailbox.account(id: accountID) else { throw TriageError.accountMismatch }
                let approval = try await owner.engine.preparePermanentDeletion(labelID: labelID, target: target)
                guard mailbox.account(id: accountID) === owner else { throw TriageError.accountMismatch }
                if approval.count > 0 { approvals.append(approval) }
            }
            guard !approvals.isEmpty else {
                mailbox.notice = MailboxModel.Notice(message: "No messages are available to delete.")
                return
            }
            deletionReview = MailDeletionReview(
                title: entireMailbox ? (labelID == SystemLabel.trash ? "Empty Trash" : "Delete All Spam") : "Delete Forever",
                approvals: approvals)
            queuedApprovals = []
        } catch {
            self.error = "Couldn't count the messages. Connect to Google and try again."
        }
    }

    func deleteReviewedMessages(using app: AppModel) async {
        guard !isDeleting, let review = deletionReview, let mailbox else { return }
        isDeleting = true
        error = nil
        defer { isDeleting = false }
        do {
            // Every account's permission is settled before any deletion queues.
            for approval in review.approvals {
                guard let stored = try await mailbox.accountStore?.accounts().first(where: { $0.id == approval.accountID }) else {
                    throw TriageError.accountMismatch
                }
                if !stored.enabledFeatures.contains(AccountFeature.permanentDeletion.rawValue)
                    || !GoogleScopes.isCovered(.permanentDeletion, by: stored.grantedScopes) {
                    guard let grant = try await app.enableFeature(.permanentDeletion, for: approval.accountID),
                          grant.features.contains(.permanentDeletion) else { throw TriageError.permissionRequired }
                }
            }
            guard deletionReview?.id == review.id else { return }
            for approval in review.approvals {
                guard !queuedApprovals.contains(approval.id) else { continue }
                guard let owner = mailbox.account(id: approval.accountID) else { throw TriageError.accountMismatch }
                try await owner.engine.deletePermanently(approved: approval)
                queuedApprovals.insert(approval.id)
            }
            deletionReview = nil
            mailbox.notice = MailboxModel.Notice(message: "Permanent deletion queued for \(review.count) \(review.count == 1 ? "message" : "messages").")
        } catch {
            self.error = "Permanent deletion couldn't be queued for every account. Check each account's permission and try again. Already queued deletions will finish."
        }
    }
}

extension MailboxModel {
    func performDeleteKeyAction() {
        guard MailTriagePreferences.deleteBehavior == .archive else {
            perform(.trash)
            return
        }
        let labelID = selectedLabelID
        let targets = selectedActionTargets
        let removesLabel = targets.contains { accountID, _ in
            account(id: accountID)?.labels.contains { $0.id == labelID && !$0.isSystem } == true
        }
        queueUndoable(removesLabel ? "Remove Label" : "Archive", for: selectedThreadIDs, sound: .archive) { owner, _ in
            guard let target = targets.first(where: { $0.accountID == owner.account.id })?.target else { return nil }
            let userLabel = owner.labels.first { $0.id == labelID && !$0.isSystem }
            if let userLabel { return try await owner.engine.editLabels(target: target, add: [], remove: [userLabel.id]) }
            return try await owner.engine.perform(.archive, target: target)
        }
    }
}
