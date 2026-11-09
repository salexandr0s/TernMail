import Foundation
import GRDB

extension MailCache {
    /// Whether the account already knows `address`. Company logos ask a
    /// sender's website for an icon only when this is true
    /// (`docs/domain-logos.md`). A sender is known when any of these holds:
    ///
    /// - It is one of the account's own addresses.
    /// - It is in the account's contacts, saved or "other contacts" (people
    ///   the user has written to).
    /// - The account has sent it mail, in To, Cc or Bcc.
    /// - It has sent the account two messages at least 24 hours apart, both
    ///   outside Spam, Trash and Drafts.
    ///
    /// Anyone else is a first-time sender, including a sender whose mail all
    /// arrived within one day. The rule matches whole addresses because the
    /// cache indexes addresses, not domains, so a known address doesn't vouch
    /// for others at its domain. It reads the analytics tables, which keep a
    /// message's addresses and labels after the message leaves the cache.
    public func isFamiliarSender(_ address: String, accountID: String) async throws -> Bool {
        try await read { try $0.isFamiliarSender(address, accountID: accountID) }
    }
}

extension CacheTransaction {
    /// See `MailCache.isFamiliarSender(_:accountID:)`. Each check is an index
    /// lookup on the address, and the cheapest run first.
    func isFamiliarSender(_ address: String, accountID: String) throws -> Bool {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { return false }
        if try hasRow(SenderFamiliarity.ownAddress, [accountID, address])
            || hasRow(SenderFamiliarity.contact, [accountID, address]) { return true }
        let received = MailAnalyticsDirection.received.rawValue
        if let first = try Date.fetchOne(db, sql: SenderFamiliarity.firstReceived, arguments: [accountID, address, received]),
           try hasRow(SenderFamiliarity.receivedSince,
                      [accountID, address, first.addingTimeInterval(SenderFamiliarity.repeatInterval), received]) {
            return true
        }
        return try hasRow(SenderFamiliarity.sentTo, [accountID, address, MailAnalyticsDirection.sent.rawValue])
    }

    private func hasRow(_ sql: String, _ arguments: StatementArguments) throws -> Bool {
        try Row.fetchOne(db, sql: sql, arguments: arguments) != nil
    }
}

/// The statements behind `isFamiliarSender`. `SenderFamiliarityTests` checks
/// that each one searches an index.
enum SenderFamiliarity {
    /// How far apart two messages have to be to make their sender known.
    static let repeatInterval: TimeInterval = 24 * 60 * 60

    static let ownAddress = "SELECT 1 FROM ownAddress WHERE accountID = ? AND address = ? LIMIT 1"

    static let contact = "SELECT 1 FROM contactEmail WHERE accountID = ? AND lowercasedAddress = ? LIMIT 1"

    // `+isIncluded` keeps SQLite on the sender index. `mailAnalyticsMessage_date`
    // matches as many terms and would walk every included message in the account.
    static let firstReceived = """
        SELECT date FROM mailAnalyticsMessage
        WHERE accountID = ? AND senderAddress = ? AND direction = ? AND +isIncluded = 1
        ORDER BY date LIMIT 1
        """

    static let receivedSince = """
        SELECT 1 FROM mailAnalyticsMessage
        WHERE accountID = ? AND senderAddress = ? AND date >= ? AND direction = ? AND +isIncluded = 1
        LIMIT 1
        """

    /// Sent mail lists its recipients in `mailAnalyticsContact`; received mail lists its sender there.
    static let sentTo = """
        SELECT 1 FROM mailAnalyticsContact c
        JOIN mailAnalyticsMessage m ON m.accountID = c.accountID AND m.messageID = c.messageID
        WHERE c.accountID = ? AND c.address = ? AND m.direction = ?
        LIMIT 1
        """
}
