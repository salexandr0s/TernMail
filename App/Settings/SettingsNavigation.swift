import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable, Sendable {
    case general, accounts, profiles, notifications, reading, messageList, composing
    case signatures, filters, blocked, vacation, attachments, failedChanges, maintenance, assistant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .accounts: "Accounts"
        case .profiles: "Profiles"
        case .notifications: "Notifications"
        case .reading: "Reading"
        case .messageList: "Message List"
        case .composing: "Composing"
        case .signatures: "Gmail Signatures"
        case .filters: "Filters"
        case .blocked: "Blocked Senders"
        case .vacation: "Vacation Responder"
        case .attachments: "Attachments"
        case .failedChanges: "Failed Changes"
        case .maintenance: "Cache & Storage"
        case .assistant: "Assistant"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .accounts: "person.crop.circle"
        case .profiles: "person.2"
        case .notifications: "bell"
        case .reading: "doc.text"
        case .messageList: "list.bullet.rectangle"
        case .composing: "square.and.pencil"
        case .signatures: "signature"
        case .filters: "line.3.horizontal.decrease.circle"
        case .blocked: "person.crop.circle.badge.xmark"
        case .vacation: "sun.max"
        case .attachments: "paperclip"
        case .failedChanges: "exclamationmark.arrow.triangle.2.circlepath"
        case .maintenance: "externaldrive"
        case .assistant: "sparkles"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Default email app, sending, and keyboard shortcuts."
        case .accounts: "Manage your Google accounts and connected services."
        case .profiles: "Group your accounts and set notification hours."
        case .notifications: "Choose which mail gets your attention."
        case .reading: "Adjust message appearance and reading behavior."
        case .messageList: "Choose how your inbox looks and responds."
        case .composing: "Set up your writing defaults and reusable replies."
        case .signatures: "Manage the signatures saved to your Gmail accounts."
        case .filters: "Organize incoming mail with Gmail rules."
        case .blocked: "Manage the senders you've blocked in Gmail."
        case .vacation: "Let people know when you're away."
        case .attachments: "Choose how Tern downloads and opens attachments."
        case .assistant: "Ask about your mail, summarize threads, and prepare replies."
        case .failedChanges: "Review mail changes that couldn't be completed."
        case .maintenance: "Manage the mail and attachments stored on this Mac."
        }
    }

    var tint: Color {
        switch self {
        case .general, .maintenance: .gray
        case .accounts, .profiles: .indigo
        case .notifications: .red
        case .reading, .messageList: .blue
        case .composing, .signatures: .purple
        case .filters, .blocked, .failedChanges: .orange
        case .vacation: .teal
        case .attachments: .cyan
        case .assistant: .indigo
        }
    }

    private var searchTerms: String {
        switch self {
        case .general: "default mail app email links undo send keyboard shortcuts archive trash snooze triage"
        case .accounts: "google login sign in sync nickname color order connections calendar permissions"
        case .profiles: "work personal groups focus notification schedule hours"
        case .notifications: "alerts sound badge dock menu bar permission"
        case .reading: "remote images privacy tracking dark mode conversation order mark read delay text size"
        case .messageList: "density compact comfortable preview swipe sidebar mailbox count badges importance"
        case .composing: "font reply format templates local signatures suggestions recipients"
        case .signatures: "gmail send as identity footer"
        case .filters: "rules forwarding labels delete archive"
        case .blocked: "spam block email address"
        case .vacation: "automatic reply out of office autoresponder dates"
        case .attachments: "download files preview cache"
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
        SettingsNavigationSection(title: "Application", destinations: [.general, .accounts, .profiles, .notifications]),
        SettingsNavigationSection(title: "Mail", destinations: [.reading, .messageList, .composing, .signatures, .filters, .blocked, .vacation, .attachments]),
        SettingsNavigationSection(title: "Tools", destinations: [.assistant, .failedChanges, .maintenance])
    ]
}
