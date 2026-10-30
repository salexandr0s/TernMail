import Foundation
import GmailAPI
import MailStore

/// Edits supported choices while preserving every other Gmail label action.
struct FilterEditorDraft {
    var criteria: GmailFilter.Criteria
    var skipInbox = false
    var markRead = false
    var star = false
    var neverSpam = false
    var trash = false
    /// -1 never, 0 unchanged, 1 always.
    var importance = 0
    var labelID = ""
    var forward = ""
    var sizeText = ""
    var preservedAdds: [String]
    var preservedRemoves: [String]

    init(filter: GmailFilter?, labels: [LabelRecord]) {
        criteria = filter?.criteria ?? .init()
        let adds = filter?.action.addLabelIds ?? []
        let removes = filter?.action.removeLabelIds ?? []
        skipInbox = removes.contains("INBOX")
        markRead = removes.contains("UNREAD")
        star = adds.contains("STARRED")
        neverSpam = removes.contains("SPAM")
        trash = adds.contains("TRASH")
        importance = adds.contains("IMPORTANT") ? 1 : removes.contains("IMPORTANT") ? -1 : 0
        let knownUsers = Set(labels.filter { !$0.isSystem }.map(\.id))
        labelID = adds.first(where: { knownUsers.contains($0) }) ?? ""
        let editableAdds: Set<String> = ["STARRED", "TRASH", "IMPORTANT", labelID]
        let editableRemoves: Set<String> = ["INBOX", "UNREAD", "SPAM", "IMPORTANT"]
        preservedAdds = adds.filter { !editableAdds.contains($0) }
        preservedRemoves = removes.filter { !editableRemoves.contains($0) }
        forward = filter?.action.forward ?? ""
        sizeText = criteria.size.map(String.init) ?? ""
    }

    func validation(acceptedForwarding: [String]) -> String? {
        if !forward.isEmpty, !acceptedForwarding.contains(where: { $0.caseInsensitiveCompare(forward) == .orderedSame }) {
            return "Choose a verified forwarding address, or turn forwarding off."
        }
        if !sizeText.isEmpty, Int(sizeText).map({ $0 < 0 }) ?? true { return "Size must be a whole number of bytes, zero or greater." }
        let text = [criteria.from, criteria.to, criteria.subject, criteria.query, criteria.negatedQuery]
        if text.allSatisfy({ ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
           criteria.hasAttachment != true, criteria.excludeChats != true, sizeText.isEmpty {
            return "Add at least one filter condition."
        }
        if !skipInbox && !markRead && !star && !neverSpam && !trash && importance == 0 && labelID.isEmpty
            && forward.isEmpty && preservedAdds.isEmpty && preservedRemoves.isEmpty { return "Choose at least one action." }
        return nil
    }

    func filter() -> GmailFilter {
        var criteria = criteria
        criteria.from = trimmed(criteria.from)
        criteria.to = trimmed(criteria.to)
        criteria.subject = trimmed(criteria.subject)
        criteria.query = trimmed(criteria.query)
        criteria.negatedQuery = trimmed(criteria.negatedQuery)
        criteria.size = Int(sizeText)
        if criteria.size == nil { criteria.sizeComparison = nil }
        else if criteria.sizeComparison == nil || criteria.sizeComparison == .unspecified { criteria.sizeComparison = .larger }
        var adds = preservedAdds
        var removes = preservedRemoves
        if skipInbox { removes.append("INBOX") }
        if markRead { removes.append("UNREAD") }
        if neverSpam { removes.append("SPAM") }
        if star { adds.append("STARRED") }
        if trash { adds.append("TRASH") }
        if importance == 1 { adds.append("IMPORTANT") }
        if importance == -1 { removes.append("IMPORTANT") }
        if !labelID.isEmpty { adds.append(labelID) }
        return GmailFilter(criteria: criteria, action: .init(
            addLabelIds: Array(Set(adds)).sorted(), removeLabelIds: Array(Set(removes)).sorted(),
            forward: forward.isEmpty ? nil : forward
        ))
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
