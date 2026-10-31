import CoreSpotlight
import Foundation
import MessageContent
import Testing
@testable import Tern

@Suite struct MailSpotlightTests {
    @Test func aConversationItemCarriesSubjectAndAccountButNoAddressesOrBody() throws {
        let conversation = MailSpotlightIndexer.Conversation(
            accountID: "account-1", threadID: "thread-1", subject: "Quarterly plan",
            snippet: "Here is the draft for Thursday",
            senderName: MailSpotlightIndexer.senderName("\"Jane Doe\" <jane@example.com>"),
            lastDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let item = try #require(MailSpotlightIndexer.item(for: conversation))
        let attributes = item.attributeSet
        #expect(item.uniqueIdentifier == MailLink(accountID: "account-1", threadID: "thread-1").ternURL?.absoluteString)
        #expect(item.domainIdentifier == "account-1")
        #expect(attributes.title == "Quarterly plan")
        #expect(attributes.contentDescription == "Here is the draft for Thursday")
        #expect(attributes.authorNames == ["Jane Doe"])
        #expect(attributes.contentModificationDate == conversation.lastDate)
        #expect(attributes.textContent == nil)
        #expect(attributes.htmlContentData == nil)
        #expect(attributes.authors == nil)
        #expect(attributes.authorEmailAddresses == nil)
        #expect(attributes.recipientEmailAddresses == nil)
        #expect(attributes.emailAddresses == nil)
        // Nothing in the stored item names the address, whichever attribute it might hide in.
        let archive = try NSKeyedArchiver.archivedData(withRootObject: item, requiringSecureCoding: true)
        #expect(!String(decoding: archive, as: UTF8.self).contains("jane@example.com"))
    }

    @Test func aSenderWithoutADisplayNameStaysAnonymous() {
        #expect(MailSpotlightIndexer.senderName("jane@example.com") == nil)
        #expect(MailSpotlightIndexer.senderName("\"jane@example.com\" <jane@example.com>") == nil)
        #expect(MailSpotlightIndexer.senderName("Jane Doe <jane@example.com>") == "Jane Doe")
    }
}
