import AppKit
import MailStore
import MessageContent
import Observation
import SwiftUI
import SyncEngine

struct UnsubscribeWindow: View {
    static let sceneID = "unsubscribe"
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let mailbox = app.mailbox {
                UnsubscribeWorkspace(app: app, mailbox: mailbox)
                    .id(ObjectIdentifier(mailbox))
            } else {
                ContentUnavailableView("Sign in to manage newsletters", systemImage: "envelope.open",
                    description: Text("Connect a mail account in Tern to find your subscriptions."))
            }
        }
        .frame(minWidth: Tokens.Layout.windowMinWidth, minHeight: Tokens.Layout.windowMinHeight)
        .navigationTitle("Unsubscribe")
        .focusedSceneValue(\.isMainWindow, false)
    }
}

private struct UnsubscribeWorkspace: View {
    let app: AppModel
    let mailbox: MailboxModel
    @Environment(\.openWindow) private var openWindow
    @State private var model: UnsubscribeModel
    @State private var routes: UnsubscribeRoutes

    init(app: AppModel, mailbox: MailboxModel) {
        self.app = app; self.mailbox = mailbox
        let routes = UnsubscribeRoutes()
        _routes = State(initialValue: routes)
        _model = State(initialValue: UnsubscribeBindings.make(app: app, mailbox: mailbox, routes: routes))
    }

    private struct Scope: Hashable {
        let owners: [ObjectIdentifier]
        let unavailable: Set<String>
        let names: [String]
    }

    private var scope: Scope {
        Scope(owners: mailbox.accounts.map(ObjectIdentifier.init), unavailable: app.accountsNeedingSignIn,
            names: mailbox.accounts.map { mailbox.accountTitle($0.account) })
    }

    var body: some View {
        UnsubscribeView(model: model)
            .task(id: scope) {
                model.configure(accounts: mailbox.accounts.map {
                    UnsubscribeAccount(id: $0.account.id, title: mailbox.accountTitle($0.account), email: $0.account.email)
                }, unavailable: app.accountsNeedingSignIn)
                await model.load()
            }
            .onDisappear { model.stop() }
            .onChange(of: routes.composeID) { _, id in
                guard let id else { return }; routes.composeID = nil
                openWindow(id: ComposeWindow.sceneID, value: id)
            }
            .onChange(of: routes.message) { _, link in
                guard let link else { return }; routes.message = nil
                openWindow(id: ConversationWindow.sceneID, value: link)
            }
    }
}

@MainActor @Observable final class UnsubscribeRoutes {
    var composeID: String?
    var message: MailLink?
}

@MainActor enum UnsubscribeBindings {
    static func make(app: AppModel, mailbox: MailboxModel, routes: UnsubscribeRoutes) -> UnsubscribeModel {
        let available: (String) -> Bool = { [weak app, weak mailbox] id in
            guard let app, let mailbox else { return false }
            return app.mailbox === mailbox && mailbox.account(id: id) != nil && !app.accountsNeedingSignIn.contains(id)
        }
        return UnsubscribeModel(client: { [weak mailbox] id in
            guard let engine = mailbox?.account(id: id)?.engine else { return nil }
            return UnsubscribeClient(
                snapshot: { try await engine.newsletterSnapshot() },
                scan: { try await engine.loadNewsletterPage(restart: $0) },
                request: { try await engine.requestNewsletterUnsubscribe(id: $0) },
                markOpened: { _ = try await engine.markNewsletterOpened(id: $0) },
                complete: { _ = try await engine.confirmNewsletterUnsubscribed(id: $0) },
                reset: { _ = try await engine.resetNewsletterStatus(id: $0) })
        }, available: available, openManual: { [weak mailbox] item in
            guard available(item.accountID), let mailbox else { throw NewsletterActionError.unavailable }
            if let url = item.unsubscribeURL,
               let safe = NewsletterURLPolicy.webURL(url.absoluteString) {
                guard NSWorkspace.shared.open(safe) else { throw NewsletterActionError.unavailable }
            } else if let url = item.mailtoURL,
                      let safe = NewsletterURLPolicy.mailtoURL(url.absoluteString) {
                let request = try MailtoParser.parse(safe)
                guard let draftID = await mailbox.startMailto(request, accountID: item.accountID),
                      available(item.accountID) else { throw NewsletterActionError.unavailable }
                routes.composeID = draftID
            } else { throw NewsletterActionError.unavailable }
        }, openMessage: { item in
            guard available(item.accountID) else { return }
            routes.message = MailLink(accountID: item.accountID, threadID: item.latestThreadID, messageID: item.latestMessageID)
        })
    }
}
