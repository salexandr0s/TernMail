import Foundation
import MailStore
import Testing
@testable import Tern

@MainActor
@Suite struct LabelAppearanceTests {
    @Test func iconsPersistByAccountAndIDAcrossRenames() throws {
        let suite = "LabelAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = LabelAppearance(defaults: defaults)
        let label = label("Label_1", accountID: "a", name: "Trips")
        appearance.setIcon("airplane", labelID: label.id, accountID: label.accountID)

        let restored = LabelAppearance(defaults: defaults)
        #expect(restored.icon(for: label) == "airplane")
        #expect(restored.icon(for: self.label("Label_1", accountID: "a", name: "Travel")) == "airplane")
        #expect(restored.icon(for: self.label("Label_1", accountID: "b", name: "Trips")) == "tag")
        #expect(restored.icon(for: self.label("Label_2", accountID: "a", name: "Trips")) == "tag")

        restored.setIcon("not.a.symbol", labelID: label.id, accountID: label.accountID)
        #expect(restored.icon(for: label) == "airplane")
        restored.setIcon("tag", labelID: label.id, accountID: label.accountID)
        #expect(LabelAppearance(defaults: defaults).icon(for: label) == "tag")
    }

    @Test func aCreatedLabelsIconFollowsItsDurableAliasAndLatestEdit() async throws {
        let suite = "LabelAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = try MailCache.inMemory()
        let temporaryID = LabelRules.temporaryID()
        let appearance = LabelAppearance(defaults: defaults)
        appearance.setIcon("briefcase", labelID: temporaryID, accountID: "a")
        await appearance.reconcile(using: cache)
        #expect(appearance.icon(for: label(temporaryID, accountID: "a")) == "briefcase")

        try await cache.write { tx in
            _ = try tx.recordCreatedLabel(temporaryID: temporaryID, realID: "Label_7", accountID: "a")
        }
        let restored = LabelAppearance(defaults: defaults)
        await restored.reconcile(using: cache)
        #expect(restored.icon(for: label("Label_7", accountID: "a")) == "briefcase")
        #expect(LabelAppearance(defaults: defaults).icon(for: label("Label_7", accountID: "a")) == "briefcase")
        #expect(restored.icon(for: label("Label_7", accountID: "b")) == "tag")

        // A sheet opened before the ID changed can still save through that ID.
        restored.setIcon("heart", labelID: temporaryID, accountID: "a")
        await restored.reconcile(using: cache)
        #expect(restored.icon(for: label("Label_7", accountID: "a")) == "heart")
        // A later choice through the permanent ID must win over pending migration.
        restored.setIcon("star", labelID: temporaryID, accountID: "a")
        restored.setIcon("tag", labelID: "Label_7", accountID: "a")
        await restored.reconcile(using: cache)
        #expect(restored.icon(for: label("Label_7", accountID: "a")) == "tag")
    }

    @Test func accountStartupMigratesIconsBeforeTheEngineClearsAliases() async throws {
        let accountID = UUID().uuidString
        let account = AccountRecord(
            id: accountID, email: "audit@example.invalid", displayName: nil,
            grantedScopes: [], addedAt: .now
        )
        let cache = try MailCache.inMemory()
        let temporaryID = LabelRules.temporaryID()
        LabelAppearance.shared.setIcon("leaf", labelID: temporaryID, accountID: accountID)
        try await cache.write { tx in
            _ = try tx.recordCreatedLabel(temporaryID: temporaryID, realID: "Label_1", accountID: accountID)
        }
        let mailbox = AccountMailbox(
            account: account, cache: cache, gmail: AuditGmail(),
            outgoingDirectory: FileManager.default.temporaryDirectory, snoozeStore: nil
        )
        await mailbox.start()
        #expect(LabelAppearance.shared.icon(for: label("Label_1", accountID: accountID)) == "leaf")
        let cleared = try await cache.read { tx in
            try tx.resolvedLabelID(temporaryID, accountID: accountID)
        }
        #expect(cleared == temporaryID)
        await mailbox.stop()
    }

    private func label(_ id: String, accountID: String, name: String = "Work") -> LabelRecord {
        LabelRecord(accountID: accountID, id: id, name: name, isSystem: false)
    }
}
