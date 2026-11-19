#if TERN_TEST_SUPPORT || TERN_PERFORMANCE
import AppKit
import Foundation
import MessageContent
import SyncEngine

/// Times opening a compose window through its menu item, as File > New
/// Message and Message > Reply do. The item runs the command's own action, so
/// the draft, the window and the field that gets the cursor all come from app
/// code. Each window closes untouched, which discards its draft.
@MainActor
enum PerformanceComposeAudit {
    /// One window opened through the menu item. Each time counts from the
    /// item's action and is nil when that moment never came.
    struct Record: Codable {
        /// The window became key. Keys typed before this go to the main window.
        let keyMilliseconds: Double?
        /// The main thread was first free with the window on screen.
        let windowMilliseconds: Double?
        /// A field in the window had the cursor. Keys typed after the window
        /// became key and before this are held, then typed into the field.
        let cursorMilliseconds: Double?
        /// The main thread stayed free after the cursor arrived.
        let settledMilliseconds: Double?
        /// From asking the window to close until it was gone.
        let closeMilliseconds: Double?
    }

    struct Result: Codable {
        let name: String
        let requestedOpenings: Int
        let completedOpenings: Int
        let failureReason: String?
        /// The draft alone, made by the same model call with no window.
        let draftOnly: NavigationPerformance.Summary?
        let key: NavigationPerformance.Summary?
        let window: NavigationPerformance.Summary?
        let cursor: NavigationPerformance.Summary?
        let settled: NavigationPerformance.Summary?
        let close: NavigationPerformance.Summary?
        let records: [Record]
    }

    /// Opens `count` new messages, then `count` replies to a conversation in
    /// the list, each after three untimed ones. `mayStart` says whether the
    /// main window may start the next opening; it can't while a compose window
    /// is key.
    static func run(mailbox: MailboxModel, count: Int, mayStart: () -> Bool,
                    hadInput: () -> Bool, interruption: () -> String) async -> [Result] {
        let newMessage = await measure("compose-new", menuItem: "New Message", count: count,
                                       mayStart: mayStart, hadInput: hadInput, interruption: interruption) {
            guard let id = await mailbox.startCompose(.newMessage) else { return nil }
            return (id, mailbox.composeAccount.engine)
        }
        guard let row = mailbox.listItems.first(where: { $0.id.threadID.hasPrefix("performance-thread-") })?.id else {
            return [newMessage, failure("compose-reply", count: count, reason: "No conversation to reply to was listed.")]
        }
        mailbox.selectListRows([row])
        // The reader reads the conversation before Reply has a message to answer.
        guard await waitUntil(timeout: .seconds(5), { mailbox.canReply }) else {
            return [newMessage, failure("compose-reply", count: count, reason: "The selected conversation never had a message to answer.")]
        }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return [newMessage] }
        let reply = await measure("compose-reply", menuItem: "Reply", count: count,
                                  mayStart: mayStart, hadInput: hadInput, interruption: interruption) {
            guard let accountID = mailbox.replyTarget?.accountID, let owner = mailbox.account(id: accountID),
                  let id = await mailbox.startReply(.reply, quote: nil) else { return nil }
            return (id, owner.engine)
        }
        return [newMessage, reply]
    }

    private static let warmup = 3

    /// Times `count` windows opened through the menu item, then `count` drafts
    /// made by `makeDraft` alone. The drafts come after the windows, so their
    /// discards are queued after the last window closed.
    private static func measure(_ name: String, menuItem title: String, count: Int, mayStart: () -> Bool,
                                hadInput: () -> Bool, interruption: () -> String,
                                makeDraft: () async -> (id: String, engine: SyncEngine)?) async -> Result {
        var records: [Record] = []
        var failureReason: String?
        for index in 0..<(warmup + count) {
            // A compose window that just closed hands the keyboard back to
            // the main window, and the menu follows a moment later.
            guard await waitUntil(timeout: .seconds(3), mayStart) else {
                failureReason = interruption()
                break
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { failureReason = "Audit cancelled."; break }
            let opening = await open(menuItem: title)
            if hadInput() {
                failureReason = interruption()
                break
            }
            switch opening {
            case .opened(let record):
                if index >= warmup { records.append(record) }
            case .failed(let reason):
                failureReason = reason
            }
            if failureReason != nil { break }
        }
        var drafts: [Double] = []
        if failureReason == nil {
            for index in 0..<(warmup + count) {
                let started = ContinuousClock.now
                guard let draft = await makeDraft() else {
                    failureReason = "A draft could not be made without its window."
                    break
                }
                if index >= warmup { drafts.append(NavigationPerformance.milliseconds(ContinuousClock.now - started)) }
                // As closing its untouched window would.
                _ = try? await draft.engine.discardDraft(draft.id, hold: 0)
            }
        }
        func summary(_ value: (Record) -> Double?) -> NavigationPerformance.Summary? {
            NavigationPerformance.Summary(records.compactMap(value))
        }
        return Result(name: name, requestedOpenings: count, completedOpenings: records.count,
                      failureReason: failureReason, draftOnly: NavigationPerformance.Summary(drafts),
                      key: summary(\.keyMilliseconds), window: summary(\.windowMilliseconds),
                      cursor: summary(\.cursorMilliseconds), settled: summary(\.settledMilliseconds),
                      close: summary(\.closeMilliseconds), records: records)
    }

    private enum Opening {
        case opened(Record)
        case failed(String)
    }

    /// When each window first became key since the observer started.
    @MainActor
    private final class KeyMoments {
        private(set) var moments: [ObjectIdentifier: ContinuousClock.Instant] = [:]

        func record(_ window: ObjectIdentifier) {
            if moments[window] == nil { moments[window] = ContinuousClock.now }
        }
    }

    private static func open(menuItem title: String) async -> Opening {
        var target: (menu: NSMenu, index: Int)?
        guard await waitUntil(timeout: .seconds(2), {
            target = menuItem(titled: title)
            return target.map { $0.menu.items[$0.index].isEnabled } ?? false
        }), let target else {
            return .failed("The \(title) menu item was \(target == nil ? "missing" : "disabled").")
        }
        let shown = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        let keyMoments = KeyMoments()
        // AppKit posts this on the main thread, and a nil queue delivers it there at once.
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                              object: nil, queue: nil) { note in
            guard let window = note.object as? NSWindow else { return }
            let id = ObjectIdentifier(window)
            MainActor.assumeIsolated { keyMoments.record(id) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let clock = ContinuousClock()
        let started = clock.now
        target.menu.performActionForItem(at: target.index)
        var window: NSWindow?
        var windowAt: ContinuousClock.Instant?
        var cursorAt: ContinuousClock.Instant?
        let deadline = started.advanced(by: .seconds(5))
        while cursorAt == nil, clock.now < deadline {
            if window == nil, let found = NSApp.windows.first(where: { isNewWindow($0, shown: shown) }) {
                window = found
                windowAt = clock.now
            }
            // The same test the window's type-ahead uses before it types the held keys.
            if let window, (window.firstResponder as? NSText)?.isEditable == true {
                cursorAt = clock.now
            } else {
                do { try await Task.sleep(for: .milliseconds(1)) } catch { break }
            }
        }
        guard let window else { return .failed("No compose window opened within 5 seconds.") }
        var settledAt: ContinuousClock.Instant?
        if let cursorAt { settledAt = await settled(after: cursorAt) }
        let closeStarted = clock.now
        window.performClose(nil)
        let closed = await waitUntil(timeout: .seconds(5), { !window.isVisible })
        guard closed else { return .failed("A compose window did not close within 5 seconds.") }
        guard cursorAt != nil else { return .failed("No field in a compose window had the cursor within 5 seconds.") }
        func elapsed(_ instant: ContinuousClock.Instant?) -> Double? {
            instant.map { NavigationPerformance.milliseconds($0 - started) }
        }
        return .opened(Record(keyMilliseconds: elapsed(keyMoments.moments[ObjectIdentifier(window)]),
                              windowMilliseconds: elapsed(windowAt), cursorMilliseconds: elapsed(cursorAt),
                              settledMilliseconds: elapsed(settledAt),
                              closeMilliseconds: NavigationPerformance.milliseconds(clock.now - closeStarted)))
    }

    /// A window that came on screen after `shown` was taken. Panels, such as
    /// tooltips, don't count.
    private static func isNewWindow(_ window: NSWindow, shown: Set<ObjectIdentifier>) -> Bool {
        window.isVisible && !shown.contains(ObjectIdentifier(window)) && !(window is NSPanel)
            && window.styleMask.contains(.titled)
    }

    /// The main menu's item with `title`. SwiftUI gives its command items an
    /// action and their enabled state only when AppKit says their menu is
    /// about to open, so each menu gets that call before it is searched.
    private static func menuItem(titled title: String) -> (menu: NSMenu, index: Int)? {
        func search(_ menu: NSMenu) -> (menu: NSMenu, index: Int)? {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            for (index, item) in menu.items.enumerated() {
                if let submenu = item.submenu {
                    if let found = search(submenu) { return found }
                } else if item.title == title {
                    return (menu, index)
                }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(search)
    }

    /// When the main thread came free after `start`: two short sleeps in a row
    /// returned on time. Nil when that took over two seconds.
    private static func settled(after start: ContinuousClock.Instant) async -> ContinuousClock.Instant? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        var settled = start
        var onTime = 0
        while onTime < 2 {
            guard clock.now < deadline else { return nil }
            let before = clock.now
            do { try await Task.sleep(for: .milliseconds(8)) } catch { return nil }
            if clock.now - before < .milliseconds(16) { onTime += 1 } else { onTime = 0; settled = clock.now }
        }
        return settled
    }

    private static func waitUntil(timeout: Duration, _ ready: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if ready() { return true }
            do { try await Task.sleep(for: .milliseconds(2)) } catch { return false }
        }
        return false
    }

    private static func failure(_ name: String, count: Int, reason: String) -> Result {
        Result(name: name, requestedOpenings: count, completedOpenings: 0, failureReason: reason, draftOnly: nil,
               key: nil, window: nil, cursor: nil, settled: nil, close: nil, records: [])
    }
}
#endif
