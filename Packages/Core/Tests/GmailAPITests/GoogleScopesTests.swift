import Testing
@testable import GmailAPI

@Suite struct GoogleScopesTests {
    @Test func theRequestAsksForTheBaseScopesThenEachFeatureOnce() {
        #expect(GoogleScopes.request(features: [], isWorkspace: true) == GoogleScopes.base)
        #expect(GoogleScopes.request(features: [.inboxUpdates, .contacts], isWorkspace: false) == GoogleScopes.base + [
            GoogleScopes.contacts, GoogleScopes.otherContacts, GoogleScopes.fullMail,
        ])
        // Only Workspace accounts have a directory.
        #expect(GoogleScopes.request(features: [.contacts], isWorkspace: true) == GoogleScopes.base + [
            GoogleScopes.contacts, GoogleScopes.otherContacts, GoogleScopes.directory,
        ])
    }

    @Test func aGrantFromAnotherAccountOrWithoutMailIsThrownAway() {
        let granted = GoogleScopes.request(features: [.contacts], isWorkspace: false)
        #expect(throws: FeatureGrant.Rejection.otherAccount) {
            try FeatureGrant(subject: "222", granted: granted, accountID: "111", features: [.contacts])
        }
        // The user unticked mail access on the consent screen.
        #expect(throws: FeatureGrant.Rejection.mailAccessNotGranted) {
            try FeatureGrant(
                subject: "111", granted: granted.filter { $0 != GoogleScopes.gmailModify },
                accountID: "111", features: [.contacts]
            )
        }
        // A first sign-in has no account to match.
        #expect(throws: Never.self) {
            try FeatureGrant(subject: "222", granted: granted, accountID: nil, features: [])
        }
    }

    @Test func aPartialGrantLeavesTheFeatureOffAndNamesWhatsMissing() throws {
        let granted = GoogleScopes.base + [GoogleScopes.gmailSettings, GoogleScopes.contacts]
        let grant = try FeatureGrant(subject: "111", granted: granted, accountID: "111", features: [.gmailSettings, .contacts])

        #expect(grant.features == [.gmailSettings])
        #expect(grant.missingScopes == [GoogleScopes.otherContacts])
    }

    @Test func broaderScopesCountAndTheDirectoryIsOptional() throws {
        // Google can answer with the broader scope instead of the one asked for.
        let granted = [
            "openid", "email", GoogleScopes.fullMail,
            "https://www.googleapis.com/auth/contacts", GoogleScopes.otherContacts,
        ]
        let grant = try FeatureGrant(subject: "111", granted: granted, accountID: "111", features: [.contacts, .inboxUpdates])

        #expect(grant.features == [.contacts, .inboxUpdates])
        #expect(grant.missingScopes.isEmpty)
        // Settings' scope isn't implied by full mail access.
        #expect(!GoogleScopes.isCovered(.gmailSettings, by: granted))
    }

    @Test func storedFeaturesKeepOnlyCoveredOnesThisVersionKnows() {
        let granted = GoogleScopes.base + [GoogleScopes.gmailSettings]
        let stored = ["contacts", "someLaterFeature", "gmailSettings"]

        #expect(GoogleScopes.covered(stored, by: granted) == [.gmailSettings])
        #expect(AccountFeature.names(of: [.inboxUpdates, .gmailSettings]) == ["gmailSettings", "inboxUpdates"])
    }
}
