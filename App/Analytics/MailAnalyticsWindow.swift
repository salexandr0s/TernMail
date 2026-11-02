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

enum MailAnalyticsSection: String, CaseIterable {
    case activity, people, receipts, history

    func title(isContact: Bool) -> String {
        switch self {
        case .activity: "Activity"
        case .people: isContact ? "Profile" : "Contacts"
        case .receipts: "Read receipts"
        case .history: "History"
        }
    }
}

struct MailAnalyticsWorkspace: View {
    let route: MailAnalyticsRoute
    let mailbox: MailboxModel
    @State private var accountID: String
    @State private var period: MailAnalyticsPeriod = .year
    @State private var section: MailAnalyticsSection
    @Environment(\.openWindow) private var openWindow

    init(route: MailAnalyticsRoute, mailbox: MailboxModel, section: MailAnalyticsSection = .activity) {
        self.route = route
        self.mailbox = mailbox
        _accountID = State(initialValue: route.accountID ?? "")
        _section = State(initialValue: section)
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
                sectionPicker
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Tokens.Space.s6) {
                        accountPicker
                        Spacer(minLength: Tokens.Space.s4)
                        dateScope
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        accountPicker
                        dateScope
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
                    selectedAccountID: accountID.isEmpty ? nil : accountID, period: period, section: section)
                    .id(Scope(accountIDs: owners.map(\.account.id), address: route.address,
                              period: period, owners: owners.map(ObjectIdentifier.init)))
            }
        }
        .background(Tokens.Surface.canvas)
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
            TernPageHeader(title: title, subtitle: subtitle)
                .textSelection(.enabled)
                .help(route.address ?? title)
        }
    }

    private var subtitle: String {
        guard let address = route.address else { return "Your email, over time." }
        return title.caseInsensitiveCompare(address) == .orderedSame ? "Correspondence activity" : address
    }

    private var sectionPicker: some View {
        ViewThatFits(in: .horizontal) {
            sectionChoices.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
            sectionChoices.pickerStyle(.menu)
        }
        .accessibilityIdentifier("analytics-section-picker")
    }

    private var sectionChoices: some View {
        Picker("Analytics section", selection: $section) {
            ForEach(MailAnalyticsSection.allCases, id: \.self) { item in
                Text(item.title(isContact: route.address != nil)).tag(item)
            }
        }
        .labelsHidden()
        .accessibilityLabel("Analytics section")
    }

    @ViewBuilder private var dateScope: some View {
        if section == .activity || (section == .people && route.address == nil) {
            periodPicker
        } else {
            Label("All indexed mail", systemImage: "clock")
                .font(.callout).foregroundStyle(.secondary)
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
    let section: MailAnalyticsSection
    @State private var model = MailAnalyticsModel()
    @State private var reload = UUID()
    @State private var calendarContext = AnalyticsCalendarContext()

    private struct ObservationIdentity: Hashable {
        let reload: UUID
        let calendarContext: AnalyticsCalendarContext
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s6) {
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
                        switch section {
                        case .activity:
                            AnalyticsMetricsView(snapshot: snapshot, period: period)
                            AnalyticsActivityChart(snapshot: snapshot)
                            AnalyticsRecentMessagesView(messages: snapshot.recentMessages, mailbox: mailbox)
                        case .people:
                            people(snapshot: snapshot)
                        case .receipts:
                            receipts
                        case .history:
                            AnalyticsHistoryView(snapshot: snapshot, model: model, owners: owners)
                            AnalyticsMilestonesView(snapshot: snapshot)
                        }
                        if section == .activity || section == .people || section == .history {
                            Text("Drafts, spam and trash are excluded. Emails in multiple accounts count once per account. Dates use this Mac's time zone.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .id("analytics-top")
                .padding(Tokens.Workspace.pageGutter)
                .frame(maxWidth: Tokens.Analytics.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: section) {
                proxy.scrollTo("analytics-top", anchor: .top)
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
