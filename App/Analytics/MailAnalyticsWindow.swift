import MailStore
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
            .background(.bar)
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

    private struct ObservationIdentity: Hashable {
        let reload: UUID
        let calendarContext: AnalyticsCalendarContext
    }

    var body: some View {
        GeometryReader { geometry in
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
                        if geometry.size.width >= Tokens.Analytics.twoColumnWidth {
                            HStack(alignment: .top, spacing: Tokens.Space.s5) {
                                VStack(spacing: Tokens.Space.s5) {
                                    people(snapshot: snapshot)
                                    receipts
                                }
                                .frame(maxWidth: .infinity)
                                AnalyticsRecentMessagesView(messages: snapshot.recentMessages, mailbox: mailbox)
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            people(snapshot: snapshot)
                            receipts
                            AnalyticsRecentMessagesView(messages: snapshot.recentMessages, mailbox: mailbox)
                        }
                        Text("Counts exclude drafts, spam and trash. Each account counts its own copy of an email. Dates use this Mac's time zone.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, Tokens.Space.s1)
                    }
                }
                .padding(Tokens.Space.s6)
                .frame(maxWidth: Tokens.Layout.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: ObservationIdentity(reload: reload, calendarContext: calendarContext)) {
            await model.observe(cache: mailbox.cache,
                query: .init(accountIDs: owners.map(\.account.id), contactAddress: route.address, period: period))
        }
        .modifier(AnalyticsCalendarRefresh(context: $calendarContext))
        .onDisappear { model.stop() }
    }

    @ViewBuilder private func people(snapshot: MailAnalyticsSnapshot) -> some View {
        if route.address != nil {
            SenderProfileLinksView(links: model.profileLinks)
                .padding(Tokens.Space.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .analyticsPanel()
        } else {
            AnalyticsCorrespondentsView(correspondents: snapshot.correspondents,
                selectedAccountID: selectedAccountID)
        }
    }

    private var receipts: some View {
        AnalyticsReceiptsView(receipts: model.receipts, error: model.receiptError,
            contactAddress: route.address, mailbox: mailbox)
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: Tokens.Space.s4) {
            if let address = route.address, let owner = owners.first {
                ContactAvatar(accountID: owner.account.id, address: address, name: route.name ?? address,
                    cache: mailbox.cache, accounts: mailbox.accountStore, size: Tokens.Space.s12)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(route.address == nil ? "Overview" : "Correspondence")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(route.name ?? route.address ?? "Mail activity")
                    .font(.largeTitle.weight(.bold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let address = route.address {
                    Text(address).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text("Sent and received email across your selected accounts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Space.s2)
    }
}
