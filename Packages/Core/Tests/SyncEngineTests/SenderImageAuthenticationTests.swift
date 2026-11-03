import Foundation
import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct SenderImageAuthenticationTests {
    @Test func metadataMapsEvidenceAndNewerUnverifiedMailClearsPositiveCacheState() async throws {
        #expect(SyncEngine.metadataHeaders.contains("Authentication-Results"))
        let cache = try MailCache.inMemory()
        let verified = try Mapping.message(message(historyID: 100,
            authentication: "mx.google.com; dmarc=pass header.from=example.com"), accountID: "account")
        #expect(verified.record.verifiedImageSender == "trusted@example.com")
        try await cache.write { tx in _ = try tx.upsertMessages([verified]) }
        #expect(try await cache.read { try $0.message(id: "message", accountID: "account")?.verifiedImageSender } == "trusted@example.com")

        let unverified = try Mapping.message(message(historyID: 101, authentication: nil), accountID: "account")
        try await cache.write { tx in _ = try tx.upsertMessages([unverified]) }
        #expect(try await cache.read { try $0.message(id: "message", accountID: "account")?.verifiedImageSender } == nil)

        // A late response cannot put the previous positive result back.
        try await cache.write { tx in _ = try tx.upsertMessages([verified]) }
        #expect(try await cache.read { try $0.message(id: "message", accountID: "account")?.verifiedImageSender } == nil)
    }

    private func message(historyID: Int, authentication: String?) throws -> GmailMessage {
        var headers = [["name": "From", "value": "Trusted <trusted@example.com>"]]
        if let authentication { headers.append(["name": "Authentication-Results", "value": authentication]) }
        let object: [String: Any] = ["id": "message", "threadId": "thread", "historyId": String(historyID),
                                   "payload": ["headers": headers]]
        return try JSONDecoder().decode(GmailMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
