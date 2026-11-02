import MailStore
import MessageContent
import SwiftUI

struct MailAnalyticsWindow: View {
    static let sceneID = "mail-analytics"
    let route: MailAnalyticsRoute?
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let mailbox = app.mailbox {
                MailAnalyticsWorkspace(route: route ?? MailAnalyticsRoute(), mailbox: mailbox)
            } else {
                ContentUnavailableView("Mail analytics", systemImage: "chart.bar.xaxis",
                    description: Text("Sign in to an email account to see its activity."))
            }
        }
        .frame(minWidth: Tokens.Analytics.minWidth, minHeight: Tokens.Analytics.minHeight)
        .focusedSceneValue(\.isMainWindow, false)
    }
}

struct MailAnalyticsWorkspace: View {
    let route: MailAnalyticsRoute
    let mailbox: MailboxModel
    @State private var accountID: String
    @State private var period: MailAnalyticsPeriod = .year
    @Environment(\.openWindow) private var openWindow

    init(route: MailAnalyticsRoute, mailbox: MailboxModel) {
        self.route = route
        self.mailbox = mailbox
        _accountID = State(initialValue: route.accountID ?? "")
    }

    private var owners: [AccountMailbox] {
        mailbox.presentedAccounts.filter { accountID.isEmpty || $0.account.id == accountID }
    }

    private struct Scope: Hashable {
        let accountIDs: [String]
        let address: String?
        let period: MailAnalyticsPeriod
        let owners: [ObjectIdentifier]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s4) {
                Picker("Account", selection: $accountID) {
                    Text("All accounts").tag("")
                    ForEach(mailbox.presentedAccounts, id: \.account.id) { owner in
                        Text(mailbox.accountTitle(owner.account)).tag(owner.account.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: Tokens.Settings.pickerWidth)
                .accessibilityLabel("Analytics account")
                Spacer(minLength: Tokens.Space.s2)
                Picker("Date range", selection: $period) {
                    ForEach(MailAnalyticsPeriod.allCases, id: \.self) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: Tokens.Layout.attachmentWidth + Tokens.Space.s16)
                .accessibilityLabel("Analytics date range")
            }
            .padding(.horizontal, Tokens.Space.s4)
            .frame(height: Tokens.Space.s12 + Tokens.Space.s2)
            Divider()
            if owners.isEmpty {
                ContentUnavailableView("Account unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Choose an available account to view its analytics."))
            } else {
                MailAnalyticsDashboard(mailbox: mailbox, owners: owners, route: route,
                    selectedAccountID: accountID.isEmpty ? nil : accountID, period: period)
                    .id(Scope(accountIDs: owners.map(\.account.id), address: route.address,
                              period: period, owners: owners.map(ObjectIdentifier.init)))
            }
        }
        .background(Tokens.Surface.muted)
        .navigationTitle(route.address == nil ? "Mail analytics" : "Sender analytics")
        .navigationSubtitle(route.name ?? route.address ?? "")
        .toolbar {
            if route.address != nil {
                ToolbarItem {
                    Button("All mail analytics", systemImage: "chart.bar.xaxis") {
                        openWindow(id: MailAnalyticsWindow.sceneID,
                            value: MailAnalyticsRoute(accountID: accountID.isEmpty ? nil : accountID))
                    }
                }
            }
        }
    }
}

private struct MailAnalyticsDashboard: View {
    let mailbox: MailboxModel
    let owners: [AccountMailbox]
    let route: MailAnalyticsRoute
    let selectedAccountID: String?
    let period: MailAnalyticsPeriod
    @State private var model = MailAnalyticsModel()
    @State private var reload = UUID()
    @State private var calendarContext = AnalyticsCalendarContext()
    @Environment(\.openWindow) private var openWindow

    private struct ObservationIdentity: Hashable {
        let reload: UUID
        let calendarContext: AnalyticsCalendarContext
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                heading
                if model.isLoading {
                    ProgressView("Loading mail analytics…")
                        .frame(maxWidth: .infinity, minHeight: Tokens.Layout.editorMinHeight)
                } else if let error = model.error {
                    ContentUnavailableView {
                        Label("Analytics unavailable", systemImage: "chart.bar.xaxis")
                    } description: { Text(error) } actions: {
                        Button("Try again") { reload = UUID() }
                    }
                } else if let snapshot = model.snapshot {
                    AnalyticsMetricsView(snapshot: snapshot, period: period)
                    AnalyticsActivityChart(snapshot: snapshot)
                    AnalyticsHistoryView(snapshot: snapshot, model: model, owners: owners)
                    if route.address != nil {
                        SenderProfileLinksView(links: model.profileLinks)
                            .padding(Tokens.Space.s5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .ternSurface()
                    } else {
                        AnalyticsCorrespondentsView(correspondents: snapshot.correspondents,
                            selectedAccountID: selectedAccountID)
                    }
                    AnalyticsRecentMessagesView(messages: snapshot.recentMessages, mailbox: mailbox)
                    AnalyticsReceiptsView(receipts: model.receipts, error: model.receiptError,
                        contactAddress: route.address, mailbox: mailbox)
                    Text("Counts exclude drafts, spam and trash. A message in two accounts counts once in each account. Dates use this Mac's time zone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Tokens.Space.s6)
            .frame(maxWidth: Tokens.Layout.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: ObservationIdentity(reload: reload, calendarContext: calendarContext)) {
            await model.observe(cache: mailbox.cache,
                query: .init(accountIDs: owners.map(\.account.id), contactAddress: route.address, period: period))
        }
        .modifier(AnalyticsCalendarRefresh(context: $calendarContext))
        .onDisappear { model.stop() }
    }

    private var heading: some View {
        HStack(spacing: Tokens.Space.s3) {
            if let address = route.address, let owner = owners.first {
                ContactAvatar(accountID: owner.account.id, address: address, name: route.name ?? address,
                    cache: mailbox.cache, accounts: mailbox.accountStore, size: Tokens.Space.s12)
            } else {
                Image(systemName: "chart.bar.xaxis")
                    .font(.title).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(route.name ?? route.address ?? "Mail activity")
                    .font(.title2.weight(.semibold)).textSelection(.enabled)
                if let address = route.address {
                    Text(address).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("Email sent and received across your selected accounts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AnalyticsHistoryView: View {
    let snapshot: MailAnalyticsSnapshot
    let model: MailAnalyticsModel
    let owners: [AccountMailbox]
    @Environment(\.openSettings) private var openSettings

    private var hasScannedHistory: Bool {
        !snapshot.coverage.isEmpty && snapshot.coverage.allSatisfy(\.isComplete)
    }

    private var canLoadHistory: Bool { owners.contains(where: \.syncEnabled) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                Image(systemName: hasScannedHistory ? "clock.arrow.circlepath" : "clock.badge.questionmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(hasScannedHistory ? "History scanned" : "Partial history").font(.headline)
                    Text(hasScannedHistory
                        ? "These totals include the history loaded from Gmail. Scan again to reconcile older changes."
                        : "Totals currently cover indexed messages. Load full history to include older mail and find the earliest email.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            ForEach(snapshot.coverage, id: \.accountID) { coverage in
                HStack(alignment: .firstTextBaseline) {
                    Text(owners.first(where: { $0.account.id == coverage.accountID })?.account.email ?? "Account")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Tokens.Space.s2)
                    if let date = coverage.historyLoadedAt {
                        Text("Scanned \(date.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("\(coverage.indexedMessageCount.formatted()) indexed")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if model.isLoadingHistory {
                HStack(spacing: Tokens.Space.s2) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                        Text("Loading history · \(model.historyPagesLoaded.formatted()) pages saved")
                        if let account = model.historyAccountName {
                            Text(account).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }.font(.caption)
                    Spacer(minLength: Tokens.Space.s2)
                    Button("Cancel") { model.cancelHistory() }
                }
            } else {
                Button(hasScannedHistory ? "Scan history again" : "Load full history") {
                    model.loadHistory(accounts: owners, restart: hasScannedHistory)
                }
                .disabled(!canLoadHistory)
                if !canLoadHistory {
                    Text("Mail sync is paused for the selected accounts. Turn on Sync Mail in Account Settings to load older messages.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings") { openSettings() }
                    .buttonStyle(.borderless).font(.caption)
                }
            }
            if let error = model.historyError {
                Text(error).font(.caption).foregroundStyle(Tokens.Status.error)
            }
            Text("Loading history downloads message details and leaves read status unchanged. You can cancel and resume.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }
}
