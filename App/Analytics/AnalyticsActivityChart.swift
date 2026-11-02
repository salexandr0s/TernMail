import Charts
import Foundation
import MailStore
import SwiftUI

struct AnalyticsActivityChart: View {
    let snapshot: MailAnalyticsSnapshot
    @State private var selectedDate: Date?
    @State private var showsTable: Bool

    init(snapshot: MailAnalyticsSnapshot, selectedDate: Date? = nil, showsTable: Bool = false) {
        self.snapshot = snapshot
        _selectedDate = State(initialValue: selectedDate)
        _showsTable = State(initialValue: showsTable)
    }

    private var selectedBucket: MailAnalyticsBucket? {
        guard let selectedDate else { return nil }
        return snapshot.buckets.last { $0.date <= selectedDate }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            HStack(alignment: .top, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Emails over time").font(.headline)
                    Text(periodDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if snapshot.totalCount > 0 {
                    Button(showsTable ? "Chart" : "Values", systemImage: showsTable ? "chart.bar" : "tablecells") {
                        showsTable.toggle()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel(showsTable ? "Show activity chart" : "Show activity values")
                }
            }
            if snapshot.totalCount == 0 {
                ContentUnavailableView("No email in this period", systemImage: "tray",
                    description: Text("Choose another date range or load more history."))
                    .frame(height: Tokens.Analytics.chartHeight - Tokens.Space.s16)
            } else {
                HStack(spacing: Tokens.Space.s6) {
                    legend("Received", value: snapshot.receivedCount, symbol: "tray.and.arrow.down", color: Tokens.Analytics.received)
                    legend("Sent", value: snapshot.sentCount, symbol: "paperplane", color: Tokens.Analytics.sent)
                    Spacer(minLength: 0)
                }
                Group {
                    if showsTable { valuesTable } else { plot }
                }
                .frame(height: Tokens.Analytics.chartHeight)
                Divider()
                selectionSummary
                    .frame(height: Tokens.Space.s8, alignment: .center)
            }
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    private var plot: some View {
        Chart(snapshot.buckets, id: \.date) { bucket in
            bar(bucket, count: bucket.receivedCount, direction: "Received")
            bar(bucket, count: bucket.sentCount, direction: "Sent")
            if selectedBucket?.date == bucket.date {
                RuleMark(x: .value("Selected period", bucket.date, unit: snapshot.bucketUnit.calendarComponent))
                    .foregroundStyle(Color.secondary.opacity(Tokens.Opacity.outline))
                    .lineStyle(StrokeStyle(lineWidth: Tokens.Border.hairline, dash: [Tokens.Space.s1]))
                    .accessibilityHidden(true)
            }
        }
        .chartForegroundStyleScale(["Received": Tokens.Analytics.received, "Sent": Tokens.Analytics.sent])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...yMaximum)
        .chartXScale(range: .plotDimension(padding: Tokens.Space.s2))
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0, through: yMaximum, by: yStep))) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: Tokens.Border.hairline))
                    .foregroundStyle(Tokens.Surface.border.opacity(Tokens.Opacity.outline))
                AxisValueLabel {
                    if let number = value.as(Int.self) {
                        Text(number, format: .number).font(.caption2).monospacedDigit().foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisValueLabel(anchor: xTickAnchor(value.as(Date.self)), verticalSpacing: Tokens.Space.s2) {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date)).font(.caption2).foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .accessibilityLabel("Sent and received emails over time")
    }

    private func bar(_ bucket: MailAnalyticsBucket, count: Int, direction: String) -> some ChartContent {
        BarMark(x: .value("Period", bucket.date, unit: snapshot.bucketUnit.calendarComponent),
                y: .value("Emails", count), width: .ratio(Tokens.Analytics.barWidthRatio))
            .foregroundStyle(by: .value("Direction", direction))
            .position(by: .value("Direction", direction))
            .cornerRadius(Tokens.Space.s0_5)
            .opacity(selectedBucket == nil || selectedBucket?.date == bucket.date ? 1 : Tokens.Opacity.disabled)
            .accessibilityLabel("\(bucketLabel(bucket.date)), \(direction.lowercased())")
            .accessibilityValue(count.formatted())
    }

    private func legend(_ title: String, value: Int, symbol: String, color: Color) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: symbol).foregroundStyle(color)
                .frame(width: Tokens.Control.icon)
            Text(title).foregroundStyle(.secondary)
            Text(value, format: .number).fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var selectionSummary: some View {
        HStack(spacing: Tokens.Space.s3) {
            if !showsTable, let bucket = selectedBucket {
                selectedSummary(bucket)
            } else {
                Label(showsTable ? "Individual emails per \(bucketHeading.lowercased())" : "Select a bar to see its counts",
                      systemImage: showsTable ? "number" : "cursorarrow")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .font(.caption).monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    private func selectedSummary(_ bucket: MailAnalyticsBucket) -> some View {
        let date = bucketLabel(bucket.date)
        let counts = "\(bucket.receivedCount.formatted()) received · \(bucket.sentCount.formatted()) sent"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s3) {
                Text(date).fontWeight(.medium).fixedSize()
                Spacer(minLength: 0)
                Text(counts).foregroundStyle(.secondary).fixedSize()
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(date).fontWeight(.medium)
                Text(counts).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(Tokens.Analytics.metricMinimumScale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(date): \(bucket.receivedCount.formatted()) received, \(bucket.sentCount.formatted()) sent")
    }

    private var valuesTable: some View {
        VStack(spacing: 0) {
            tableRow(date: bucketHeading, received: "Received", sent: "Sent")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.vertical, Tokens.Space.s3)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.buckets, id: \.date) { bucket in
                        tableRow(date: bucketLabel(bucket.date), received: bucket.receivedCount.formatted(),
                                 sent: bucket.sentCount.formatted())
                            .font(.callout).monospacedDigit()
                            .padding(.vertical, Tokens.Space.s3)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(bucketLabel(bucket.date)): \(bucket.receivedCount) received, \(bucket.sentCount) sent")
                        Divider().opacity(Tokens.Opacity.outline)
                    }
                }
            }
        }
    }

    private func tableRow(date: String, received: String, sent: String) -> some View {
        HStack(spacing: Tokens.Space.s4) {
            Text(date).frame(maxWidth: .infinity, alignment: .leading)
            Text(received).frame(maxWidth: .infinity, alignment: .trailing)
            Text(sent).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Tokens.Space.s2)
    }

    private var yStep: Int {
        let peak = snapshot.buckets.map { max($0.receivedCount, $0.sentCount) }.max() ?? 0
        let target = max(1, Double(peak) / 4)
        let scale = pow(10, floor(log10(target)))
        let step = [1.0, 2, 5, 10].first { $0 * scale >= target } ?? 10
        return max(1, Int(step * scale))
    }

    private var xTicks: [Date] {
        let dates = snapshot.buckets.map(\.date)
        guard dates.count > 1 else { return dates }
        let step = max(1, Int(ceil(Double(dates.count - 1) / 5)))
        var ticks = stride(from: 0, to: dates.count, by: step).map { dates[$0] }
        if let last = dates.last, ticks.last != last { ticks.append(last) }
        return ticks
    }

    private func xTickAnchor(_ date: Date?) -> UnitPoint {
        if date == snapshot.buckets.first?.date { return .topLeading }
        if date == snapshot.buckets.last?.date { return .topTrailing }
        return .top
    }

    private var yMaximum: Int {
        let peak = snapshot.buckets.map { max($0.receivedCount, $0.sentCount) }.max() ?? 0
        return max(yStep, Int(ceil(Double(peak) / Double(yStep))) * yStep)
    }

    private var bucketHeading: String {
        switch snapshot.bucketUnit { case .day: "Day"; case .month: "Month"; case .year: "Year" }
    }

    private var periodDescription: String {
        guard let first = snapshot.buckets.first?.date, let last = snapshot.buckets.last?.date else { return "Indexed mail activity" }
        return "\(bucketHeading) by \(bucketHeading.lowercased()) · \(bucketLabel(first)) – \(bucketLabel(last))"
    }

    private func bucketLabel(_ date: Date) -> String {
        switch snapshot.bucketUnit {
        case .day: date.formatted(date: .abbreviated, time: .omitted)
        case .month: date.formatted(.dateTime.month(.abbreviated).year())
        case .year: date.formatted(.dateTime.year())
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch snapshot.bucketUnit {
        case .day: date.formatted(.dateTime.day().month(.abbreviated))
        case .month: snapshot.buckets.count > 12
            ? date.formatted(.dateTime.month(.abbreviated).year())
            : date.formatted(.dateTime.month(.abbreviated))
        case .year: date.formatted(.dateTime.year())
        }
    }
}
