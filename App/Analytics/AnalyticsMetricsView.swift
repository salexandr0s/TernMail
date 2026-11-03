import MailStore
import SwiftUI

struct AnalyticsMetricsView: View {
    let snapshot: MailAnalyticsSnapshot
    let period: MailAnalyticsPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { summary; Spacer(); coverage }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) { summary; coverage }
            }
            HStack(spacing: Tokens.Space.s3) {
                metric("Received", value: snapshot.receivedCount, symbol: "arrow.down.left",
                       color: Tokens.Analytics.received)
                Divider().frame(height: Tokens.Space.s10)
                metric("Sent", value: snapshot.sentCount, symbol: "arrow.up.right",
                       color: Tokens.Analytics.sent)
                Divider().frame(height: Tokens.Space.s10)
                metric("Conversations", value: snapshot.threadCount, symbol: "bubble.left.and.bubble.right",
                       color: .secondary)
            }
        }
        .padding(Tokens.Space.s3)
        .analyticsPanel()
    }

    private var summary: some View {
        HStack(spacing: Tokens.Space.s2) {
            Text("Activity").fontWeight(.semibold)
            Text("· \(period.title) · \(snapshot.totalCount.formatted()) emails").foregroundStyle(.secondary)
        }
        .font(.caption)
        .fixedSize()
    }

    private var coverage: some View { AnalyticsCoverageLabel(coverage: snapshot.coverage) }

    private func metric(_ title: String, value: Int, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            HStack(spacing: Tokens.Space.s1) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(Tokens.Analytics.metricMinimumScale)
            }
            .font(.caption)
            Text(value, format: .number).font(.title2.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(Tokens.Analytics.metricMinimumScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value.formatted())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.formatted()), \(period.title)")
    }
}

struct AnalyticsMilestonesView: View {
    let snapshot: MailAnalyticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("Mail history").fontWeight(.semibold)
                Spacer(minLength: 0)
                Text("All indexed mail").foregroundStyle(.secondary)
            }
            .font(.caption)
            if snapshot.firstReceivedAt == nil, snapshot.firstSentAt == nil, snapshot.lastContactAt == nil {
                Text("No indexed email yet").font(.caption).foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Tokens.Space.s3) { milestones }
                    VStack(alignment: .leading, spacing: Tokens.Space.s2) { milestones }
                }
            }
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    @ViewBuilder private var milestones: some View {
        milestone("First received", date: snapshot.firstReceivedAt)
        milestone("First sent", date: snapshot.firstSentAt)
        milestone("Latest email", date: snapshot.lastContactAt)
    }

    private func milestone(_ title: String, date: Date?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s1) { milestoneText(title, date: date) }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) { milestoneText(title, date: date) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func milestoneText(_ title: String, date: Date?) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary).fixedSize()
        Text(date?.formatted(date: .abbreviated, time: .omitted) ?? "No indexed email")
            .font(.caption.weight(.medium)).fixedSize()
    }
}

struct AnalyticsCoverageLabel: View {
    let coverage: [MailAnalyticsCoverage]

    private var scannedAt: Date? {
        guard !coverage.isEmpty, coverage.allSatisfy(\.isComplete) else { return nil }
        return coverage.compactMap(\.historyLoadedAt).min()
    }

    var body: some View {
        Group {
            if let scannedAt {
                Label("Scanned \(scannedAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.circle")
                    .help("History has been scanned for these accounts. Scan again to reconcile older changes.")
            } else {
                Label("Partial history", systemImage: "clock.badge.questionmark")
                    .help("Totals cover indexed mail. Load full history in Analytics to include older messages.")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.Space.s2).padding(.vertical, Tokens.Space.s1)
        .background(Color.primary.opacity(Tokens.Opacity.wash), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
    }
}
