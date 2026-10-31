import MessageContent
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A conversation dragged inside Tern. Info.plist exports the type.
    static let ternConversation = UTType(exportedAs: "dev.tern.mail.conversation")
}

/// One conversation in a drag. Message list rows provide it; sidebar labels
/// and the calendar grid accept it. Other apps receive the `tern://` link.
struct ConversationDragItem: Codable, Hashable, Sendable, Transferable {
    let link: MailLink

    init(_ link: MailLink) { self.link = link }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .ternConversation)
        ProxyRepresentation { item in
            guard let url = item.link.ternURL else { throw TransferError.noLink }
            return url
        }
    }

    private enum TransferError: Error { case noLink }
}
