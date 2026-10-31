import AppKit
import Foundation
import UserNotifications

/// The actions on new-mail notifications. The categories register once at
/// launch, and each delivery names the one that leads with the user's choice.
enum MailNotificationCategories {
    static let actionPrefix = "tern.mail.action."
    /// Reply opens a reply window, so the signature, quoted text and Undo Send apply.
    static let replyIdentifier = actionPrefix + "reply"

    static func identifier(for primary: MailNotificationAction) -> String { "tern.mail." + primary.rawValue }

    /// The chosen action first, then the other triage actions, then Reply.
    static func actions(leadingWith primary: MailNotificationAction) -> [UNNotificationAction] {
        let triage = [primary] + MailNotificationAction.allCases.filter { $0 != primary }
        return triage.map { action in
            UNNotificationAction(identifier: actionPrefix + action.rawValue, title: action.title,
                                 options: action == .trash ? [.destructive] : [])
        } + [UNNotificationAction(identifier: replyIdentifier, title: "Reply", options: [.foreground])]
    }

    static var all: Set<UNNotificationCategory> {
        Set(MailNotificationAction.allCases.map { primary in
            UNNotificationCategory(identifier: identifier(for: primary), actions: actions(leadingWith: primary),
                                   intentIdentifiers: [], options: [])
        })
    }

    /// What a click on the notification, or on one of its actions, asks for.
    static func response(for actionIdentifier: String) -> MailNotificationRouter.Response? {
        if actionIdentifier == UNNotificationDefaultActionIdentifier { return .open }
        guard actionIdentifier.hasPrefix(actionPrefix) else { return nil }
        if actionIdentifier == replyIdentifier { return .reply }
        return MailNotificationAction(rawValue: String(actionIdentifier.dropFirst(actionPrefix.count))).map { .perform($0) }
    }
}

/// One system delegate routes both mail and Calendar notifications.
@MainActor final class MailNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MailNotificationRouter()
    enum Response: Sendable, Equatable {
        case open
        case reply
        case perform(MailNotificationAction)
    }
    struct Target: Sendable, Equatable {
        var accountID: String
        var threadID: String
        var messageID: String
        var response: Response
    }
    private var pending: [Target] = []
    private var handler: ((Target) async -> Void)?
    /// Set by the app model: whether a window shows the conversation.
    var isOnScreen: ((ThreadKey) -> Bool)?

    func install() {
        UNUserNotificationCenter.current().delegate = self
        Task {
            // Keep other categories and replace mail ones from an earlier launch.
            let center = UNUserNotificationCenter.current()
            let others = await center.notificationCategories().filter { !$0.identifier.hasPrefix("tern.mail.") }
            center.setNotificationCategories(others.union(MailNotificationCategories.all))
        }
    }
    func unbind() { handler = nil }
    func bind(_ handler: @escaping (Target) async -> Void) {
        self.handler = handler
        let targets = pending; pending = []
        Task { [weak self] in for target in targets { await self?.route(target) } }
    }
    private func route(_ target: Target) async {
        guard let handler else { pending.append(target); return }
        await handler(target)
    }

    /// Tern is frontmost and a window shows the conversation, so new mail in it needs no alert.
    func isShowing(accountID: String, threadID: String) -> Bool {
        NSApp.isActive && isOnScreen?(ThreadKey(accountID: accountID, threadID: threadID)) == true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.identifier.hasPrefix("tern.calendar.") {
            await CalendarNotificationRouter.shared.userNotificationCenter(center, didReceive: response)
            return
        }
        guard response.notification.request.identifier.hasPrefix("tern.mail.") else { return }
        let values = response.notification.request.content.userInfo
        guard let account = values["mailAccountID"] as? String, let thread = values["mailThreadID"] as? String,
              let message = values["mailMessageID"] as? String,
              [account, thread, message].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }),
              let answer = MailNotificationCategories.response(for: response.actionIdentifier) else { return }
        await route(Target(accountID: account, threadID: thread, messageID: message, response: answer))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let request = notification.request
        if request.identifier.hasPrefix("tern.calendar.") {
            return await CalendarNotificationRouter.shared.userNotificationCenter(center, willPresent: notification)
        }
        guard request.identifier.hasPrefix("tern.mail.") else { return [] }
        let account = request.content.userInfo["mailAccountID"] as? String ?? ""
        let thread = request.content.userInfo["mailThreadID"] as? String ?? ""
        return await isShowing(accountID: account, threadID: thread) ? [] : [.banner, .list, .sound]
    }
}
