import Foundation
import GmailAPI
import GRDB
import Testing
@testable import MailStore

/// Company logos ask a website for an icon only for senders the account
/// knows, so a first-time sender's server doesn't learn when its mail was seen.
@Suite struct SenderFamiliarityTests {
    private static let day: TimeInterval = 24 * 60 * 60
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ownAddressesContactsAndPeopleTheUserWroteToAreKnown() async throws {
        let cache = try MailCache.inMemory()
        try await cache.write { tx in
            try tx.setOwnAddresses(["Me@Home.example"], accountID: "a")
            for (source, resource, address) in [(ContactSource.connection, "people/1", "Saved@Partner.example"),
                                                (.other, "otherContacts/1", "wrote@partner.example")] {
                let people = try JSONDecoder().decode([Person].self, from: Data(
                    #"[{"resourceName":"\#(resource)","emailAddresses":[{"value":"\#(address)"}]}]"#.utf8))
                try tx.applyContactSync(people, source: source, syncToken: nil, fields: "f", isFullSync: true,
                                        now: .now, accountID: "a")
            }
            _ = try tx.upsertMessages([Self.message("sent", from: "me@home.example", to: "To <to@vendor.example>",
                cc: "cc@vendor.example", bcc: "hidden@vendor.example", labels: [SystemLabel.sent])])
        }
        for address in ["me@home.example", "saved@partner.example", " WROTE@partner.example ",
                        "to@vendor.example", "cc@vendor.example", "hidden@vendor.example"] {
            #expect(try await cache.isFamiliarSender(address, accountID: "a"), "\(address)")
            #expect(try await cache.isFamiliarSender(address, accountID: "b") == false, "\(address)")
        }
    }

    @Test func aSenderIsKnownAfterTwoMessagesADayApartOutsideSpamAndTrash() async throws {
        let cache = try MailCache.inMemory()
        let start = Self.start, day = Self.day
        try await cache.write { tx in
            _ = try tx.upsertMessages([
                Self.message("weekly-1", from: "News <news@shop.example>", at: start, labels: [SystemLabel.inbox]),
                Self.message("weekly-2", from: "news@shop.example", at: start.addingTimeInterval(day), labels: []),
                Self.message("once", from: "once@spam.example", at: start, labels: [SystemLabel.inbox]),
                Self.message("burst-1", from: "burst@spam.example", at: start, labels: [SystemLabel.inbox]),
                Self.message("burst-2", from: "burst@spam.example", at: start.addingTimeInterval(day - 1),
                             labels: [SystemLabel.inbox]),
                Self.message("spam-1", from: "promo@spam.example", at: start, labels: [SystemLabel.spam]),
                Self.message("spam-2", from: "promo@spam.example", at: start.addingTimeInterval(7 * day),
                             labels: [SystemLabel.spam]),
                Self.message("mixed-1", from: "mixed@spam.example", at: start, labels: [SystemLabel.spam]),
                Self.message("mixed-2", from: "mixed@spam.example", at: start.addingTimeInterval(2 * day),
                             labels: [SystemLabel.inbox]),
                Self.message("trashed-1", from: "trashed@spam.example", at: start, labels: [SystemLabel.trash]),
                Self.message("trashed-2", from: "trashed@spam.example", at: start.addingTimeInterval(2 * day),
                             labels: [SystemLabel.inbox]),
            ])
        }
        #expect(try await cache.isFamiliarSender("news@shop.example", accountID: "a"))
        // Received mail lists its sender among the message's addresses, which isn't mail sent to them.
        for address in ["once@spam.example", "burst@spam.example", "promo@spam.example",
                        "mixed@spam.example", "trashed@spam.example"] {
            #expect(try await cache.isFamiliarSender(address, accountID: "a") == false, "\(address)")
        }
    }

    /// Avatars ask once each, so a check that scanned the account would run
    /// for every row of a long list.
    @Test func everyCheckSearchesAnIndexOnTheAddress() async throws {
        let cache = try MailCache.inMemory()
        let plans: [[String]] = try await cache.read { tx in
            let received = MailAnalyticsDirection.received.rawValue
            let checks: [(String, StatementArguments)] = [
                (SenderFamiliarity.ownAddress, ["a", "x@y.example"]),
                (SenderFamiliarity.contact, ["a", "x@y.example"]),
                (SenderFamiliarity.firstReceived, ["a", "x@y.example", received]),
                (SenderFamiliarity.receivedSince, ["a", "x@y.example", Self.start, received]),
                (SenderFamiliarity.sentTo, ["a", "x@y.example", MailAnalyticsDirection.sent.rawValue]),
            ]
            return try checks.map { sql, arguments in
                try Row.fetchAll(tx.db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] }
            }
        }
        let expected = [("ownAddress", "address=?"), ("contactEmail_address", "lowercasedAddress=?"),
                        ("mailAnalyticsMessage_sender", "senderAddress=?"), ("mailAnalyticsMessage_sender", "senderAddress=?"),
                        ("mailAnalyticsContact_address", "address=?")]
        #expect(plans.count == expected.count)
        for (steps, (index, column)) in zip(plans, expected) {
            #expect(steps.allSatisfy { $0.hasPrefix("SEARCH ") }, "\(steps)")
            #expect(steps.first.map { $0.contains(index) && $0.contains(column) } == true, "\(steps)")
            #expect(!steps.contains { $0.contains("TEMP B-TREE") }, "\(steps)")
        }
    }

    private static func message(_ id: String, from sender: String, to recipients: String = "me@home.example",
                                cc: String? = nil, bcc: String? = nil, at date: Date = start,
                                labels: [String]) -> CacheTransaction.MessageUpdate {
        CacheTransaction.MessageUpdate(record: MessageRecord(
            accountID: "a", id: id, threadID: id, historyID: 1, date: date, snippet: "", sender: sender,
            recipients: recipients, cc: cc, subject: "", sizeEstimate: 1, bcc: bcc
        ), labelIDs: labels)
    }
}
