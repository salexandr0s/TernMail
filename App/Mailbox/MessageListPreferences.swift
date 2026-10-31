import Foundation
import Observation

enum MailListDensity: String, CaseIterable, Identifiable {
    case standard, compact
    var id: String { rawValue }
    var title: String { self == .standard ? "Default" : "Compact" }
}

enum MailQuickFilter: String, CaseIterable, Identifiable {
    case unread, starred, attachments, important, addressedToMe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unread: "Unread"
        case .starred: "Starred"
        case .attachments: "Has Attachments"
        case .important: "Important"
        case .addressedToMe: "Addressed to Me"
        }
    }
    var symbol: String {
        switch self {
        case .unread: "envelope.badge"
        case .starred: "star"
        case .attachments: "paperclip"
        case .important: "exclamationmark"
        case .addressedToMe: "person"
        }
    }
}

enum MailNextSelection: String, CaseIterable, Identifiable {
    case below, above, none
    var id: String { rawValue }
    var title: String { switch self { case .below: "Below"; case .above: "Above"; case .none: "None" } }
}

enum MailSwipeAction: String, CaseIterable, Identifiable {
    case archive, trash, read, star, snooze, move, label, spam, none
    var id: String { rawValue }
    /// The name in Settings, matching the menu command.
    var title: String {
        switch self {
        case .archive: "Archive"
        case .trash: "Move to Trash"
        case .read: "Mark as Read or Unread"
        case .star: "Star or Remove Star"
        case .snooze: "Snooze"
        case .move: "Move to"
        case .label: "Edit Labels"
        case .spam: "Report Spam"
        case .none: "None"
        }
    }

    /// The short name on a swipe button, for the row's current state.
    func buttonTitle(isUnread: Bool, isStarred: Bool) -> String {
        switch self {
        case .trash: "Trash"
        case .read: isUnread ? "Read" : "Unread"
        case .star: isStarred ? "Unstar" : "Star"
        case .move: "Move"
        case .label: "Label"
        case .spam: "Spam"
        case .archive, .snooze, .none: title
        }
    }
    var symbol: String {
        switch self {
        case .archive: "archivebox"
        case .trash: "trash"
        case .read: "envelope.open"
        case .star: "star"
        case .snooze: "clock"
        case .move: "folder"
        case .label: "tag"
        case .spam: "xmark.bin"
        case .none: "minus"
        }
    }
}

@MainActor @Observable
final class MessageListPreferences {
    static let shared = MessageListPreferences()
    var density: MailListDensity { didSet { defaults.set(density.rawValue, forKey: "mailListDensity") } }
    var conversations: Bool { didSet { defaults.set(conversations, forKey: "mailConversations") } }
    var showsAccountBadges: Bool { didSet { defaults.set(showsAccountBadges, forKey: "mailShowsAccountBadges") } }
    var showsImportance: Bool { didSet { defaults.set(showsImportance, forKey: "mailShowsImportance") } }
    var showsQuickFilters: Bool { didSet { defaults.set(showsQuickFilters, forKey: "mailShowsQuickFilters") } }
    var nextSelection: MailNextSelection { didSet { defaults.set(nextSelection.rawValue, forKey: "mailNextSelection") } }
    var leadingFirst: MailSwipeAction { didSet { defaults.set(leadingFirst.rawValue, forKey: "mailLeadingFirst") } }
    var leadingSecond: MailSwipeAction { didSet { defaults.set(leadingSecond.rawValue, forKey: "mailLeadingSecond") } }
    var trailingFirst: MailSwipeAction { didSet { defaults.set(trailingFirst.rawValue, forKey: "mailTrailingFirst") } }
    var trailingSecond: MailSwipeAction { didSet { defaults.set(trailingSecond.rawValue, forKey: "mailTrailingSecond") } }
    var showsMore: Bool { didSet { defaults.set(showsMore, forKey: "mailShowsMore") } }
    var starredTotal: Bool { didSet { defaults.set(starredTotal, forKey: "mailStarredTotal") } }
    var draftsTotal: Bool { didSet { defaults.set(draftsTotal, forKey: "mailDraftsTotal") } }
    var spamUnread: Bool { didSet { defaults.set(spamUnread, forKey: "mailSpamUnread") } }
    var filters: Set<MailQuickFilter> = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        density = MailListDensity(rawValue: defaults.string(forKey: "mailListDensity") ?? "") ?? .standard
        conversations = defaults.object(forKey: "mailConversations") as? Bool ?? true
        showsAccountBadges = defaults.object(forKey: "mailShowsAccountBadges") as? Bool ?? true
        showsImportance = defaults.object(forKey: "mailShowsImportance") as? Bool ?? false
        showsQuickFilters = defaults.object(forKey: "mailShowsQuickFilters") as? Bool ?? true
        nextSelection = MailNextSelection(rawValue: defaults.string(forKey: "mailNextSelection") ?? "") ?? .below
        leadingFirst = MailSwipeAction(rawValue: defaults.string(forKey: "mailLeadingFirst") ?? "") ?? .read
        leadingSecond = MailSwipeAction(rawValue: defaults.string(forKey: "mailLeadingSecond") ?? "") ?? .star
        trailingFirst = MailSwipeAction(rawValue: defaults.string(forKey: "mailTrailingFirst") ?? "") ?? .archive
        trailingSecond = MailSwipeAction(rawValue: defaults.string(forKey: "mailTrailingSecond") ?? "") ?? .trash
        showsMore = defaults.object(forKey: "mailShowsMore") as? Bool ?? true
        starredTotal = defaults.object(forKey: "mailStarredTotal") as? Bool ?? true
        draftsTotal = defaults.object(forKey: "mailDraftsTotal") as? Bool ?? true
        spamUnread = defaults.object(forKey: "mailSpamUnread") as? Bool ?? true
    }
}
