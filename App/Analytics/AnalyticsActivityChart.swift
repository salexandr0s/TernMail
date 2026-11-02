import Charts
import MailStore
import SwiftUI

struct AnalyticsMetricsView: View {
    let snapshot: MailAnalyticsSnapshot
    let period: MailAnalyticsPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
                Text(period.title).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                AnalyticsCoverageLabel(coverage: snapshot.coverage)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s3), count: 3),
                      alignment: .leading, spacing: Tokens.Space.s3) {
                metric("Received", value: snapshot.receivedCount, symbol: "tray.and.arrow.down")
                metric("Sent", value: snapshot.sentCount, symbol: "paperplane")
                metric("Conversations", value: snapshot.threadCount, symbol: "bubble.left.and.bubble.right")
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Text("Across indexed history").font(.caption).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: Tokens.Space.s6) { milestones }
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) { milestones }
                }
            }
        }
    }

    @ViewBuilder private var milestones: some View {
        milestone("First received", date: snapshot.firstReceivedAt)
        milestone("First sent", date: snapshot.firstSentAt)
        milestone("Last email", date: snapshot.lastContactAt)
    }

    private func metric(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value, format: .number).font(.largeTitle.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s4)
        .ternSurface()
        .accessibilityElement(children: .combine)
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct AnalyticsActivityChart: View {
    let snapshot: MailAnalyticsSnapshot
    @State private var selectedDate: Date?
    @State private var showsTable = false

    private var selectedBucket: MailAnalyticsBucket? {
        guard let selectedDate else { return nil }
        return snapshot.buckets.last { $0.date <= selectedDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Emails over time").font(.headline)
                Spacer(minLength: 0)
                if snapshot.totalCount > 0 {
                    Button(showsTable ? "Show chart" : "Show values") { showsTable.toggle() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            if snapshot.totalCount == 0 {
                ContentUnavailableView("No email in this period", systemImage: "tray",
                    description: Text("Choose another date range or load more history."))
                    .frame(height: Tokens.Analytics.chartHeight)
            } else if showsTable {
                valuesTable
            } else {
                Chart(snapshot.buckets, id: \.date) { bucket in
                    BarMark(x: .value("Date", bucket.date, unit: snapshot.bucketUnit.calendarComponent),
                            y: .value("Emails", bucket.receivedCount))
                        .foregroundStyle(by: .value("Direction", "Received"))
                        .position(by: .value("Direction", "Received"))
                        .accessibilityLabel(bucketLabel(bucket.date))
                        .accessibilityValue("\(bucket.receivedCount) received")
                    BarMark(x: .value("Date", bucket.date, unit: snapshot.bucketUnit.calendarComponent),
                            y: .value("Emails", bucket.sentCount))
                        .foregroundStyle(by: .value("Direction", "Sent"))
                        .position(by: .value("Direction", "Sent"))
                        .accessibilityLabel(bucketLabel(bucket.date))
                        .accessibilityValue("\(bucket.sentCount) sent")
                    if let selectedBucket, bucket.date == selectedBucket.date {
                        RuleMark(x: .value("Selected date", bucket.date))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartForegroundStyleScale(["Received": Color.accentColor, "Sent": Color.secondary])
                .chartLegend(position: .bottom, alignment: .leading)
                .chartYAxis { AxisMarks(position: .leading) }
                .chartXSelection(value: $selectedDate)
                .frame(height: Tokens.Analytics.chartHeight)
                .accessibilityLabel("Sent and received emails over time")
                if let selectedBucket {
                    Text("\(bucketLabel(selectedBucket.date)): \(selectedBucket.receivedCount.formatted()) received, \(selectedBucket.sentCount.formatted()) sent")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Tokens.Space.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ternSurface()
    }

    private var valuesTable: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: Tokens.Space.s5, verticalSpacing: Tokens.Space.s2) {
                GridRow {
                    Text(bucketHeading)
                    Text("Received")
                    Text("Sent")
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(snapshot.buckets, id: \.date) { bucket in
                    GridRow {
                        Text(bucketLabel(bucket.date))
                        Text(bucket.receivedCount, format: .number).monospacedDigit()
                        Text(bucket.sentCount, format: .number).monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Tokens.Analytics.chartHeight)
    }

    private var bucketHeading: String {
        switch snapshot.bucketUnit {
        case .day: "Date"
        case .month: "Month"
        case .year: "Year"
        }
    }

    private func bucketLabel(_ date: Date) -> String {
        switch snapshot.bucketUnit {
        case .day: date.formatted(date: .abbreviated, time: .omitted)
        case .month: date.formatted(.dateTime.month(.abbreviated).year())
        case .year: date.formatted(.dateTime.year())
        }
    }
}
