import Foundation

public struct ThreadListPage: Decodable, Sendable {
    public struct Thread: Decodable, Sendable, Hashable {
        public let id: String
        public let snippet: String?
        public let historyId: String?
    }

    public let threads: [Thread]?
    public let nextPageToken: String?
    public let resultSizeEstimate: Int?
}

extension GmailClient {
    /// One page of `threads.list`, newest conversation first. `query` takes
    /// the same syntax as Gmail's search box.
    public func listThreads(
        query: String? = nil,
        labelIDs: [String] = [],
        includeSpamTrash: Bool = false,
        pageToken: String? = nil,
        maxResults: Int = 25
    ) async throws -> ThreadListPage {
        let items = Self.listQuery(
            query: query,
            labelIDs: labelIDs,
            includeSpamTrash: includeSpamTrash,
            pageToken: pageToken,
            maxResults: maxResults
        )
        return try decode(await send(.get("threads", items)))
    }

    /// `threads.get` for each ID through `/batch`.
    public func threads(
        ids: [String],
        format: MessageFormat,
        metadataHeaders: [String] = []
    ) async throws -> [String: Result<GmailThread, GmailError>] {
        let items = Self.formatQuery(format, metadataHeaders: metadataHeaders)
        return try await batchDecode(ids) { .get("threads/\($0)", items) }
    }
}
