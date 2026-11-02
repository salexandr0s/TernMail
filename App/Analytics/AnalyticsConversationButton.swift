import MailStore
import MessageContent
import SwiftUI

/// Historical analytics can outlive the reading cache. Load missing metadata
/// before handing a message to the normal conversation window.
struct AnalyticsConversationButton<Label: View>: View {
    let link: MailLink
    let mailbox: MailboxModel
    @ViewBuilder var label: Label
    @Environment(\.openWindow) private var openWindow
    @State private var task: Task<Void, Never>?
    @State private var isOpening = false
    @State private var error: String?
    @State private var request = UUID()

    private struct Identity: Equatable {
        let link: MailLink
        let owner: ObjectIdentifier?
        let lifecycle: Int
        let isVisible: Bool
    }

    private var identity: Identity {
        .init(link: link, owner: mailbox.account(id: link.accountID).map(ObjectIdentifier.init),
              lifecycle: ReaderCacheLifecycle.shared.revision,
              isVisible: mailbox.presentedAccounts.contains { $0.account.id == link.accountID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Button(action: open) {
                HStack(spacing: Tokens.Space.s2) {
                    label
                    if isOpening { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isOpening || !identity.isVisible)
            if let error { Text(error).font(.caption).foregroundStyle(Tokens.Status.error) }
        }
        .onChange(of: identity) { _, _ in cancel() }
        .onDisappear { cancel() }
    }

    private func open() {
        guard !isOpening, identity.isVisible, let owner = mailbox.account(id: link.accountID) else { return }
        let expected = identity
        let target = link
        let cache = mailbox.cache
        let requestID = UUID()
        request = requestID
        isOpening = true
        error = nil
        task = Task {
            defer {
                if request == requestID { isOpening = false; task = nil }
            }
            do {
                let cached = try await cache.read { transaction in
                    try transaction.messages(threadID: target.threadID, accountID: target.accountID)
                        .contains { target.messageID == nil || $0.id == target.messageID }
                }
                try Task.checkCancellation()
                if !cached {
                    guard owner.syncEnabled else {
                        error = "Enable mail sync to download this older email."
                        return
                    }
                    try await owner.engine.assistantLoadSource(link.threadID)
                    let found = try await cache.read { transaction in
                        try transaction.messages(threadID: target.threadID, accountID: target.accountID)
                            .contains { target.messageID == nil || $0.id == target.messageID }
                    }
                    guard !Task.isCancelled, request == requestID, identity == expected else { return }
                    guard found else {
                        error = "This email is no longer available."
                        return
                    }
                }
                guard !Task.isCancelled, request == requestID, identity == expected else { return }
                openWindow(id: ConversationWindow.sceneID, value: link)
            } catch {
                guard !Task.isCancelled, request == requestID, identity == expected else { return }
                self.error = "Couldn't open this email. It may have been removed. Try again."
            }
        }
    }

    private func cancel() {
        request = UUID()
        task?.cancel()
        task = nil
        isOpening = false
        error = nil
    }
}
