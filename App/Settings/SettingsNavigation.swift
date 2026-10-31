import Observation
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable, Sendable {
    case general, mailActions, notifications
    case connections, accountPreferences, profiles
    case reading, messageList, attachments
    case writing, templates, signatures, suggestions
    case filters, blocked, vacation, calendar
    case assistant, failedChanges, maintenance
    var id: String { rawValue }
    /// The `UserDefaults` key holding the pane the window shows. Other windows
    /// write a raw value here before opening Settings to land on that pane.
    static let storageKey = "settingsDestination"

    /// The stored pane, or General when the value is missing or unknown.
    static func stored(_ rawValue: String) -> SettingsDestination {
        SettingsDestination(rawValue: rawValue) ?? .general
    }

    var title: String {
        switch self {
        case .general: "General"
        case .mailActions: "Mail Actions"
        case .notifications: "Notifications"
        case .connections: "Connections"
        case .accountPreferences: "Preferences"
        case .profiles: "Profiles"
        case .reading: "Reading"
        case .messageList: "Message List"
        case .attachments: "Attachments"
        case .writing: "Writing"
        case .templates: "Templates"
        case .signatures: "Signatures"
        case .suggestions: "Suggestions"
        case .filters: "Filters"
        case .blocked: "Blocked Senders"
        case .vacation: "Vacation Responder"
        case .calendar: "Calendar"
        case .assistant: "Assistant"
        case .failedChanges: "Failed Changes"
        case .maintenance: "Cache & Storage"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .mailActions: "archivebox"
        case .notifications: "bell"
        case .connections: "person.crop.circle"
        case .accountPreferences: "slider.horizontal.3"
        case .profiles: "person.2"
        case .reading: "doc.text"
        case .messageList: "list.bullet.rectangle"
        case .attachments: "paperclip"
        case .writing: "square.and.pencil"
        case .templates: "doc.on.doc"
        case .signatures: "signature"
        case .suggestions: "person.crop.circle.badge.checkmark"
        case .filters: "line.3.horizontal.decrease.circle"
        case .blocked: "person.crop.circle.badge.xmark"
        case .vacation: "sun.max"
        case .calendar: "calendar"
        case .assistant: "sparkles"
        case .failedChanges: "exclamationmark.arrow.triangle.2.circlepath"
        case .maintenance: "externaldrive"
        }
    }

    /// A line above the pane for what its headers don't say. `nil` where it
    /// would only list the pane's own sections.
    var subtitle: String? {
        switch self {
        case .connections: "Add Google accounts and choose what each one shares with Tern."
        case .profiles: "Group your accounts and set notification hours."
        case .templates: "Save reusable messages to insert while writing."
        case .signatures: "Signatures on this Mac stay in Tern. Gmail signatures are saved to your Google account."
        case .assistant: "Ask about your mail, summarize threads, and prepare replies."
        default: nil
        }
    }

    var tint: Color {
        switch self {
        case .general, .mailActions, .maintenance: .gray
        case .notifications: .red
        case .connections, .accountPreferences, .profiles, .assistant: .indigo
        case .reading, .messageList: .blue
        case .attachments: .cyan
        case .writing, .templates, .signatures, .suggestions: .purple
        case .filters, .blocked, .failedChanges: .orange
        case .vacation: .teal
        case .calendar: .mint
        }
    }

    private var searchTerms: String {
        switch self {
        case .general: "default mail app email links undo send sending keyboard shortcuts"
        case .mailActions: "archive trash delete key snooze triage sounds"
        case .notifications: "alerts notify new mail sound badge dock menu bar permission"
        case .connections: "google login sign in sync accounts permissions calendar contacts deletion"
        case .accountPreferences: "preferences name nickname color sidebar order profile sync pause"
        case .profiles: "work personal groups focus notification schedule hours"
        case .reading: "appearance remote images privacy tracking company business bank logos sender photos website icons dark mode conversation order mark read delay text size"
        case .messageList: "inbox appearance density compact comfortable preview swipe sidebar mailbox count badges importance"
        case .attachments: "download open files preview cache"
        case .writing: "font reply format markdown quote recipients sender send from default account"
        case .templates: "reusable replies canned responses"
        case .signatures: "local gmail new messages replies separator send as identity footer"
        case .suggestions: "recipients autocomplete hide hidden addresses"
        case .filters: "gmail rules incoming forwarding labels delete archive"
        case .blocked: "gmail spam block email address"
        case .vacation: "automatic reply away out of office autoresponder dates"
        case .calendar: "calendars events subscriptions sharing scheduling availability"
        case .assistant: "chatgpt openai ai model writing style summaries privacy access"
        case .failedChanges: "retry errors pending queue discard"
        case .maintenance: "disk space storage cache attachments budget reset trim database"
        }
    }

    func matches(_ query: String) -> Bool {
        let searchable = "\(title) \(subtitle ?? "") \(searchTerms)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchable.localizedStandardContains(String($0))
        }
    }
}

struct SettingsNavigationSection: Identifiable, Sendable {
    /// Empty for the first group, which shows no header, as in System Settings,
    /// so General isn't named twice.
    let title: String
    let destinations: [SettingsDestination]
    var id: String { title }
    static let sections = [
        SettingsNavigationSection(title: "", destinations: [.general, .mailActions, .notifications]),
        SettingsNavigationSection(title: "Accounts", destinations: [.connections, .accountPreferences, .profiles]),
        SettingsNavigationSection(title: "Mail", destinations: [.reading, .messageList, .attachments]),
        SettingsNavigationSection(title: "Composing", destinations: [.writing, .templates, .signatures, .suggestions]),
        SettingsNavigationSection(title: "Google", destinations: [.filters, .blocked, .vacation, .calendar]),
        SettingsNavigationSection(title: "Tools", destinations: [.assistant, .failedChanges, .maintenance])
    ]

    static func section(containing destination: SettingsDestination) -> SettingsNavigationSection? {
        sections.first { $0.destinations.contains(destination) }
    }
}

/// A pane whose edits only Save sends registers them here, so leaving the pane
/// or closing the window asks first.
@MainActor @Observable
final class SettingsUnsavedChanges {
    /// What the edits belong to, in sentence case for the confirmation. `nil` when nothing waits.
    private(set) var subject: String?

    func set(_ subject: String) { self.subject = subject }
    func clear() { subject = nil }
}
