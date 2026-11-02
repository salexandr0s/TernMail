import Foundation
import MessageContent

enum AssistantResultExport {
    static func markdown(_ message: AssistantMessage) -> String {
        guard !message.isUser else { return message.text }
        var parts = message.text.isEmpty ? [] : [message.text]
        switch message.state {
        case .failed: parts.append("Response incomplete. " + (message.errorMessage ?? "The request did not finish."))
        case .cancelled: parts.append("Response stopped before completion.")
        case .streaming: parts.append("Response still in progress.")
        case .completed: break
        }
        parts += message.emailResults.map(email)
        parts += message.taskResults.map(task)
        parts += message.eventResults.map(event)
        var included = Set(message.emailResults.map { $0.source.id }
            + message.taskResults.map { $0.source.id } + message.eventResults.map { $0.source.id })
        parts += message.sources.filter { included.insert($0.id).inserted }.map(source)
        parts += message.calendarProposals.map { "Calendar proposal: \($0.title) (not saved)" }
        parts += message.availabilityChoices.map {
            "Available time: \($0.displayTitle) (\($0.timeZoneIdentifier)); checked \($0.checkedAt.formatted(date: .abbreviated, time: .shortened)). Not reserved."
        }
        if !message.draftIDs.isEmpty {
            parts.append("\(message.draftIDs.count) editable drafts prepared in Tern. Not sent.")
            parts += message.draftIDs.compactMap { message.draftStyleNotes[$0] }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func email(_ result: AssistantEmailResult) -> String {
        var lines = ["### \(literal(result.subject.isEmpty ? "No Subject" : result.subject))",
                     "From: \(literal(result.senderName)) <\(literal(result.senderEmail))>",
                     "Account: \(literal(result.accountEmail))"]
        if let date = result.date { lines.append("Date: \(date.formatted(date: .complete, time: .shortened))") }
        if let reason = result.reason { lines.append(literal(reason)) }
        if !result.snippet.isEmpty { lines.append(literal(result.snippet)) }
        if result.isUnread { lines.append("Unread") }
        if result.isStarred { lines.append("Starred") }
        if !result.labels.isEmpty { lines.append("Labels: " + result.labels.map { literal($0.name) }.joined(separator: ", ")) }
        lines.append("\(result.messageCount) messages")
        lines.append(source(result.source))
        return lines.joined(separator: "\n\n")
    }

    private static func task(_ result: AssistantTaskResult) -> String {
        var lines = ["### \(literal(result.title))", "Due: \(result.dueDate ?? "No due date stated")"]
        if let owner = result.owner { lines.append("Owner: \(literal(owner))") }
        if !result.notes.isEmpty { lines.append(literal(result.notes)) }
        lines.append("Source excerpt: \(literal(result.evidence))")
        lines.append(source(result.source))
        return lines.joined(separator: "\n\n")
    }

    private static func event(_ result: AssistantEventResult) -> String {
        let presentation = result.presentation()
        var lines = ["### \(literal(result.title))", presentation.dateLine]
        if let original = presentation.originalTimeZoneLine { lines.append(original) }
        if let location = presentation.location { lines.append("Location: \(literal(location))") }
        if let notes = result.event.description, !notes.isEmpty { lines.append(literal(notes)) }
        lines += result.uncertainties.map { "Review: \(literal($0))" }
        if let evidence = result.evidence { lines.append("Source excerpt: \(literal(evidence))") }
        lines.append(source(result.source))
        if result.source.isCalendar, let text = result.event.htmlLink,
           let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
           url.host == "calendar.google.com" || (url.host == "www.google.com" && url.path.hasPrefix("/calendar/")) {
            lines.append(url.absoluteString)
        }
        return lines.joined(separator: "\n\n")
    }

    private static func source(_ source: AssistantSource) -> String {
        let title = "Source: \(literal(source.title))"
        guard !source.isCalendar else { return title }
        let link = MailLink(accountID: source.accountID, threadID: source.threadID,
                            messageID: source.messageID, partID: source.partID)
        return link.ternURL.map { title + "\n\n" + $0.absoluteString } ?? title
    }

    /// Card metadata is plain text, including when exported through Markdown.
    private static func literal(_ value: String) -> String {
        value.reduce(into: "") { output, character in
            if "\\`*_{}[]<>#|".contains(character) { output.append("\\") }
            output.append(character)
        }
    }
}
