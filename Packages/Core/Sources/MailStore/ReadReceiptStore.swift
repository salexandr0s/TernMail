import Foundation
import GRDB
import MessageContent

extension MailCache {
    public func readReceiptStatus(accountID: String, rfcMessageID: String) async throws -> ReadReceiptStatus? {
        try await read { try $0.readReceiptStatus(accountID: accountID, rfcMessageID: rfcMessageID) }
    }

    public func observeReadReceiptStatus(accountID: String, rfcMessageID: String)
        -> AsyncThrowingStream<ReadReceiptStatus?, any Error> {
        observe { try CacheTransaction(db: $0).readReceiptStatus(accountID: accountID, rfcMessageID: rfcMessageID) }
    }

    public func readReceiptStatuses(accountID: String, recipient: String? = nil, limit: Int = 50) async throws -> [ReadReceiptStatus] {
        try await read { try $0.readReceiptStatuses(accountID: accountID, recipient: recipient, limit: limit) }
    }

    public func observeReadReceiptStatuses(accountID: String, recipient: String? = nil, limit: Int = 50)
        -> AsyncThrowingStream<[ReadReceiptStatus], any Error> {
        observe { try CacheTransaction(db: $0).readReceiptStatuses(accountID: accountID, recipient: recipient, limit: limit) }
    }
}

extension CacheTransaction {
    /// Called only after Gmail accepted the send, including lost-response
    /// reconciliation, inside the transaction that removes the local draft.
    public func recordReadReceiptRequest(for draft: LocalDraft, senderAddress: String,
                                         messageID: String?, threadID: String?, sentAt: Date) throws {
        let sender = EmailAddress(address: senderAddress)
        guard draft.requestsReadReceipt, sender.isValid, ReadReceiptParser.validMessageID(draft.rfcMessageID),
              sentAt.timeIntervalSince1970.isFinite else { return }
        let recipients = Set((draft.to + draft.cc + draft.bcc).filter(\.isValid).map(\.normalized)).sorted()
        guard !recipients.isEmpty else { return }
        try db.execute(sql: """
            INSERT INTO readReceiptRequest (accountID,rfcMessageID,senderAddress,subject,messageID,threadID,sentAt)
            VALUES (?,?,?,?,?,?,?) ON CONFLICT(accountID,rfcMessageID) DO UPDATE SET
            messageID=COALESCE(excluded.messageID,readReceiptRequest.messageID),
            threadID=COALESCE(excluded.threadID,readReceiptRequest.threadID)
            """, arguments: [draft.accountID, draft.rfcMessageID, sender.normalized, draft.subject, messageID, threadID, sentAt])
        for address in recipients {
            try db.execute(sql: "INSERT OR IGNORE INTO readReceiptRecipient (accountID,rfcMessageID,address) VALUES (?,?,?)",
                arguments: [draft.accountID, draft.rfcMessageID, address])
        }
    }

    /// Events may arrive before a lost send response is reconciled. Keeping
    /// them separately lets the matching query join them once the request exists.
    public func storeReadReceipt(_ receipt: ReadReceipt, accountID: String, receiptMessageID: String,
                                 reporter: String, returnAddresses: [String], receivedAt: Date) throws {
        let source = EmailAddress(address: reporter)
        let recipient = EmailAddress(address: receipt.recipient)
        let addresses = Set(returnAddresses.map { EmailAddress(address: $0) }.filter(\.isValid).map(\.normalized)).sorted()
        guard !accountID.isEmpty, !receiptMessageID.isEmpty, source.isValid, recipient.isValid,
              source.normalized == recipient.normalized, !addresses.isEmpty,
              ReadReceiptParser.validMessageID(receipt.originalMessageID), receivedAt.timeIntervalSince1970.isFinite else { return }
        let encodedAddresses = String(decoding: try JSONEncoder().encode(addresses), as: UTF8.self)
        try db.execute(sql: """
            INSERT OR IGNORE INTO readReceiptEvent
            (accountID,receiptMessageID,rfcMessageID,recipient,reporter,disposition,receivedAt,returnAddresses)
            VALUES (?,?,?,?,?,?,?,?)
            """, arguments: [accountID, receiptMessageID, receipt.originalMessageID, recipient.normalized,
                source.normalized, receipt.disposition.rawValue, receivedAt, encodedAddresses])
    }

    public func hasReadReceiptEvent(accountID: String, receiptMessageID: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM readReceiptEvent WHERE accountID=? AND receiptMessageID=?)",
            arguments: [accountID, receiptMessageID]) ?? false
    }

    public func readReceiptStatuses(accountID: String, recipient: String? = nil, limit: Int = 50) throws -> [ReadReceiptStatus] {
        try readReceiptStatuses(accountID: accountID, recipient: recipient, rfcMessageID: nil, limit: limit)
    }

    public func readReceiptStatus(accountID: String, rfcMessageID: String) throws -> ReadReceiptStatus? {
        try readReceiptStatuses(accountID: accountID, recipient: nil, rfcMessageID: rfcMessageID, limit: 1).first
    }

    private func readReceiptStatuses(accountID: String, recipient: String?, rfcMessageID: String?, limit: Int) throws -> [ReadReceiptStatus] {
        var sql = "SELECT q.* FROM readReceiptRequest q WHERE q.accountID = ?"
        var args: StatementArguments = [accountID]
        if let recipient {
            sql += " AND EXISTS(SELECT 1 FROM readReceiptRecipient r WHERE r.accountID=q.accountID AND r.rfcMessageID=q.rfcMessageID AND r.address=?)"
            args += [EmailAddress(address: recipient).normalized]
        }
        if let rfcMessageID {
            sql += " AND q.rfcMessageID=?"
            args += [rfcMessageID]
        }
        sql += " ORDER BY q.sentAt DESC,q.rfcMessageID LIMIT ?"
        args += [max(0, min(limit, 500))]
        return try Row.fetchAll(db, sql: sql, arguments: args).map { request in
            let rfcMessageID: String = request["rfcMessageID"]
            let rows = try Row.fetchAll(db, sql: """
                SELECT r.address,MIN(e.receivedAt) AS receivedAt
                FROM readReceiptRecipient r
                JOIN readReceiptRequest q ON q.accountID=r.accountID AND q.rfcMessageID=r.rfcMessageID
                LEFT JOIN readReceiptEvent e ON e.accountID=r.accountID AND e.rfcMessageID=r.rfcMessageID
                    AND e.recipient=r.address AND e.reporter=r.address AND e.disposition='displayed'
                    AND EXISTS(SELECT 1 FROM json_each(e.returnAddresses) WHERE value=q.senderAddress)
                WHERE r.accountID=? AND r.rfcMessageID=? GROUP BY r.address ORDER BY r.address
                """, arguments: [accountID, rfcMessageID])
            return ReadReceiptStatus(accountID: accountID, rfcMessageID: rfcMessageID, messageID: request["messageID"],
                threadID: request["threadID"], subject: request["subject"], sentAt: request["sentAt"],
                recipients: rows.map { ReadReceiptRecipientStatus(address: $0["address"], receivedAt: $0["receivedAt"]) })
        }
    }

    public func deleteReadReceiptData(accountID: String) throws {
        try db.execute(sql: "DELETE FROM readReceiptPending WHERE accountID=?", arguments: [accountID])
        try db.execute(sql: "DELETE FROM readReceiptEvent WHERE accountID=?", arguments: [accountID])
        try db.execute(sql: "DELETE FROM readReceiptRequest WHERE accountID=?", arguments: [accountID])
    }

    public func queueReadReceipt(messageID: String, accountID: String) throws {
        guard !messageID.isEmpty, try !hasReadReceiptEvent(accountID: accountID, receiptMessageID: messageID) else { return }
        try db.execute(sql: "INSERT OR IGNORE INTO readReceiptPending (accountID,messageID) VALUES (?,?)", arguments: [accountID, messageID])
    }

    /// Fair rotation keeps a failed report from starving newer candidates.
    public func pendingReadReceiptIDs(accountID: String, attemptedAt: Date, limit: Int = 25) throws -> [String] {
        let ids = try String.fetchAll(db, sql: """
            SELECT messageID FROM readReceiptPending WHERE accountID=?
            ORDER BY lastAttemptAt,messageID LIMIT ?
            """, arguments: [accountID, max(0, min(limit, 25))])
        for id in ids {
            try db.execute(sql: "UPDATE readReceiptPending SET lastAttemptAt=? WHERE accountID=? AND messageID=?",
                arguments: [attemptedAt, accountID, id])
        }
        return ids
    }

    public func finishReadReceipt(messageID: String, accountID: String) throws {
        try db.execute(sql: "DELETE FROM readReceiptPending WHERE accountID=? AND messageID=?", arguments: [accountID, messageID])
    }
}
