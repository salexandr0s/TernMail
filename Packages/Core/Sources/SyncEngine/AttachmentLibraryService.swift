import Foundation
import GmailAPI

extension GmailService {
    /// In-memory providers can supply their existing full-message fixtures.
    /// GmailClient uses a field-masked request that omits all file bytes.
    public func attachmentMetadata(ids: [String]) async throws -> [String: Result<GmailMessage, GmailError>] {
        try await messages(ids: ids, format: .full, metadataHeaders: [])
    }

    public func attachmentHistory(startHistoryID: String, pageToken: String?) async throws -> HistoryPage {
        try await history(startHistoryID: startHistoryID, pageToken: pageToken)
    }
}
