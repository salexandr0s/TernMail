import AppKit
import Foundation
import UserNotifications

/// Retains notification clicks until the authenticated calendar workspace is
/// ready. A notification never authorizes a calendar write.
@MainActor
final class CalendarNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CalendarNotificationRouter()
    private weak var model: CalendarModel?
    private var pending: Target?
    /// Shows the main window; the app model sets it.
    var openMainWindow: (@MainActor () -> Void)?

    struct Target: Sendable {
        let accountID: String
        let calendarID: String
        let eventID: String
    }

    func install() { UNUserNotificationCenter.current().delegate = self }

    func bind(_ model: CalendarModel) {
        self.model = model
        if let pending { self.pending = nil; open(pending) }
    }

    private func open(_ target: Target) {
        guard let model else { pending = target; return }
        Task {
            await model.openEvent(accountID: target.accountID, calendarID: target.calendarID, eventID: target.eventID)
            NSApp.activate()
            openMainWindow?()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.identifier.hasPrefix("tern.calendar.") else { return }
        let values = response.notification.request.content.userInfo
        guard let account = values["accountID"] as? String, let calendar = values["calendarID"] as? String,
              let event = values["eventID"] as? String,
              [account, calendar, event].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else { return }
        await open(Target(accountID: account, calendarID: calendar, eventID: event))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix("tern.calendar.") ? [.banner, .sound] : []
    }
}
