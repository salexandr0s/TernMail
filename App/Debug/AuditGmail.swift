#if DEBUG
import Foundation
import GmailAPI
import MailStore
import SyncEngine

/// Synthetic mail for --ui-audit. No OAuth, disk storage or Gmail requests.
actor AuditGmail: GmailService {
    private struct Message {
        let id: String
        let thread: String
        let subject: String
        let text: String
        let html: Bool
        var labels: Set<String>
        var history = 200
    }

    private var version = 200
    private let referenceDate = Date.now
    private var mail: [Message] = [
        Message(id: "m1", thread: "t1", subject: "Field notes", text: "<p>Today’s field notes.</p><img src='https://example.invalid/pixel'><p><a href='https://example.com/'>Example link</a></p><div style='width:900px;background:#eef'>Wide message, right edge →</div>" + String(repeating: "<p>Another paragraph of synthetic mail.</p>", count: 18), html: true, labels: ["INBOX", "UNREAD"]),
        Message(id: "m2", thread: "t2", subject: "Weekend plans", text: "The earlier message.", html: false, labels: ["INBOX"]),
        Message(id: "m3", thread: "t2", subject: "Weekend plans", text: "The latest reply. See https://example.com/ for details.", html: false, labels: ["INBOX", "UNREAD", "STARRED"]),
        Message(id: "m4", thread: "t3", subject: "Trail plans", text: "Archived mail with a custom label.", html: false, labels: ["Label_1", "UNREAD"]),
        Message(id: "m5", thread: "t4", subject: "Discarded draft notes", text: "Synthetic trash message.", html: false, labels: ["TRASH"]),
        Message(id: "m6", thread: "t5", subject: "Sent confirmation", text: "Synthetic sent message.", html: false, labels: ["SENT"]),
        Message(id: "m7", thread: "t6", subject: "Unwanted offer", text: "Synthetic spam message.", html: false, labels: ["SPAM", "UNREAD"]),
    ]

    func profile() throws -> GmailProfile {
        try decode(["emailAddress": "audit@example.invalid", "historyId": String(version)])
    }

    func labels() throws -> [GmailLabel] {
        try (["INBOX", "STARRED", "SENT", "DRAFT", "SPAM", "TRASH"] + ["Label_1"]).map { id in
            let unread = Set(mail.filter { $0.labels.contains(id) && $0.labels.contains("UNREAD") }.map(\.thread)).count
            return try decode(["id": id, "name": id == "Label_1" ? "Hiking" : id, "type": id == "Label_1" ? "user" : "system", "threadsUnread": unread])
        }
    }

    func labels(ids: [String]) throws -> [String: Result<GmailLabel, GmailError>] {
        Dictionary(uniqueKeysWithValues: try labels().filter { ids.contains($0.id) }.map { ($0.id, .success($0)) })
    }

    func listMessages(query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) throws -> MessageListPage {
        let selected = mail.filter { message in
            labelIDs.allSatisfy(message.labels.contains) && (includeSpamTrash || message.labels.isDisjoint(with: ["TRASH", "SPAM"]))
        }
        return try decode(["messages": selected.map { ["id": $0.id, "threadId": $0.thread] }])
    }

    func messages(ids: [String], format: MessageFormat, metadataHeaders: [String]) throws -> [String: Result<GmailMessage, GmailError>] {
        try Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, try mail.first { $0.id == id }.map { .success(try decode(messageJSON($0))) } ?? .failure(.notFound))
        })
    }

    func thread(id: String, format: MessageFormat) throws -> GmailThread {
        let messages = mail.filter { $0.thread == id }
        guard !messages.isEmpty else { throw GmailError.notFound }
        return try decode(["id": id, "messages": messages.map(messageJSON)])
    }

    func history(startHistoryID: String, pageToken: String?) throws -> HistoryPage {
        let changed = mail.filter { $0.history > (Int(startHistoryID) ?? 0) }
        let allLabels: Set<String> = ["INBOX", "UNREAD", "STARRED", "SENT", "SPAM", "TRASH", "Label_1"]
        return try decode(["historyId": String(version), "history": changed.map { message in
            ["id": String(message.history),
             "labelsAdded": [["message": ["id": message.id, "threadId": message.thread], "labelIds": Array(message.labels)]],
             "labelsRemoved": [["message": ["id": message.id, "threadId": message.thread], "labelIds": Array(allLabels.subtracting(message.labels))]]] as [String: Any]
        }])
    }

    func modifyThreads(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) -> [String: GmailError] {
        change(ids: mail.filter { ids.contains($0.thread) }.map(\.id), add: addLabelIDs, remove: removeLabelIDs)
        return [:]
    }

    func trashThreads(ids: [String]) -> [String: GmailError] {
        modifyThreads(ids: ids, addLabelIDs: ["TRASH"], removeLabelIDs: [])
    }

    func untrashThreads(ids: [String]) -> [String: GmailError] {
        modifyThreads(ids: ids, addLabelIDs: [], removeLabelIDs: ["TRASH"])
    }

    func batchModifyMessages(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) {
        change(ids: ids, add: addLabelIDs, remove: removeLabelIDs)
    }

    private func change(ids: [String], add: [String], remove: [String]) {
        version += 1
        for index in mail.indices where ids.contains(mail[index].id) {
            mail[index].labels.formUnion(add)
            mail[index].labels.subtract(remove)
            mail[index].history = version
        }
    }

    private func messageJSON(_ message: Message) -> [String: Any] {
        let index = mail.firstIndex { $0.id == message.id } ?? 0
        let ageHours = message.id == "m2" ? 3 : Double(index)
        return ["id": message.id, "threadId": message.thread, "labelIds": Array(message.labels),
                "historyId": String(message.history), "internalDate": String(Int(referenceDate.addingTimeInterval(-ageHours * 3600).timeIntervalSince1970 * 1000)),
                "snippet": "Synthetic mail for the UI audit", "payload": [
                    "mimeType": message.html ? "text/html" : "text/plain",
                    "headers": [["name": "From", "value": "River <river@example.invalid>"], ["name": "To", "value": "audit@example.invalid"], ["name": "Subject", "value": message.subject]],
                    "body": ["data": Data(message.text.utf8).base64EncodedString()]]]
    }

    private func decode<T: Decodable>(_ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
#endif
