import SwiftUI

struct CalendarMiniMonth: View {
    @Environment(\.calendarPresentation) private var presentation
    @Binding var date: Date
    let calendar: Calendar
    var fixedMonth: Date?
    var events: [CalendarDisplayEvent] = []
    var select: ((Date) -> Void)?

    private static let cellHeight = Tokens.Space.s6 + Tokens.Space.s0_5 + Tokens.Space.s1
    private static let gridHeight = Tokens.Space.s8 + 6 * (cellHeight + Tokens.Space.s1)
    /// The month with its title row, for callers that size a container to it.
    static let height = Tokens.Space.s6 + Tokens.Space.s1 + gridHeight

    var body: some View {
        let month = fixedMonth ?? date
        VStack(spacing: Tokens.Space.s1) {
            if fixedMonth == nil {
                HStack {
                    Text(CalendarLayout.format(month, style: .dateTime.month(.wide).year(), calendar: calendar)).font(.callout.weight(.semibold))
                    Spacer()
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous month")
                        .help("Previous month")
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next month")
                        .help("Next month")
                }.buttonStyle(.borderless).frame(height: Tokens.Space.s6)
            }
            dateGrid(month: month)
        }
    }

    private func dateGrid(month: Date) -> some View {
        let days = CalendarLayout.monthDays(containing: month, calendar: calendar)
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
                                    dayButton(days[index], month: month)
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

    private func dayButton(_ day: Date, month: Date) -> some View {
        Button {
            if let select { select(day) } else { date = day }
        } label: {
            VStack(spacing: Tokens.Space.s0_5) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption.weight(calendar.isDateInToday(day) ? .bold : .regular)).monospacedDigit()
                    .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                    .foregroundStyle(calendar.isDate(day, equalTo: month, toGranularity: .month) ? Color.primary : Color.secondary)
                    .background(calendar.isDateInToday(day) ? Color.accentColor.opacity(Tokens.Calendar.selectedTint) : .clear, in: Circle())
                    .overlay { Circle().strokeBorder(calendar.isDate(day, inSameDayAs: date) ? Color.accentColor : .clear, lineWidth: Tokens.Border.focus) }
                Circle().fill(hasEvents(on: day) ? .secondary : Color.clear)
                    .frame(width: Tokens.Space.s1, height: Tokens.Space.s1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .ternHover()
            .accessibilityLabel(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month().day().year(), calendar: calendar))
            .accessibilityValue(calendar.isDate(day, inSameDayAs: date) ? "Selected" : calendar.isDateInToday(day) ? "Today" : "")
    }

    private func shift(_ amount: Int) { date = calendar.date(byAdding: .month, value: amount, to: date) ?? date }

    private func hasEvents(on day: Date) -> Bool {
        guard !events.isEmpty else { return false }
        if let presentation, presentation.matches(calendar) { return presentation.day(day)?.events.isEmpty == false }
        return !CalendarLayout.events(events, on: day, calendar: calendar).isEmpty
    }
}
