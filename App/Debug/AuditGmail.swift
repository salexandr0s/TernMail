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
        /// The name of a small text file the message carries.
        var attachment: String?
        var ageDays: Int?
    }

    private struct UserLabel {
        let id: String
        var name: String
        var color: LabelColor?
    }

    private static let attachmentData = Data("Synthetic attachment for the UI audit.\n".utf8)

    private var drafts: [String: String] = [:]
    private var nextDraft = 1
    /// Gmail lists UNREAD with the other system labels and answers `labels.get` for it.
    private static let systemLabels = ["INBOX", "STARRED", "UNREAD", "SENT", "DRAFT", "SPAM", "TRASH"]
    private var userLabels = [UserLabel(id: "Label_1", name: "Hiking")]
    private var nextLabel = 2
    private var shouldFailNextThreadLoad = false

    private var version = 200
    private let referenceDate = Date.now
    private var mail: [Message] = [
        Message(id: "m1", thread: "t1", subject: "Field notes", text: "<p>Today’s field notes.</p><img src='https://example.invalid/pixel'><img src='https://example.invalid/open.gif' width='1' height='1'><img src='https://example.invalid/click.gif' style='width:1px;height:1px'><p><a href='https://example.com/'>Example link</a></p><div style='width:900px;background:#eef'>Wide message, right edge →</div>" + String(repeating: "<p>Another paragraph of synthetic mail.</p>", count: 18), html: true, labels: ["INBOX", "UNREAD"]),
        Message(id: "m2", thread: "t2", subject: "Weekend plans", text: "The earlier message.", html: false, labels: ["INBOX"]),
        Message(id: "m3", thread: "t2", subject: "Weekend plans", text: "The latest reply. See https://example.com/ for details.", html: false, labels: ["INBOX", "UNREAD", "STARRED"], attachment: "Trail map.txt"),
        Message(id: "m4", thread: "t3", subject: "Trail plans", text: "Archived mail with a custom label.", html: false, labels: ["Label_1", "UNREAD"]),
        Message(id: "m5", thread: "t4", subject: "Discarded draft notes", text: "Synthetic trash message.", html: false, labels: ["TRASH"]),
        Message(id: "m6", thread: "t5", subject: "Sent confirmation", text: "Synthetic sent message.", html: false, labels: ["SENT"]),
        Message(id: "m7", thread: "t6", subject: "Unwanted offer", text: "Synthetic spam message.", html: false, labels: ["SPAM", "UNREAD"]),
    ]

    /// Which audit account's mail to serve.
    enum Account {
        case first
        /// Other mail under the first account's message, thread and label
        /// IDs, as separate Gmail accounts can have.
        case second
    }

    init(_ account: Account = .first) {
        if account == .second {
            mail = Self.secondMail
            userLabels = [UserLabel(id: "Label_1", name: "Projects")]
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-audit-list") {
            userLabels += [
                UserLabel(id: "Label_2", name: "Field research"),
                UserLabel(id: "Label_3", name: "Equipment planning"),
            ]
            nextLabel = 4
            mail += [
                Message(id: "list1", thread: "list1", subject: "Planning the next field visit and reviewing the equipment checklist", text: "Please review the route and let us know which equipment you can bring.", html: false, labels: ["INBOX", "UNREAD", "STARRED", "Label_1", "Label_2", "Label_3"], from: "Alexandra Morgan and the field research team <team@example.invalid>", attachment: "Field visit equipment checklist and route notes.txt"),
                Message(id: "list2", thread: "list1", subject: "Planning the next field visit and reviewing the equipment checklist", text: "The revised checklist is ready for review.", html: false, labels: ["INBOX", "UNREAD", "STARRED", "Label_1", "Label_2", "Label_3"], from: "Alexandra Morgan and the field research team <team@example.invalid>"),
                Message(id: "list3", thread: "list2", subject: "", text: "", html: false, labels: ["INBOX"], from: "Sam <sam@example.invalid>"),
                Message(id: "list4", thread: "list3", subject: "Workshop registration", text: "Your place is confirmed. The workshop starts at nine.", html: false, labels: ["INBOX", "UNREAD"], from: "Community workshop <workshop@example.invalid>"),
                Message(id: "list5", thread: "list4", subject: "Notes from Monday", text: "Here are the notes and next steps from our conversation.", html: false, labels: ["INBOX"], from: "Rowan <rowan@example.invalid>"),
                Message(id: "list6", thread: "list5", subject: "A quick update", text: "Everything is ready for tomorrow.", html: false, labels: ["INBOX"], from: "Casey <casey@example.invalid>"),
            ]
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-audit-attachments") {
            mail += (0..<125).map { index in
                Message(id: "attachment-\(index)", thread: "attachment-thread-\(index)",
                    subject: index == 124 ? "Your October 2024 invoice" : "Project documents \(index + 1)",
                    text: "Synthetic email for attachment-library verification. The attached document is test data.",
                    html: false, labels: index == 124 ? ["Label_1"] : ["INBOX"],
                    from: index == 124 ? "Mira Chen <billing@example.invalid>" : "Rowan Ellis <rowan@example.invalid>",
                    attachment: index == 124 ? "Invoice-2024-1042.pdf" : "Project-notes-\(index + 1).txt",
                    ageDays: index == 124 ? 730 : index)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-audit-attachment-categories") {
            mail += [
                Message(id: "category-ticket", thread: "category-ticket", subject: "Your journey",
                    text: "Synthetic travel document.", html: false, labels: ["INBOX"], attachment: "Fahrkarte-4821.txt"),
                Message(id: "category-receipt", thread: "category-receipt", subject: "Payment received",
                    text: "Synthetic payment document.", html: false, labels: ["INBOX"], attachment: "Receipt-4821.txt"),
                Message(id: "category-invoice", thread: "category-invoice", subject: "Your documents",
                    text: "Synthetic document with a generic filename.", html: false, labels: ["INBOX"], attachment: "Document-4821.pdf"),
            ]
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-audit-writing-style") {
            mail += (0..<100).map { index in
                Message(id: "writing-\(index)", thread: "writing-thread-\(index)",
                    subject: "Synthetic sent reply \(index + 1)",
                    text: WritingStyleAuditFixtures.message(index: index, formal: account == .second),
                    html: false, labels: ["SENT"],
                    from: account == .first ? "UI Audit <audit@example.invalid>" : "Second Audit <second@example.invalid>")
            }
        }
    }

    private static let secondMail: [Message] = [
        Message(id: "m1", thread: "t1", subject: "Book club", text: "The next meeting moves to Thursday.", html: false, labels: ["INBOX", "UNREAD"], from: "Sky <sky@example.invalid>"),
        Message(id: "m2", thread: "t2", subject: "Garden plans", text: "The first message.", html: false, labels: ["INBOX"], from: "Sky <sky@example.invalid>"),
        Message(id: "m3", thread: "t2", subject: "Garden plans", text: "The latest reply, with the planting list attached.", html: false, labels: ["INBOX", "STARRED"], from: "Sky <sky@example.invalid>", attachment: "Planting list.txt"),
        Message(id: "m4", thread: "t3", subject: "Project notes", text: "Archived mail with a custom label.", html: false, labels: ["Label_1"], from: "Sky <sky@example.invalid>"),
        Message(id: "m5", thread: "t5", subject: "Order confirmation", text: "Synthetic sent message.", html: false, labels: ["SENT"]),
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

    /// Like Gmail's batch, answers every ID, with a 404 for a label it doesn't have.
    func labels(ids: [String]) throws -> [String: Result<GmailLabel, GmailError>] {
        let all = try labels()
        return Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, all.first { $0.id == id }.map { .success($0) } ?? .failure(.notFound))
        })
    }

    func listMessages(query: String?, labelIDs: [String], includeSpamTrash: Bool, pageToken: String?, maxResults: Int) throws -> MessageListPage {
        let selected = mail.filter { message in
            labelIDs.allSatisfy(message.labels.contains) && (includeSpamTrash || message.labels.isDisjoint(with: ["TRASH", "SPAM"]))
                && (query != "has:attachment" || message.attachment != nil)
        }
        if query == "has:attachment" || query == "in:sent" {
            let offset = Int(pageToken ?? "0") ?? 0
            let page = selected.dropFirst(offset).prefix(maxResults)
            var json: [String: Any] = ["messages": page.map { ["id": $0.id, "threadId": $0.thread] }]
            if offset + page.count < selected.count { json["nextPageToken"] = String(offset + page.count) }
            return try decode(json)
        }
        return try decode(["messages": selected.map { ["id": $0.id, "threadId": $0.thread] }])
    }

    func messages(ids: [String], format: MessageFormat, metadataHeaders: [String]) throws -> [String: Result<GmailMessage, GmailError>] {
        try Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, try mail.first { $0.id == id }.map { .success(try decode(messageJSON($0))) } ?? .failure(.notFound))
        })
    }

    func failNextThreadLoad() {
        shouldFailNextThreadLoad = true
    }

    func thread(id: String, format: MessageFormat) throws -> GmailThread {
        if shouldFailNextThreadLoad {
            shouldFailNextThreadLoad = false
            throw URLError(.notConnectedToInternet)
        }
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

    func attachment(messageID: String, attachmentID: String) throws -> Data {
        guard mail.contains(where: { $0.id == messageID && $0.attachment != nil }) else { throw GmailError.notFound }
        let filename = mail.first { $0.id == messageID }?.attachment ?? ""
        return filename.hasSuffix(".pdf") ? AttachmentAuditFixtures.invoicePDF : Self.attachmentData
    }

    func history(startHistoryID: String, pageToken: String?) throws -> HistoryPage {
        let changed = mail.filter { $0.history > (Int(startHistoryID) ?? 0) }
        let allLabels = Set(Self.systemLabels + userLabels.map(\.id))
        return try decode(["historyId": String(version), "history": changed.map { message in
            ["id": String(message.history),
             "labelsAdded": [["message": ["id": message.id, "threadId": message.thread], "labelIds": Array(message.labels)]],
             "labelsRemoved": [["message": ["id": message.id, "threadId": message.thread], "labelIds": Array(allLabels.subtracting(message.labels))]]] as [String: Any]
        }])
    }

    func modifyThreads(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) -> LabelChangeResult {
        change(ids: mail.filter { ids.contains($0.thread) }.map(\.id), add: addLabelIDs, remove: removeLabelIDs)
        return LabelChangeResult(confirmedHistoryID: Int64(version))
    }

    func trashThreads(ids: [String]) -> LabelChangeResult {
        modifyThreads(ids: ids, addLabelIDs: ["TRASH"], removeLabelIDs: [])
    }

    func untrashThreads(ids: [String]) -> LabelChangeResult {
        modifyThreads(ids: ids, addLabelIDs: [], removeLabelIDs: ["TRASH"])
    }

    func batchModifyMessages(ids: [String], addLabelIDs: [String], removeLabelIDs: [String]) -> LabelChangeResult {
        change(ids: ids, add: addLabelIDs, remove: removeLabelIDs)
        return LabelChangeResult(confirmedHistoryID: Int64(version))
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
        let ageHours = message.ageDays.map { Double($0 * 24) } ?? (message.id == "m2" ? 3 : Double(index))
        return ["id": message.id, "threadId": message.thread, "labelIds": Array(message.labels),
                "historyId": String(message.history), "internalDate": String(Int(referenceDate.addingTimeInterval(-ageHours * 3600).timeIntervalSince1970 * 1000)),
                "snippet": message.id.hasPrefix("list") ? message.text : "Synthetic mail for the UI audit", "payload": payload(message)]
    }

    private func payload(_ message: Message) -> [String: Any] {
        let headers = [["name": "From", "value": message.from], ["name": "To", "value": "audit@example.invalid"], ["name": "Subject", "value": message.subject]]
        let text: [String: Any] = ["mimeType": message.html ? "text/html" : "text/plain", "body": ["data": Data(message.text.utf8).base64EncodedString()]]
        guard let name = message.attachment else { return text.merging(["headers": headers]) { $1 } }
        let file: [String: Any] = [
            "partId": "1", "mimeType": name.hasSuffix(".pdf") ? "application/pdf" : "text/plain", "filename": name,
            "headers": [["name": "Content-Disposition", "value": "attachment; filename=\"\(name)\""]],
            "body": ["attachmentId": "a-\(message.id)", "size": name.hasSuffix(".pdf") ? AttachmentAuditFixtures.invoicePDF.count : Self.attachmentData.count],
        ]
        return ["mimeType": "multipart/mixed", "headers": headers, "parts": [text.merging(["partId": "0"]) { $1 }, file]]
    }

    private func decode<T: Decodable>(_ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
#endif
