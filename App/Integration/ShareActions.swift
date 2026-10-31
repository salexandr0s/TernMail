import Foundation
import MailStore
import MessageContent
import SwiftUI
import UniformTypeIdentifiers

/// One message as an .eml file for Share. Gmail sends the original RFC 822
/// bytes only when a service asks for the file, so an unopened Share menu
/// costs nothing.
struct MessageFileItem: Transferable {
    let mailbox: MailboxModel
    /// The message's conversation. Without a message ID or a preferred message,
    /// the conversation's newest message that isn't a draft is shared.
    let link: MailLink
    /// The message with selected text, used when the link names no message.
    let preferredMessageID: String?
    /// The message's subject when the caller has it. Otherwise it is read
    /// from the cache once the message is known.
    let subject: String?
    let preview: SharePreview<Never, Never>

    init(_ message: MessageDetail, mailbox: MailboxModel) {
        self.init(link: MailLink(accountID: message.record.accountID, threadID: message.record.threadID, messageID: message.id),
                  subject: message.record.subject, previewTitle: message.record.subject, mailbox: mailbox)
    }

    /// A nil `previewTitle` means the subject isn't known yet, so the preview says "Message".
    init(link: MailLink, preferredMessageID: String? = nil, subject: String? = nil, previewTitle: String?, mailbox: MailboxModel) {
        self.mailbox = mailbox
        self.link = link
        self.preferredMessageID = preferredMessageID
        self.subject = subject
        preview = SharePreview(previewTitle.map { $0.isEmpty ? "No Subject" : $0 } ?? "Message")
    }

    /// The .eml type, falling back to the generic message type.
    static let emlType = UTType(filenameExtension: "eml", conformingTo: .emailMessage) ?? .emailMessage

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: emlType) { item in
            let message = try await item.load()
            let file = try TemporaryShareFile.write(message.data, named: message.name, pathExtension: "eml")
            return SentTransferredFile(file, allowAccessingOriginalFile: false)
        }
        .suggestedFileName { item in item.subject.map { filename(forSubject: $0) + ".eml" } }
    }

    /// The subject made safe for a file name, or "Message" when nothing is left.
    static func filename(forSubject subject: String) -> String {
        TemporaryShareFile.safeName(subject, fallback: "Message")
    }

    @MainActor private func load() async throws -> (data: Data, name: String) {
        do {
            guard let owner = mailbox.account(id: link.accountID),
                  let messageID = try await resolveMessageID() else { throw CocoaError(.fileNoSuchFile) }
            let data = try await owner.engine.rawMessage(id: messageID)
            var subject = self.subject
            if subject == nil {
                let accountID = link.accountID
                subject = try await mailbox.cache.read { try $0.message(id: messageID, accountID: accountID) }?.subject
            }
            return (data, Self.filename(forSubject: subject ?? ""))
        } catch {
            if !(error is CancellationError) {
                mailbox.notice = MailboxModel.Notice(message: "Couldn't share this message. Try again.", isError: true)
            }
            throw error
        }
    }

    /// The link's message or the one with selected text, else the conversation's
    /// newest message that isn't a draft.
    @MainActor private func resolveMessageID() async throws -> String? {
        if let id = link.messageID ?? preferredMessageID { return id }
        for try await detail in mailbox.cache.thread(accountID: link.accountID, threadID: link.threadID) {
            return detail?.messages.last { !$0.labels.contains(SystemLabel.draft) }?.id
        }
        return nil
    }
}

/// Files handed to a share service. Each goes in a folder of its own, so two
/// items with the same name never replace each other while a service reads one.
enum TemporaryShareFile {
    /// Longest name kept, in UTF-8 bytes. File names can have 255, which
    /// leaves room for the extension.
    static let maximumNameBytes = 200

    /// Drops path separators, colons and control characters, and the leading
    /// dots that would hide the file.
    static func safeName(_ title: String, fallback: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        var name = ""
        for character in title.components(separatedBy: unsafe).joined(separator: "-") {
            guard name.utf8.count + character.utf8.count <= maximumNameBytes else { break }
            name.append(character)
        }
        let trimmed = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-")))
        return trimmed.isEmpty ? fallback : trimmed
    }

    static func write(_ data: Data, named name: String, pathExtension: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name, directoryHint: .notDirectory).appendingPathExtension(pathExtension)
        try data.write(to: file, options: .atomic)
        return file
    }
}
