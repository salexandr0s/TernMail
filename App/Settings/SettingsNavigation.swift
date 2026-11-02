import Foundation
import Observation

enum SettingsDestination: String, CaseIterable, Identifiable, Sendable {
    case general, mailActions, notifications
    case connections, accountPreferences, profiles
    case reading, messageList, attachments
    case writing, templates, signatures, suggestions
    case organizeMail, filters, blocked, vacation, calendar
    case assistant, failedChanges, maintenance
    var id: String { rawValue }
    /// The last accepted pane. Other windows use SettingsNavigationRequests
    /// so an open editor can refuse navigation before this preference changes.
    static let storageKey = "settingsDestination"

    /// The stored pane, or General when the value is missing or unknown.
    static func stored(_ rawValue: String) -> SettingsDestination {
        SettingsDestination(rawValue: rawValue) ?? .general
    }

    /// Moves a pane saved before the two signature panes merged.
    /// "localSignatures" opens Signatures on this Mac, and "signatures", which
    /// then meant Gmail Signatures, opens Signatures in Gmail. The move saves a
    /// signature source, and a saved source skips it, so it runs once and a
    /// later "signatures" keeps the source the user chose.
    static func migrateSavedPane(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: SignatureSource.storageKey) == nil else { return }
        let saved = defaults.string(forKey: storageKey)
        if saved == "localSignatures" {
            defaults.set(SettingsDestination.signatures.rawValue, forKey: storageKey)
        }
        let source: SignatureSource = saved == SettingsDestination.signatures.rawValue ? .gmail : .local
        defaults.set(source.rawValue, forKey: SignatureSource.storageKey)
    }

    var title: String {
        switch self {
        case .general: "General"
        case .mailActions: "Mail Actions"
        case .notifications: "Notifications"
        case .connections: "Connections"
        case .accountPreferences: "Account Settings"
        case .profiles: "Profiles"
        case .reading: "Reading"
        case .messageList: "Message List"
        case .attachments: "Attachments"
        case .writing: "Writing"
        case .templates: "Templates"
        case .signatures: "Signatures"
        case .suggestions: "Suggestions"
        case .organizeMail: "Organize Mail"
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
        case .organizeMail: "tag"
        case .filters: "line.3.horizontal.decrease.circle"
        case .blocked: "person.crop.circle.badge.xmark"
        case .vacation: "sun.max"
        case .calendar: "calendar"
        case .assistant: "sparkles"
        case .failedChanges: "exclamationmark.arrow.triangle.2.circlepath"
        case .maintenance: "externaldrive"
        }
    }

    /// A short purpose statement for the page header and search results.
    var subtitle: String {
        switch self {
        case .general: "Set up everyday defaults for using Tern."
        case .mailActions: "Choose how keyboard actions and mail sounds behave."
        case .notifications: "Choose which mail gets your attention and how you are notified."
        case .connections: "Add Google accounts and choose what each one shares with Tern."
        case .accountPreferences: "Arrange your accounts and personalize how they appear."
        case .profiles: "Group your accounts and set notification hours."
        case .reading: "Make conversations comfortable to read and control what loads."
        case .messageList: "Choose what appears in your inbox and how you move through it."
        case .attachments: "Choose where attachments are stored when you open them."
        case .writing: "Choose your sender, formatting, and reply defaults."
        case .templates: "Save reusable messages to insert while writing."
        case .signatures: "Signatures on this Mac stay in Tern. Gmail signatures are saved to your Google account."
        case .suggestions: "Choose which addresses appear when you add recipients."
        case .organizeMail: "Find useful labels for your mail, then review what gets applied."
        case .filters: "Set rules for how incoming mail is handled in Gmail."
        case .blocked: "Review sender filters that move new messages to Trash."
        case .vacation: "Send an automatic reply while you are away."
        case .calendar: "Manage your calendars, sharing, and scheduling preferences."
        case .assistant: "Connect ChatGPT and choose what your assistant can access."
        case .failedChanges: "Review changes that could not finish and choose what happens next."
        case .maintenance: "Manage downloaded mail and the storage it uses on this Mac."
        }
    }

    /// Lists and editors can use a wider working area than preference forms.
    var usesWideLayout: Bool {
        switch self {
        case .accountPreferences, .templates, .signatures, .organizeMail,
             .filters, .vacation, .calendar, .failedChanges: true
        default: false
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
        case .reading: "appearance remote images privacy tracking company business bank logos sender photos website icons dark mode conversation order mark read delay text size spotlight search index"
        case .messageList: "inbox appearance density compact comfortable preview swipe sidebar mailbox count badges importance"
        case .attachments: "download open files preview cache"
        case .writing: "font reply format markdown quote recipients sender send from default account"
        case .templates: "reusable replies canned responses"
        case .signatures: "local gmail new messages replies separator send as identity footer"
        case .suggestions: "recipients autocomplete hide hidden addresses"
        case .organizeMail: "gmail labels categories rules newsletters action waiting accounts finance personalized ai organize"
        case .filters: "gmail rules incoming forwarding labels delete archive"
        case .blocked: "gmail trash block sender filter email address"
        case .vacation: "automatic reply away out of office autoresponder dates"
        case .calendar: "calendars events subscriptions sharing scheduling availability"
        case .assistant: "chatgpt openai ai model writing style summaries privacy access"
        case .failedChanges: "retry errors pending queue discard"
        case .maintenance: "disk space storage cache attachments budget reset trim database"
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
        SettingsNavigationSection(title: "Workspace", destinations: [.general, .notifications, .calendar, .assistant]),
        SettingsNavigationSection(title: "Accounts", destinations: [.connections, .accountPreferences, .profiles]),
        SettingsNavigationSection(title: "Mail", destinations: [.reading, .messageList, .mailActions, .attachments]),
        SettingsNavigationSection(title: "Writing", destinations: [.writing, .templates, .signatures, .suggestions]),
        SettingsNavigationSection(title: "Rules & Replies", destinations: [.organizeMail, .filters, .blocked, .vacation]),
        SettingsNavigationSection(title: "Maintenance", destinations: [.failedChanges, .maintenance])
    ]

}

/// A pane whose edits only Save sends registers them here, so leaving the pane
/// or closing the window asks first.
@MainActor @Observable
final class SettingsUnsavedChanges {
    /// What the edits belong to, in sentence case for the confirmation. `nil` when nothing waits.
    private(set) var subject: String?
    var pendingChange: PendingChange?

    struct PendingChange {
        let subject: String
        let apply: @MainActor () -> Void
    }

    func set(_ subject: String) { self.subject = subject }
    func clear() { subject = nil }

    /// Every route that replaces an editor asks before mutating its identity.
    func request(_ change: @escaping @MainActor () -> Void) {
        guard let subject else { change(); return }
        pendingChange = PendingChange(subject: subject, apply: change)
    }

    func discardAndApply(_ change: PendingChange) {
        pendingChange = nil
        clear()
        change.apply()
    }
}
