import Foundation
import MailStore
import Testing
@testable import Tern

@Suite @MainActor struct FavoritePickerTests {
    @Test func folderChoicesKeepSystemScopeAndLabelOwnership() throws {
        let labels = [
            LabelRecord(accountID: "a", id: SystemLabel.inbox, name: "INBOX", isSystem: true),
            LabelRecord(accountID: "b", id: SystemLabel.inbox, name: "INBOX", isSystem: true),
            LabelRecord(accountID: "b", id: SystemLabel.important, name: "IMPORTANT", isSystem: true),
            LabelRecord(accountID: "a", id: "shared-id", name: "Projects/Hidden", isSystem: false, labelListVisibility: "labelHide"),
            LabelRecord(accountID: "b", id: "shared-id", name: "Other Account", isSystem: false),
            LabelRecord(accountID: "a", id: LabelRules.temporaryPrefix + "pending", name: "Pending", isSystem: false),
        ]
        let unified = FavoriteFolderOption.choices(accountID: nil, labels: labels)
        #expect(unified.filter { $0.target == .mailbox(labelID: SystemLabel.inbox, scope: .allAccounts) }.count == 1)
        #expect(unified.contains { $0.target == .mailbox(labelID: SystemLabel.important, scope: .allAccounts) })
        #expect(!unified.contains { $0.isLabel })

        let account = FavoriteFolderOption.choices(accountID: "a", labels: labels)
        #expect(account.contains { $0.target == .mailbox(labelID: SystemLabel.inbox, scope: .accounts(["a"])) })
        #expect(!account.contains { $0.target == .mailbox(labelID: SystemLabel.important, scope: .accounts(["a"])) })
        let custom = account.filter(\.isLabel)
        #expect(custom.count == 1)
        #expect(custom.first?.title == "Projects/Hidden")
        #expect(custom.first?.target == .label(accountID: "a", labelID: "shared-id"))
        let outbox = try #require(account.first { $0.target == .mailbox(labelID: MailboxModel.outboxID, scope: .accounts(["a"])) })
        #expect(outbox.title == SystemMailbox.outbox.title)
        #expect(outbox.systemImage == SystemMailbox.outbox.systemImage)
    }

    @Test func legacyAccountFolderAliasesMatchWithoutMergingUnifiedOrOtherAccounts() {
        let legacy = MailFavoriteTarget.label(accountID: "a", labelID: SystemLabel.important)
        let account = MailFavoriteTarget.mailbox(labelID: SystemLabel.important, scope: .accounts(["a"]))
        let unified = MailFavoriteTarget.mailbox(labelID: SystemLabel.important, scope: .allAccounts)
        #expect(account.matchesFavorite(legacy))
        #expect(legacy.matchesFavorite(account))
        #expect(!unified.matchesFavorite(legacy))
        #expect(!unified.matchesFavorite(account))
        #expect(!MailFavoriteTarget.mailbox(labelID: SystemLabel.important, scope: .accounts(["b"])).matchesFavorite(legacy))
        #expect(!MailFavoriteTarget.mailbox(labelID: SystemLabel.inbox, scope: .accounts(["a"])).matchesFavorite(legacy))
        #expect(!MailFavoriteTarget.label(accountID: "b", labelID: SystemLabel.important).matchesFavorite(legacy))
    }

    @Test func addingPersistsAndDoesNotDuplicateOrMergeAccountScopes() async throws {
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "a", email: "a@example.invalid", displayName: nil, grantedScopes: [], addedAt: .now))
        let navigation = MailNavigationModel(store: store)
        let target = MailFavoriteTarget.mailbox(labelID: SystemLabel.inbox, scope: .accounts(["a"]))

        #expect(await navigation.addFavorite(target))
        let saved = try await store.mailFavorites()
        #expect(navigation.favorites == saved)
        #expect(saved.contains { $0.target == .mailbox(labelID: SystemLabel.inbox, scope: .allAccounts) })
        #expect(saved.filter { $0.target == target }.count == 1)
        #expect(await navigation.addFavorite(target))
        #expect(try await store.mailFavorites() == saved)

        let label = MailFavoriteTarget.label(accountID: "a", labelID: "custom")
        #expect(await navigation.addFavorite(label))
        #expect(try await store.mailFavorites().last?.target == label)

        let legacy = MailFavoriteTarget.label(accountID: "a", labelID: SystemLabel.important)
        #expect(await navigation.addFavorite(legacy))
        let withLegacy = try await store.mailFavorites()
        #expect(await navigation.addFavorite(.mailbox(labelID: SystemLabel.important, scope: .accounts(["a"]))))
        #expect(try await store.mailFavorites() == withLegacy)
    }

    @Test func failedAddReportsFailureAndPreservesFavoritesForRetry() async throws {
        let store = try AccountStore.inMemory()
        let navigation = MailNavigationModel(store: store)
        let original = navigation.favorites
        #expect(await navigation.addFavorite(.savedSearch(id: "missing")) == false)
        #expect(navigation.error != nil)
        #expect(!navigation.isSaving)
        #expect(navigation.favorites == original)
        #expect(try await store.mailFavorites() == original)

        #expect(await navigation.addFavorite(.mailbox(labelID: SystemLabel.important, scope: .allAccounts)))
        #expect(navigation.error == nil)
        #expect(await MailNavigationModel(store: nil).addFavorite(.mailbox(labelID: SystemLabel.important, scope: .allAccounts)) == false)
    }
}
