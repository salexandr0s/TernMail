import AppIntents
import Foundation
import MailStore
import MessageContent

/// Why an intent couldn't act, as Shortcuts shows it.
enum MailIntentError: Error, CustomLocalizedStringResourceConvertible {
    case signedOut, nothingSelected, pastDate, draftFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .signedOut: "Sign in to Tern first."
        case .nothingSelected: "Select conversations in Tern first."
        case .pastDate: "Choose a time in the future."
        case .draftFailed: "Tern couldn't start the message."
        }
    }
}

/// The mailboxes Open Mailbox can show.
enum MailboxIntentTarget: String, AppEnum {
    case inbox, starred, snoozed, sent, drafts, allMail, spam, trash

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mailbox")
    static let caseDisplayRepresentations: [MailboxIntentTarget: DisplayRepresentation] = [
        .inbox: DisplayRepresentation(title: "Inbox", image: .init(systemName: "tray")),
        .starred: DisplayRepresentation(title: "Starred", image: .init(systemName: "star")),
        .snoozed: DisplayRepresentation(title: "Snoozed", image: .init(systemName: "clock")),
        .sent: DisplayRepresentation(title: "Sent", image: .init(systemName: "paperplane")),
        .drafts: DisplayRepresentation(title: "Drafts", image: .init(systemName: "doc")),
        .allMail: DisplayRepresentation(title: "All Mail", image: .init(systemName: "archivebox")),
        .spam: DisplayRepresentation(title: "Spam", image: .init(systemName: "xmark.bin")),
        .trash: DisplayRepresentation(title: "Trash", image: .init(systemName: "trash")),
    ]

    var labelID: String {
        switch self {
        case .inbox: SystemLabel.inbox
        case .starred: SystemLabel.starred
        case .snoozed: MailboxModel.snoozedID
        case .sent: SystemLabel.sent
        case .drafts: SystemLabel.draft
        case .allMail: SystemLabel.allMail
        case .spam: SystemLabel.spam
        case .trash: SystemLabel.trash
        }
    }
}

struct NewMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "New Message"
    static let description = IntentDescription("Opens a new message in Tern. Nothing is sent until you send it.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "To") var recipients: String?
    @Parameter(title: "Subject") var subject: String?
    @Parameter(title: "Message", inputOptions: .init(multiline: true)) var body: String?
    @Dependency private var app: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        guard let mailbox = app.mailbox else { throw MailIntentError.signedOut }
        let to = EmailAddress.parseList(recipients ?? "").filter(\.isValid)
        app.showMainWindow()
        guard let id = await mailbox.startMailto(MailtoRequest(to: to, subject: subject ?? "", body: body ?? "")) else {
            throw MailIntentError.draftFailed
        }
        app.mailURLs.composeDraftID = id
        return .result()
    }
}

struct CheckForNewMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for New Mail"
    static let description = IntentDescription("Asks Gmail for new mail in every signed-in account.")
    @Dependency private var app: AppModel

    @MainActor func perform() async throws -> some IntentResult {
        guard let mailbox = app.mailbox else { throw MailIntentError.signedOut }
        mailbox.syncNow()
        return .result()
    }
}

struct OpenMailboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Mailbox"
    static let description = IntentDescription("Shows a mailbox in Tern's main window.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Mailbox", default: .inbox) var target: MailboxIntentTarget
    @Dependency private var app: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$target)") }

    @MainActor func perform() async throws -> some IntentResult {
        guard let mailbox = app.mailbox else { throw MailIntentError.signedOut }
        app.showMainWindow()
        app.destination = .mail
        mailbox.go(to: target.labelID)
        return .result()
    }
}

struct SearchMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Mail"
    static let description = IntentDescription("Searches your mail in Tern's main window.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Search For") var text: String
    @Dependency private var app: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Search mail for \(\.$text)") }

    @MainActor func perform() async throws -> some IntentResult {
        guard let mailbox = app.mailbox else { throw MailIntentError.signedOut }
        app.showMainWindow()
        app.destination = .mail
        mailbox.search.update(text)
        mailbox.search.submit()
        return .result()
    }
}

/// Works on the selection in Tern's main window, like the Snooze command.
struct SnoozeSelectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Snooze Selected Conversations"
    static let description = IntentDescription("Snoozes the conversations selected in Tern until the time you choose.")

    @Parameter(title: "Until") var date: Date
    @Dependency private var app: AppModel

    static var parameterSummary: some ParameterSummary { Summary("Snooze selected conversations until \(\.$date)") }

    @MainActor func perform() async throws -> some IntentResult {
        guard let mailbox = app.mailbox else { throw MailIntentError.signedOut }
        guard date > .now else { throw MailIntentError.pastDate }
        guard let task = mailbox.snooze(until: date) else { throw MailIntentError.nothingSelected }
        await task.value
        return .result()
    }
}

struct TernAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewMessageIntent(), phrases: [
            "New message in \(.applicationName)",
            "Write an email in \(.applicationName)",
        ], shortTitle: "New Message", systemImageName: "square.and.pencil")
        AppShortcut(intent: CheckForNewMailIntent(), phrases: [
            "Check for new mail in \(.applicationName)",
        ], shortTitle: "Check for New Mail", systemImageName: "arrow.clockwise")
        AppShortcut(intent: OpenMailboxIntent(), phrases: [
            "Open \(\.$target) in \(.applicationName)",
            "Show my \(\.$target) in \(.applicationName)",
        ], shortTitle: "Open Mailbox", systemImageName: "tray")
        AppShortcut(intent: SearchMailIntent(), phrases: [
            "Search mail in \(.applicationName)",
        ], shortTitle: "Search Mail", systemImageName: "magnifyingglass")
    }
}
