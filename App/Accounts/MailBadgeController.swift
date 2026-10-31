import AppKit
import Foundation

@MainActor final class MailBadgeController: NSObject {
    private var item: NSStatusItem?
    private var unread = 0
    private let defaults: UserDefaults
    private var defaultsObserver: (any NSObjectProtocol)?
    var onOpenMailbox: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.render() } }
    }

    func update(unreadCount: Int) {
        unread = max(0, unreadCount)
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
            item.button?.target = self
            item.button?.action = #selector(openMailbox)
            self.item = item
        }
        item?.button?.title = " \(unread)"
        item?.button?.toolTip = "\(unread) unread Inbox \(unread == 1 ? "conversation" : "conversations")"
        item?.button?.setAccessibilityLabel("Tern, \(unread) unread Inbox conversations")
    }

    @objc private func openMailbox() { onOpenMailbox?() }
}
