import Charts
import MailStore
import SwiftUI

struct AnalyticsMetricsView: View {
    let snapshot: MailAnalyticsSnapshot
    let period: MailAnalyticsPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { summary; Spacer(); coverage }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) { summary; coverage }
            }
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s3), count: 3),
                      spacing: Tokens.Space.s3) {
                metric("Received", value: snapshot.receivedCount, symbol: "arrow.down.left",
                       color: Tokens.Analytics.received, series: \.receivedCount)
                metric("Sent", value: snapshot.sentCount, symbol: "arrow.up.right",
                       color: Tokens.Analytics.sent, series: \.sentCount)
                metric("Conversations", value: snapshot.threadCount, symbol: "bubble.left.and.bubble.right",
                       color: .secondary)
            }
        }
        .padding(Tokens.Space.s6)
        .analyticsPanel()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(period.title).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s2) {
                Text(snapshot.totalCount, format: .number).font(.largeTitle.bold()).monospacedDigit()
                Text("emails").font(.title3).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var coverage: some View { AnalyticsCoverageLabel(coverage: snapshot.coverage) }

    private func metric(_ title: String, value: Int, symbol: String, color: Color,
                        series: KeyPath<MailAnalyticsBucket, Int>? = nil) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary).lineLimit(1)
                    .minimumScaleFactor(Tokens.Analytics.metricMinimumScale)
            }
            .font(.callout.weight(.medium))
            Text(value, format: .number).font(.title2.bold()).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(Tokens.Analytics.metricMinimumScale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value.formatted())
            Group {
                if let series {
                    miniChart(series: series, color: color)
                } else {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text("Threads with activity")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(height: Tokens.Analytics.sparklineHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.formatted()), \(period.title)\(series == nil ? ", \(snapshot.totalCount.formatted()) emails" : "")")
    }

    private func miniChart(series: KeyPath<MailAnalyticsBucket, Int>, color: Color) -> some View {
        Chart(snapshot.buckets, id: \.date) { bucket in
            AreaMark(x: .value("Date", bucket.date), y: .value("Emails", bucket[keyPath: series]))
                .foregroundStyle(LinearGradient(colors: [color.opacity(Tokens.Opacity.tint), .clear], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.linear)
            LineMark(x: .value("Date", bucket.date), y: .value("Emails", bucket[keyPath: series]))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: Tokens.Border.focus, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
        }
        .chartYScale(domain: 0...max(1, snapshot.buckets.map { max($0.receivedCount, $0.sentCount) }.max() ?? 0))
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

struct AnalyticsMilestonesView: View {
    let snapshot: MailAnalyticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "clock").foregroundStyle(.secondary)
                Text("First and latest emails").fontWeight(.semibold)
                Spacer(minLength: 0)
                Text("All indexed mail").foregroundStyle(.secondary)
            }
            .font(.caption)
            if snapshot.firstReceivedAt == nil, snapshot.firstSentAt == nil, snapshot.lastContactAt == nil {
                Text("No indexed email yet").font(.callout).foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Tokens.Space.s6) { milestones }
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) { milestones }
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    @ViewBuilder private var milestones: some View {
        milestone("First received", date: snapshot.firstReceivedAt)
        milestone("First sent", date: snapshot.firstSentAt)
        milestone("Latest email", date: snapshot.lastContactAt)
    }

    private func milestone(_ title: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(date?.formatted(date: .abbreviated, time: .omitted) ?? "No indexed email")
                .font(.callout.weight(.medium)).fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
