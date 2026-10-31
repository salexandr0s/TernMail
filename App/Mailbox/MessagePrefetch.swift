import SwiftUI
import MailStore
import MessageContent

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
    private var prepareTask: Task<Void, Never>?

    func update(keys: [ThreadKey], accounts: [AccountMailbox], mailbox: MailboxModel? = nil) {
        prepareTask?.cancel()
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
        if let mailbox, !keys.isEmpty {
            prepareTask = Task {
                await updateTask?.value
                for key in keys {
                    guard !Task.isCancelled else { return }
                    guard let owner = active.first(where: { $0.account.id == key.accountID }) else { continue }
                    await Self.prepare(key, owner: owner, mailbox: mailbox)
                }
            }
        }
    }

    func stop() { update(keys: [], accounts: []) }

    private static func prepare(_ key: ThreadKey, owner: AccountMailbox, mailbox: MailboxModel) async {
        do {
            try await owner.engine.prepareReadingThread(key.threadID)
            try Task.checkCancellation()
            for try await detail in mailbox.cache.thread(accountID: key.accountID, threadID: key.threadID) {
                guard let detail, !Task.isCancelled, mailbox.account(id: key.accountID) === owner else { return }
                let expanded = ReadingPreferences.initiallyExpanded(ids: detail.messages.map(\.id),
                    unread: Set(detail.messages.filter(\.isUnread).map(\.id)), selected: nil)
                let defaults = UserDefaults.standard
                let blocks = defaults.object(forKey: ReadingPreferences.blockImagesKey) as? Bool ?? true
                let allowed = (try? await mailbox.accountStore?.allowedImageSenders(accountID: key.accountID)) ?? []
                let scale = ReadingPreferences.textScale(defaults.object(forKey: ReadingPreferences.textScaleKey) as? Double ?? 1)
                let messages = defaults.string(forKey: ReadingPreferences.orderKey) == ReadingPreferences.Order.newestFirst.rawValue
                    ? Array(detail.messages.reversed()) : detail.messages
                for message in messages.filter({ expanded.contains($0.id) }).prefix(2) {
                    try Task.checkCancellation()
                    guard let body = message.body else { continue }
                    let messageID = message.id
                    let resources = try await mailbox.cache.read { tx in
                        ReadingResourceSnapshot(resources: try tx.mimeResources(messageID: messageID, accountID: key.accountID))
                    }
                    let sender = EmailAddress.parseList(message.record.sender).first?.address.lowercased() ?? ""
                    let images = !blocks || allowed.contains(sender)
                    let rules = await RemoteContentBlocker.ruleList(allowsRemoteImages: images)
                    let cacheKey = ReaderPreparationKey(accountID: key.accountID, owner: ObjectIdentifier(owner), messageID: messageID,
                        body: ReaderBodyVersion(body), resourcesRevision: resources.revision, allowsImages: images, textOnly: rules == nil, textScale: scale)
                    _ = try await ReaderPreparedCache.shared.prepare(key: cacheKey, body: body, resources: resources.resources, isSpeculative: true)
                }
                return
            }
        } catch { /* Selection retries required content in the foreground lane. */ }
    }
}

struct MessagePrefetchModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let mailbox: MailboxModel
    @State private var controller = MessagePrefetchController()

    private var plan: MessagePrefetchPlan {
        guard app.destination == .mail,
              mailbox.selectedLabelID != AttachmentLibraryModel.mailboxID else {
            return MessagePrefetchPlan(keys: [], accounts: [])
        }
        return MessagePrefetchPlan(
            keys: MessagePrefetchPlan.candidates(rows: mailbox.listItems.map(\.id), selected: mailbox.selectedListRowIDs),
            accounts: mailbox.accounts.map(ObjectIdentifier.init)
        )
    }

    func body(content: Content) -> some View {
        content
            .onAppear { MessageWebViewWarmup.start() }
            .onChange(of: plan, initial: true) { _, plan in
                controller.update(keys: plan.keys, accounts: plan.accounts.isEmpty ? [] : mailbox.accounts, mailbox: mailbox)
            }
            .onDisappear { controller.stop() }
    }
}
