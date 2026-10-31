import Testing
@testable import Tern

struct AvatarInitialsTests {
    @Test func namesHeadersAndAddressesGiveTheSameInitials() {
        #expect(AvatarInitials.from(name: "Jane Doe") == "JD")
        #expect(AvatarInitials.from(name: #""Jane Doe" <jane@example.com>"#) == "JD")
        #expect(AvatarInitials.from(name: "jane.doe@example.com") == "JD")
        #expect(AvatarInitials.from(name: " ", address: "jane@example.com") == "JA")
        #expect(AvatarInitials.from(name: "Cher", address: "jane@example.com") == "CH")
        #expect(AvatarInitials.from(name: "", address: "").isEmpty)
    }
}
