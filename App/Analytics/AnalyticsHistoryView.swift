import MailStore
import SwiftUI

struct AnalyticsHistoryView: View {
    let snapshot: MailAnalyticsSnapshot
    let model: MailAnalyticsModel
    let owners: [AccountMailbox]
    @Environment(\.openSettings) private var openSettings
    @State private var showsDetails = false

    private var hasScannedHistory: Bool {
        !snapshot.coverage.isEmpty && snapshot.coverage.allSatisfy(\.isComplete)
    }

    private var canLoadHistory: Bool { owners.contains(where: \.syncEnabled) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s4) {
                    summary
                    Spacer(minLength: Tokens.Space.s2)
                    action
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s3) { summary; action }
            }
            if model.isLoadingHistory {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Loading history · \(model.historyPagesLoaded.formatted()) pages saved")
                    if let account = model.historyAccountName {
                        Text(account).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if !canLoadHistory {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                    Text("Mail sync is paused. Enable Sync Mail in Account Settings to load older email.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Open Settings") { openSettings() }
                        .buttonStyle(.borderless).font(.caption).fixedSize()
                }
            }
            if let error = model.historyError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Tokens.Status.error)
            }
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    ForEach(snapshot.coverage, id: \.accountID) { coverage in
                        accountCoverage(coverage)
                    }
                    Text("Loading history adds older message details without changing read status. You can cancel and resume. Scan again to reconcile older changes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Tokens.Space.s2)
            } label: {
                Text("History details").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("analytics-history-details")
        }
        .padding(Tokens.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: Tokens.Space.s3) {
            Image(systemName: hasScannedHistory ? "clock.arrow.circlepath" : "clock.badge.questionmark")
                .font(.title3).foregroundStyle(.secondary)
                .frame(width: Tokens.Analytics.symbolSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(hasScannedHistory ? "History scanned" : "Partial history")
                    .font(.callout.weight(.semibold))
                Text(hasScannedHistory ? "Totals include the history loaded from Gmail." : "Scan your history to include older email.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var action: some View {
        if model.isLoadingHistory {
            HStack(spacing: Tokens.Space.s2) {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelHistory() }
            }
        } else {
            Button(hasScannedHistory ? "Scan again" : "Load full history") {
                model.loadHistory(accounts: owners, restart: hasScannedHistory)
            }
            .disabled(!canLoadHistory)
        }
    }

    private func accountCoverage(_ coverage: MailAnalyticsCoverage) -> some View {
        let email = owners.first(where: { $0.account.id == coverage.accountID })?.account.email ?? "Account"
        return HStack(alignment: .firstTextBaseline) {
            Text(email).lineLimit(1).truncationMode(.middle).help(email)
            Spacer(minLength: Tokens.Space.s2)
            if let date = coverage.historyLoadedAt {
                Text("Scanned \(date.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Text("\(coverage.indexedMessageCount.formatted()) indexed")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
