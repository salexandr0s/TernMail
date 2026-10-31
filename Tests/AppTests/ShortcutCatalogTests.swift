import SwiftUI
import Testing
@testable import Tern

@Suite struct ShortcutCatalogTests {
    @Test func noTwoLiveCommandsShareAShortcut() {
        let clashes = ShortcutCatalog.clashes()
        #expect(clashes.isEmpty, "\(clashes.map { "\($0.0.id) and \($0.1.id) both use \($0.0.label)" })")
    }

    @Test func commandIDsAreUnique() {
        let ids = ShortcutCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func helpListsEveryCommandOnce() {
        let listed = ShortcutCatalog.sections.flatMap(\.commands).map(\.id)
        #expect(Set(listed) == Set(ShortcutCatalog.all.map(\.id)))
        #expect(listed.count == ShortcutCatalog.all.count)
        // Menus keep their left-to-right order in Help.
        let menus = ShortcutCatalog.sections.map(\.menu)
        #expect(menus == ShortcutCatalog.Menu.allCases.filter(menus.contains))
    }

    @Test func labelsReadAsMenusDrawThem() {
        #expect(ShortcutCatalog.moveToTrash.label == "⌘⌫")
        #expect(ShortcutCatalog.goToLabel.label == "⌃⌥⌘L")
        #expect(ShortcutCatalog.newLabel.label == "⌃⌘N")
        #expect(ShortcutCatalog.replyAll.label == "⇧⌘R")
        #expect(ShortcutCatalog.mailboxes.first?.label == "⌘1")
    }

    @Test func sameKeysInSeparateScopesDoNotClash() {
        let mail = ShortcutCatalog.Command("test.mail", menu: .message, title: "Mail", key: "x", scopes: [.mail])
        let calendar = ShortcutCatalog.Command("test.calendar", menu: .calendar, title: "Calendar", key: "x",
                                               scopes: [.calendar])
        let everywhere = ShortcutCatalog.Command("test.everywhere", menu: .file, title: "Everywhere", key: "x",
                                                 scopes: ShortcutCatalog.Scope.all)
        #expect(!mail.clashes(with: calendar))
        #expect(mail.clashes(with: everywhere))
        #expect(ShortcutCatalog.clashes(in: [mail, calendar, everywhere]).count == 2)
        // Different modifiers never clash.
        let shifted = ShortcutCatalog.Command("test.shifted", menu: .message, title: "Shifted", key: "x",
                                              modifiers: [.shift, .command], scopes: [.mail])
        #expect(!mail.clashes(with: shifted))
    }

    @Test func newLabelAndNewEventUseDifferentKeys() {
        // The two once shared ⌥⌘N; the catalog keeps them apart.
        #expect(ShortcutCatalog.newLabel.label != ShortcutCatalog.newEvent.label)
    }
}
