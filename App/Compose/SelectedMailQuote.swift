import Foundation
import SwiftUI

/// Selection belongs to one exact message in one reader scene.
struct SelectedMailQuote: Equatable, Sendable {
    let accountID: String
    let threadID: String
    let messageID: String
    let text: String

    func belongsTo(accountID: String, threadID: String, messageID: String? = nil) -> Bool {
        self.accountID == accountID && self.threadID == threadID
            && (messageID == nil || self.messageID == messageID)
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension FocusedValues {
    @Entry var selectedMailQuote: SelectedMailQuote?
}
