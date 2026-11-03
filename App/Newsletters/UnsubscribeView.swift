import MailStore
import SwiftUI

struct UnsubscribeView: View {
    @Bindable var model: UnsubscribeModel
    @AppStorage(DomainLogoPreferences.key) private var showsLogos = DomainLogoPreferences.defaultEnabled
    @FocusState private var searchFocused: Bool
    @State private var showsCoverage = false

    private var canScan: Bool {
        model.accounts.contains {
            (model.selectedAccountID.isEmpty || $0.id == model.selectedAccountID)
                && !model.unavailableAccountIDs.contains($0.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage {
                notice(error, isError: true) { model.errorMessage = nil }
            } else if let message = model.notice {
                notice(message, isError: false) { model.notice = nil }
            }
            if !model.accounts.isEmpty && !canScan {
                Label("Sign in again in Settings to manage newsletters for this account.",
                    systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, Tokens.Space.s6).padding(.vertical, Tokens.Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            listHeader
            Divider()
            GeometryReader { geometry in
                if model.visibleSubscriptions.isEmpty { emptyState }
                else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.visibleSubscriptions) { subscription in
                                UnsubscribeRow(subscription: subscription, model: model,
                                    isCompact: geometry.size.width < Tokens.Layout.readableWidth)
                                Divider().padding(.leading, Tokens.Space.s6)
                            }
                        }
                    }
                    .accessibilityIdentifier("unsubscribe.list")
                }
            }
            Divider()
            footer
        }
        .background(Tokens.Surface.primary)
        .sheet(item: $model.confirmation) { confirmation in
            UnsubscribeConfirmationView(model: model, confirmation: confirmation)
        }
        .sheet(item: $model.manualSubscription) { subscription in
            UnsubscribeManualView(model: model, subscription: subscription)
        }
        .onExitCommand {
            if searchFocused { searchFocused = false }
            else { model.clearSelection() }
        }
        .background {
            Button("Find newsletters") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "envelope.open")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s8, height: Tokens.Space.s8)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash),
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                Text("Unsubscribe").font(.title.weight(.semibold))
                Spacer(minLength: Tokens.Space.s4)
                HStack(spacing: Tokens.Space.s4) {
                    metric(model.subscriptionCount, title: "subscriptions", symbol: "tray.full")
                    metric(model.messageCount, title: "newsletter emails found", symbol: "envelope")
                    metric(model.requestedCount, title: "unsubscribe requests sent", symbol: "checkmark.circle")
                }
                Divider().frame(height: Tokens.Space.s4).padding(.horizontal, Tokens.Space.s1)
                UnsubscribeIconButton(symbol: "arrow.clockwise", title: "Refresh newsletters") { model.startScan(restart: true) }
                    .disabled(model.isScanning || model.isWorking || !canScan)
                    .accessibilityIdentifier("unsubscribe.refresh")
                Menu {
                    Toggle("Show sender logos", isOn: $showsLogos)
                    Text("Sender websites receive your IP address when logos load.")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Display options")
                .accessibilityLabel("Newsletter display options")
            }
            filters
        }
        .padding(.horizontal, Tokens.Space.s6)
        .padding(.vertical, Tokens.Space.s4)
        .background(Tokens.Surface.muted)
    }

    private func metric(_ count: Int, title: String, symbol: String) -> some View {
        HStack(spacing: Tokens.Space.s1_5) {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                .fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
        .fixedSize()
        .help("\(count.formatted()) \(title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(title)")
    }

    private var filters: some View {
        HStack(spacing: Tokens.Space.s3) {
            Picker("Newsletter status", selection: $model.filter) {
                ForEach(UnsubscribeFilter.allCases, id: \.self) { filter in
                    Image(systemName: filter.newsletterSymbol)
                        .accessibilityLabel(filter.title)
                        .help(filter.title)
                        .tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: Tokens.Space.s10 * 3)
            .accessibilityLabel("Newsletter status")
            .accessibilityIdentifier("unsubscribe.filter")
            Menu {
                Picker("Account", selection: $model.selectedAccountID) {
                    Text("All accounts").tag("")
                    ForEach(model.accounts) { account in Text(account.title).tag(account.id) }
                }
            } label: {
                Label(model.selectedAccountID.isEmpty ? "All accounts" : model.accountTitle(for: model.selectedAccountID),
                    systemImage: "tray.2")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Tokens.Layout.searchMinWidth, alignment: .leading)
            .help("Filter by receiving account")
            .accessibilityLabel("Receiving account")
            .accessibilityIdentifier("unsubscribe.account")
            Spacer(minLength: 0)
            HStack(spacing: Tokens.Space.s1_5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search", text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search newsletters")
                    .accessibilityIdentifier("unsubscribe.search")
                if !model.search.isEmpty {
                    Button { model.search = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear newsletter search")
                }
            }
            .padding(.horizontal, Tokens.Space.s2)
            .padding(.vertical, Tokens.Space.s1_5)
            .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .ternOutline(radius: Tokens.Radius.sm, focus: searchFocused ? .accentColor : nil)
            .frame(minWidth: Tokens.Layout.searchMinWidth, maxWidth: Tokens.Layout.searchMaxWidth)
        }
    }

    private var listHeader: some View {
        HStack(spacing: Tokens.Space.s3) {
            UnsubscribeCheckbox(isOn: model.allVisibleSelected, isMixed: model.someVisibleSelected,
                isEnabled: model.canSelectAll && !model.isWorking,
                label: "Select all newsletters available for batch unsubscribe",
                identifier: "unsubscribe.selectAll", action: model.toggleAll)
            if model.selectedCount > 0 {
                Text("\(model.selectedCount) selected").fontWeight(.medium).monospacedDigit()
                UnsubscribeIconButton(symbol: "xmark.circle", title: "Clear selection") { model.clearSelection() }
                    .accessibilityIdentifier("unsubscribe.clearSelection")
            } else {
                Text(model.visibleSubscriptions.count == 1 ? "1 newsletter" : "\(model.visibleSubscriptions.count) newsletters")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Tokens.Space.s3)
            if model.selectedCount > 0 {
                Button("Unsubscribe from \(model.selectedCount)…", action: model.proposeSelection)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("unsubscribe.batch")
            } else {
                Menu {
                    Picker("Sort newsletters", selection: $model.sort) {
                        ForEach(UnsubscribeSort.allCases, id: \.self) { sort in Text(sort.title).tag(sort) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort: \(model.sort.title)")
                .accessibilityLabel("Sort newsletters")
                .accessibilityIdentifier("unsubscribe.sort")
            }
        }
        .font(.callout)
        .padding(.horizontal, Tokens.Space.s6)
        .padding(.vertical, Tokens.Space.s2)
        .frame(minHeight: Tokens.Space.s10)
        .background(model.selectedCount > 0 ? Color.accentColor.opacity(Tokens.Opacity.wash) : Tokens.Surface.primary)
    }

    @ViewBuilder private var emptyState: some View {
        if model.isLoading || (model.isScanning && model.subscriptions.isEmpty) {
            VStack(spacing: Tokens.Space.s3) {
                ProgressView()
                Text(model.isLoading ? "Loading newsletters…" : "Finding your newsletters…").font(.headline)
                Text("Subscriptions appear as your mail is checked.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.search.isEmpty {
            ContentUnavailableView {
                Label("No matching newsletters", systemImage: "magnifyingglass")
            } description: {
                Text("Try another sender, address or newsletter name.")
            } actions: {
                Button("Clear search") { model.search = ""; searchFocused = true }
            }
        } else if model.filter == .history {
            ContentUnavailableView("No unsubscribe history", systemImage: "checkmark.circle",
                description: Text("Your requests and completed unsubscribes will appear here."))
        } else if model.accounts.isEmpty {
            ContentUnavailableView("No mail accounts", systemImage: "person.crop.circle.badge.plus",
                description: Text("Connect a mail account to find its newsletters."))
        } else {
            ContentUnavailableView {
                Label("No newsletters to unsubscribe from", systemImage: "tray")
            } description: {
                Text("Tern looks for unsubscribe options provided by the sender. Check again after new mail arrives.")
            } actions: {
                Button("Check for newsletters") { model.startScan(restart: true) }
                    .disabled(model.isScanning || !canScan)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s2) {
            if model.isSendingRequests {
                ProgressView().controlSize(.mini)
                Text("Sending requests · \(model.batchCompleted) of \(model.batchTotal)").monospacedDigit()
                Spacer(minLength: Tokens.Space.s3)
                UnsubscribeIconButton(symbol: "stop.circle", title: "Stop unsubscribe requests", action: model.stopBatch)
                    .accessibilityIdentifier("unsubscribe.stopBatch")
            } else if model.isWorking {
                ProgressView().controlSize(.mini)
                Text("Updating subscription…")
                Spacer(minLength: 0)
            } else {
                if model.isScanning { ProgressView().controlSize(.mini) }
                else { Image(systemName: "checkmark.circle").accessibilityHidden(true) }
                Text(coverageTitle).lineLimit(1).monospacedDigit().help(model.scanSummary)
                Spacer(minLength: Tokens.Space.s3)
                if model.isScanning {
                    UnsubscribeIconButton(symbol: "pause.circle", title: "Pause newsletter scan", action: model.stopScan)
                        .accessibilityIdentifier("unsubscribe.pauseScan")
                } else if model.hasMoreToScan {
                    UnsubscribeIconButton(symbol: "play.circle", title: "Continue newsletter scan") { model.startScan() }
                        .disabled(!canScan)
                        .accessibilityIdentifier("unsubscribe.continueScan")
                }
            }
            UnsubscribeIconButton(symbol: "info.circle", title: "About this newsletter list") { showsCoverage.toggle() }
                .popover(isPresented: $showsCoverage) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        Text("Newsletter coverage").font(.headline)
                        Text(model.scanSummary)
                        Text("Counts include received newsletter emails found so far. Checkboxes select subscriptions that support direct unsubscribe. Other senders have a website or email option.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(Tokens.Space.s4).frame(width: Tokens.Popover.width)
                }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s6)
        .padding(.vertical, Tokens.Space.s1_5)
        .background(Tokens.Surface.muted)
    }

    private var coverageTitle: String {
        let snapshots = model.accounts.filter {
            model.selectedAccountID.isEmpty || $0.id == model.selectedAccountID
        }.compactMap { model.snapshots[$0.id] }
        let count = snapshots.reduce(0) { $0 + $1.scannedMessageCount }.formatted()
        if model.isLoading { return "Loading newsletters…" }
        if model.isScanning {
            return snapshots.contains(where: \.isRefreshing) ? "Refreshing · \(count) checked" : "Checking mail · \(count) checked"
        }
        return model.hasMoreToScan ? "\(count) messages checked so far" : "\(count) messages checked"
    }

    private func notice(_ message: String, isError: Bool, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Tokens.Status.warning : Tokens.Status.success)
                .accessibilityHidden(true)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Tokens.Space.s2)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(isError ? "Dismiss newsletter error" : "Dismiss newsletter notice")
        }
        .padding(.horizontal, Tokens.Space.s6)
        .padding(.vertical, Tokens.Space.s3)
        .background((isError ? Tokens.Status.warning : Tokens.Status.success).opacity(Tokens.Opacity.wash))
    }
}

private extension UnsubscribeFilter {
    var newsletterSymbol: String {
        switch self { case .active: "tray"; case .history: "checkmark.circle"; case .all: "square.stack" }
    }
}
