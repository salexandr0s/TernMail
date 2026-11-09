import Testing
@testable import Tern

/// Saved Keychain items are looked up by these names.
@Suite struct AppIdentityTests {
    @Test func shippingAppKeepsItsKeychainNames() {
        #expect(AppIdentity.keychainService(.oauth, bundleIdentifier: "dev.tern.mail") == "dev.tern.mail.oauth")
        #expect(AppIdentity.keychainService(.chatGPT, bundleIdentifier: "dev.tern.mail") == "dev.tern.mail.chatgpt")
        #expect(AppIdentity.keychainService(.apiKey, bundleIdentifier: "dev.tern.mail") == "dev.tern.mail.ai-api-key")
    }

    @Test func anotherBundleIDGetsItsOwnNames() {
        #expect(AppIdentity.keychainService(.oauth, bundleIdentifier: "dev.tern.mail.testing")
            == "dev.tern.mail.testing.oauth")
    }
}
