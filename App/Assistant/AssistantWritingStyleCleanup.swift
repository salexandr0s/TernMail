import Foundation

/// Account removal must erase learned preferences even when the assistant has
/// never been opened. This path does not initialize ChatGPT or access Keychain.
@MainActor
enum AssistantWritingStyleCleanup {
    /// Saves the opt-out at once, then rewrites the profile file without the account.
    /// It returns when the file is written, so a caller that records the removal as
    /// done afterwards cannot lose it to a quit in between.
    static func erase(accountID: String, store supplied: (any AssistantWritingStyleStore)? = nil) async throws {
        let store = supplied ?? AssistantWritingStyleStores.makeDefault()
        try await queueErasure(accountID: accountID, store: store).value
    }

    /// Nothing suspends between reading the archive and queueing its replacement,
    /// so no other write can come between them.
    private static func queueErasure(accountID: String,
                                     store: any AssistantWritingStyleStore) throws -> AssistantWritingStyleWrite {
        guard !accountID.isEmpty, accountID.utf8.count <= 512 else {
            throw AssistantWritingStyleStoreError.invalidData
        }
        var disabled = store.disabledAccountIDs
        disabled.insert(accountID)
        try store.setDisabledAccountIDs(disabled)
        var archive = try store.load()
        archive.profiles.removeAll { $0.accountID == accountID }
        archive.disabledAccountIDs.formUnion(disabled)
        return try store.save(archive)
    }
}
