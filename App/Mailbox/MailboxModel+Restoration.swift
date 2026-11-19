import Foundation
import MailStore

extension MailboxID {
    /// The mailbox as text the main window keeps in its scene storage. A
    /// profile's scoped mailbox has none, because only that profile shows it.
    var restorationValue: String? {
        let parts: [String]
        switch self {
        case .combined(let id): parts = ["combined", id]
        case .account(let accountID, let id): parts = ["account", accountID, id]
        case .scoped: return nil
        }
        guard let data = try? JSONEncoder().encode(parts) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    init?(restorationValue: String) {
        guard let parts = try? JSONDecoder().decode([String].self, from: Data(restorationValue.utf8)) else { return nil }
        switch (parts.first, parts.count) {
        case ("combined", 2): self = .combined(parts[1])
        case ("account", 3): self = .account(parts[1], parts[2])
        default: return nil
        }
    }
}

extension MailboxModel {
    /// Reopens what the main window showed before the app quit: the mailbox,
    /// if it still exists, and the attachment library if it was in front.
    /// Neither comes back once something has been chosen since launch, such
    /// as a mailbox by a link. The conversation isn't reopened, so a relaunch
    /// never marks mail read.
    func restoreMailbox(_ box: MailboxID?, showingAttachmentLibrary: Bool = false) {
        guard isShowingLaunchInbox, !showsAttachmentLibrary else { return }
        if let box, box != selectedMailbox, canRestore(box) { selectedMailbox = box }
        if showingAttachmentLibrary { showAttachmentLibrary() }
    }

    private var isShowingLaunchInbox: Bool {
        switch selectedMailbox {
        case .combined(SystemLabel.inbox)?, .account(_, SystemLabel.inbox)?: true
        default: false
        }
    }

    private func canRestore(_ box: MailboxID) -> Bool {
        let fixedIDs = Set(SystemMailbox.all.map(\.id) + [Self.outboxID])
        switch box {
        case .combined(let id):
            return presentedAccounts.count > 1 && fixedIDs.contains(id)
        case .account(let accountID, let id):
            guard let owner = presentedAccounts.first(where: { $0.account.id == accountID }) else { return false }
            if fixedIDs.contains(id) { return true }
            // Saved searches load later and fall back to the Inbox, so they
            // aren't reopened. Labels may not have loaded either: until they
            // have, any label passes, and `labelsChanged` leaves a deleted one.
            guard !id.hasPrefix(MailNavigationModel.searchPrefix) else { return false }
            return owner.labels.isEmpty || owner.labels.contains { $0.id == id }
        case .scoped:
            return false
        }
    }
}
