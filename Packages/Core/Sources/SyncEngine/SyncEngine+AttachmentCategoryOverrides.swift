import MailStore

extension SyncEngine {
    func attachmentCategoryOverrides(messageIDs: [String]) async throws -> [AttachmentCategoryOverride] {
        try checkAttachmentAccess()
        guard let accounts, !messageIDs.isEmpty else { return [] }
        let result = try await accounts.attachmentCategoryOverrides(accountID: accountID, messageIDs: messageIDs)
        try checkAttachmentAccess()
        return result
    }
}
