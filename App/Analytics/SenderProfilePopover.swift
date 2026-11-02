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
                        AnalyticsCoverageLabel(coverage: snapshot.coverage)
                        HStack(spacing: Tokens.Space.s6) {
                            compactMetric("Received", count: snapshot.receivedCount)
                            compactMetric("Sent", count: snapshot.sentCount)
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            if let first = snapshot.firstReceivedAt {
                                LabeledContent("First received", value: first.formatted(date: .abbreviated, time: .omitted))
                            }
                            if let last = snapshot.lastContactAt {
                                LabeledContent("Last email", value: last.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
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
                Label("View analytics", systemImage: "chart.bar.xaxis")
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
                Text(name.isEmpty ? address : name).font(.title3.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text(address).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.replaceContents(with: address)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy email address")
                .accessibilityLabel("Copy email address")
        }
    }

    private func compactMetric(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(count, format: .number).font(.title2.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
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
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text("Profiles and websites").font(.headline)
            if links.isEmpty {
                Text("No profile links found in the signatures available on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(links) { evidence in
                    Link(destination: evidence.link.url) {
                        HStack(spacing: Tokens.Space.s2) {
                            Image(systemName: evidence.link.kind == .website ? "globe" : "person.crop.square")
                                .frame(width: Tokens.Control.icon)
                            Text(evidence.link.label).layoutPriority(1)
                            if let detail = destinationDetail(evidence.link) {
                                Text(detail).font(.caption)
                                    .foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.caption)
                        }
                        .padding(.vertical, Tokens.Space.s1)
                        .contentShape(Rectangle())
                    }
                    .help("\(evidence.link.url.absoluteString)\nFound in an email signature from \(evidence.date.formatted(date: .abbreviated, time: .omitted))")
                    .accessibilityLabel("\(evidence.link.label), \(evidence.link.url.absoluteString)")
                }
                Text("Found in email signatures. Links may belong to a person or an organization.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func destinationDetail(_ link: SenderProfileLink) -> String? {
        let path = link.url.path(percentEncoded: false)
        let query = link.url.query(percentEncoded: false).map { "?" + $0 } ?? ""
        let host = link.kind == .mastodon ? (link.url.host() ?? "") : ""
        let detail = host + path + query
        return detail.isEmpty ? nil : detail
    }
}
