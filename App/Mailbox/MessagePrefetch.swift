import SwiftUI

/// Keeps a few conversations near the selection ready to read. The ordered
/// rows already reflect the mailbox's account scope, filters and sort order.
struct MessagePrefetchPlan: Equatable {
    let keys: [ThreadKey]
    let accounts: [ObjectIdentifier]

    static func candidates(rows: [MailListRowID], selected: Set<MailListRowID>) -> [ThreadKey] {
        var ordered: [MailListRowID]
        if selected.count == 1, let index = rows.firstIndex(where: selected.contains) {
            // Prefer the next messages, then the previous one. Skip siblings
            // from the selected conversation because its reader loads them.
            let nearby = [index + 1, index + 2, index - 1, index + 3, index - 2]
            ordered = nearby.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        } else {
            ordered = Array(rows.prefix(8))
        }
        var seen = Set(selected.map(\.threadKey))
        ordered = ordered.filter { seen.insert($0.threadKey).inserted }
        return Array(ordered.prefix(4).map(\.threadKey))
    }
}

/// Serializes short plan updates so a disappearing list cannot cancel the
/// replacement list's newer lookahead. Network work belongs to each engine.
@MainActor
final class MessagePrefetchController {
    private var owners: [AccountMailbox] = []
    private var updateTask: Task<Void, Never>?

    func update(keys: [ThreadKey], accounts: [AccountMailbox]) {
        let active = accounts.filter(\.syncEnabled)
        let previousOwners = owners
        owners = active
        let previousUpdate = updateTask
        updateTask = Task {
            await previousUpdate?.value
            for owner in previousOwners where !active.contains(where: { $0 === owner }) {
                await owner.engine.prefetchThreads([])
            }
            for owner in active {
                let ids = keys.filter { $0.accountID == owner.account.id }.map(\.threadID)
                await owner.engine.prefetchThreads(ids)
            }
        }
    }

    func stop() { update(keys: [], accounts: []) }
}

struct MessagePrefetchModifier: ViewModifier {
    let mailbox: MailboxModel
    @State private var controller = MessagePrefetchController()

    private var plan: MessagePrefetchPlan {
        MessagePrefetchPlan(
            keys: MessagePrefetchPlan.candidates(rows: mailbox.listItems.map(\.id), selected: mailbox.selectedListRowIDs),
            accounts: mailbox.accounts.map(ObjectIdentifier.init)
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { MessageWebViewWarmup.start() }
            .onChange(of: plan, initial: true) { _, plan in
                controller.update(keys: plan.keys, accounts: mailbox.accounts)
            }
            .onDisappear { controller.stop() }
    }
}
