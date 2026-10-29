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
        /// Not a shortcut. The monitor lets the event through.
        case ignored
    }

    /// How long after "g" the second key still counts.
    static let destinationTimeout: TimeInterval = 1.5

    private var prefixTime: TimeInterval?

    /// Only Shift may be held. ⌘, ⌥ and ⌃ keys belong to menus and text input.
    static func accepts(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.isDisjoint(with: [.command, .option, .control])
    }

    /// - Parameters:
    ///   - characters: The event's characters, with Shift applied.
    ///   - shift: Whether Shift is held. Without it, letters count as lowercase,
    ///     so Caps Lock neither breaks "e" nor turns "i" into Mark as Read.
    ///   - time: The event's timestamp, in seconds.
    mutating func outcome(for characters: String, shift: Bool, at time: TimeInterval) -> Outcome {
        let prefix = prefixTime
        prefixTime = nil
        guard characters.count == 1 else { return .ignored }
        let key = shift ? characters : characters.lowercased()

        if let prefix, time - prefix <= Self.destinationTimeout {
            return Self.destinations[key].map { .perform(.go($0)) } ?? .ignored
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

    private static let actions: [String: Action] = [
        "j": .nextConversation, "k": .previousConversation,
        "o": .openConversation, "\r": .openConversation,
        "e": .archive, "#": .trash, "s": .toggleStar,
        "I": .markRead, "U": .markUnread,
        "l": .editLabels, "v": .moveTo, "b": .snooze,
        "/": .search, "c": .newMessage,
        "r": .reply, "a": .replyAll, "f": .forward,
        "z": .undo, "?": .showShortcuts,
    ]

    private static let destinations: [String: Destination] = [
        "i": .inbox, "s": .starred, "b": .snoozed, "d": .drafts, "t": .sent, "a": .allMail,
    ]
}
