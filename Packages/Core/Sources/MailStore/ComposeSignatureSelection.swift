import Foundation
import MessageContent

public struct DraftSignature: Sendable, Equatable {
    public var html: String?
    public var aboveQuote: Bool
    public var separator: Bool
}

extension AccountStore {
    /// Resolves an exact address override before the account-wide default.
    /// Callers save the result with the draft rather than resolving it at send time.
    public func composeSignature(accountID: String, address: String, kind: LocalDraft.Kind) async throws -> DraftSignature {
        guard let account = try await accounts().first(where: { $0.id == accountID }) else {
            return DraftSignature(html: nil, aboveQuote: true, separator: false)
        }
        let identity = try await identities(accountID: accountID).first { $0.lowercasedAddress == address.lowercased() && $0.canSend }
        let assignments = try await signatureAssignments(accountID: accountID)
        let assignment = assignments.first { $0.address == address.lowercased() } ?? assignments.first { $0.address.isEmpty }
        let isNew = kind == .new || kind == .edit
        guard let assignment else {
            return DraftSignature(html: isNew || account.signatureOnReplies ? identity?.signatureHTML : nil,
                                  aboveQuote: true, separator: false)
        }
        let selection = isNew ? assignment.newMessages : assignment.replies
        let html: String?
        switch selection {
        case .none: html = nil
        case .gmail: html = identity?.signatureHTML
        case .local(let id): html = try await localSignatures().first { $0.id == id }?.document.html()
        }
        return DraftSignature(html: html, aboveQuote: assignment.placeAboveQuote, separator: assignment.includeSeparator)
    }
}
