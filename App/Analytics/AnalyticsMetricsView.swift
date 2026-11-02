import Charts
import MailStore
import SwiftUI

struct AnalyticsMetricsView: View {
    let snapshot: MailAnalyticsSnapshot
    let period: MailAnalyticsPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                Text(period.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                AnalyticsCoverageLabel(coverage: snapshot.coverage)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s3), count: 3),
                      alignment: .leading, spacing: Tokens.Space.s3) {
                metric("Received", value: snapshot.receivedCount, symbol: "tray.and.arrow.down",
                       color: Tokens.Analytics.received, series: \.receivedCount)
                metric("Sent", value: snapshot.sentCount, symbol: "paperplane",
                       color: Tokens.Analytics.sent, series: \.sentCount)
                metric("Conversations", value: snapshot.threadCount, symbol: "bubble.left.and.bubble.right", color: .secondary)
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Text("Across indexed history").font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Tokens.Space.s6) { milestones }
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) { milestones }
                }
            }
            .padding(.horizontal, Tokens.Space.s1)
        }
    }

    @ViewBuilder private var milestones: some View {
        milestone("First received", date: snapshot.firstReceivedAt)
        milestone("First sent", date: snapshot.firstSentAt)
        milestone("Last email", date: snapshot.lastContactAt)
    }

    private func metric(_ title: String, value: Int, symbol: String, color: Color,
                        series: KeyPath<MailAnalyticsBucket, Int>? = nil) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(title).foregroundStyle(.secondary)
            }.font(.callout)
            Text(value, format: .number).font(.largeTitle.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(Tokens.Analytics.metricMinimumScale)
                .help(value.formatted())
            Group {
                if let series {
                    miniChart(series: series, color: color)
                } else {
                    Text("Threads in this period").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(height: Tokens.Analytics.sparklineHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s4)
        .analyticsPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value.formatted()), \(period.title)")
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

    private func milestone(_ title: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(date?.formatted(date: .abbreviated, time: .omitted) ?? "No indexed email")
                .font(.callout.weight(.medium))
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
                Label("Scanned \(scannedAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock.arrow.circlepath")
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
