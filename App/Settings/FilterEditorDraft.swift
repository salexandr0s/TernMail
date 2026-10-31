import Foundation
import GmailAPI
import MailStore

/// Edits supported choices while preserving every other Gmail label action.
struct FilterEditorDraft {
    /// Criteria fields hold plain values; `filter()` writes unset ones as `nil`.
    var from = ""
    var to = ""
    var subject = ""
    var query = ""
    var negatedQuery = ""
    var hasAttachment = false
    var excludeChats = false
    var sizeComparison = GmailFilter.SizeComparison.larger
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
        let criteria = filter?.criteria ?? .init()
        from = criteria.from ?? ""
        to = criteria.to ?? ""
        subject = criteria.subject ?? ""
        query = criteria.query ?? ""
        negatedQuery = criteria.negatedQuery ?? ""
        hasAttachment = criteria.hasAttachment == true
        excludeChats = criteria.excludeChats == true
        if criteria.sizeComparison == .smaller { sizeComparison = .smaller }
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
        let text = [from, to, subject, query, negatedQuery]
        if text.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
           !hasAttachment, !excludeChats, sizeText.isEmpty {
            return "Add at least one filter condition."
        }
        if !skipInbox && !markRead && !star && !neverSpam && !trash && importance == 0 && labelID.isEmpty
            && forward.isEmpty && preservedAdds.isEmpty && preservedRemoves.isEmpty { return "Choose at least one action." }
        return nil
    }

    func filter() -> GmailFilter {
        let size = Int(sizeText)
        let criteria = GmailFilter.Criteria(
            from: trimmed(from), to: trimmed(to), subject: trimmed(subject),
            query: trimmed(query), negatedQuery: trimmed(negatedQuery),
            hasAttachment: hasAttachment ? true : nil, excludeChats: excludeChats ? true : nil,
            size: size, sizeComparison: size == nil ? nil : sizeComparison
        )
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

    private func trimmed(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
