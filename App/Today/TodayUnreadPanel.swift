import SwiftUI

struct TodayUnreadPanel: View {
    let dashboard: TodayDashboardModel
    let query: String

    private var messages: [TodayUnreadMessage] {
        dashboard.unreadMessages.filter { query.isEmpty || [$0.sender, $0.subject, $0.snippet, $0.accountTitle]
            .contains { $0.localizedCaseInsensitiveContains(query) } }
    }
    private var count: Int? {
        dashboard.hasLoadedUnread && !dashboard.unreadLoading && (dashboard.unreadError == nil || !messages.isEmpty)
            && !dashboard.context.accountIDs.isEmpty ? messages.count : nil
    }

    var body: some View {
        TodayDashboardSection(title: "Unread emails", symbol: "envelope.badge", count: count, countLabel: "cached unread emails shown") {
            if dashboard.unreadLoading && messages.isEmpty {
                TodayLoadingStatus("Loading unread emails…").padding(.vertical, Tokens.Space.s2)
            } else if dashboard.context.accountIDs.isEmpty {
                TodayCompactState(title: "No mail accounts", symbol: "envelope",
                    message: "No mail accounts are available in this profile.")
            } else if !dashboard.hasLoadedUnread {
                TodayCompactState(title: "Unread mail not loaded", symbol: "envelope",
                    message: "Refresh to check synced inbox mail.")
            } else if messages.isEmpty {
                TodayCompactState(title: emptyTitle, symbol: dashboard.unreadError == nil ? "envelope" : "exclamationmark.circle",
                    message: query.isEmpty ? "Mail that has not synced is not included." : "Try another search.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(messages) { message in
                        Button { dashboard.openUnread(message) } label: { TodayUnreadRow(message: message) }
                            .buttonStyle(.plain).ternHover()
                            .accessibilityLabel("Open unread email: \(message.subject.isEmpty ? "No subject" : message.subject), from \(message.sender)")
                            .accessibilityValue("\(message.accountTitle), \(message.date.formatted(date: .complete, time: .shortened))")
                            .accessibilityIdentifier("today-unread-\(message.messageID)")
                        if message.id != messages.last?.id { Divider() }
                    }
                }
            }
            footer
        }
        .accessibilityIdentifier("today-unread")
    }

    private var emptyTitle: String {
        if dashboard.unreadError != nil { return "Unread mail unavailable" }
        return query.isEmpty ? "No cached unread emails" : "No matching unread emails"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if let error = dashboard.unreadError {
                TodayInlineWarning(error, retry: { Task { await dashboard.refreshUnread() } })
            }
            if dashboard.unreadLoading && !messages.isEmpty { TodayLoadingStatus("Updating unread emails…") }
            TodayCoverageNote(summary: "Synced inbox mail only.", details: dashboard.unreadCoverage, label: "Unread mail data")
        }
    }
}

private struct TodayUnreadRow: View {
    let message: TodayUnreadMessage

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s2) {
            Circle().fill(Color.accentColor).frame(width: Tokens.Space.s1_5, height: Tokens.Space.s1_5)
                .padding(.top, Tokens.Space.s1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                        sender.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: Tokens.Space.s2)
                        date.fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) { sender; date }
                }
                Text(message.subject.isEmpty ? "No subject" : message.subject)
                    .font(.callout.weight(.semibold)).lineLimit(2)
                if !message.snippet.isEmpty {
                    Text(message.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(message.accountTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(message.accountTitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .padding(.vertical, Tokens.Space.s3).padding(.horizontal, Tokens.Space.s1)
        .contentShape(Rectangle())
    }

    private var sender: some View {
        Text(message.sender).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).help(message.sender)
    }
    private var date: some View {
        Text(message.date.formatted(date: .abbreviated, time: .shortened))
            .font(.caption).foregroundStyle(.secondary)
            .help(message.date.formatted(date: .complete, time: .shortened))
    }
}
