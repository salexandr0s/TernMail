import CryptoKit
import Foundation
import MailStore
import MessageContent
import TernAI

/// A summary suggestion must point to a message in the displayed conversation.
struct FollowUpSuggestionRequest {
    let source: FollowUpSource
    let title: String
    let ownerName: String?
    let dueAt: Date?
    let acceptanceKey: String

    static func make(_ task: AssistantSummary.OpenTask, report: ThreadSummaryReport,
                     detail: ThreadDetail) -> Self? {
        let references = report.sources.filter {
            task.sourceIDs.contains($0.id) && $0.accountID == detail.thread.accountID
                && $0.threadID == detail.thread.id
        }
        guard let message = references.compactMap({ source in
            detail.messages.first {
                $0.id == source.messageID && $0.record.accountID == detail.thread.accountID
                    && $0.record.threadID == detail.thread.id && !$0.labels.contains(SystemLabel.draft)
            }
        }).first else { return nil }
        let title = task.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let identity = [message.record.accountID, message.record.threadID, message.id,
                        normalized(title), normalized(task.owner ?? "")].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        // Deadlines are calendar days encoded at UTC midnight, like Google Tasks.
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        let dueAt = task.dueDate.flatMap { text -> Date? in
            guard let date = parser.date(from: text), parser.string(from: date) == text else { return nil }
            return date
        }
        return Self(source: FollowUpSource(record: message.record), title: title,
                    ownerName: task.owner, dueAt: dueAt, acceptanceKey: "summary:\(digest)")
    }
}

extension AppModel {
    /// Capture the source before any read; changing list selection cannot retarget the editor.
    func requestFollowUp(accountID: String, threadID: String, messageID: String? = nil) async {
        guard let mailbox, let owner = mailbox.account(id: accountID) else { return }
        do {
            _ = try await mailURLs.resolveConversation(MailLink(accountID: accountID, threadID: threadID,
                messageID: messageID)) { [weak self] in
                self?.mailbox === mailbox && mailbox.account(id: accountID) === owner
            }
            let source = try await mailbox.cache.read { tx -> MessageRecord? in
                let labels = try tx.currentLabels(threadID: threadID, accountID: accountID)
                if let messageID {
                    guard let record = try tx.message(id: messageID, accountID: accountID),
                          record.threadID == threadID, labels[record.id]?.contains(SystemLabel.draft) != true else { return nil }
                    return record
                }
                return try tx.messages(threadID: threadID, accountID: accountID).last {
                    labels[$0.id]?.contains(SystemLabel.draft) != true
                }
            }
            try Task.checkCancellation()
            guard self.mailbox === mailbox, mailbox.account(id: accountID) === owner else { return }
            guard let source else { throw FollowUpModelError.invalidSource }
            showMainWindow()
            followUps.beginTracking(source: FollowUpSource(record: source))
        } catch is CancellationError {} catch {
            guard self.mailbox === mailbox, mailbox.account(id: accountID) === owner else { return }
            mailbox.notice = .init(message: "Couldn't open this message for follow-up tracking. Refresh mail and try again.", isError: true)
        }
    }

    func requestFollowUp(_ suggestion: FollowUpSuggestionRequest) {
        guard mailbox?.account(id: suggestion.source.accountID) != nil else { return }
        showMainWindow()
        followUps.beginTracking(source: suggestion.source, title: suggestion.title,
            ownerName: suggestion.ownerName, dueAt: suggestion.dueAt, acceptanceKey: suggestion.acceptanceKey)
    }
}
