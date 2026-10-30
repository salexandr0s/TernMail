import GmailAPI
import MailStore
import Testing
@testable import Tern

@Suite struct TriagePresentationTests {
    @Test func unblockRecognizesOnlyTheSimpleSenderTrashFilter() {
        let blocked = GmailFilter(criteria: .init(from: "Sender@Example.com"), action: .init(addLabelIds: [SystemLabel.trash]))
        #expect(SenderFilterRules.blockedAddress(blocked)?.normalized == "sender@example.com")
        let subjectFilter = GmailFilter(criteria: .init(from: "sender@example.com", subject: "Receipts"), action: blocked.action)
        #expect(SenderFilterRules.blockedAddress(subjectFilter) == nil)
        let labelFilter = GmailFilter(criteria: blocked.criteria, action: .init(addLabelIds: [SystemLabel.trash, "Label_receipts"]))
        #expect(SenderFilterRules.blockedAddress(labelFilter) == nil)
        let compoundSender = GmailFilter(criteria: .init(from: "sender@example.com, another@example.com"), action: blocked.action)
        #expect(SenderFilterRules.blockedAddress(compoundSender) == nil)
    }
}
