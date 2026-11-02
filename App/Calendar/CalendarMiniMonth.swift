import SwiftUI

struct CalendarMiniMonth: View {
    @Binding var date: Date
    let calendar: Calendar
    var fixedMonth: Date?
    var events: [CalendarDisplayEvent] = []
    var select: ((Date) -> Void)?

    private static let cellHeight = Tokens.Space.s6 + Tokens.Space.s0_5 + Tokens.Space.s1
    private static let gridHeight = Tokens.Space.s8 + 6 * (cellHeight + Tokens.Space.s1)
    /// The month with its title row, for callers that size a container to it.
    static let height = Tokens.Settings.rowHeight + Tokens.Space.s2 + gridHeight

    var body: some View {
        let month = fixedMonth ?? date
        VStack(spacing: Tokens.Space.s2) {
            if fixedMonth == nil { heading(month: month) }
            dateGrid(month: month)
        }
    }

    private func heading(month: Date) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            ViewThatFits(in: .horizontal) {
                monthTitle(month, style: .dateTime.month(.wide).year())
                monthTitle(month, style: .dateTime.month(.abbreviated).year())
                monthTitle(month, style: .dateTime.month(.twoDigits).year())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CalendarLayout.format(month, style: .dateTime.month(.wide).year(), calendar: calendar))
            HStack(spacing: Tokens.Space.s0_5) {
                Button("Today") { choose(.now) }
                    .font(.caption.weight(.medium))
                    .fixedSize()
                    .padding(.horizontal, Tokens.Space.s1)
                    .frame(height: Tokens.Space.s6)
                    .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    .ternHover()
                    .help("Go to today")
                    .accessibilityLabel("Go to today")
                monthButton(-1, symbol: "chevron.left", title: "Previous month")
                monthButton(1, symbol: "chevron.right", title: "Next month")
            }
            .buttonStyle(.plain)
        }
        .frame(height: Tokens.Settings.rowHeight)
    }

    private func monthTitle(_ month: Date, style: Date.FormatStyle) -> some View {
        Text(CalendarLayout.format(month, style: style, calendar: calendar))
            .font(.callout.weight(.semibold))
            .fixedSize()
    }

    private func monthButton(_ offset: Int, symbol: String, title: String) -> some View {
        Button { shift(offset) } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .ternHover()
        .accessibilityLabel(title)
        .help(title)
    }

    private func dateGrid(month: Date) -> some View {
        let days = CalendarLayout.monthDays(containing: month, calendar: calendar)
        let activity = Self.activity(events: events, days: days, calendar: calendar)
        return GeometryReader { geometry in
            let columnWidth = geometry.size.width / 7
            VStack(spacing: Tokens.Space.s1) {
                CalendarWeekdayHeader(calendar: calendar)
                VStack(spacing: Tokens.Space.s1) {
                    ForEach(0..<6) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7) { column in
                                let index = row * 7 + column
                                if index < days.count {
                                    dayButton(days[index], month: month, activity: activity[days[index]] ?? DayActivity())
                                        .frame(width: columnWidth, height: Self.cellHeight)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: Self.gridHeight)
    }

    private func dayButton(_ day: Date, month: Date, activity: DayActivity) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: date)
        let isToday = calendar.isDateInToday(day)
        let isCurrentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let title = CalendarLayout.format(day, style: .dateTime.weekday(.wide).month().day().year(), calendar: calendar)
        let details = [isToday ? "Today" : nil, isSelected ? "Selected" : nil, activity.count > 0 ? activity.description : nil]
            .compactMap { $0 }.joined(separator: ", ")
        return Button { choose(day) } label: {
            VStack(spacing: Tokens.Space.s0_5) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.weight(isSelected || isToday ? .bold : activity.count > 0 ? .semibold : .regular))
                    .monospacedDigit()
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor)
                        : isToday ? Color.accentColor : isCurrentMonth ? Color.primary : Color.secondary)
                    .background(isSelected ? Color.accentColor : .clear, in: Circle())
                    .overlay {
                        Circle().strokeBorder(isToday && !isSelected ? Color.accentColor : .clear, lineWidth: Tokens.Border.focus)
                    }
                HStack(spacing: Tokens.Space.s0_5) {
                    ForEach(activity.colors, id: \.self) { color in
                        Circle().fill(Color(calendarHex: color))
                            .frame(width: Tokens.Space.s1, height: Tokens.Space.s1)
                    }
                }
                .frame(height: Tokens.Space.s1)
                .opacity(isCurrentMonth ? 1 : Tokens.Opacity.disabled)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .ternHover(isEnabled: !isSelected)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(details)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(activity.count > 0 ? "\(title) · \(activity.description)" : title)
    }

    private func choose(_ day: Date) {
        if let select { select(day) } else { date = day }
    }

    private func shift(_ amount: Int) { date = calendar.date(byAdding: .month, value: amount, to: date) ?? date }

    struct DayActivity: Equatable {
        var count = 0
        var colors: [String] = []
        var description: String { count == 1 ? "1 event" : "\(count) events" }
    }

    /// Build each day's markers once from the supplied range, including events
    /// crossing midnight. Calendar arithmetic keeps all-day ends exclusive at DST.
    static func activity(events: [CalendarDisplayEvent], days: [Date], calendar: Calendar) -> [Date: DayActivity] {
        guard let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return [:] }
        var result: [Date: DayActivity] = [:]
        for event in events {
            let eventEnd = max(event.end, event.start.addingTimeInterval(1))
            guard event.start < end, eventEnd > first else { continue }
            var day = calendar.startOfDay(for: max(first, event.start))
            let lastMoment = min(end, eventEnd)
            while day < lastMoment {
                var activity = result[day, default: DayActivity()]
                activity.count += 1
                let color = event.colorHex.lowercased()
                if activity.colors.count < 3, !activity.colors.contains(color) { activity.colors.append(color) }
                result[day] = activity
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            }
        }
        return result
    }
}
