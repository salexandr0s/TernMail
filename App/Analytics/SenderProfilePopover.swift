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

    private var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? address : trimmed
    }

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
                        // The placeholder draws the rows of the loaded details and the line
                        // the links section takes when it is empty, so the popover is
                        // already that tall when the numbers arrive.
                        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                            details(received: 0, sent: 0, coverage: [],
                                firstReceived: Self.placeholderDate, lastContact: Self.placeholderDate)
                            SenderProfileLinksView(links: [], compact: true)
                        }
                        .redacted(reason: .placeholder)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading sender details")
                        .ternDelayedLoading()
                        .ternTransition(.fade)
                    } else if let error = model.error {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Label("Sender details unavailable", systemImage: "exclamationmark.circle")
                                .font(.callout.weight(.medium))
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Try again") { reload = UUID() }
                        }
                        .ternTransition(.fade)
                    } else if let snapshot = model.snapshot {
                        details(received: snapshot.receivedCount, sent: snapshot.sentCount,
                            coverage: snapshot.coverage, firstReceived: snapshot.firstReceivedAt,
                            lastContact: snapshot.lastContactAt)
                            .ternTransition(.fade)
                        if model.didLoadProfileLinks {
                            SenderProfileLinksView(links: model.profileLinks, compact: true)
                                .ternTransition(.fade)
                        } else {
                            // The numbers are up and the signatures are still being read.
                            // This holds the line the section takes when it has no links,
                            // so the popover grows only if some are found.
                            SenderProfileLinksView(links: [], compact: true)
                                .redacted(reason: .placeholder)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                                .ternDelayedLoading()
                                .ternTransition(.fade)
                        }
                    }
                }
                .ternAnimation(value: phase, duration: Tokens.Motion.fast)
                .padding(.horizontal, Tokens.Space.s5)
                .padding(.bottom, Tokens.Space.s5)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            Button {
                openWindow(id: MailAnalyticsWindow.sceneID,
                    value: MailAnalyticsRoute(accountID: accountID, address: address, name: displayName))
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
            // The counts show as soon as they load. Signature links follow.
            await model.observe(cache: mailbox.cache,
                query: .init(accountIDs: [accountID], contactAddress: address, period: .allTime),
                linksFollow: true)
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
            ContactAvatar(accountID: accountID, address: address, name: displayName,
                cache: mailbox.cache, accounts: mailbox.accountStore, size: Tokens.Space.s12)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(displayName).font(.title2.weight(.semibold))
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled).help(displayName)
                if displayName.caseInsensitiveCompare(address) != .orderedSame {
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
                ZStack {
                    if copyFeedbackID == nil {
                        Image(systemName: "doc.on.doc").ternTransition(.fade)
                    } else {
                        Image(systemName: "checkmark").ternTransition(.fade)
                    }
                }
                    .font(.callout)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
                .buttonStyle(.plain)
                .foregroundStyle(copyFeedbackID == nil ? Color.secondary : Tokens.Status.success)
                .ternAnimation(value: copyFeedbackID == nil, duration: Tokens.Motion.fast)
                .ternHover()
                .help(copyFeedbackID == nil ? "Copy email address" : "Email address copied")
                .accessibilityLabel(copyFeedbackID == nil ? "Copy email address" : "Email address copied")
                .accessibilityIdentifier("sender-copy-address")
        }
    }

    /// The unavailable notice, the placeholder, the error and the details replace
    /// one another, and the links replace their placeholder. Only those swaps fade.
    private enum Phase: Equatable { case unavailable, loading, failed, loaded(linksReady: Bool) }

    private var phase: Phase {
        if !isAvailable { .unavailable } else if model.isLoading { .loading }
        else if model.error != nil { .failed } else { .loaded(linksReady: model.didLoadProfileLinks) }
    }

    /// Stands in for both dates in the placeholder. It is drawn redacted, never read.
    private static let placeholderDate = Date(timeIntervalSinceReferenceDate: 0)

    /// The sender's counts and dates. The loading placeholder draws the same rows.
    private func details(received: Int, sent: Int, coverage: [MailAnalyticsCoverage],
                         firstReceived: Date?, lastContact: Date?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    Text("All indexed mail").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    AnalyticsCoverageLabel(coverage: coverage)
                }
                HStack(spacing: Tokens.Space.s3) {
                    compactMetric("Received", count: received,
                        symbol: "arrow.down.left", tint: Tokens.Analytics.received)
                    compactMetric("Sent", count: sent,
                        symbol: "arrow.up.right", tint: Tokens.Analytics.sent)
                }
            }
            if firstReceived != nil || lastContact != nil {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    if let firstReceived {
                        dateRow("First received", date: firstReceived)
                    }
                    if let lastContact {
                        dateRow("Last email", date: lastContact)
                    }
                }
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, Tokens.Space.s2)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            }
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

    private var iconSize: CGFloat { compact ? Tokens.Space.s6 : Tokens.Analytics.symbolSize }
    private var rowSpacing: CGFloat { compact ? Tokens.Space.s2 : Tokens.Space.s3 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? Tokens.Space.s2 : Tokens.Space.s3) {
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
                            HStack(spacing: rowSpacing) {
                                Image(systemName: symbol(for: evidence.link.kind))
                                    .font(compact ? .caption : .callout).foregroundStyle(Color.accentColor)
                                    .frame(width: iconSize, height: iconSize)
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
                            .padding(.horizontal, Tokens.Space.s2)
                            .padding(.vertical, compact ? Tokens.Space.s1 : Tokens.Space.s2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .ternHover(pointer: .link)
                        .help("\(evidence.link.url.absoluteString)\nFound in an email signature from \(evidence.date.formatted(date: .abbreviated, time: .omitted))")
                        .accessibilityLabel("\(evidence.link.label), \(evidence.link.url.absoluteString)")
                        if evidence.id != links.last?.id {
                            Divider().padding(.leading, iconSize + rowSpacing + Tokens.Space.s2)
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
