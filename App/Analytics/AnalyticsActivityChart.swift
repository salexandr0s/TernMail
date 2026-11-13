import Charts
import Foundation
import MailStore
import SwiftUI

struct AnalyticsActivityChart: View {
    let snapshot: MailAnalyticsSnapshot
    /// The start of the selected bucket, not the exact date under the pointer.
    @State private var selectedDate: Date?
    @State private var showsTable: Bool

    init(snapshot: MailAnalyticsSnapshot, selectedDate: Date? = nil, showsTable: Bool = false) {
        self.snapshot = snapshot
        _selectedDate = State(initialValue: selectedDate.flatMap { Self.bucket(containing: $0, in: snapshot.buckets)?.date })
        _showsTable = State(initialValue: showsTable)
    }

    private static func bucket(containing date: Date, in buckets: [MailAnalyticsBucket]) -> MailAnalyticsBucket? {
        buckets.last { $0.date <= date }
    }

    /// Charts writes the exact date under the pointer. Storing the start of its
    /// bucket means a move within one bar changes nothing, so the chart isn't rebuilt.
    private var selection: Binding<Date?> {
        Binding(
            get: { selectedDate },
            set: { date in
                let start = date.flatMap { Self.bucket(containing: $0, in: snapshot.buckets)?.date }
                if start != selectedDate { selectedDate = start }
            })
    }

    var body: some View {
        // Looked up once per update. A stored date from another date range still
        // resolves to the bucket that contains it, or to none.
        let selected = selectedDate.flatMap { Self.bucket(containing: $0, in: snapshot.buckets) }
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .center, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    HStack(spacing: Tokens.Space.s3) {
                        Text("Emails over time").font(.headline)
                        Spacer(minLength: 0)
                        if snapshot.totalCount > 0 {
                            legend("Received", symbol: "arrow.down.left", color: Tokens.Analytics.received)
                            legend("Sent", symbol: "arrow.up.right", color: Tokens.Analytics.sent)
                        }
                    }
                    Text(periodDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if snapshot.totalCount > 0 {
                    Picker("Activity display", selection: $showsTable) {
                        Image(systemName: "chart.bar.xaxis").tag(false)
                            .accessibilityLabel("Show activity chart").help("Show activity chart")
                        Image(systemName: "tablecells").tag(true)
                            .accessibilityLabel("Show activity values").help("Show activity values")
                    }
                    .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                    .frame(width: Tokens.Space.s16)
                    .accessibilityIdentifier("analytics-chart-display")
                }
            }
            if snapshot.totalCount == 0 {
                ContentUnavailableView("No email in this period", systemImage: "tray",
                    description: Text("Choose another date range or load more history."))
                    .frame(height: Tokens.Analytics.chartHeight - Tokens.Space.s16)
            } else {
                ZStack {
                    if showsTable {
                        valuesTable.ternTransition(.fade)
                    } else {
                        plot(selected: selected?.date).ternTransition(.fade)
                    }
                }
                .frame(height: Tokens.Analytics.chartHeight)
                .ternAnimation(value: showsTable, duration: Tokens.Motion.fast)
                Divider()
                selectionSummary(selected)
                    .frame(minHeight: Tokens.Space.s6, alignment: .center)
            }
        }
        .padding(Tokens.Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyticsPanel()
    }

    private func plot(selected: Date?) -> some View {
        // Worked out once per update. The marks would otherwise repeat it for every bucket.
        let axis = yAxis
        let ticks = xTicks
        return Chart(snapshot.buckets, id: \.date) { bucket in
            let label = bucketLabel(bucket.date)
            bar(bucket, count: bucket.receivedCount, direction: "Received", label: label, selected: selected)
            bar(bucket, count: bucket.sentCount, direction: "Sent", label: label, selected: selected)
            if selected == bucket.date {
                RuleMark(x: .value("Selected period", bucket.date, unit: snapshot.bucketUnit.calendarComponent))
                    .foregroundStyle(Color.secondary.opacity(Tokens.Opacity.outline))
                    .lineStyle(StrokeStyle(lineWidth: Tokens.Border.hairline, dash: [Tokens.Space.s1]))
                    .accessibilityHidden(true)
            }
        }
        .chartForegroundStyleScale(["Received": Tokens.Analytics.received, "Sent": Tokens.Analytics.sent])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...axis.maximum)
        .chartXScale(range: .plotDimension(padding: Tokens.Space.s2))
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(stride(from: 0, through: axis.maximum, by: axis.step))) { value in
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
            AxisMarks(values: ticks) { value in
                AxisValueLabel(anchor: xTickAnchor(value.as(Date.self)), verticalSpacing: Tokens.Space.s2) {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date)).font(.caption2).foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXSelection(value: selection)
        .accessibilityLabel("Sent and received emails over time")
    }

    private func bar(_ bucket: MailAnalyticsBucket, count: Int, direction: String,
                     label: String, selected: Date?) -> some ChartContent {
        BarMark(x: .value("Period", bucket.date, unit: snapshot.bucketUnit.calendarComponent),
                y: .value("Emails", count), width: .ratio(Tokens.Analytics.barWidthRatio))
            .foregroundStyle(by: .value("Direction", direction))
            .position(by: .value("Direction", direction))
            .cornerRadius(Tokens.Space.s0_5)
            .opacity(selected == nil || selected == bucket.date ? 1 : Tokens.Opacity.disabled)
            .accessibilityLabel("\(label), \(direction.lowercased())")
            .accessibilityValue(count.formatted())
    }

    private func legend(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(color)
            Text(title).foregroundStyle(.secondary)
        }
        .font(.caption).fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func selectionSummary(_ selected: MailAnalyticsBucket?) -> some View {
        HStack(spacing: Tokens.Space.s3) {
            if !showsTable, let bucket = selected {
                selectedSummary(bucket)
                Button {
                    selectedDate = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .ternHover()
                .help("Clear selection")
                .accessibilityLabel("Clear selection")
                .accessibilityIdentifier("analytics-clear-selection")
            } else {
                Label(showsTable ? "Individual emails per \(bucketHeading.lowercased())" : "Select a bar to see its counts",
                      systemImage: showsTable ? "number" : "cursorarrow")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .font(.caption).monospacedDigit()
        .accessibilityElement(children: .contain)
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
                .padding(.vertical, Tokens.Space.s2)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(snapshot.buckets, id: \.date) { bucket in
                        tableRow(date: bucketLabel(bucket.date), received: bucket.receivedCount.formatted(),
                                 sent: bucket.sentCount.formatted())
                            .font(.callout).monospacedDigit()
                            .padding(.vertical, Tokens.Space.s2)
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

    /// The Y axis step and its top value, from one pass over the buckets.
    private var yAxis: (step: Int, maximum: Int) {
        let peak = snapshot.buckets.map { max($0.receivedCount, $0.sentCount) }.max() ?? 0
        let target = max(1, Double(peak) / 4)
        let scale = pow(10, floor(log10(target)))
        let factor = [1.0, 2, 5, 10].first { $0 * scale >= target } ?? 10
        let step = max(1, Int(factor * scale))
        return (step, max(step, Int(ceil(Double(peak) / Double(step))) * step))
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
