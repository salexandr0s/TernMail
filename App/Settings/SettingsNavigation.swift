import Observation
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable, Sendable {
    case general, mailActions, notifications
    case connections, accountPreferences, profiles
    case reading, messageList, attachments
    case writing, templates, localSignatures, suggestions
    case signatures, filters, blocked, vacation, calendar
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
        case .localSignatures: "Signatures"
        case .suggestions: "Suggestions"
        case .signatures: "Gmail Signatures"
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
        case .localSignatures: "pencil.line"
        case .suggestions: "person.crop.circle.badge.checkmark"
        case .signatures: "signature"
        case .filters: "line.3.horizontal.decrease.circle"
        case .blocked: "person.crop.circle.badge.xmark"
        case .vacation: "sun.max"
        case .calendar: "calendar"
        case .assistant: "sparkles"
        case .failedChanges: "exclamationmark.arrow.triangle.2.circlepath"
        case .maintenance: "externaldrive"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Default email app, sending and keyboard shortcuts."
        case .mailActions: "Choose what the Delete key does and when Tern plays sounds."
        case .notifications: "Choose which mail gets your attention."
        case .connections: "Add Google accounts and choose what each one shares with Tern."
        case .accountPreferences: "Name, color, profile, sync and sidebar order for each account."
        case .profiles: "Group your accounts and set notification hours."
        case .reading: "Adjust message appearance and reading behavior."
        case .messageList: "Choose how your inbox looks and responds."
        case .attachments: "Choose how Tern downloads and opens attachments."
        case .writing: "Set the default sender, font and reply behavior."
        case .templates: "Save reusable messages to insert while writing."
        case .localSignatures: "Signatures stored on this Mac and where Tern adds them."
        case .suggestions: "Hide addresses from recipient suggestions."
        case .signatures: "Manage the signatures saved to your Gmail accounts."
        case .filters: "Organize incoming mail with Gmail rules."
        case .blocked: "Manage the senders you've blocked in Gmail."
        case .vacation: "Let people know when you're away."
        case .calendar: "Choose the calendars Tern shows and how it schedules events."
        case .assistant: "Ask about your mail, summarize threads, and prepare replies."
        case .failedChanges: "Review mail changes that couldn't be completed."
        case .maintenance: "Manage the mail and attachments stored on this Mac."
        }
    }

    var tint: Color {
        switch self {
        case .general, .mailActions, .maintenance: .gray
        case .notifications: .red
        case .connections, .accountPreferences, .profiles, .assistant: .indigo
        case .reading, .messageList: .blue
        case .attachments: .cyan
        case .writing, .templates, .localSignatures, .suggestions, .signatures: .purple
        case .filters, .blocked, .failedChanges: .orange
        case .vacation: .teal
        case .calendar: .mint
        }
    }

    private var searchTerms: String {
        switch self {
        case .general: "default mail app email links undo send keyboard shortcuts"
        case .mailActions: "archive trash delete key snooze triage sounds"
        case .notifications: "alerts sound badge dock menu bar permission"
        case .connections: "google login sign in sync accounts permissions calendar contacts deletion"
        case .accountPreferences: "nickname color order profile sync pause"
        case .profiles: "work personal groups focus notification schedule hours"
        case .reading: "remote images privacy tracking company business bank logos sender photos website icons dark mode conversation order mark read delay text size"
        case .messageList: "density compact comfortable preview swipe sidebar mailbox count badges importance"
        case .attachments: "download files preview cache"
        case .writing: "font reply format markdown quote recipients send from default account"
        case .templates: "reusable replies canned responses"
        case .localSignatures: "local signatures new messages replies separator"
        case .suggestions: "recipients autocomplete hidden addresses"
        case .signatures: "gmail send as identity footer"
        case .filters: "rules forwarding labels delete archive"
        case .blocked: "spam block email address"
        case .vacation: "automatic reply out of office autoresponder dates"
        case .calendar: "calendars subscriptions sharing scheduling availability"
        case .assistant: "chatgpt openai ai model writing style summaries privacy access"
        case .failedChanges: "retry errors pending queue discard"
        case .maintenance: "disk space storage cache budget reset trim database"
        }
    }

    func matches(_ query: String) -> Bool {
        let searchable = "\(title) \(subtitle) \(searchTerms)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            searchable.localizedStandardContains(String($0))
        }
    }
}

struct SettingsNavigationSection: Identifiable, Sendable {
    let title: String
    let destinations: [SettingsDestination]
    var id: String { title }
    static let sections = [
        SettingsNavigationSection(title: "General", destinations: [.general, .mailActions, .notifications]),
        SettingsNavigationSection(title: "Accounts", destinations: [.connections, .accountPreferences, .profiles]),
        SettingsNavigationSection(title: "Mail", destinations: [.reading, .messageList, .attachments]),
        SettingsNavigationSection(title: "Composing", destinations: [.writing, .templates, .localSignatures, .suggestions]),
        SettingsNavigationSection(title: "Google", destinations: [.signatures, .filters, .blocked, .vacation, .calendar]),
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
