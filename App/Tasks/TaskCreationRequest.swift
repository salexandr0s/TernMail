import CryptoKit
import Foundation
import GmailAPI
import MessageContent

struct TaskEmailSource: Equatable, Sendable {
    var accountID: String
    var threadID: String
    var messageID: String? = nil
    var subject: String
    var gmailURL: URL? = nil

    var mailLink: MailLink { MailLink(accountID: accountID, threadID: threadID, messageID: messageID) }
}

/// One explicit Add action. Its reference survives retries and is written to
/// Google notes so a refreshed summary cannot silently create the same task twice.
struct TaskCreationRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    var title: String
    var notes = ""
    var dueDate: String? = nil
    var source: TaskEmailSource? = nil
    var deduplicationKey: String? = nil
    var accountID: String? = nil
    var listID: String? = nil

    var reference: String {
        let identity: String
        if let deduplicationKey {
            identity = [(source?.accountID ?? accountID ?? ""), deduplicationKey].joined(separator: "\u{0}")
        } else if let source {
            identity = [source.accountID, source.threadID, source.messageID ?? "",
                title.trimmingCharacters(in: .whitespacesAndNewlines), dueDate ?? ""].joined(separator: "\u{0}")
        } else { identity = id.uuidString }
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var marker: String { "Tern task reference: \(reference)" }

    func draft(email: String) throws -> GoogleTaskDraft {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GoogleTasksModelError.emptyTitle }
        let taskTitle = String(trimmed.prefix(1024))
        var sections = [String]()
        if trimmed.count > 1024 { sections.append(trimmed) }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(notes) }
        var footer = [String]()
        if let source {
            footer.append("Email: \(source.subject.isEmpty ? "No Subject" : source.subject)")
            if let url = source.gmailURL ?? source.mailLink.gmailURL(email: email) { footer.append(url.absoluteString) }
            if let url = source.mailLink.ternURL { footer.append(url.absoluteString) }
        }
        footer.append(marker)
        let suffix = footer.joined(separator: "\n")
        let text = sections.joined(separator: "\n\n")
        // Google caps notes at 8,192 characters. Never lose the source/reference.
        guard text.count + suffix.count + 2 <= 8192 else { throw GoogleTasksModelError.notesTooLong }
        return GoogleTaskDraft(title: taskTitle, notes: text.isEmpty ? suffix : text + "\n\n" + suffix, due: dueDate)
    }
}

enum TaskCreationState: Equatable {
    case idle, adding, added, uncertain
}

struct GoogleTaskLocation: Equatable, Sendable {
    let accountID: String
    let listID: String
}

enum GoogleTasksModelError: Error, LocalizedError {
    case emptyTitle, notesTooLong, unavailable, noLists

    var errorDescription: String? {
        switch self {
        case .emptyTitle: "Enter a task title."
        case .notesTooLong: "This selection is too long for Google Tasks. Choose a shorter passage."
        case .unavailable: "Connect this account to Google Tasks to add the task."
        case .noLists: "Create a list in Google Tasks, then refresh."
        }
    }
}

/// Only fixed descriptions reach the UI; provider bodies may contain private data.
enum GoogleTasksIssue: Equatable {
    case connection, permission, apiDisabled, network, conflict, unavailable

    init(_ error: any Error) {
        guard let error = error as? GmailError else { self = .unavailable; return }
        switch error {
        case .unauthorized: self = .connection
        case .http where error.isMissingScope: self = .permission
        case .http(status: 403, reason: "SERVICE_DISABLED"), .http(status: 403, reason: "accessNotConfigured"): self = .apiDisabled
        case .http(status: 412, reason: _), .notFound: self = .conflict
        case .transport: self = .network
        default: self = .unavailable
        }
    }

    var needsConnection: Bool { self == .connection || self == .permission }
    var message: String {
        switch self {
        case .connection: "Sign in again to sync this account's tasks."
        case .permission: "Allow Google Tasks access to sync this account."
        case .apiDisabled: "Google Tasks is unavailable for this app. The app's Google Cloud project needs the Tasks API enabled."
        case .network: "Couldn't reach Google Tasks. Check your connection and refresh."
        case .conflict: "This task changed in Google Tasks. Refresh to see its latest version."
        case .unavailable: "Couldn't sync with Google Tasks. Try refreshing."
        }
    }

    static func creationMayHaveSucceeded(_ error: any Error) -> Bool {
        guard let error = error as? GmailError else { return !(error is GoogleTasksModelError) }
        return switch error {
        case .transport, .server, .decoding, .rateLimited: true
        default: false
        }
    }
}

/// Keep Tern's source/reference footer out of the editable notes field while
/// preserving it byte-for-byte when the user changes their own notes.
struct GoogleTaskNotes {
    let text: String
    let footer: String

    init(_ raw: String) {
        var lines = raw.components(separatedBy: "\n")
        guard let last = lines.last, last.hasPrefix("Tern task reference: "),
              last.count == "Tern task reference: ".count + 64 else {
            text = raw; footer = ""; return
        }
        var reserved = [lines.removeLast()]
        if lines.count >= 3,
           let url = URL(string: lines[lines.count - 1]), MailLink(url: url) != nil,
           let gmail = URLComponents(string: lines[lines.count - 2]), gmail.scheme == "https", gmail.host == "mail.google.com",
           lines[lines.count - 3].hasPrefix("Email: ") {
            reserved = Array(lines.suffix(3)) + reserved
            lines.removeLast(3)
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        footer = reserved.joined(separator: "\n")
    }

    func replacingText(_ value: String) -> String {
        guard !footer.isEmpty else { return value }
        return value.isEmpty ? footer : value + "\n\n" + footer
    }
}
