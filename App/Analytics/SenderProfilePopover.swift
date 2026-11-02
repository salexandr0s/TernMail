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
    @State private var copyFeedbackID: UUID?

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
            identity
                .padding(Tokens.Space.s4)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    if !isAvailable {
                        Label("This account is no longer available.", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if model.isLoading {
                        ProgressView("Loading sender details…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let error = model.error {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Label("Sender details unavailable", systemImage: "exclamationmark.circle")
                                .font(.callout.weight(.medium))
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Try again") { reload = UUID() }
                        }
                    } else if let snapshot = model.snapshot {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                                Text("All indexed mail").font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                                AnalyticsCoverageLabel(coverage: snapshot.coverage)
                            }
                            HStack(spacing: Tokens.Space.s3) {
                                compactMetric("Received", count: snapshot.receivedCount,
                                    symbol: "arrow.down.left", tint: Tokens.Analytics.received)
                                compactMetric("Sent", count: snapshot.sentCount,
                                    symbol: "arrow.up.right", tint: Tokens.Analytics.sent)
                            }
                        }
                        if snapshot.firstReceivedAt != nil || snapshot.lastContactAt != nil {
                            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                                if let first = snapshot.firstReceivedAt {
                                    dateRow("First received", date: first)
                                }
                                if let last = snapshot.lastContactAt {
                                    dateRow("Last email", date: last)
                                }
                            }
                            .padding(.horizontal, Tokens.Space.s3)
                            .padding(.vertical, Tokens.Space.s2)
                            .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                        }
                        SenderProfileLinksView(links: model.profileLinks, compact: true)
                    }
                }
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s5)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            Button {
                openWindow(id: MailAnalyticsWindow.sceneID,
                    value: MailAnalyticsRoute(accountID: accountID, address: address, name: name))
                dismiss()
            } label: {
                HStack(spacing: Tokens.Space.s3) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.title3.weight(.medium))
                        .frame(width: Tokens.Space.s8, height: Tokens.Space.s8)
                        .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                        Text("View analytics").font(.callout.weight(.semibold))
                        Text("Activity and email history").font(.caption).foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.callout.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.vertical, Tokens.Space.s3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .ternHover()
            .disabled(!isAvailable)
            .accessibilityIdentifier("sender-view-analytics")
            .accessibilityLabel("View analytics")
            .accessibilityHint("Opens activity and email history for this contact")
        }
        .frame(width: Tokens.Analytics.popoverWidth)
        .frame(maxHeight: Tokens.Analytics.popoverMaxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(Tokens.Surface.primary)
        .task(id: LoadIdentity(accountID: accountID, address: EmailAddress(address: address).normalized,
                              reload: reload, isAvailable: isAvailable, calendarContext: calendarContext)) {
            guard isAvailable else { model.stop(); return }
            await model.observe(cache: mailbox.cache,
                query: .init(accountIDs: [accountID], contactAddress: address, period: .allTime))
        }
        .modifier(AnalyticsCalendarRefresh(context: $calendarContext))
        .task(id: copyFeedbackID) {
            guard copyFeedbackID != nil else { return }
            do { try await Task.sleep(for: Tokens.Toast.info) } catch { return }
            copyFeedbackID = nil
        }
        .onDisappear { model.stop() }
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            ContactAvatar(accountID: accountID, address: address, name: name,
                cache: mailbox.cache, accounts: mailbox.accountStore, size: Tokens.Space.s12)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(name.isEmpty ? address : name).font(.title2.weight(.semibold))
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled).help(name.isEmpty ? address : name)
                if !name.isEmpty, name.caseInsensitiveCompare(address) != .orderedSame {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(address)
                }
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.replaceContents(with: address)
                copyFeedbackID = UUID()
            } label: {
                Image(systemName: copyFeedbackID == nil ? "doc.on.doc" : "checkmark")
                    .font(.callout)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
                .buttonStyle(.plain)
                .foregroundStyle(copyFeedbackID == nil ? Color.secondary : Tokens.Status.success)
                .ternHover()
                .help(copyFeedbackID == nil ? "Copy email address" : "Email address copied")
                .accessibilityLabel(copyFeedbackID == nil ? "Copy email address" : "Email address copied")
                .accessibilityIdentifier("sender-copy-address")
        }
    }

    private func compactMetric(_ title: String, count: Int, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
            }
            Text(count, format: .number).font(.title.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(Tokens.Analytics.metricMinimumScale)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s3)
        .background(tint.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .help("\(count.formatted()) \(title.lowercased())")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count.formatted()) \(title.lowercased())")
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
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            if !compact || !links.isEmpty {
                HStack {
                    Text("Profiles and websites").font(compact ? .subheadline.weight(.semibold) : .headline)
                    Spacer(minLength: 0)
                    if !links.isEmpty {
                        Text(links.count, format: .number).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if links.isEmpty {
                Label("No links in available signatures", systemImage: "link")
                    .font(compact ? .caption : .callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("No profile or website links were found in the email signatures available on this Mac.")
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
                Text("From email signatures. Links may be personal or belong to an organization.")
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
