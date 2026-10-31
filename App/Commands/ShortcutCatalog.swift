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
        case mailbox = "Mailbox"
        case message = "Message"
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
    /// The Assistant window's ⌘N.
    static let newChat = Command("file.newChat", menu: .file, title: "New Chat", key: "n", scopes: [.assistant])
    static let newEvent = Command("file.newEvent", menu: .file, title: "New Event", key: "n",
                                  modifiers: [.option, .command], scopes: [.calendar])
    /// ⌃⌘N, so the calendar keeps ⌥⌘N for a new event.
    static let newLabel = Command("file.newLabel", menu: .file, title: "New Label…", key: "n",
                                  modifiers: [.control, .command], scopes: [.mail])
    static let openConversation = Command("file.openConversation", menu: .file, title: "Open Conversation", key: "o",
                                          scopes: [.mail])
    static let attachFiles = Command("file.attachFiles", menu: .file, title: "Attach Files…", key: "a",
                                     modifiers: [.shift, .command], scopes: [.compose])
    static let print = Command("file.print", menu: .file, title: "Print…", key: "p",
                               scopes: [.mail, .conversation, .calendar])

    // MARK: Edit

    /// Finds in the destination that has a search field. Mail keeps ⌥⌘F for its Gmail search.
    static let find = Command("edit.find", menu: .edit, title: "Find…", key: "f", scopes: [.calendar, .attachments])
    static let searchMail = Command("edit.searchMail", menu: .edit, title: "Search Mail", key: "f",
                                    modifiers: [.option, .command], scopes: [.mail])

    // MARK: View

    static let toggleSidebar = Command("view.toggleSidebar", menu: .view, title: "Show or Hide Sidebar", key: "s",
                                       modifiers: [.control, .command], scopes: Scope.mainWindow)
    /// Provided by `ToolbarCommands`.
    static let toggleToolbar = Command("view.toggleToolbar", menu: .view, title: "Show or Hide Toolbar", key: "t",
                                       modifiers: [.option, .command], scopes: Scope.all)
    static let toggleReader = Command("view.toggleReader", menu: .view, title: "Show or Hide Viewing Pane", key: "v",
                                      modifiers: [.option, .command], scopes: [.mail])
    static let expandAll = Command("view.expandAll", menu: .view, title: "Expand All Messages", key: "e",
                                   modifiers: [.shift, .command], scopes: [.mail, .conversation])
    static let collapseAll = Command("view.collapseAll", menu: .view, title: "Collapse All Messages", key: "e",
                                     modifiers: [.option, .command], scopes: [.mail, .conversation])

    // MARK: Mailbox

    static let checkForNewMail = Command("mailbox.checkForNewMail", menu: .mailbox, title: "Check for New Mail", key: "n",
                                         modifiers: [.shift, .command], scopes: Scope.all)
    static let markAllRead = Command("mailbox.markAllRead", menu: .mailbox, title: "Mark All as Read", key: "u",
                                     modifiers: [.option, .command], scopes: [.mail])

    // MARK: Message

    static let send = Command("message.send", menu: .message, title: "Send", key: "d",
                              modifiers: [.shift, .command], scopes: [.compose])
    static let reply = Command("message.reply", menu: .message, title: "Reply", key: "r",
                               scopes: [.mail, .conversation])
    static let replyAll = Command("message.replyAll", menu: .message, title: "Reply All", key: "r",
                                  modifiers: [.shift, .command], scopes: [.mail, .conversation])
    static let forward = Command("message.forward", menu: .message, title: "Forward", key: "f",
                                 modifiers: [.shift, .command], scopes: [.mail, .conversation])
    static let forwardAsAttachment = Command("message.forwardAsAttachment", menu: .message, title: "Forward as Attachment",
                                             key: "f", modifiers: [.control, .shift, .command], scopes: [.mail, .conversation])
    static let archive = Command("message.archive", menu: .message, title: "Archive", key: "a",
                                 modifiers: [.control, .command], scopes: [.mail, .conversation])
    static let moveToTrash = Command("message.moveToTrash", menu: .message, title: "Move to Trash", key: .delete,
                                     scopes: [.mail, .conversation])
    static let toggleSpam = Command("message.toggleSpam", menu: .message, title: "Report Spam or Not Spam", key: "j",
                                    modifiers: [.shift, .command], scopes: [.mail])
    static let toggleRead = Command("message.toggleRead", menu: .message, title: "Mark as Read or Unread", key: "u",
                                    modifiers: [.shift, .command], scopes: [.mail])
    static let toggleStar = Command("message.toggleStar", menu: .message, title: "Star or Remove Star", key: "l",
                                    modifiers: [.shift, .command], scopes: [.mail])
    static let markImportant = Command("message.markImportant", menu: .message, title: "Mark as Important", key: "i",
                                       modifiers: [.shift, .command], scopes: [.mail])
    static let editLabels = Command("message.editLabels", menu: .message, title: "Edit Labels…", key: "l",
                                    modifiers: [.option, .command], scopes: [.mail])
    static let moveTo = Command("message.moveTo", menu: .message, title: "Move to…", key: "m",
                                modifiers: [.control, .command], scopes: [.mail])
    static let snooze = Command("message.snooze", menu: .message, title: "Snooze…", key: "b",
                                modifiers: [.control, .command], scopes: [.mail])

    // MARK: Format

    static let bold = Command("format.bold", menu: .format, title: "Bold", key: "b", scopes: [.compose, .settings])
    static let italic = Command("format.italic", menu: .format, title: "Italic", key: "i", scopes: [.compose, .settings])
    static let underline = Command("format.underline", menu: .format, title: "Underline", key: "u",
                                   scopes: [.compose, .settings])
    static let link = Command("format.link", menu: .format, title: "Add or Edit Link…", key: "k",
                              scopes: [.compose, .settings])

    // MARK: Calendar

    static let today = Command("calendar.today", menu: .calendar, title: "Today", key: "t", scopes: [.calendar])
    static let goToDate = Command("calendar.goToDate", menu: .calendar, title: "Go to Date…", key: "t",
                                  modifiers: [.shift, .command], scopes: [.calendar])
    /// ⌃⌘1 to ⌃⌘5 in the picker's order: Day, Week, Month, Year, Schedule.
    static let calendarModes: [Command] = CalendarDisplayMode.allCases.enumerated().map { index, mode in
        Command("calendar.mode.\(mode.rawValue)", menu: .calendar, title: mode.title,
                key: KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .command], scopes: [.calendar])
    }
    static func calendarMode(_ mode: CalendarDisplayMode) -> Command {
        calendarModes.first { $0.id == "calendar.mode.\(mode.rawValue)" } ?? today
    }

    // MARK: Go

    static let goMail = Command("go.mail", menu: .go, title: "Mail", key: "1",
                                modifiers: [.shift, .command], scopes: Scope.mainWindow)
    static let goCalendar = Command("go.calendar", menu: .go, title: "Calendar", key: "2",
                                    modifiers: [.shift, .command], scopes: Scope.mainWindow)
    static let goAttachments = Command("go.attachments", menu: .go, title: "Attachments", key: "3",
                                       modifiers: [.shift, .command], scopes: Scope.mainWindow)
    static let goToLabel = Command("go.goToLabel", menu: .go, title: "Go to Label…", key: "l",
                                   modifiers: [.control, .option, .command], scopes: [.mail])
    /// ⌘1 to ⌘5, in the sidebar's order, so each number matches a row.
    static let mailboxes: [Command] = SystemMailbox.numbered.enumerated().map { index, box in
        Command("go.mailbox.\(box.id)", menu: .go, title: box.title,
                key: KeyEquivalent(Character(String(index + 1))), scopes: [.mail])
    }

    // MARK: Window

    /// Brings the main window forward, or opens it again after it was closed.
    static let mainWindow = Command("window.main", menu: .window, title: "Tern", key: "0", scopes: Scope.all)
    static let assistant = Command("window.assistant", menu: .window, title: "Assistant", key: "a",
                                   modifiers: [.option, .command], scopes: Scope.all)

    // MARK: Help

    static let keyboardShortcuts = Command("help.keyboardShortcuts", menu: .help, title: "Keyboard Shortcuts", key: "/",
                                           scopes: Scope.all)

    /// Every command, in menu order.
    static let all: [Command] = [
        newMessage, newChat, newEvent, newLabel, openConversation, attachFiles, print,
        find, searchMail,
        toggleSidebar, toggleToolbar, toggleReader, expandAll, collapseAll,
        checkForNewMail, markAllRead,
        send, reply, replyAll, forward, forwardAsAttachment, archive, moveToTrash, toggleSpam,
        toggleRead, toggleStar, markImportant, editLabels, moveTo, snooze,
        bold, italic, underline, link,
        today, goToDate,
    ] + calendarModes + [
        goMail, goCalendar, goAttachments, goToLabel,
    ] + mailboxes + [
        mainWindow, assistant,
        keyboardShortcuts,
    ]

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
