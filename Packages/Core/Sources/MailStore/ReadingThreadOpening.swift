import Foundation

/// What the reader draws first when a conversation opens: the conversation,
/// and the inline resources of the messages it opens with.
public struct ReadingThreadOpening: Sendable {
    public let detail: ThreadDetail?
    /// By message ID. Holds only the messages that were asked for and have a saved body.
    public let resources: [String: ReadingResourceSnapshot]
}

extension MailCache {
    /// Reads a conversation and, in the same transaction, the inline
    /// resources of the messages `opensWith` picks from it. The reader can
    /// then prepare those messages without a second read for each.
    ///
    /// Later changes still come from `thread(accountID:threadID:)` and
    /// `readingResources(messageID:accountID:)`. Their first values equal
    /// what this returns unless a write came between.
    ///
    /// A message without a saved body is left out. Its resources are saved
    /// with its body, and its own observation delivers them then.
    public func readingThreadOpening(
        accountID: String, threadID: String,
        opensWith: @escaping @Sendable (ThreadDetail) -> [String]
    ) async throws -> ReadingThreadOpening {
        try await read { transaction in
            guard let detail = try transaction.threadDetail(threadID: threadID, accountID: accountID) else {
                return ReadingThreadOpening(detail: nil, resources: [:])
            }
            let saved = Set(detail.messages.lazy.filter { $0.body != nil }.map(\.id))
            var resources: [String: ReadingResourceSnapshot] = [:]
            for messageID in opensWith(detail) where saved.contains(messageID) {
                resources[messageID] = ReadingResourceSnapshot(
                    resources: try transaction.mimeResources(messageID: messageID, accountID: accountID))
            }
            return ReadingThreadOpening(detail: detail, resources: resources)
        }
    }
}
