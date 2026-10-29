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
        var from = "River <river@example.invalid>"
    }

    private struct UserLabel {
        let id: String
        var name: String
        var color: LabelColor?
    }

    private var drafts: [String: String] = [:]
    private var nextDraft = 1
    private static let systemLabels = ["INBOX", "STARRED", "SENT", "DRAFT", "SPAM", "TRASH"]
    private var userLabels = [UserLabel(id: "Label_1", name: "Hiking")]
    private var nextLabel = 2

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
        let system = try Self.systemLabels.map { id in
            try decode(["id": id, "name": id, "type": "system", "threadsUnread": unreadThreads(id)]) as GmailLabel
        }
        return try system + userLabels.map(labelValue)
    }

    private func labelValue(_ label: UserLabel) throws -> GmailLabel {
        var json: [String: Any] = ["id": label.id, "name": label.name, "type": "user", "threadsUnread": unreadThreads(label.id)]
        if let color = label.color {
            json["color"] = ["backgroundColor": color.backgroundColor, "textColor": color.textColor]
        }
        return try decode(json)
    }

    private func unreadThreads(_ labelID: String) -> Int {
        Set(mail.filter { $0.labels.contains(labelID) && $0.labels.contains("UNREAD") }.map(\.thread)).count
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

    /// Matches every plain word of `query` against subjects and text, and
    /// ignores operators.
    func listThreads(query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) throws -> ThreadListPage {
        let words = (query ?? "").lowercased().split(separator: " ").filter { !$0.contains(":") }
        let selected = mail.filter { message in
            let text = (message.subject + " " + message.text).lowercased()
            return labelIDs.allSatisfy(message.labels.contains)
                && (includeSpamTrash || message.labels.isDisjoint(with: ["TRASH", "SPAM"]))
                && words.allSatisfy { text.contains($0) }
        }
        var seen = Set<String>()
        return try decode(["threads": selected.map(\.thread).filter { seen.insert($0).inserted }.map { ["id": $0] }])
    }

    func threads(ids: [String], format: MessageFormat, metadataHeaders: [String]) -> [String: Result<GmailThread, GmailError>] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, Result { try thread(id: id, format: format) }.mapError { $0 as? GmailError ?? .notFound })
        })
    }

    func attachment(messageID: String, attachmentID: String) throws -> Data { throw GmailError.notFound }

    func history(startHistoryID: String, pageToken: String?) throws -> HistoryPage {
        let changed = mail.filter { $0.history > (Int(startHistoryID) ?? 0) }
        let allLabels = Set(Self.systemLabels + ["UNREAD"] + userLabels.map(\.id))
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

    // MARK: Labels

    func createLabel(name: String, color: LabelColor?) throws -> GmailLabel {
        guard !userLabels.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw GmailError.http(status: 409, reason: nil)
        }
        let label = UserLabel(id: "Label_\(nextLabel)", name: name, color: color)
        nextLabel += 1
        userLabels.append(label)
        return try labelValue(label)
    }

    func patchLabel(id: String, name: String?, color: LabelColorChange?) throws -> GmailLabel {
        guard let index = userLabels.firstIndex(where: { $0.id == id }) else { throw GmailError.notFound }
        if let name { userLabels[index].name = name }
        switch color {
        case .set(let value)?: userLabels[index].color = value
        case .remove?: userLabels[index].color = nil
        case nil: break
        }
        return try labelValue(userLabels[index])
    }

    func deleteLabel(id: String) {
        userLabels.removeAll { $0.id == id }
        change(ids: mail.filter { $0.labels.contains(id) }.map(\.id), add: [], remove: [id])
    }

    // MARK: Drafts

    func drafts(query: String?, pageToken: String?, maxResults: Int) throws -> DraftListPage {
        try decode(["drafts": drafts.sorted { $0.key < $1.key }.compactMap { id, messageID in
            mail.first { $0.id == messageID }.map { ["id": id, "message": ["id": $0.id, "threadId": $0.thread]] }
        }])
    }

    func draft(id: String, format: MessageFormat) throws -> GmailDraft {
        guard let message = drafts[id].flatMap({ messageID in mail.first { $0.id == messageID } }) else { throw GmailError.notFound }
        return try decode(["id": id, "message": messageJSON(message)])
    }

    func createDraft(_ message: OutgoingMessage) throws -> GmailDraft {
        let id = "draft\(nextDraft)"
        nextDraft += 1
        let stored = store(message, labels: ["DRAFT"])
        drafts[id] = stored.id
        return try decode(["id": id, "message": ["id": stored.id, "threadId": stored.thread]])
    }

    func updateDraft(id: String, with message: OutgoingMessage) throws -> GmailDraft {
        guard let old = drafts[id], let thread = mail.first(where: { $0.id == old })?.thread else { throw GmailError.notFound }
        mail.removeAll { $0.id == old }
        let stored = store(OutgoingMessage(raw: message.raw, threadID: thread), labels: ["DRAFT"])
        drafts[id] = stored.id
        return try decode(["id": id, "message": ["id": stored.id, "threadId": stored.thread]])
    }

    func sendDraft(id: String, with message: OutgoingMessage) throws -> GmailMessage {
        guard let old = drafts.removeValue(forKey: id), let thread = mail.first(where: { $0.id == old })?.thread else {
            throw GmailError.notFound
        }
        mail.removeAll { $0.id == old }
        return try decode(messageJSON(store(OutgoingMessage(raw: message.raw, threadID: thread), labels: ["SENT"])))
    }

    func deleteDraft(id: String) throws {
        guard let old = drafts.removeValue(forKey: id) else { throw GmailError.notFound }
        mail.removeAll { $0.id == old }
    }

    /// Keeps the subject of an uploaded message. Encoded words stay encoded.
    private func store(_ message: OutgoingMessage, labels: Set<String>) -> Message {
        version += 1
        let headers = String(decoding: message.raw, as: UTF8.self).components(separatedBy: "\r\n\r\n").first ?? ""
        let subject = headers.components(separatedBy: "\r\n").first { $0.hasPrefix("Subject: ") }.map { String($0.dropFirst(9)) }
        let stored = Message(
            id: "m\(version)", thread: message.threadID ?? "t\(version)", subject: subject ?? "",
            text: "Synthetic message saved from the compose window.", html: false, labels: labels,
            history: version, from: "Audit <audit@example.invalid>"
        )
        mail.append(stored)
        return stored
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
                    "headers": [["name": "From", "value": message.from], ["name": "To", "value": "audit@example.invalid"], ["name": "Subject", "value": message.subject]],
                    "body": ["data": Data(message.text.utf8).base64EncodedString()]]]
    }

    private func decode<T: Decodable>(_ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
#endif
