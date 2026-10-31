import AppKit
import MailStore
import MessageContent
import Observation
import SwiftUI

struct MailMessageFocus: Equatable {
    let id = UUID()
    let key: ThreadKey
    let messageID: String
}

/// External links select a known account explicitly; they never send mail.
@MainActor @Observable
final class MailURLRouter {
    var error: String?
    var composeDraftID: String?
    var conversationWindowLink: MailLink?
    private(set) var focusRequest: MailMessageFocus?
    @ObservationIgnored var openMainWindow: (() -> Void)?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var pending: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(app: AppModel) { self.app = app }

    func receive(_ url: URL) {
        guard url.absoluteString.utf8.count <= 65_536,
              ["mailto", "tern"].contains(url.scheme?.lowercased() ?? "") else {
            error = "This link isn't a supported mail link."
            return
        }
        guard pending.count < 20 else { error = "Too many mail links are waiting. Open them one at a time."; return }
        pending.append(url)
        openMainWindow?()
        NSApp.activate()
        resume()
    }

    func resume() {
        guard task == nil, app?.mailbox != nil, !pending.isEmpty else { return }
        generation += 1
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { task = nil } }
            while generation == current, !pending.isEmpty, !Task.isCancelled, let app, let mailbox = app.mailbox {
                let url = pending.removeFirst()
                do {
                    if url.scheme?.lowercased() == "mailto" {
                        let request = try MailtoParser.parse(url)
                        guard let id = await mailbox.startMailto(request), app.mailbox === mailbox else { continue }
                        guard generation == current, !Task.isCancelled else { return }
                        composeDraftID = id
                    } else {
                        guard let link = MailLink(url: url) else { throw MailRoutingError.invalidLink }
                        try await open(link, in: app, mailbox: mailbox, generation: current)
                    }
                } catch is CancellationError { return }
                catch { self.error = "Couldn't open this mail link. Check that its account is signed in." }
            }
        }
    }

    func openConversation(_ link: MailLink) {
        guard let url = link.ternURL else { return }
        receive(url)
    }

    func stop() { generation += 1; task?.cancel(); task = nil; conversationWindowLink = nil }

    private func open(_ link: MailLink, in app: AppModel, mailbox: MailboxModel, generation current: Int) async throws {
        guard let owner = mailbox.account(id: link.accountID) else { throw MailRoutingError.accountMissing }
        let needsSource = try await mailbox.cache.read { tx in
            if try tx.thread(id: link.threadID, accountID: link.accountID) == nil { return true }
            if let messageID = link.messageID { return try tx.message(id: messageID, accountID: link.accountID) == nil }
            return false
        }
        if needsSource {
            guard !app.accountsNeedingSignIn.contains(link.accountID), owner.syncEnabled else { throw MailRoutingError.accountMissing }
            try await owner.engine.loadAttachmentSource(link.threadID)
        }
        try Task.checkCancellation()
        guard app.mailbox === mailbox, mailbox.account(id: link.accountID) === owner else { throw CancellationError() }
        let labelID = try await mailbox.cache.read { tx in
            let members = try tx.currentLabels(threadID: link.threadID, accountID: link.accountID)
            let labels: [Set<String>]
            if let messageID = link.messageID {
                guard try tx.message(id: messageID, accountID: link.accountID)?.threadID == link.threadID else {
                    throw MailRoutingError.invalidLink
                }
                labels = [members[messageID] ?? []]
            } else { labels = Array(members.values) }
            if labels.contains(where: { !$0.contains(SystemLabel.trash) && !$0.contains(SystemLabel.spam) }) {
                return SystemLabel.allMail
            }
            if labels.contains(where: { $0.contains(SystemLabel.trash) }) { return SystemLabel.trash }
            return labels.contains(where: { $0.contains(SystemLabel.spam) }) ? SystemLabel.spam : SystemLabel.allMail
        }
        try Task.checkCancellation()
        guard generation == current, app.mailbox === mailbox, mailbox.account(id: link.accountID) === owner else { throw CancellationError() }
        let key = ThreadKey(accountID: link.accountID, threadID: link.threadID)
        app.destination = .mail
        if let profiles = app.accountPreferences, !profiles.visibleAccountIDs.contains(link.accountID) { profiles.selectProfile(nil) }
        mailbox.selectedMailbox = .account(link.accountID, labelID)
        mailbox.selectedThreadIDs = [key]
        if let messageID = link.messageID { focusRequest = MailMessageFocus(key: key, messageID: messageID) }
        // A linked conversation may fall outside the current list's loaded page,
        // or the viewing pane may be hidden. Its window retains the validated scope.
        conversationWindowLink = link
    }

    private enum MailRoutingError: Error { case invalidLink, accountMissing }
}

struct MailURLHandling: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .task {
                app.mailURLs.openMainWindow = { openWindow(id: RootView.sceneID) }
                app.mailURLs.resume()
            }
            .onChange(of: app.phase) { _, _ in app.mailURLs.resume() }
            .onChange(of: app.mailURLs.composeDraftID, initial: true) { _, id in
                guard let id else { return }
                openWindow(id: ComposeWindow.sceneID, value: id)
                app.mailURLs.composeDraftID = nil
            }
            .onChange(of: app.mailURLs.conversationWindowLink, initial: true) { _, link in
                guard let link else { return }
                openWindow(id: ConversationWindow.sceneID, value: link)
                app.mailURLs.conversationWindowLink = nil
            }
            .alert("Couldn't open mail link", isPresented: Bindable(app.mailURLs).error.isPresent()) {
                Button("OK") { app.mailURLs.error = nil }
            } message: { Text(app.mailURLs.error ?? "") }
    }
}
