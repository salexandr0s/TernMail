import Foundation

/// Account removal must erase learned preferences even when the assistant has
/// never been opened. This path does not initialize ChatGPT or access Keychain.
@MainActor
enum AssistantWritingStyleCleanup {
    static func remove(accountID: String, store supplied: (any AssistantWritingStyleStore)? = nil) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 512 else {
            throw AssistantWritingStyleStoreError.invalidData
        }
        let store = supplied ?? AssistantWritingStyleStores.makeDefault()
        var disabled = store.disabledAccountIDs
        disabled.insert(accountID)
        try store.setDisabledAccountIDs(disabled)
        var archive = try store.load()
        archive.profiles.removeAll { $0.accountID == accountID }
        archive.disabledAccountIDs.formUnion(disabled)
        try store.save(archive)
    }
}
