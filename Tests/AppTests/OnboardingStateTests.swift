import Foundation
import Testing
@testable import Tern

@MainActor
@Suite struct OnboardingStateTests {
    @Test func firstAccountDoesNotSkipInterruptedSetup() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let initial = OnboardingState(defaults: defaults)
        #expect(!initial.isPresented)
        initial.resolve(hasExistingAccounts: false)
        #expect(initial.isPresented)
        #expect(initial.step == .welcome)
        initial.step = .google

        let afterFirstAccount = OnboardingState(defaults: defaults)
        afterFirstAccount.resolve(hasExistingAccounts: true)
        #expect(afterFirstAccount.isPresented)
        #expect(afterFirstAccount.step == .google)
        afterFirstAccount.step = .preferences

        let resumed = OnboardingState(defaults: defaults)
        resumed.resolve(hasExistingAccounts: true)
        #expect(resumed.isPresented)
        #expect(resumed.step == .preferences)
    }

    @Test func legacyAccountsMigrateWithoutSetupAndStayCompleteAfterSignOut() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = OnboardingState(defaults: defaults)
        existing.resolve(hasExistingAccounts: true)
        #expect(!existing.isPresented)

        let signedOut = OnboardingState(defaults: defaults)
        signedOut.resolve(hasExistingAccounts: false)
        #expect(!signedOut.isPresented)
    }

    @Test func completionRequiresFinalActionAndConnectedAccount() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = OnboardingState(defaults: defaults)
        state.resolve(hasExistingAccounts: false)
        #expect(!state.finish(hasConnectedAccount: true))
        state.step = .ready
        #expect(!state.finish(hasConnectedAccount: false))
        #expect(state.isPresented)

        let stillInProgress = OnboardingState(defaults: defaults)
        stillInProgress.resolve(hasExistingAccounts: true)
        #expect(stillInProgress.isPresented)
        #expect(stillInProgress.step == .ready)
        #expect(stillInProgress.finish(hasConnectedAccount: true))

        let completed = OnboardingState(defaults: defaults)
        completed.resolve(hasExistingAccounts: true)
        #expect(!completed.isPresented)
    }

    @Test func missingAccountReturnsToGoogleWithoutLosingSetup() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = OnboardingState(defaults: defaults)
        state.resolve(hasExistingAccounts: false)
        state.step = .chatGPT
        let resumed = OnboardingState(defaults: defaults)
        resumed.resolve(hasExistingAccounts: false)
        #expect(resumed.isPresented)
        #expect(resumed.step == .google)
        // Repeated account observations cannot dismiss the in-progress flow.
        resumed.resolve(hasExistingAccounts: true)
        #expect(resumed.isPresented)
    }

    @Test func invalidSavedStepRecoversAndAuditStateDoesNotPersist() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unrecognized-step", forKey: OnboardingState.storageKey)
        let state = OnboardingState(defaults: defaults)
        state.resolve(hasExistingAccounts: true)
        #expect(state.isPresented)
        #expect(state.step == .welcome)

        let audit = OnboardingState(defaults: nil)
        audit.resolve(hasExistingAccounts: false)
        audit.step = .ready
        #expect(audit.finish(hasConnectedAccount: true))
        let anotherAudit = OnboardingState(defaults: nil)
        anotherAudit.resolve(hasExistingAccounts: false)
        #expect(anotherAudit.isPresented)
        #expect(defaults.string(forKey: OnboardingState.storageKey) == "welcome")
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "tern.tests.onboarding.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }
}
