import AppKit

/// Gmail-style single-key commands. The event monitor decides whether a key
/// press may count at all (window and focus); this type maps the keys it
/// passes on.
struct SingleKeyShortcuts {
    enum Action: Equatable {
        case nextConversation, previousConversation, openConversation
        case archive, trash, toggleStar, markRead, markUnread
        case editLabels, moveTo, snooze, search, newMessage
        case reply, replyAll, forward, undo, showShortcuts
        case go(Destination)
    }

    enum Destination: Equatable {
        case inbox, starred, snoozed, drafts, sent, allMail
    }

    enum Outcome: Equatable {
        case perform(Action)
        /// "g" was pressed; the next key picks a mailbox.
        case awaitingDestination
        /// A held shortcut key repeating. Only J and K repeat; the monitor
        /// drops the rest so holding E archives one conversation.
        case held
        /// Not a shortcut. The monitor lets the event through.
        case ignored
    }

    /// One key's command, as the lookup and Help ▸ Keyboard Shortcuts use it.
    struct Key: Sendable {
        /// What the event's characters must be, with Shift applied.
        let characters: [String]
        let action: Action
        let title: String

        /// The keys as Help shows them.
        var label: String {
            characters.map { character in
                if character == "\r" { return "Return" }
                return character.first?.isUppercase == true ? "⇧" + character : character
            }
            .joined(separator: " or ")
        }
    }

    /// The Settings switch, off until the user turns it on.
    static let settingKey = "singleKeyShortcuts"

    /// How long after "g" the second key still counts.
    static let destinationTimeout: TimeInterval = 1.5

    /// Every key, in the order Help lists them.
    static let keys = [
        Key(characters: ["j"], action: .nextConversation, title: "Next Conversation"),
        Key(characters: ["k"], action: .previousConversation, title: "Previous Conversation"),
        Key(characters: ["o", "\r"], action: .openConversation, title: "Open Conversation"),
        Key(characters: ["e"], action: .archive, title: "Archive"),
        Key(characters: ["#"], action: .trash, title: "Move to Trash"),
        Key(characters: ["s"], action: .toggleStar, title: "Star or Remove Star"),
        Key(characters: ["I"], action: .markRead, title: "Mark as Read"),
        Key(characters: ["U"], action: .markUnread, title: "Mark as Unread"),
        Key(characters: ["l"], action: .editLabels, title: "Edit Labels…"),
        Key(characters: ["v"], action: .moveTo, title: "Move to…"),
        Key(characters: ["b"], action: .snooze, title: "Snooze…"),
        Key(characters: ["/"], action: .search, title: "Search Mail"),
        Key(characters: ["c"], action: .newMessage, title: "New Message"),
        Key(characters: ["r"], action: .reply, title: "Reply"),
        Key(characters: ["a"], action: .replyAll, title: "Reply All"),
        Key(characters: ["f"], action: .forward, title: "Forward"),
        Key(characters: ["z"], action: .undo, title: "Undo"),
        Key(characters: ["?"], action: .showShortcuts, title: "Keyboard Shortcuts"),
    ]

    /// The second key after "g", in the order Help lists them.
    static let destinationKeys = [
        Key(characters: ["i"], action: .go(.inbox), title: "Go to Inbox"),
        Key(characters: ["s"], action: .go(.starred), title: "Go to Starred"),
        Key(characters: ["b"], action: .go(.snoozed), title: "Go to Snoozed"),
        Key(characters: ["d"], action: .go(.drafts), title: "Go to Drafts"),
        Key(characters: ["t"], action: .go(.sent), title: "Go to Sent"),
        Key(characters: ["a"], action: .go(.allMail), title: "Go to All Mail"),
    ]

    private var prefixTime: TimeInterval?

    /// Only Shift may be held. ⌘, ⌥ and ⌃ keys belong to menus and text input.
    static func accepts(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.isDisjoint(with: [.command, .option, .control])
    }

    /// - Parameters:
    ///   - characters: The event's characters, with Shift applied.
    ///   - shift: Whether Shift is held. Without it, letters count as lowercase,
    ///     so Caps Lock neither breaks "e" nor turns "i" into Mark as Read.
    ///   - isRepeat: Whether the event is a repeat of a held key.
    ///   - time: The event's timestamp, in seconds.
    mutating func outcome(for characters: String, shift: Bool, isRepeat: Bool = false, at time: TimeInterval) -> Outcome {
        guard characters.count == 1 else {
            prefixTime = nil
            return .ignored
        }
        let key = shift ? characters : characters.lowercased()
        if isRepeat {
            // A repeat leaves a pending "g" alone, so holding it still waits.
            guard let action = Self.actions[key] else { return key == "g" ? .held : .ignored }
            return [.nextConversation, .previousConversation].contains(action) ? .perform(action) : .held
        }
        let prefix = prefixTime
        prefixTime = nil

        if let prefix, time - prefix <= Self.destinationTimeout {
            return Self.destinations[key].map(Outcome.perform) ?? .ignored
        }
        if key == "g" {
            prefixTime = time
            return .awaitingDestination
        }
        return Self.actions[key].map(Outcome.perform) ?? .ignored
    }

    /// Drops a pending "g", for example when the window stops being key.
    mutating func reset() {
        prefixTime = nil
    }

    private static let actions = lookup(keys)
    private static let destinations = lookup(destinationKeys)

    private static func lookup(_ keys: [Key]) -> [String: Action] {
        Dictionary(uniqueKeysWithValues: keys.flatMap { key in key.characters.map { ($0, key.action) } })
    }
}
