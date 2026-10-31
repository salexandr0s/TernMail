import Testing
@testable import Tern

@Suite struct MessagePrefetchTests {
    @Test func lookaheadUsesDisplayedOrderAndKeepsAccountIdentity() {
        let rows = (0..<10).map { MailListRowID(accountID: "a", threadID: "t\($0)") }
        let nearby = MessagePrefetchPlan.candidates(rows: rows, selected: [rows[4]])
        #expect(nearby == [rows[5], rows[6], rows[3], rows[7]].map(\.threadKey))
        #expect(MessagePrefetchPlan.candidates(rows: rows, selected: []) == Array(rows.prefix(4)).map(\.threadKey))

        let otherAccount = MailListRowID(accountID: "b", threadID: rows[0].threadID)
        let sibling = MailListRowID(accountID: "a", threadID: rows[0].threadID, messageID: "sibling")
        #expect(MessagePrefetchPlan.candidates(rows: [rows[0], sibling, otherAccount, rows[1]], selected: [rows[0]])
            == [otherAccount.threadKey, rows[1].threadKey])
        #expect(MessagePrefetchPlan.candidates(rows: [rows[0]], selected: [rows[0]]).isEmpty)
    }
}
