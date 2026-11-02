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
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                heading
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Space.s6) {
                        accountPicker
                        Spacer(minLength: Tokens.Space.s4)
                        periodPicker
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        accountPicker
                        periodPicker
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(Tokens.Space.s6)
            .frame(maxWidth: Tokens.Analytics.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .background(Tokens.Surface.primary)
            Divider()
            if owners.isEmpty {
                ContentUnavailableView("Account unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("Choose an available account to view its analytics."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var heading: some View {
        HStack(spacing: Tokens.Space.s4) {
            if let address = route.address, let owner = owners.first {
                ContactAvatar(accountID: owner.account.id, address: address, name: route.name ?? address,
                    cache: mailbox.cache, accounts: mailbox.accountStore, size: Tokens.Space.s12)
                    .clipShape(Circle())
            } else {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2.weight(.medium)).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(title).font(.title.weight(.bold)).foregroundStyle(.primary).textSelection(.enabled)
                    .lineLimit(2).help(title)
                if let address = route.address {
                    if title.caseInsensitiveCompare(address) != .orderedSame {
                        Text(address).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(address)
                    } else {
                        Text("Correspondence activity")
                    }
                } else {
                    Text("Sent, received and conversation history.")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        if let address = route.address {
            let name = route.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? address : name
        }
        return "Mail analytics"
    }

    private var accountPicker: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "tray.2").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("Account", selection: $accountID) {
                Text("All accounts").tag("")
                ForEach(mailbox.presentedAccounts, id: \.account.id) { owner in
                    Text(mailbox.accountTitle(owner.account)).tag(owner.account.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: Tokens.Settings.pickerWidth)
            .accessibilityLabel("Analytics account")
            .accessibilityIdentifier("analytics-account-filter")
        }
        .frame(height: Tokens.Control.iconButton)
    }

    private var periodPicker: some View {
        Picker("Date range", selection: $period) {
            ForEach(MailAnalyticsPeriod.allCases, id: \.self) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: Tokens.Analytics.filterWidth, height: Tokens.Control.iconButton)
        .accessibilityLabel("Analytics date range")
        .accessibilityIdentifier("analytics-period-filter")
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
                        AnalyticsMilestonesView(snapshot: snapshot)
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
                            AnalyticsRecentMessagesView(messages: snapshot.recentMessages, mailbox: mailbox)
                            receipts
                        }
                        AnalyticsHistoryView(snapshot: snapshot, model: model, owners: owners)
                        Text("Drafts, spam and trash are excluded. Emails in multiple accounts count once per account. Dates use this Mac's time zone.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, Tokens.Space.s1)
                    }
                }
                .padding(Tokens.Space.s6)
                .frame(maxWidth: Tokens.Analytics.contentWidth, alignment: .leading)
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
}
