import Foundation
import MessageContent

public enum MailPreferencesError: Error, Sendable, Equatable {
    case accountMissing, invalidRecord, missingReference
}

public enum InboxCategory: String, Codable, Sendable, CaseIterable {
    case social, promotions, updates, forums

    public var labelID: String { "CATEGORY_" + rawValue.uppercased() }
}

public enum MailNotificationRule: String, Codable, Sendable, CaseIterable {
    case off, inbox, inboxWithoutCategories, allMail
}

public struct AccountMailPreferences: Codable, Sendable, Equatable, Identifiable {
    public var accountID: String
    public var nickname: String?
    public var sortOrder: Int
    public var syncEnabled: Bool
    public var profileID: String?
    public var inboxCategories: Set<InboxCategory>
    public var notificationRule: MailNotificationRule
    public var id: String { accountID }

    public init(accountID: String, nickname: String? = nil, sortOrder: Int = 0, syncEnabled: Bool = true,
                profileID: String? = nil, inboxCategories: Set<InboxCategory> = [], notificationRule: MailNotificationRule = .off) {
        self.accountID = accountID; self.nickname = nickname; self.sortOrder = sortOrder; self.syncEnabled = syncEnabled
        self.profileID = profileID; self.inboxCategories = inboxCategories; self.notificationRule = notificationRule
    }
}

public enum ISOWeekday: Int, Codable, Sendable, CaseIterable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
}

public struct DailyTimeRange: Codable, Sendable, Equatable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) { self.startMinute = startMinute; self.endMinute = endMinute }
    public var isValid: Bool { startMinute >= 0 && startMinute < endMinute && endMinute <= 1440 }
}

public enum ProfileNotificationSchedule: Codable, Sendable, Equatable {
    case unrestricted, off
    case everyDay([DailyTimeRange])
    case weekdays([DailyTimeRange])
    case custom([ISOWeekday: [DailyTimeRange]])

    public var isValid: Bool {
        switch self {
        case .unrestricted, .off: true
        case .everyDay(let ranges), .weekdays(let ranges): ranges.allSatisfy(\.isValid)
        case .custom(let days): days.values.allSatisfy { $0.allSatisfy(\.isValid) }
        }
    }

    public func allowsNotifications(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute,
              let isoDay = ISOWeekday(rawValue: ((weekday + 5) % 7) + 1), isValid else { return false }
        let minuteOfDay = hour * 60 + minute
        let ranges: [DailyTimeRange]
        switch self {
        case .unrestricted: return true
        case .off: return false
        case .everyDay(let dayRanges): ranges = dayRanges
        case .weekdays(let dayRanges): ranges = isoDay.rawValue <= 5 ? dayRanges : []
        case .custom(let days): ranges = days[isoDay] ?? []
        }
        return ranges.contains { $0.startMinute <= minuteOfDay && minuteOfDay < $0.endMinute }
    }
}

public struct MailProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var colorIndex: Int
    public var symbol: String
    public var sortOrder: Int
    public var notificationSchedule: ProfileNotificationSchedule

    public init(id: String = UUID().uuidString, name: String, colorIndex: Int = 0, symbol: String = "person.2",
                sortOrder: Int = 0, notificationSchedule: ProfileNotificationSchedule = .unrestricted) {
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.symbol = symbol
        self.sortOrder = sortOrder; self.notificationSchedule = notificationSchedule
    }
}

public enum MailSearchScope: Codable, Sendable, Equatable, Hashable {
    case allAccounts, accounts([String])
}

public struct SavedMailSearch: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var query: String
    public var scope: MailSearchScope
    public var sortOrder: Int

    public init(id: String = UUID().uuidString, name: String, query: String, scope: MailSearchScope = .allAccounts, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.query = query; self.scope = scope; self.sortOrder = sortOrder
    }
}

public enum MailFavoriteTarget: Codable, Sendable, Equatable, Hashable {
    case mailbox(labelID: String, scope: MailSearchScope)
    case label(accountID: String, labelID: String)
    case savedSearch(id: String)
}

public struct MailFavorite: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var target: MailFavoriteTarget
    public var sortOrder: Int

    public init(id: String = UUID().uuidString, target: MailFavoriteTarget, sortOrder: Int = 0) {
        self.id = id; self.target = target; self.sortOrder = sortOrder
    }

    public static var defaults: [MailFavorite] {
        [SystemLabel.inbox, SystemLabel.starred, "TERN_SNOOZED", SystemLabel.sent, SystemLabel.draft,
         SystemLabel.allMail, SystemLabel.spam, SystemLabel.trash].enumerated().map {
            MailFavorite(id: "default:" + $0.element, target: .mailbox(labelID: $0.element, scope: .allAccounts), sortOrder: $0.offset)
        }
    }
}

public struct ComposeTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var document: ComposeDocument
    public var sortOrder: Int

    public init(id: String = UUID().uuidString, name: String, document: ComposeDocument, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.document = document; self.sortOrder = sortOrder
    }
}

public struct LocalSignature: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var document: ComposeDocument
    public var sortOrder: Int

    public init(id: String = UUID().uuidString, name: String, document: ComposeDocument, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.document = document; self.sortOrder = sortOrder
    }
}

public enum SignatureSelection: Codable, Sendable, Equatable, Hashable {
    case none, gmail, local(id: String)
}

public struct SignatureAssignment: Codable, Sendable, Equatable {
    public var accountID: String
    public var address: String
    public var newMessages: SignatureSelection
    public var replies: SignatureSelection
    public var placeAboveQuote: Bool
    public var includeSeparator: Bool

    public init(accountID: String, address: String = "", newMessages: SignatureSelection = .gmail,
                replies: SignatureSelection = .none, placeAboveQuote: Bool = true, includeSeparator: Bool = true) {
        self.accountID = accountID; self.address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.newMessages = newMessages; self.replies = replies; self.placeAboveQuote = placeAboveQuote
        self.includeSeparator = includeSeparator
    }
}

public struct MailAlertWatermark: Codable, Sendable, Equatable {
    public var accountID: String
    public var historyID: Int64
    public var baselineAt: Date

    public init(accountID: String, historyID: Int64, baselineAt: Date) {
        self.accountID = accountID; self.historyID = historyID; self.baselineAt = baselineAt
    }
}
