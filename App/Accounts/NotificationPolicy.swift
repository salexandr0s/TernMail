import CryptoKit
import Foundation
import MailStore
import SyncEngine

enum MailNotificationAction: String, CaseIterable, Sendable {
    case archive, trash, markRead, star
    static let storageKey = "tern.mailNotificationAction"
    var title: String {
        switch self {
        case .archive: "Archive"
        case .trash: "Move to Trash"
        case .markRead: "Mark as Read"
        case .star: "Star"
        }
    }
}

struct MailNotificationDelivery: Sendable, Equatable {
    var id: String
    var groupID: String
    var accountID: String
    var threadID: String
    var messageID: String
    var sender: String
    var subject: String
    var snippet: String
    var profileID: String?
    var action: MailNotificationAction
    var playsSound: Bool
}

enum NotificationPolicy {
    static let soundKey = "tern.mailNotificationSound"
    static let menuBarCountKey = "tern.mailUnreadMenuBar"

    static func allows(_ message: MailNotificationMessage, preferences: AccountMailPreferences,
                       profile: MailProfile?, activeProfileID: String?, at date: Date,
                       calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard message.record.accountID == preferences.accountID, preferences.syncEnabled,
              activeProfileID == nil || preferences.profileID == activeProfileID,
              profile?.notificationSchedule.allowsNotifications(at: date, calendar: calendar) ?? true,
              message.labelIDs.isDisjoint(with: ["SPAM", "TRASH", "DRAFT", "SENT"]) else { return false }
        switch preferences.notificationRule {
        case .off: return false
        case .allMail: return true
        case .inbox: return message.labelIDs.contains("INBOX")
        case .inboxWithoutCategories:
            return message.labelIDs.contains("INBOX") && message.labelIDs.isDisjoint(with: ["CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS"])
        }
    }

    static func identifier(accountID: String, value: String, kind: String) -> String {
        let data = Data((accountID + "\u{0}" + value).utf8)
        return "tern.mail." + kind + "." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
