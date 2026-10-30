import CryptoKit
import Foundation
import MailStore

extension SyncEngine {
    /// `directory` is the account's managed attachment root, as passed to downloadAttachment.
    public nonisolated static func attachmentCacheFolder(for attachment: AttachmentRecord, in directory: URL) -> URL {
        let key = [attachment.accountID, attachment.messageID, attachment.partID]
            .map { "\($0.utf8.count):\($0)" }.joined()
        let component = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: component, directoryHint: .isDirectory)
    }
}
