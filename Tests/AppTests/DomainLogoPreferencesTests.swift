import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import Tern

@MainActor @Suite struct DomainLogoPreferencesTests {
    @Test func unsetPreferenceMakesNoWebsiteRequestAndExplicitChoicesArePreserved() async throws {
        let suite = "Tern.LogoPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = Mutex<[String]>([])
        let model = AddressAvatarModel(logoLoader: { address in
            requests.withLock { $0.append(address) }
            return nil
        })
        defer { model.stop() }
        let unset = AppStorage(wrappedValue: DomainLogoPreferences.defaultEnabled,
            DomainLogoPreferences.key, store: defaults)
        model.configure(address: "sender@company.com", accountID: nil, context: .empty, showsLogos: unset.wrappedValue)
        #expect(!unset.wrappedValue)
        await Task.yield()
        #expect(requests.withLock { $0.isEmpty })

        defaults.set(true, forKey: DomainLogoPreferences.key)
        let optedIn = AppStorage(wrappedValue: DomainLogoPreferences.defaultEnabled,
            DomainLogoPreferences.key, store: defaults)
        #expect(optedIn.wrappedValue)
        model.configure(address: "sender@company.com", accountID: nil, context: .empty, showsLogos: optedIn.wrappedValue)
        let deadline = ContinuousClock.now + .seconds(3)
        while requests.withLock({ $0.isEmpty }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(requests.withLock { $0 } == ["sender@company.com"])

        defaults.set(false, forKey: DomainLogoPreferences.key)
        let optedOut = AppStorage(wrappedValue: DomainLogoPreferences.defaultEnabled,
            DomainLogoPreferences.key, store: defaults)
        #expect(!optedOut.wrappedValue)
    }
}
