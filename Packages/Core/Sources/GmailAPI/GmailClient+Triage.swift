import Foundation

public enum LabelListVisibility: String, Codable, Sendable, CaseIterable {
    case show = "labelShow"
    case hide = "labelHide"
    case showIfUnread = "labelShowIfUnread"
}

/// Optional mail capabilities, separate from the sync/read service.
public protocol TriageService: Sendable {
    func rawMessage(id: String) async throws -> Data
    func batchDeleteMessages(ids: [String]) async throws
    func trashMessages(ids: [String]) async throws -> [String: GmailError]
    func untrashMessages(ids: [String]) async throws -> [String: GmailError]
    func patchLabelVisibility(id: String, visibility: LabelListVisibility) async throws -> GmailLabel
}

extension GmailClient: TriageService {
    public func rawMessage(id: String) async throws -> Data {
        try Self.validateTriageIDs([id])
        let response: RawMessage = try decode(await send(.get("messages/\(id)", [.init(name: "format", value: "raw")])))
        guard response.id == id, let bytes = Data(base64URLEncoded: response.raw) else {
            throw GmailError.decoding("Raw message")
        }
        return bytes
    }

    /// Google documents no batchDelete limit; bounded requests use 1,000 IDs.
    public func batchDeleteMessages(ids: [String]) async throws {
        try Self.validateTriageIDs(ids)
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        for start in stride(from: 0, to: unique.count, by: 1000) {
            try Task.checkCancellation()
            let chunk = Array(unique[start..<min(start + 1000, unique.count)])
            _ = try await send(.post("messages/batchDelete", body: encode(DeletionBody(ids: chunk))))
        }
    }

    public func trashMessages(ids: [String]) async throws -> [String: GmailError] {
        try await changeMessageTrash(ids: ids, operation: "trash")
    }

    public func untrashMessages(ids: [String]) async throws -> [String: GmailError] {
        try await changeMessageTrash(ids: ids, operation: "untrash")
    }

    public func patchLabelVisibility(id: String, visibility: LabelListVisibility) async throws -> GmailLabel {
        try Self.validateTriageIDs([id])
        return try decode(await send(.patch("labels/\(id)", body: encode(VisibilityBody(labelListVisibility: visibility)))))
    }

    private func changeMessageTrash(ids: [String], operation: String) async throws -> [String: GmailError] {
        try Self.validateTriageIDs(ids)
        var failures: [String: GmailError] = [:]
        for id in Set(ids).sorted() {
            try Task.checkCancellation()
            do { _ = try await send(.post("messages/\(id)/\(operation)")) }
            catch let error as GmailError { failures[id] = error }
        }
        return failures
    }

    private static func validateTriageIDs(_ ids: [String]) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard ids.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw GmailError.invalidRequest("Invalid mail identifier")
        }
    }
}

private struct RawMessage: Decodable { let id: String; let raw: String }
private struct DeletionBody: Encodable { let ids: [String] }
private struct VisibilityBody: Encodable { let labelListVisibility: LabelListVisibility }
