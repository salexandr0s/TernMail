import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import Tern

@Suite @MainActor struct SettingsEditorTests {
    @Test func liveSettingsPermissionChangesWithoutRebuildingTheAccount() async throws {
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "account", email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: .now))
        let state = SettingsAccountState(accountID: "account", store: store)
        let observation = Task { await state.observe() }
        defer { observation.cancel() }
        try await eventually { state.account != nil }
        #expect(!state.isEnabled(.gmailSettings))
        try await store.updateAccount(id: "account") { $0.enabledFeatures = [AccountFeature.gmailSettings.rawValue] }
        try await eventually { state.isEnabled(.gmailSettings) }
        try await store.updateAccount(id: "account") { $0.enabledFeatures = [] }
        try await eventually { !state.isEnabled(.gmailSettings) }
        try await store.deleteAccount(id: "account")
        try await eventually { state.account == nil }
    }

    @Test func queueOverlayAppliesOfflineAndUndoRestoresServerSnapshot() async throws {
        let cache = try MailCache.inMemory()
        let original = GmailFilter(id: "old", criteria: .init(from: "sender@example.com"), action: .init(addLabelIds: ["STARRED"]))
        let edited = GmailFilter(criteria: original.criteria, action: .init(addLabelIds: ["TRASH"]))
        let identity = IdentityRecord(accountID: "account", address: "me@example.com", signatureHTML: "<b>Old</b>", isPrimary: true, fetchedAt: .now)
        let originalVacation = VacationSettings(responseSubject: "Old subject", responseBodyPlainText: "Old body")
        let changedVacation = VacationSettings(responseSubject: "New subject", responseBodyPlainText: "Other body's edit")
        let server = SettingsSnapshot(filters: [original], identities: [identity], vacation: originalVacation)
        let changes = try await cache.write { tx in
            [try tx.enqueueSettingsChange(.replaceFilter(oldID: "old", old: original, new: edited, listedIDs: nil, newID: nil), accountID: "account", now: .now, notBefore: .now),
             try tx.enqueueSettingsChange(.signature(address: "me@example.com", html: "<i>New</i>", previousHTML: "<b>Old</b>"), accountID: "account", now: .now, notBefore: .now),
             try tx.enqueueSettingsChange(.vacation(fields: [.subject], new: changedVacation, previous: originalVacation), accountID: "account", now: .now, notBefore: .now)]
        }
        let pending = server.applying(changes)
        #expect(pending.filters == [edited])
        #expect(pending.identities.first?.signatureHTML == "<i>New</i>")
        #expect(pending.vacation.responseSubject == "New subject")
        #expect(pending.vacation.responseBodyPlainText == "Old body")
        #expect(server.applying([]) == server)
        #expect(server.applying(changes) == pending)
    }

    @Test func filterEditPreservesUnsupportedLabelActions() {
        let label = LabelRecord(accountID: "account", id: "Label_work", name: "Work", isSystem: false)
        let original = GmailFilter(id: "filter", criteria: .init(from: "sender@example.com"),
            action: .init(addLabelIds: ["Label_work", "CATEGORY_PROMOTIONS", "FUTURE_LABEL"], removeLabelIds: ["CHAT", "INBOX"]))
        var draft = FilterEditorDraft(filter: original, labels: [label])
        draft.subject = "Planning"
        draft.skipInbox = false
        let edited = draft.filter()
        #expect(Set(edited.action.addLabelIds ?? []) == ["Label_work", "CATEGORY_PROMOTIONS", "FUTURE_LABEL"])
        #expect(edited.action.removeLabelIds == ["CHAT"])
        #expect(edited.criteria.subject == "Planning")
    }

    @Test func unverifiedForwardCannotBeSavedAndCaseInsensitiveVerifiedForwardCan() {
        let original = GmailFilter(criteria: .init(from: "sender@example.com"), action: .init(forward: "pending@example.com"))
        var draft = FilterEditorDraft(filter: original, labels: [])
        #expect(draft.validation(acceptedForwarding: ["verified@example.com"]) != nil)
        draft.forward = "VERIFIED@example.com"
        #expect(draft.validation(acceptedForwarding: ["verified@example.com"]) == nil)
        draft.forward = ""
        draft.markRead = true
        #expect(draft.validation(acceptedForwarding: []) == nil)
        #expect(draft.filter().action.forward == nil)
    }

    @Test func sizeAndEmptyFilterValidationPreventInvalidWrites() {
        var draft = FilterEditorDraft(filter: nil, labels: [])
        draft.markRead = true
        #expect(draft.validation(acceptedForwarding: []) != nil)
        draft.hasAttachment = true
        draft.sizeText = "-10"
        #expect(draft.validation(acceptedForwarding: []) != nil)
        draft.sizeText = "1000"
        #expect(draft.validation(acceptedForwarding: []) == nil)
        #expect(draft.filter().criteria.size == 1000)
        #expect(draft.filter().criteria.sizeComparison == .larger)
    }

    @Test func unsupportedVacationHTMLRemainsReadOnlyAndByteForByteUnchanged() {
        let html = "<table><tr><td><b>Away</b></td></tr></table>"
        let draft = SettingsMessageDraft(html: html, plainText: "Away")
        #expect(draft.isReadOnly)
        draft.document = ComposeDocument(plainText: "replacement")
        #expect(!draft.changed)
        #expect(draft.savedHTML == html)
        #expect(draft.savedPlainText == "Away")
    }

    @Test func editedVacationBodyHasMatchingHTMLAndPlainTextAndUntouchedHTMLStaysIntact() {
        let original = "<div><b>Away</b></div>"
        let draft = SettingsMessageDraft(html: original, plainText: "Away")
        #expect(!draft.isReadOnly)
        #expect(draft.savedHTML == original)
        draft.document = ComposeDocument(blocks: [.init(runs: [.init("Back Monday", bold: true)])])
        #expect(draft.savedHTML?.contains("<b>Back Monday</b>") == true)
        #expect(draft.savedPlainText == "Back Monday")
    }

    @Test func panesSavedBeforeTheSignatureMergeMoveOnce() throws {
        // The pane saved by an older version, then the pane and source it becomes.
        let cases = [("localSignatures", "signatures", "local"),
                     ("signatures", "signatures", "gmail"),
                     ("connections", "connections", "local")]
        for (saved, pane, source) in cases {
            let suite = "SettingsEditorTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(saved, forKey: SettingsDestination.storageKey)
            SettingsDestination.migrateSavedPane(in: defaults)
            #expect(defaults.string(forKey: SettingsDestination.storageKey) == pane)
            #expect(defaults.string(forKey: SignatureSource.storageKey) == source)
            // From then on "signatures" is the merged pane, which keeps its source.
            defaults.set("signatures", forKey: SettingsDestination.storageKey)
            SettingsDestination.migrateSavedPane(in: defaults)
            #expect(defaults.string(forKey: SignatureSource.storageKey) == source)
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
}
