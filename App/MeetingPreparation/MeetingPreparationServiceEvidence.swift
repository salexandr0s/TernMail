import Foundation
import MailStore
import TernAI

enum MeetingPreparationEvidence {
    /// Fresh metadata supplies exact membership and acceptance headers. The
    /// bounded full read supplies attachment instances without downloading files.
    static func detail(_ detail: ThreadDetail, read: AssistantToolResult, thread: ThreadKey) throws -> ThreadDetail {
        guard detail.thread.accountID == thread.accountID, detail.thread.id == thread.threadID,
              detail.messages.allSatisfy({ $0.record.accountID == thread.accountID && $0.record.threadID == thread.threadID }),
              read.data["account_id"]?.stringValue == thread.accountID, read.data["thread_id"]?.stringValue == thread.threadID,
              let rawMessages = read.data["messages"]?.arrayValue, !rawMessages.isEmpty,
              let total = read.data["total_messages"]?.numberValue.flatMap({ Int(exactly: $0) }),
              total == detail.messages.count else { throw MeetingPreparationServiceError.invalidSource }
        let expected = Set(detail.messages.map(\.id))
        let readIDs = Set(rawMessages.compactMap { $0["message_id"]?.stringValue })
        guard readIDs.count == rawMessages.count, readIDs.isSubset(of: expected),
              Set(read.sources.compactMap(\.messageID)) == readIDs,
              read.sources.allSatisfy({ !$0.isCalendar && $0.accountID == thread.accountID && $0.threadID == thread.threadID
                  && $0.partID == nil && $0.messageID.map(readIDs.contains) == true }),
              rawMessages.allSatisfy({ $0["thread_id"]?.stringValue == thread.threadID }) else {
            throw MeetingPreparationServiceError.invalidSource
        }
        var attachments: [String: [AttachmentRecord]] = [:]
        for message in rawMessages {
            guard let messageID = message["message_id"]?.stringValue else { throw MeetingPreparationServiceError.invalidSource }
            for value in message["attachments"]?.arrayValue ?? [] {
                guard value["account_id"]?.stringValue == thread.accountID, value["message_id"]?.stringValue == messageID,
                      let part = value["part_id"]?.stringValue, !part.isEmpty,
                      let name = value["filename"]?.stringValue, let type = value["mime_type"]?.stringValue,
                      let size = value["size"]?.numberValue.flatMap({ Int(exactly: $0) }), size >= 0,
                      let inline = value["is_inline"]?.boolValue else { throw MeetingPreparationServiceError.invalidSource }
                attachments[messageID, default: []].append(AttachmentRecord(accountID: thread.accountID, messageID: messageID,
                    partID: part, attachmentID: value["attachment_id"]?.stringValue, filename: name,
                    mimeType: type, size: size, isInline: inline))
            }
        }
        var result = detail
        for index in result.messages.indices {
            // Never resurrect stale cache attachments absent from the full read.
            result.messages[index].attachments = attachments[result.messages[index].id] ?? []
        }
        return result
    }
}
