import Foundation

enum ReadingPreferences {
    static let blockImagesKey = "blockRemoteImages"
    static let adaptDarkKey = "adaptMailToDarkMode"
    static let orderKey = "conversationMessageOrder"
    static let markReadKey = "markMailReadPolicy"
    static let readDelayKey = "markMailReadDelay"
    static let textScaleKey = "mailTextScale"
    static let sizeKey = "showMessageSize"
    static let imagePermissionChanged = Notification.Name("TernImageSenderPermissionChanged")

    enum Order: String, CaseIterable { case oldestFirst, newestFirst }
    enum MarkRead: String, CaseIterable { case immediately, delayed, manually }

    static func textScale(_ value: Double) -> Double { value.isFinite ? min(1.5, max(0.85, value)) : 1 }
    static func readDelay(_ value: Double) -> Duration { .seconds(value.isFinite ? min(30, max(1, value)) : 3) }

    /// The messages a conversation opens with: the newest, every unread one
    /// and the one chosen in a message list. The others start collapsed.
    /// `ids` run oldest first.
    static func initiallyExpanded(ids: [String], unread: Set<String>, selected: String?) -> Set<String> {
        var expanded = unread
        if let newest = ids.last { expanded.insert(newest) }
        if let selected { expanded.insert(selected) }
        return expanded
    }
}

/// Cancelling the owning view or changing its identity invalidates a delayed read.
@MainActor
final class DelayedReadController {
    private var generation = 0
    private var task: Task<Void, Never>?

    func schedule(delay: Duration, action: @escaping @MainActor () async -> Void) {
        cancel()
        let current = generation
        task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, self?.generation == current else { return }
            await action()
        }
    }

    func cancel() { generation += 1; task?.cancel(); task = nil }
}
