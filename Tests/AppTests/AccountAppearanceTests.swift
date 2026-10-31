import Foundation
import MailStore
import Testing
@testable import Tern

@Suite struct AccountAppearanceTests {
    @Test func accountsKeepTheirColorsAsOthersComeAndGo() {
        var indexes = AccountAppearance.colorIndexes(for: ["a", "b", "c"], stored: [:])
        #expect(indexes == ["a": 0, "b": 1, "c": 2])

        // Removing an account leaves the others alone, and the next one
        // takes the color it freed.
        indexes = AccountAppearance.colorIndexes(for: ["a", "c"], stored: indexes)
        #expect(indexes == ["a": 0, "c": 2])
        indexes = AccountAppearance.colorIndexes(for: ["d", "a", "c"], stored: indexes)
        #expect(indexes == ["a": 0, "c": 2, "d": 1])

        // A stored index the palette no longer has is assigned again.
        #expect(AccountAppearance.colorIndexes(for: ["a"], stored: ["a": 99]) == ["a": 0])
    }

    @Test func colorsRepeatOnlyOnceThePaletteIsUsedUp() {
        let ids = (0...AccountAppearance.palette.count).map { "account\($0)" }
        let indexes = AccountAppearance.colorIndexes(for: ids, stored: [:])
        #expect(Set(ids.dropLast().compactMap { indexes[$0] }) == Set(AccountAppearance.palette.indices))
        #expect(indexes[ids[ids.count - 1]] == 0)
    }

    @Test func shortNamesUseTheWholeAddressWhenNamesMatch() {
        let accounts = [
            account("1", "sam@example.com"),
            account("2", "Sam@example.org"),
            account("3", "lee@example.com"),
        ]
        #expect(AccountAppearance.shortNames(accounts) == [
            "1": "sam@example.com", "2": "Sam@example.org", "3": "lee",
        ])
    }

    @Test func sidebarNamesPreferNicknamesThenNamesNoOtherAccountShares() {
        let accounts = [
            account("1", "sam@example.com", name: "Sam Lee"),
            account("2", "sam.lee@work.example", name: "sam lee"),
            account("3", "lee@example.com", name: " "),
            account("4", "kim@example.com", name: "Kim Park"),
            account("5", "kim.park@home.example", name: "Kim Park"),
        ]
        // A shared name falls back to the address, and a nickname frees the name it replaces.
        #expect(SidebarAccountNames.names(for: accounts, nicknames: ["4": "", "5": " Home "]) == [
            "1": "sam", "2": "sam.lee", "3": "lee", "4": "Kim Park", "5": "Home",
        ])
    }

    private func account(_ id: String, _ email: String, name: String? = nil) -> AccountRecord {
        AccountRecord(id: id, email: email, displayName: name, grantedScopes: [], addedAt: .now)
    }
}
