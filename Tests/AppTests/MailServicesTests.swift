import MessageContent
import Testing
@testable import Tern

/// New Tern Message to Address turns a text selection into To addresses.
@Suite struct MailServicesTests {
    @Test func oneAddressGoesInTo() throws {
        let request = try #require(MailServices.addressRequest(from: " pat@example.com\n"))
        #expect(request.to == [EmailAddress(address: "pat@example.com")])
        #expect(request.body.isEmpty)
    }

    @Test func addressesSplitOnCommasAndNewLines() throws {
        let text = "Pat Lee <pat@example.com>, team@example.org\nsam@example.net\r\nTEAM@example.org"
        let request = try #require(MailServices.addressRequest(from: text))
        #expect(request.to == [
            EmailAddress(name: "Pat Lee", address: "pat@example.com"),
            EmailAddress(address: "team@example.org"),
            EmailAddress(address: "sam@example.net"),
        ])
    }

    @Test(arguments: ["", " \n ", "see you at noon", "pat at example dot com", "@example.com, pat@"])
    func junkStartsNoDraft(_ text: String) {
        #expect(MailServices.addressRequest(from: text) == nil)
    }
}
