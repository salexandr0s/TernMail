import Foundation
import MailStore

public enum NewsletterActionError: Error, Sendable, LocalizedError {
    case unavailable
    case requestFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This newsletter's unsubscribe action is no longer available. Refresh the list and try again."
        case .requestFailed: "The request could not be confirmed. It may have reached the sender. Check before retrying."
        }
    }
}

extension SyncEngine {
    /// Called only for a user-selected row. The stored, validated endpoint is
    /// claimed once and sent without Google credentials through its own transport.
    @discardableResult
    public func requestNewsletterUnsubscribe(id: String,
        transport: any NewsletterUnsubscribeTransport = NewsletterHTTPSession.shared) async throws -> NewsletterSubscription {
        try checkNewsletterAccess()
        let accountID = accountID, ownerID = newsletterOwnerID, date = now()
        let requestID = ownerID + ":" + UUID().uuidString
        let abandoned = abandonedNewsletterRequests
        let claimed = try await write { tx in
            try tx.recoverNewsletterRequests(accountID: accountID, ownerID: ownerID,
                abandonedRequestIDs: abandoned, now: date)
            return try tx.claimNewsletterRequest(id: id, accountID: accountID, requestID: requestID, now: date)
        }
        abandonedNewsletterRequests.subtract(abandoned)
        guard let claimed, let url = claimed.oneClickURL else { throw NewsletterActionError.unavailable }
        let request = Task {
            try self.checkNewsletterAccess()
            try await transport.unsubscribe(at: url)
        }
        newsletterRequestTasks[requestID] = request
        defer { newsletterRequestTasks[requestID] = nil }
        do {
            try await withTaskCancellationHandler {
                try await request.value
            } onCancel: { request.cancel() }
            // A completed request is recorded even when its caller canceled just
            // after the response. Engine teardown still fences this write.
            try await finishNewsletterRequest(id: id, requestID: requestID, accepted: true)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            do { try await finishNewsletterRequest(id: id, requestID: requestID, accepted: false) }
            catch { abandonedNewsletterRequests.insert(requestID) }
            if cancelled { throw CancellationError() }
            throw NewsletterActionError.requestFailed
        }
        try checkNewsletterAccess()
        guard let updated = try await cache.read({ try $0.newsletter(id: id, accountID: accountID) }) else {
            throw NewsletterActionError.unavailable
        }
        return updated
    }

    private func finishNewsletterRequest(id: String, requestID: String, accepted: Bool) async throws {
        // This task deliberately does not inherit the caller's cancellation:
        // the ambiguous/successful outcome must survive closing the page.
        let completion = Task {
            try self.checkNewsletterAccess()
            let accountID = self.accountID, date = self.now()
            let message = accepted ? nil : NewsletterActionError.requestFailed.errorDescription
            try await self.write {
                try $0.finishNewsletterRequest(id: id, accountID: accountID, requestID: requestID,
                    accepted: accepted, error: message, now: date)
            }
        }
        try await completion.value
    }

    @discardableResult
    public func markNewsletterOpened(id: String) async throws -> NewsletterSubscription {
        try checkNewsletterAccess()
        let accountID = accountID, date = now()
        guard let row = try await write({ try $0.markNewsletterOpened(id: id, accountID: accountID, now: date) })
        else { throw NewsletterActionError.unavailable }
        return row
    }

    @discardableResult
    public func confirmNewsletterUnsubscribed(id: String) async throws -> NewsletterSubscription {
        try checkNewsletterAccess()
        let accountID = accountID, date = now()
        guard let row = try await write({ try $0.confirmNewsletterUnsubscribed(id: id, accountID: accountID, now: date) })
        else { throw NewsletterActionError.unavailable }
        return row
    }

    @discardableResult
    public func resetNewsletterStatus(id: String) async throws -> NewsletterSubscription {
        _ = try await newsletterSnapshot()
        try checkNewsletterAccess()
        let accountID = accountID
        guard let row = try await write({ try $0.resetNewsletterStatus(id: id, accountID: accountID) })
        else { throw NewsletterActionError.unavailable }
        return row
    }
}
