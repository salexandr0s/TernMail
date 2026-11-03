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
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s3) {
                    summary
                    Spacer(minLength: Tokens.Space.s3)
                    action.fixedSize()
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) { summary; action }
            }
            if !model.isLoadingHistory, !canLoadHistory {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                    Text("Mail sync is paused. Enable Sync Mail to load older email.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Open Settings") { openSettings() }
                        .buttonStyle(.borderless).font(.caption).fixedSize()
                }
            }
            if let error = model.historyError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Tokens.Status.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    ForEach(snapshot.coverage, id: \.accountID) { coverage in
                        accountCoverage(coverage)
                    }
                    Text("Loading history adds older email without changing read status. You can cancel and resume. Scan again to include older changes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Tokens.Space.s2)
            } label: {
                Text("History details").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("analytics-history-details")
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: Tokens.Space.s2) {
            Group {
                if model.isLoadingHistory {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: hasScannedHistory ? "checkmark.circle" : "clock.arrow.circlepath")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(width: Tokens.Space.s4, height: Tokens.Space.s4)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(model.isLoadingHistory ? "Loading mail history" : "Mail history")
                    .font(.callout.weight(.semibold))
                if model.isLoadingHistory {
                    Text("\(model.historyPagesLoaded.formatted()) pages saved")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let account = model.historyAccountName {
                        Text(account).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text(hasScannedHistory ? "History scanned. Totals include loaded email." : "Partial history. Older email may be missing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var action: some View {
        if model.isLoadingHistory {
            Button("Cancel") { model.cancelHistory() }
                .buttonStyle(.bordered).controlSize(.small)
        } else {
            Button(hasScannedHistory ? "Scan again" : "Load full history") {
                model.loadHistory(accounts: owners, restart: hasScannedHistory)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!canLoadHistory)
        }
    }

    private func accountCoverage(_ coverage: MailAnalyticsCoverage) -> some View {
        let email = owners.first(where: { $0.account.id == coverage.accountID })?.account.email ?? "Account"
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                Text(email).lineLimit(1).truncationMode(.middle).help(email)
                Spacer(minLength: Tokens.Space.s2)
                coverageStatus(coverage).fixedSize()
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(email).lineLimit(1).truncationMode(.middle).help(email)
                coverageStatus(coverage)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func coverageStatus(_ coverage: MailAnalyticsCoverage) -> some View {
        if let date = coverage.historyLoadedAt {
            Text("Scanned \(date.formatted(date: .abbreviated, time: .shortened))")
        } else {
            Text("\(coverage.indexedMessageCount.formatted()) indexed")
        }
    }
}
