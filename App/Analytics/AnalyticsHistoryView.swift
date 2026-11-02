import MailStore
import SwiftUI

struct AnalyticsHistoryView: View {
    let snapshot: MailAnalyticsSnapshot
    let model: MailAnalyticsModel
    let owners: [AccountMailbox]
    @Environment(\.openSettings) private var openSettings
    @State private var showsDetails = true

    private var hasScannedHistory: Bool {
        !snapshot.coverage.isEmpty && snapshot.coverage.allSatisfy(\.isComplete)
    }

    private var canLoadHistory: Bool { owners.contains(where: \.syncEnabled) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s4) {
                    summary
                    Spacer(minLength: Tokens.Space.s3)
                    action.fixedSize()
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s3) { summary; action }
            }
            if !model.isLoadingHistory, !canLoadHistory {
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
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
            Divider()
            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    ForEach(snapshot.coverage, id: \.accountID) { coverage in
                        accountCoverage(coverage)
                    }
                    Text("Loading history adds older email without changing read status. You can cancel and resume. Scan again to include older changes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Tokens.Space.s3)
            } label: {
                Text("Account coverage").font(.callout.bold())
            }
            .accessibilityIdentifier("analytics-history-details")
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    private var summary: some View {
        HStack(alignment: .center, spacing: Tokens.Space.s3) {
            Group {
                if model.isLoadingHistory {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: hasScannedHistory ? "checkmark.circle" : "clock.arrow.circlepath")
                        .font(.title2).foregroundStyle(hasScannedHistory ? Tokens.Status.success : Color.accentColor)
                }
            }
            .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
            .background(Color.primary.opacity(Tokens.Opacity.wash),
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(model.isLoadingHistory ? "Loading mail history" : "Mail history")
                    .font(.title3.bold()).accessibilityAddTraits(.isHeader)
                if model.isLoadingHistory {
                    Text("\(model.historyPagesLoaded.formatted()) pages saved")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let account = model.historyAccountName {
                        Text(account).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text(hasScannedHistory ? "History scanned. Totals include loaded email." : "Partial history. Older email may be missing.")
                        .font(.callout).foregroundStyle(.secondary)
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
            .buttonStyle(.borderedProminent)
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
        .font(.callout)
        .padding(Tokens.Space.s3)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func coverageStatus(_ coverage: MailAnalyticsCoverage) -> some View {
        if let date = coverage.historyLoadedAt {
            Text("Scanned \(date.formatted(date: .abbreviated, time: .shortened))")
        } else {
            Text("\(coverage.indexedMessageCount.formatted()) indexed")
        }
    }
}
