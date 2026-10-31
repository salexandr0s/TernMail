import AppKit
import Foundation

/// Shows unread Inbox mail on the Dock icon and, when turned on, in a menu bar item.
@MainActor final class MailBadgeController: NSObject {
    /// One account's unread Inbox conversations, listed in the menu bar item's menu.
    struct AccountUnread: Equatable {
        var id: String
        var title: String
        var count: Int
    }

    private enum Command {
        case inbox(accountID: String?), checkForNewMail, newMessage, openApp
    }

    private var item: NSStatusItem?
    private var accounts: [AccountUnread] = []
    private let defaults: UserDefaults
    private var defaultsObserver: (any NSObjectProtocol)?
    /// Shows the Inbox of every account when the ID is nil, otherwise one account's.
    var onOpenInbox: ((String?) -> Void)?
    var onCheckForNewMail: (() -> Void)?
    var onNewMessage: (() -> Void)?
    var onOpenApp: (() -> Void)?

    private var unread: Int { accounts.reduce(0) { $0 + $1.count } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
    }

    func update(accounts: [AccountUnread]) {
        self.accounts = accounts.map { account in
            var account = account
            account.count = max(0, account.count)
            return account
        }
        render()
    }

    func stop() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        NSApp.dockTile.badgeLabel = nil
    }

    private func render() {
        let unread = unread
        let showsDockBadge = defaults.object(forKey: NotificationPolicy.dockBadgeKey) == nil
            || defaults.bool(forKey: NotificationPolicy.dockBadgeKey)
        NSApp.dockTile.badgeLabel = unread == 0 || !showsDockBadge ? nil : String(unread)
        guard defaults.bool(forKey: NotificationPolicy.menuBarCountKey) else {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "envelope", accessibilityDescription: "Unread Inbox")
            item.button?.imagePosition = .imageLeading
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        }
        let summary = "\(unread) unread Inbox \(unread == 1 ? "conversation" : "conversations")"
        item?.button?.title = " \(unread)"
        item?.button?.toolTip = summary
        item?.button?.setAccessibilityLabel("Tern, \(summary)")
    }

    private func entry(_ title: String, badge: Int = 0, command: Command) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = command
        if badge > 0 { entry.badge = NSMenuItemBadge(count: badge) }
        return entry
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command else { return }
        switch command {
        case .inbox(let accountID): onOpenInbox?(accountID)
        case .checkForNewMail: onCheckForNewMail?()
        case .newMessage: onNewMessage?()
        case .openApp: onOpenApp?()
        }
    }
}

extension MailBadgeController: NSMenuDelegate {
    /// Builds the menu as it opens, so the counts match the badge.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(entry("Inbox", badge: unread, command: .inbox(accountID: nil)))
        if accounts.count > 1 {
            for account in accounts {
                let row = entry(account.title, badge: account.count, command: .inbox(accountID: account.id))
                row.indentationLevel = 1
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        menu.addItem(entry("Check for New Mail", command: .checkForNewMail))
        menu.addItem(entry("New Message", command: .newMessage))
        menu.addItem(.separator())
        menu.addItem(entry("Open Tern", command: .openApp))
    }
}
