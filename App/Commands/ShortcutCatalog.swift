import SwiftUI

/// Every menu command with a key equivalent, in one table. The menus, the
/// calendar and Help ▸ Keyboard Shortcuts read from it, so a shortcut changes
/// in one place and a clash between two commands shows up in a test.
enum ShortcutCatalog {
    /// Where a command can act. Commands whose scopes overlap must not share keys.
    enum Scope: String, CaseIterable, Sendable {
        /// The main window showing mail.
        case mail
        /// The main window showing the calendar.
        case calendar
        /// The main window showing the attachment library.
        case attachments
        /// A conversation opened in its own window.
        case conversation
        /// A compose window.
        case compose
        /// The Settings window, whose signature editor takes formatting.
        case settings
        /// The Assistant window.
        case assistant

        /// Every state of the main window.
        static let mainWindow: Set<Scope> = [.mail, .calendar, .attachments]
        /// Every window that shows mail or writes it.
        static let mailWindows: Set<Scope> = mainWindow.union([.conversation, .compose])
        static let all = Set(allCases)
    }

    /// The menus, in their order from left to right.
    enum Menu: String, CaseIterable, Sendable {
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case message = "Message"
        case mailbox = "Mailbox"
        case format = "Format"
        case calendar = "Calendar"
        case go = "Go"
        case window = "Window"
        case help = "Help"
    }

    struct Command: Identifiable, Sendable {
        let id: String
        let menu: Menu
        /// The title Help shows. A menu item may show a state-dependent variant.
        let title: String
        let key: KeyEquivalent
        let modifiers: EventModifiers
        let scopes: Set<Scope>

        init(_ id: String, menu: Menu, title: String, key: KeyEquivalent,
             modifiers: EventModifiers = .command, scopes: Set<Scope>) {
            self.id = id
            self.menu = menu
            self.title = title
            self.key = key
            self.modifiers = modifiers
            self.scopes = scopes
        }

        var shortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }

        /// The keys as menus draw them: modifiers in ⌃⌥⇧⌘ order, then the key.
        var label: String { ShortcutCatalog.label(key: key, modifiers: modifiers) }

        /// True when both commands can be live at once and answer the same keys.
        func clashes(with other: Command) -> Bool {
            id != other.id && key.character == other.key.character && modifiers == other.modifiers
                && !scopes.isDisjoint(with: other.scopes)
        }
    }

    /// One menu's shortcuts, as Help lists them.
    struct MenuSection: Identifiable {
        let menu: Menu
        let commands: [Command]
        var id: Menu { menu }
    }

    // MARK: File

    /// Opens a compose window. The Assistant window keeps ⌘N for a new chat.
    static let newMessage = Command("file.newMessage", menu: .file, title: "New Message", key: "n",
                                    scopes: Scope.all.subtracting([.assistant]))
    static let attachFiles = Command("file.attachFiles", menu: .file, title: "Attach Files…", key: "a",
                                     modifiers: [.shift, .command], scopes: [.compose])

    // MARK: Edit

    static let searchMail = Command("edit.searchMail", menu: .edit, title: "Search Mail", key: "f",
                                    modifiers: [.option, .command], scopes: [.mail])
    static let findAttachment = Command("edit.findAttachment", menu: .edit, title: "Find Attachment", key: "f",
                                        scopes: [.attachments])

    // MARK: Message

    static let send = Command("message.send", menu: .message, title: "Send", key: "d",
                              modifiers: [.shift, .command], scopes: [.compose])
    static let reply = Command("message.reply", menu: .message, title: "Reply", key: "r",
                               scopes: [.mail, .conversation])
    static let replyAll = Command("message.replyAll", menu: .message, title: "Reply All", key: "r",
                                  modifiers: [.shift, .command], scopes: [.mail, .conversation])
    static let forward = Command("message.forward", menu: .message, title: "Forward", key: "f",
                                 modifiers: [.shift, .command], scopes: [.mail, .conversation])
    static let archive = Command("message.archive", menu: .message, title: "Archive", key: "a",
                                 modifiers: [.control, .command], scopes: [.mail, .conversation])
    static let moveToTrash = Command("message.moveToTrash", menu: .message, title: "Move to Trash", key: .delete,
                                     scopes: [.mail, .conversation])
    static let toggleRead = Command("message.toggleRead", menu: .message, title: "Mark as Read or Unread", key: "u",
                                    modifiers: [.shift, .command], scopes: [.mail])
    static let toggleStar = Command("message.toggleStar", menu: .message, title: "Star or Remove Star", key: "l",
                                    modifiers: [.shift, .command], scopes: [.mail])
    static let editLabels = Command("message.editLabels", menu: .message, title: "Edit Labels…", key: "l",
                                    modifiers: [.option, .command], scopes: [.mail])
    static let moveTo = Command("message.moveTo", menu: .message, title: "Move to…", key: "m",
                                modifiers: [.control, .command], scopes: [.mail])
    static let snooze = Command("message.snooze", menu: .message, title: "Snooze…", key: "b",
                                modifiers: [.control, .command], scopes: [.mail])

    // MARK: Mailbox

    static let checkForNewMail = Command("mailbox.checkForNewMail", menu: .mailbox, title: "Check for New Mail", key: "n",
                                         modifiers: [.shift, .command], scopes: Scope.all)
    /// ⌃⌘N, so the calendar keeps ⌥⌘N for a new event.
    static let newLabel = Command("mailbox.newLabel", menu: .mailbox, title: "New Label…", key: "n",
                                  modifiers: [.control, .command], scopes: [.mail])

    // MARK: Format

    static let bold = Command("format.bold", menu: .format, title: "Bold", key: "b", scopes: [.compose, .settings])
    static let italic = Command("format.italic", menu: .format, title: "Italic", key: "i", scopes: [.compose, .settings])
    static let underline = Command("format.underline", menu: .format, title: "Underline", key: "u",
                                   scopes: [.compose, .settings])
    static let link = Command("format.link", menu: .format, title: "Add or Edit Link…", key: "k",
                              scopes: [.compose, .settings])

    // MARK: Calendar

    static let newEvent = Command("calendar.newEvent", menu: .calendar, title: "New Event", key: "n",
                                  modifiers: [.option, .command], scopes: [.calendar])
    static let today = Command("calendar.today", menu: .calendar, title: "Today", key: "t", scopes: [.calendar])

    // MARK: Go

    static let goToLabel = Command("go.goToLabel", menu: .go, title: "Go to Label…", key: "l",
                                   modifiers: [.control, .option, .command], scopes: [.mail])
    /// ⌘1 to ⌘5, in the sidebar's order, so each number matches a row.
    static let mailboxes: [Command] = SystemMailbox.numbered.enumerated().map { index, box in
        Command("go.mailbox.\(box.id)", menu: .go, title: box.title,
                key: KeyEquivalent(Character(String(index + 1))), scopes: [.mail])
    }

    /// Every command, in menu order.
    static let all: [Command] = [
        newMessage, attachFiles,
        searchMail, findAttachment,
        send, reply, replyAll, forward, archive, moveToTrash, toggleRead, toggleStar, editLabels, moveTo, snooze,
        checkForNewMail, newLabel,
        bold, italic, underline, link,
        newEvent, today,
        goToLabel,
    ] + mailboxes

    /// The commands grouped by menu, skipping menus without shortcuts.
    static var sections: [MenuSection] {
        Menu.allCases.compactMap { menu in
            let commands = all.filter { $0.menu == menu }
            return commands.isEmpty ? nil : MenuSection(menu: menu, commands: commands)
        }
    }

    /// Pairs of commands that answer the same keys while both can be live.
    static func clashes(in commands: [Command] = all) -> [(Command, Command)] {
        var found: [(Command, Command)] = []
        for (index, command) in commands.enumerated() {
            for other in commands[(index + 1)...] where command.clashes(with: other) {
                found.append((command, other))
            }
        }
        return found
    }

    static func label(key: KeyEquivalent, modifiers: EventModifiers) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + name(of: key)
    }

    private static func name(of key: KeyEquivalent) -> String {
        switch key.character {
        case KeyEquivalent.delete.character: "⌫"
        case KeyEquivalent.return.character: "↩"
        case KeyEquivalent.space.character: "Space"
        case KeyEquivalent.escape.character: "⎋"
        case KeyEquivalent.tab.character: "⇥"
        case KeyEquivalent.upArrow.character: "↑"
        case KeyEquivalent.downArrow.character: "↓"
        case KeyEquivalent.leftArrow.character: "←"
        case KeyEquivalent.rightArrow.character: "→"
        default: String(key.character).uppercased()
        }
    }
}
