import AppKit
import Testing
@testable import Tern

@Suite struct SingleKeyShortcutsTests {
    @Test func keysMatchByCharacterAndShiftMatters() {
        var keys = SingleKeyShortcuts()
        #expect(keys.outcome(for: "e", shift: false, at: 0) == .perform(.archive))
        #expect(keys.outcome(for: "#", shift: true, at: 0) == .perform(.trash))
        #expect(keys.outcome(for: "I", shift: true, at: 0) == .perform(.markRead))
        #expect(keys.outcome(for: "U", shift: true, at: 0) == .perform(.markUnread))
        #expect(keys.outcome(for: "\r", shift: false, at: 0) == .perform(.openConversation))
        // Lowercase i and u aren't shortcuts, and Shift turns e into something else.
        #expect(keys.outcome(for: "i", shift: false, at: 0) == .ignored)
        #expect(keys.outcome(for: "E", shift: true, at: 0) == .ignored)
        // Caps Lock: uppercase characters without Shift count as lowercase.
        #expect(keys.outcome(for: "E", shift: false, at: 0) == .perform(.archive))
        #expect(keys.outcome(for: "I", shift: false, at: 0) == .ignored)
        #expect(keys.outcome(for: "ab", shift: false, at: 0) == .ignored)
    }

    @Test func gPicksAMailboxOnlyWithinTheTimeout() {
        var keys = SingleKeyShortcuts()
        #expect(keys.outcome(for: "g", shift: false, at: 10) == .awaitingDestination)
        #expect(keys.outcome(for: "i", shift: false, at: 11) == .perform(.go(.inbox)))
        // After the destination, "s" stars again.
        #expect(keys.outcome(for: "s", shift: false, at: 11.2) == .perform(.toggleStar))

        // A key that isn't a destination cancels the prefix and does nothing.
        #expect(keys.outcome(for: "g", shift: false, at: 20) == .awaitingDestination)
        #expect(keys.outcome(for: "e", shift: false, at: 20.5) == .ignored)
        #expect(keys.outcome(for: "e", shift: false, at: 20.6) == .perform(.archive))

        // A late second key is read on its own.
        #expect(keys.outcome(for: "g", shift: false, at: 30) == .awaitingDestination)
        #expect(keys.outcome(for: "s", shift: false, at: 31.6) == .perform(.toggleStar))

        #expect(keys.outcome(for: "g", shift: false, at: 40) == .awaitingDestination)
        keys.reset()
        #expect(keys.outcome(for: "a", shift: false, at: 40.1) == .perform(.replyAll))
    }

    @Test func onlyShiftMayBeHeld() {
        #expect(SingleKeyShortcuts.accepts([]))
        #expect(SingleKeyShortcuts.accepts([.shift, .capsLock]))
        #expect(!SingleKeyShortcuts.accepts([.command]))
        #expect(!SingleKeyShortcuts.accepts([.option, .shift]))
        #expect(!SingleKeyShortcuts.accepts([.control]))
    }
}
