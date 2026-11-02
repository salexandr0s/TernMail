import AppKit
import MailStore
import SwiftUI
import Testing
@testable import Tern

@Suite(.serialized) @MainActor struct FavoritesInteractionTests {
    @Test func sidebarRowsKeepOneSelectionAcrossDisclosureAndDuplicateDestinations() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let suite = "SidebarSelectionInteractionTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set("", forKey: SidebarExpansion.storageKey)
        settings.set(false, forKey: "sidebarFavoritesCollapsed")
        defer { settings.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: SidebarView(mailbox: mailbox)
            .environment(app).defaultAppStorage(settings))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Tokens.Layout.sidebarMaxWidth, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: Tokens.Layout.sidebarMaxWidth, height: 800))
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil }

        do {
            try await eventually("Synthetic accounts and labels must finish loading") {
                mailbox.hasSyncedOnce && mailbox.presentedAccounts.count == 2
                    && mailbox.presentedAccounts.allSatisfy { !$0.labels.isEmpty }
            }
            try await settle()
            let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
            mailbox.selectedMailbox = .combined(SystemLabel.starred)
            try await settle()
            let inboxRow = try #require(nativeRows(label: "Inbox", in: table).first)
            let rowCount = table.numberOfRows
            try await selectSidebarRow(row: inboxRow, in: table)
            try await eventually("Selecting Inbox must update the destination and native selected row") {
                mailbox.selectedMailbox == .combined(SystemLabel.inbox)
                    && table.selectedRowIndexes == IndexSet(integer: inboxRow)
            }
            #expect(settings.string(forKey: SidebarExpansion.storageKey) == "")
            #expect(table.numberOfRows == rowCount, "Selecting a mailbox must not expand accounts")

            for (name, expanded) in [("Show Accounts", true), ("Hide Accounts", false)] {
                let nodes = elements(in: controller.view)
                let candidate = nodes.first {
                    $0.accessibilityLabel() == "Inbox" && $0.customActions.contains { $0.name == name }
                }
                if candidate == nil {
                    for node in nodes where node.accessibilityLabel()?.contains("Inbox") == true {
                        print("Sidebar Inbox AX: role=\(node.accessibilityRole()?.rawValue ?? "nil"), label=\(String(reflecting: node.accessibilityLabel())), actions=\(node.customActions.map(\.name))")
                    }
                }
                let inbox = try #require(candidate, "Inbox must expose the named \(name) action")
                try performAction(name, on: inbox)
                try await eventually("\(name) must update account disclosure") {
                    (settings.string(forKey: SidebarExpansion.storageKey)?.contains(SystemLabel.inbox) == true) == expanded
                        && (expanded ? table.numberOfRows > rowCount : table.numberOfRows == rowCount)
                        && self.elements(in: controller.view).contains {
                            $0.accessibilityLabel() == "Inbox"
                                && $0.customActions.contains { $0.name == (expanded ? "Hide Accounts" : "Show Accounts") }
                        }
                }
                #expect(mailbox.selectedMailbox == .combined(SystemLabel.inbox))
                #expect(table.selectedRowIndexes == IndexSet(integer: inboxRow))
            }

            let owner = try #require(mailbox.presentedAccounts.first { $0.account.id == "ui-audit" })
            let label = try #require(owner.labels.first { !$0.isSystem && !$0.name.contains("/") })
            let destination = MailboxID.account(owner.account.id, label.id)
            try #require(await mailbox.navigation.addFavorite(.label(accountID: owner.account.id, labelID: label.id)))
            try await eventually("The label must appear in both Favorites and its account section") {
                self.nativeRows(label: label.name, in: table).count == 2
            }
            let copies = nativeRows(label: label.name, in: table)
            for row in copies.reversed() {
                try await selectSidebarRow(row: row, in: table)
                try await eventually("Selecting label occurrence \(row) must update the destination") {
                    mailbox.selectedMailbox == destination && table.selectedRowIndexes == IndexSet(integer: row)
                }
                try await settle()
                #expect(table.selectedRowIndexes == IndexSet(integer: row), "The chosen occurrence must retain its highlight")
            }

            let expandedFavoritesRowCount = table.numberOfRows
            try performHeaderAction("Collapse Favorites", in: controller.view)
            try await eventually("Collapse Favorites must hide the selected section") {
                settings.bool(forKey: "sidebarFavoritesCollapsed") && table.numberOfRows < expandedFavoritesRowCount
                    && self.element(id: "favorites.header", in: controller.view)?.accessibilityValue() == "Collapsed"
            }
            #expect(mailbox.selectedMailbox == destination, "Collapsing the selected section must preserve the destination")
            try performHeaderAction("Expand Favorites", in: controller.view)
            try await eventually("Reopening Favorites must restore the selected occurrence") {
                !settings.bool(forKey: "sidebarFavoritesCollapsed")
                    && table.selectedRowIndexes == IndexSet(integer: copies[0])
                    && table.numberOfRows == expandedFavoritesRowCount
                    && self.element(id: "favorites.header", in: controller.view)?.accessibilityValue() == "Expanded"
            }
            #expect(mailbox.selectedMailbox == destination)

            mailbox.selectedMailbox = .combined(SystemLabel.starred)
            try await settle()
            try performHeaderAction("Collapse Favorites", in: controller.view)
            try await eventually("Favorites must be collapsed before programmatic navigation") {
                settings.bool(forKey: "sidebarFavoritesCollapsed") && table.numberOfRows < expandedFavoritesRowCount
                    && self.element(id: "favorites.header", in: controller.view)?.accessibilityValue() == "Collapsed"
            }
            mailbox.selectedMailbox = destination
            try await eventually("Programmatic navigation must reveal and select the favorite") {
                !settings.bool(forKey: "sidebarFavoritesCollapsed")
                    && table.selectedRowIndexes == IndexSet(integer: copies[0])
                    && table.numberOfRows == expandedFavoritesRowCount
                    && self.element(id: "favorites.header", in: controller.view)?.accessibilityValue() == "Expanded"
            }

            let accountID = owner.account.id
            let child = LabelRecord(accountID: accountID, id: "Label_sidebar_child", name: "\(label.name)/Trips", isSystem: false)
            let labels = owner.labels + [child]
            try await mailbox.cache.write { try $0.replaceLabels(labels, accountID: accountID) }
            try await eventually("The account must observe its added child label") { owner.labels.contains { $0.id == child.id } }
            let childDestination = MailboxID.account(accountID, child.id)
            mailbox.selectedMailbox = childDestination
            try await eventually("Navigating to a nested label must reveal and highlight it") {
                guard let row = self.nativeRows(label: child.name, in: table).first else { return false }
                return table.selectedRowIndexes == IndexSet(integer: row)
            }
            let childRow = try #require(nativeRows(label: child.name, in: table).first)
            try await selectSidebarRow(row: childRow, in: table)
            for (name, expanded) in [("Hide Labels", false), ("Show Labels", true), ("Hide Labels", false)] {
                let parent = try #require(elements(in: controller.view).first {
                    $0.accessibilityLabel() == label.name && $0.customActions.contains { $0.name == name }
                })
                try performAction(name, on: parent)
                try await eventually("\(name) must update nested label disclosure") {
                    !self.nativeRows(label: child.name, in: table).isEmpty == expanded
                }
                #expect(mailbox.selectedMailbox == childDestination, "Label disclosure must preserve the destination")
                if expanded {
                    let row = try #require(nativeRows(label: child.name, in: table).first)
                    #expect(table.selectedRowIndexes == IndexSet(integer: row))
                }
            }
            mailbox.selectedMailbox = destination
            try await settle()
            mailbox.selectedMailbox = childDestination
            try await eventually("Navigating back to the child must reveal and highlight its native row") {
                guard let row = self.nativeRows(label: child.name, in: table).first else { return false }
                return table.selectedRowIndexes == IndexSet(integer: row)
            }
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearance)
                try await settle()
                try capture(controller.view, name: "tern-sidebar-selection-\(name).png")
            }
        } catch {
            let table = descendants(controller.view).compactMap { $0 as? NSTableView }.first
            print("Sidebar selection failure: mailbox=\(String(describing: mailbox.selectedMailbox)), rows=\(table?.selectedRowIndexes.map { $0 } ?? []), rowCount=\(table?.numberOfRows ?? -1), active=\(NSApp.isActive), key=\(window.isKeyWindow)")
            try? capture(controller.view, name: "tern-sidebar-selection-failure.png")
            await app.signOut()
            throw error
        }
        await app.signOut()
    }

    @Test func collapsedFavoritesCanAddAnAccountLabelAndCancelWithoutSaving() async throws {
        let app = AppModel()
        await app.start()
        let mailbox = try #require(app.mailbox)
        let suite = "FavoritesInteractionTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        settings.set("", forKey: SidebarExpansion.storageKey)
        settings.set(false, forKey: "sidebarFavoritesCollapsed")
        defer { settings.removePersistentDomain(forName: suite) }
        let controller = NSHostingController(rootView: SidebarView(mailbox: mailbox)
            .frame(width: Tokens.Layout.sidebarMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .environment(app).defaultAppStorage(settings))
        controller.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 640, height: 640))
        window.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
            window.contentViewController = nil
        }

        do {
            do {
                try await eventually("Synthetic accounts and labels must finish loading") {
                    mailbox.hasSyncedOnce && mailbox.presentedAccounts.count == 2
                        && mailbox.presentedAccounts.allSatisfy { !$0.labels.isEmpty }
                }
            } catch {
                print("Favorites readiness: synced=\(mailbox.hasSyncedOnce), accounts=\(mailbox.presentedAccounts.count), labelCounts=\(mailbox.presentedAccounts.map { $0.labels.count })")
                throw error
            }
            try await settle()
            try #require(controller.view.bounds.height >= 600, "The hosted sidebar must have a full-height viewport")
            try capture(controller.view, name: "tern-favorites-header-idle.png")
            if element(id: "favorites.header", in: controller.view) == nil {
                diagnoseAccessibility(in: controller.view)
            }
            try await eventually("The rendered Favorites header must expose favorites.header") {
                self.element(id: "favorites.header", in: controller.view) != nil
            }
            let originalSelection = mailbox.selectedMailbox
            let originalFavorites = mailbox.navigation.favorites
            let store = try #require(mailbox.accountStore)
            let table = try #require(descendants(controller.view).compactMap { $0 as? NSTableView }.first)
            let expandedRowCount = table.numberOfRows

            let header = try #require(element(id: "favorites.header", in: controller.view))
            #expect(header.accessibilityRole()?.rawValue == "AXHeading")
            #expect(header.accessibilityLabel() == "Favorites")
            #expect(header.accessibilityValue() == "Expanded")
            #expect(header.customActions.contains { $0.name == "Add Favorite" })
            try performHeaderAction("Collapse Favorites", in: controller.view)
            try await eventually { settings.bool(forKey: "sidebarFavoritesCollapsed") && table.numberOfRows < expandedRowCount }
            #expect(mailbox.selectedMailbox == originalSelection)
            let collapsedHeader = try #require(element(id: "favorites.header", in: controller.view))
            #expect(collapsedHeader.accessibilityValue() == "Collapsed")
            #expect(collapsedHeader.customActions.contains { $0.name == "Add Favorite" })
            #expect(collapsedHeader.customActions.contains { $0.name == "Expand Favorites" })
            #expect(!collapsedHeader.customActions.contains { $0.name == "Collapse Favorites" })
            try performHeaderAction("Expand Favorites", in: controller.view)
            try await eventually { !settings.bool(forKey: "sidebarFavoritesCollapsed") && table.numberOfRows == expandedRowCount }
            #expect(mailbox.selectedMailbox == originalSelection)
            try performHeaderAction("Collapse Favorites", in: controller.view)
            try await eventually { settings.bool(forKey: "sidebarFavoritesCollapsed") && table.numberOfRows < expandedRowCount }
            try capture(controller.view, name: "tern-favorites-collapsed.png")

            try performHeaderAction("Add Favorite", in: controller.view)
            try await eventually { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            let sheetView = try #require(sheet.contentView)
            try await eventually { self.element(id: "favorites.confirmAdd", in: sheetView) != nil }
            #expect(window.sheets.count == 1, "One Add Favorite action must present exactly one sheet")
            try capture(controller.view, name: "tern-favorites-header-controls.png")
            let confirm = try #require(element(id: "favorites.confirmAdd", in: sheetView))
            #expect(!confirm.isAccessibilityEnabled())

            // A unified Inbox already exists. Selecting it must not enable a duplicate write.
            try await search("Inbox", in: sheet)
            try await selectFolder(label: "Inbox, already in Favorites", in: sheet)
            try await settle()
            #expect(!confirm.isAccessibilityEnabled())

            let owner = try #require(mailbox.presentedAccounts.first { $0.account.id == "ui-audit" })
            let label = try #require(owner.labels.first { !$0.isSystem })
            try await chooseAccount(named: mailbox.accountTitle(owner.account), in: sheet)
            try await settle()
            #expect(element(id: "favorites.confirmAdd", in: sheetView)?.isAccessibilityEnabled() == false, "Changing accounts must clear the previous folder selection")

            try await search(label.name, in: sheet)
            try await selectFolder(label: label.name, in: sheet)
            try capture(sheetView, name: "tern-favorites-popup-selected.png")
            try await eventually("Selecting an account label must enable Add Favorite") {
                self.element(id: "favorites.confirmAdd", in: sheetView)?.isAccessibilityEnabled() == true
            }
            for (appearance, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                sheet.appearance = NSAppearance(named: appearance)
                try await settle()
                try capture(sheetView, name: "tern-favorites-popup-\(name).png")
            }
            let readyConfirm = try #require(element(id: "favorites.confirmAdd", in: sheetView))
            try #require(readyConfirm.accessibilityPerformPress())
            let target = MailFavoriteTarget.label(accountID: owner.account.id, labelID: label.id)
            try await eventually("Adding must persist the account label, dismiss the sheet, and expand Favorites") {
                window.attachedSheet == nil && mailbox.navigation.favorites.contains { $0.target == target }
                    && !settings.bool(forKey: "sidebarFavoritesCollapsed")
            }
            let saved = try await store.mailFavorites()
            #expect(saved.count == originalFavorites.count + 1)
            #expect(saved.last?.target == target)
            #expect(mailbox.selectedMailbox == originalSelection)

            // Reopening starts with no choice; Cancel must leave the persisted list intact.
            try performHeaderAction("Add Favorite", in: controller.view)
            try await eventually { window.attachedSheet != nil }
            let cancelledSheet = try #require(window.attachedSheet)
            let cancelledView = try #require(cancelledSheet.contentView)
            try await eventually { self.element(id: "favorites.confirmAdd", in: cancelledView) != nil }
            #expect(window.sheets.count == 1, "Expanded Favorites must not queue a sheet for every row")
            #expect(element(id: "favorites.confirmAdd", in: cancelledView)?.isAccessibilityEnabled() == false)
            let cancel = try #require(elements(in: cancelledView).first {
                $0.accessibilityRole() == .button && $0.accessibilityLabel() == "Cancel"
            })
            try #require(cancel.accessibilityPerformPress())
            try await eventually { window.attachedSheet == nil }
            try await Task.sleep(for: .seconds(1))
            #expect(window.attachedSheet == nil, "Cancel must keep the sheet dismissed")
            #expect(window.sheets.isEmpty, "Cancel must leave no queued sheets to reopen")

            try performHeaderAction("Add Favorite", in: controller.view)
            try await eventually { window.attachedSheet != nil }
            let escapedSheet = try #require(window.attachedSheet)
            let escapedView = try #require(escapedSheet.contentView)
            try await eventually { self.element(id: "favorites.confirmAdd", in: escapedView) != nil }
            #expect(window.sheets.count == 1)
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: escapedSheet.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            escapedSheet.sendEvent(escape)
            try await eventually { window.attachedSheet == nil }
            try await Task.sleep(for: .seconds(1))
            #expect(window.attachedSheet == nil, "Escape must keep the sheet dismissed")
            #expect(window.sheets.isEmpty, "Escape must leave no queued sheets to reopen")
            #expect(try await store.mailFavorites() == saved)
            #expect(mailbox.selectedMailbox == originalSelection)
        } catch {
            await app.signOut()
            throw error
        }
        await app.signOut()
    }

    private func search(_ text: String, in window: NSWindow) async throws {
        let view = try #require(window.contentView)
        try #require(element(id: "favorites.searchFolders", in: view) != nil)
        let field = try #require(descendants(view).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Find a folder"
        })
        try #require(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await settle()
        #expect(field.stringValue == text)
    }

    private func chooseAccount(named title: String, in window: NSWindow) async throws {
        let view = try #require(window.contentView)
        let picker = try #require(element(id: "favorites.accountPicker", in: view))
        let attempt = MenuChoiceAttempt()
        NotificationCenter.default.addObserver(attempt, selector: #selector(MenuChoiceAttempt.menuBeganTracking(_:)),
            name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(attempt) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        // The native menu may track synchronously, so inspect its public AX
        // nodes from the main run loop while the popup's press action runs.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let roots: [Any] = [picker.object, NSApplication.shared] + (picker.shownMenu.map { [$0] } ?? [])
                let nodes = roots.flatMap { self.elements(in: $0) }
                if let menu = attempt.menu, let index = menu.items.firstIndex(where: { $0.title == title }) {
                    menu.performActionForItem(at: index)
                    menu.cancelTrackingWithoutAnimation()
                    attempt.selected = true
                    attempt.completed = true
                    attempt.timer?.invalidate()
                } else if let item = nodes.first(where: { $0.accessibilityRole() == .menuItem && $0.accessibilityLabel() == title }),
                   item.accessibilityPerformPress() {
                    attempt.selected = true
                    attempt.completed = true
                    attempt.timer?.invalidate()
                } else if ContinuousClock.now >= deadline {
                    attempt.completed = true
                    attempt.timer?.invalidate()
                    print("Favorites account menu: pickerRole=\(picker.accessibilityRole()?.rawValue ?? "nil"), trackedItems=\(attempt.menu?.numberOfItems ?? 0)")
                    for menu in nodes.compactMap({ $0.object as? NSMenu }) { menu.cancelTrackingWithoutAnimation() }
                    if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        NSApplication.shared.postEvent(escape, atStart: true)
                    }
                }
            }
        }
        attempt.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }
        try #require(picker.accessibilityPerformPress(), "The account picker must open its native menu")
        try await eventually("The native account menu selection must complete") { attempt.completed }
        try #require(attempt.selected, "The account menu must expose and activate the selected account")
    }

    @MainActor private final class MenuChoiceAttempt: NSObject {
        var selected = false
        var completed = false
        var timer: Timer?
        var menu: NSMenu?

        @objc func menuBeganTracking(_ notification: Notification) {
            menu = notification.object as? NSMenu
        }
    }

    private func selectFolder(label: String, in window: NSWindow) async throws {
        let view = try #require(window.contentView)
        try await eventually("The selected account's matching folder must appear") {
            self.elements(in: view).contains { $0.accessibilityLabel() == label }
        }
        let row = try #require(elements(in: view).first { $0.accessibilityLabel() == label }, "Missing folder row: \(label)")
        let frame = row.accessibilityFrame()
        try #require(!frame.isEmpty)
        let table = try #require(descendants(view).compactMap { $0 as? NSTableView }.first)
        let windowPoint = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        let rowIndex = table.row(at: table.convert(windowPoint, from: nil))
        try #require(rowIndex >= 0, "The accessible folder must belong to a native list row")
        window.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
    }

    private func performHeaderAction(_ name: String, in view: NSView) throws {
        let header = try #require(element(id: "favorites.header", in: view))
        try performAction(name, on: header)
    }

    private func performAction(_ name: String, on element: NativeAccessibilityElement) throws {
        let action = try #require(element.customActions.first { $0.name == name }, "Missing sidebar action: \(name)")
        if let handler = action.handler {
            try #require(handler(), "Favorites action did not execute: \(name)")
        } else {
            let target = try #require(action.target as? NSObject)
            let selector = try #require(action.selector)
            try #require(target.responds(to: selector))
            let implementation = try #require(target.method(for: selector))
            // NSAccessibilityCustomAction documents BOOL methods with either no
            // explicit argument or the custom action as their single argument.
            if NSStringFromSelector(selector).contains(":") {
                typealias Action = @convention(c) (AnyObject, Selector, NSAccessibilityCustomAction) -> Bool
                try #require(unsafeBitCast(implementation, to: Action.self)(target, selector, action))
            } else {
                typealias Action = @convention(c) (AnyObject, Selector) -> Bool
                try #require(unsafeBitCast(implementation, to: Action.self)(target, selector))
            }
        }
    }

    private func nativeRows(label: String, in table: NSTableView) -> [Int] {
        guard let window = table.window, let root = window.contentView else { return [] }
        return Set(elements(in: root).filter { $0.accessibilityLabel() == label }.compactMap { element in
            let frame = element.accessibilityFrame()
            guard !frame.isEmpty else { return nil }
            let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            let index = table.row(at: table.convert(point, from: nil))
            return index >= 0 ? index : nil
        }).sorted()
    }

    private func selectSidebarRow(row: Int, in table: NSTableView) async throws {
        table.scrollRowToVisible(row)
        try await settle()
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await settle()
    }

    private func element(id: String, in view: NSView) -> NativeAccessibilityElement? {
        elements(in: view).first { $0.accessibilityIdentifier() == id }
    }

    private func elements(in root: Any) -> [NativeAccessibilityElement] {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ value: Any) -> [NativeAccessibilityElement] {
            guard let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let element = NativeAccessibilityElement(object: object)
            let children = element.children
            return [element] + (children + NSAccessibility.unignoredChildren(from: children)).flatMap(visit)
        }
        // SwiftUI places list cells in native descendants of the hosting view;
        // ignored hosting containers need not expose those cells as direct AX children.
        if let view = root as? NSView {
            let windowRoots: [Any] = view.window.map { [$0] } ?? []
            return (windowRoots + descendants(view)).flatMap(visit)
        }
        return visit(root)
    }

    private func diagnoseAccessibility(in view: NSView) {
        let nativeViews = descendants(view)
        let accessible = elements(in: view)
        print("Favorites AX: nativeViews=\(nativeViews.count), accessibleElements=\(accessible.count)")
        for element in accessible.prefix(80) {
            print("Favorites AX element: class=\(type(of: element.object)), role=\(element.accessibilityRole()?.rawValue ?? "nil"), id=\(element.accessibilityIdentifier() ?? "nil")")
        }
        for nativeView in nativeViews.prefix(30) {
            let children = nativeView.accessibilityChildren() ?? []
            print("Favorites native root: class=\(type(of: nativeView)), children=\(children.count), childClasses=\(children.prefix(8).map { String(describing: type(of: $0)) })")
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    /// SwiftUI nodes expose modern Objective-C accessibility getters without
    /// formal protocol conformance; outline rows also use the informal API.
    @MainActor private struct NativeAccessibilityElement {
        let object: NSObject

        private func modernValue(_ key: String, getter: String? = nil) -> Any? {
            guard object.responds(to: NSSelectorFromString(getter ?? key)) else { return nil }
            return object.value(forKey: key)
        }

        var children: [Any] {
            modernValue("accessibilityChildren") as? [Any] ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
        }

        var customActions: [NSAccessibilityCustomAction] {
            modernValue("accessibilityCustomActions") as? [NSAccessibilityCustomAction] ?? []
        }

        var shownMenu: Any? {
            modernValue("accessibilityShownMenu") ?? object.accessibilityAttributeValue(.shownMenu)
        }

        func accessibilityIdentifier() -> String? {
            modernValue("accessibilityIdentifier") as? String ?? object.accessibilityAttributeValue(.identifier) as? String
        }

        func accessibilityLabel() -> String? {
            modernValue("accessibilityLabel") as? String ?? object.accessibilityAttributeValue(.description) as? String
                ?? object.accessibilityAttributeValue(.title) as? String
        }

        func accessibilityValue() -> String? {
            modernValue("accessibilityValue") as? String ?? object.accessibilityAttributeValue(.value) as? String
        }

        func accessibilityRole() -> NSAccessibility.Role? {
            let role = modernValue("accessibilityRole") as? String ?? object.accessibilityAttributeValue(.role) as? String
            return role.map(NSAccessibility.Role.init(rawValue:))
        }

        func accessibilityFrame() -> NSRect {
            if let frame = modernValue("accessibilityFrame") as? NSValue { return frame.rectValue }
            guard let position = object.accessibilityAttributeValue(.position) as? NSValue,
                  let size = object.accessibilityAttributeValue(.size) as? NSValue else { return .zero }
            return NSRect(origin: position.pointValue, size: size.sizeValue)
        }

        func isAccessibilityEnabled() -> Bool {
            let enabled = modernValue("accessibilityEnabled", getter: "isAccessibilityEnabled") as? NSNumber
                ?? object.accessibilityAttributeValue(.enabled) as? NSNumber
            return enabled?.boolValue ?? false
        }

        func accessibilityPerformPress() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if object.responds(to: selector), let implementation = object.method(for: selector) {
                // NSAccessibility.h declares this public selector as -(BOOL)accessibilityPerformPress.
                // The guarded IMP call uses that exact receiver/selector/BOOL signature.
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                return unsafeBitCast(implementation, to: Press.self)(object, selector)
            }
            guard object.accessibilityActionNames().contains(.press) else { return false }
            object.accessibilityPerformAction(.press)
            return true
        }
    }

    private func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: name)
    }

    private func eventually(_ description: String = "The native Favorites interaction did not reach its expected state", _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await settle() }
        try #require(condition(), "\(description)")
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(200)) }
}
