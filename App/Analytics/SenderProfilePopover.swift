import AppKit
import MailStore
import MessageContent
import SwiftUI

struct SenderProfilePopover: View {
    let accountID: String
    let address: String
    let name: String
    let mailbox: MailboxModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var model = MailAnalyticsModel()
    @State private var reload = UUID()
    @State private var calendarContext = AnalyticsCalendarContext()

    private struct LoadIdentity: Hashable {
        let accountID: String
        let address: String
        let reload: UUID
        let isAvailable: Bool
        let calendarContext: AnalyticsCalendarContext
    }

    private var isAvailable: Bool { mailbox.presentedAccounts.contains { $0.account.id == accountID } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    identity
                    Divider()
                    if !isAvailable {
                        Text("This account is no longer available in the current profile.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if model.isLoading {
                        ProgressView("Loading sender details…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let error = model.error {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try again") { reload = UUID() }
                    } else if let snapshot = model.snapshot {
                        HStack(spacing: Tokens.Space.s3) {
                            compactMetric("Received", count: snapshot.receivedCount,
                                symbol: "arrow.down.left", tint: Tokens.Analytics.received)
                            compactMetric("Sent", count: snapshot.sentCount,
                                symbol: "arrow.up.right", tint: Tokens.Analytics.sent)
                        }
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            if let first = snapshot.firstReceivedAt {
                                dateRow("First received", date: first)
                            }
                            if let last = snapshot.lastContactAt {
                                dateRow("Last email", date: last)
                            }
                        }
                        AnalyticsCoverageLabel(coverage: snapshot.coverage)
                        Divider()
                        SenderProfileLinksView(links: model.profileLinks)
                    }
                }
                .padding(Tokens.Space.s5)
            }
            Divider()
            Button {
                openWindow(id: MailAnalyticsWindow.sceneID,
                    value: MailAnalyticsRoute(accountID: accountID, address: address, name: name))
                dismiss()
            } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Label("View analytics", systemImage: "chart.bar.xaxis")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isAvailable)
            .accessibilityIdentifier("sender-view-analytics")
            .padding(.horizontal, Tokens.Space.s5)
            .padding(.vertical, Tokens.Space.s3)
        }
        .frame(width: Tokens.Analytics.popoverWidth)
        .frame(maxHeight: Tokens.Analytics.popoverMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: LoadIdentity(accountID: accountID, address: EmailAddress(address: address).normalized,
                              reload: reload, isAvailable: isAvailable, calendarContext: calendarContext)) {
            guard isAvailable else { model.stop(); return }
            await model.observe(cache: mailbox.cache,
                query: .init(accountIDs: [accountID], contactAddress: address, period: .allTime))
        }
        .modifier(AnalyticsCalendarRefresh(context: $calendarContext))
        .onDisappear { model.stop() }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            ContactAvatar(accountID: accountID, address: address, name: name,
                cache: mailbox.cache, accounts: mailbox.accountStore, size: Tokens.Space.s12)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(name.isEmpty ? address : name).font(.title2.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !name.isEmpty, name.caseInsensitiveCompare(address) != .orderedSame {
                    Text(address).font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.replaceContents(with: address)
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .ternHover()
                .help("Copy email address")
                .accessibilityLabel("Copy email address")
        }
    }

    private func compactMetric(_ title: String, count: Int, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.caption.weight(.medium))
            Text(count, format: .number).font(.title.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s3)
        .background(tint.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .accessibilityElement(children: .combine)
    }

    private func dateRow(_ title: String, date: Date) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: Tokens.Space.s3)
            Text(date, format: .dateTime.day().month(.abbreviated).year()).fontWeight(.medium)
        }
        .font(.caption)
        .help(date.formatted(date: .complete, time: .shortened))
        .accessibilityElement(children: .combine)
    }
}

/// Calendar boundaries, rather than every activation, refresh date-limited queries.
struct AnalyticsCalendarContext: Hashable {
    let dayStart: Date
    let timeZoneID: String
    let secondsFromGMT: Int

    init(now: Date = .now, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        dayStart = calendar.startOfDay(for: now)
        timeZoneID = timeZone.identifier
        secondsFromGMT = timeZone.secondsFromGMT(for: now)
    }
}

struct AnalyticsCalendarRefresh: ViewModifier {
    @Binding var context: AnalyticsCalendarContext

    func body(content: Content) -> some View {
        content
            .onAppear { refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in refresh() }
    }

    private func refresh() {
        let current = AnalyticsCalendarContext()
        if context != current { context = current }
    }
}

struct SenderProfileLinksView: View {
    let links: [SenderProfileEvidence]

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack {
                Text("Profiles and websites").font(.headline)
                Spacer(minLength: 0)
                if !links.isEmpty {
                    Text(links.count, format: .number).font(.caption).foregroundStyle(.secondary)
                }
            }
            if links.isEmpty {
                Label("No profile links found in the signatures available on this Mac.", systemImage: "link")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(links) { evidence in
                        Link(destination: evidence.link.url) {
                            HStack(spacing: Tokens.Space.s3) {
                                Image(systemName: symbol(for: evidence.link.kind))
                                    .font(.callout).foregroundStyle(Color.accentColor)
                                    .frame(width: Tokens.Analytics.symbolSize, height: Tokens.Analytics.symbolSize)
                                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                                        in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                                    Text(evidence.link.label).font(.callout.weight(.medium)).foregroundStyle(.primary)
                                    Text(destinationDetail(evidence.link)).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(Tokens.Space.s2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .ternHover(pointer: .link)
                        .help("\(evidence.link.url.absoluteString)\nFound in an email signature from \(evidence.date.formatted(date: .abbreviated, time: .omitted))")
                        .accessibilityLabel("\(evidence.link.label), \(evidence.link.url.absoluteString)")
                        if evidence.id != links.last?.id {
                            Divider().padding(.leading, Tokens.Analytics.symbolSize + Tokens.Space.s3 + Tokens.Space.s2)
                        }
                    }
                }
                Text("Found in email signatures. Links may belong to a person or an organization.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func destinationDetail(_ link: SenderProfileLink) -> String {
        let path = link.url.path(percentEncoded: false)
        let query = link.url.query(percentEncoded: false).map { "?" + $0 } ?? ""
        let host = link.kind == .website ? "" : (link.url.host() ?? "")
        let detail = host + path + query
        return detail.isEmpty ? "Website" : detail
    }

    private func symbol(for kind: SenderProfileLinkKind) -> String {
        switch kind {
        case .linkedin: "briefcase"
        case .instagram: "camera"
        case .facebook: "person.2"
        case .x, .mastodon: "bubble.left.and.bubble.right"
        case .github: "curlybraces"
        case .youtube: "play.rectangle"
        case .tiktok: "music.note"
        case .website: "globe"
        }
    }
}
