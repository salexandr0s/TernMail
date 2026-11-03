import SwiftUI

/// An event date card with the same month grid and semantic colors as the calendar sidebar.
struct CalendarEventDatePicker: View {
    let title: String
    @Binding var selection: Date
    let allDay: Bool
    let calendar: Calendar
    @Environment(\.isEnabled) private var isEnabled
    @State private var showsCalendar = false
    @FocusState private var hasDateFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Button { showsCalendar = true } label: {
                HStack(spacing: Tokens.Space.s2) {
                    Text(CalendarLayout.format(selection, style: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year(), calendar: calendar))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "calendar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Tokens.Space.s1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable()
            .focusEffectDisabled()
            .focused($hasDateFocus)
            .onKeyPress(keys: [.return, .space]) { _ in
                showsCalendar = true
                return .handled
            }
            .ternHover()
            .accessibilityLabel("\(title) date")
            .accessibilityValue(CalendarLayout.format(selection, style: .dateTime.weekday(.wide).month(.wide).day().year(), calendar: calendar))
            .help("Choose \(title.lowercased()) date")
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                CalendarEventDatePopover(selection: $selection, allDay: allDay, calendar: calendar) {
                    showsCalendar = false
                }
            }
            if !allDay {
                DatePicker("\(title) time", selection: $selection, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .accessibilityLabel("\(title) time")
                    .environment(\.timeZone, calendar.timeZone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Space.s3)
        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md, focus: hasDateFocus || showsCalendar ? .accentColor : nil)
        .opacity(isEnabled ? 1 : Tokens.Opacity.disabled)
    }

    /// Keep the event's wall-clock time when choosing another day, even across a DST change.
    /// A skipped clock time moves forward by the DST gap; an ambiguous time uses its first occurrence.
    static func selection(on day: Date, preserving value: Date, allDay: Bool, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: day)
        guard !calendar.isDate(day, inSameDayAs: value) else { return value }
        guard !allDay else { return day }
        let time = calendar.dateComponents([.hour, .minute, .second], from: value)
        let result = calendar.nextDate(after: day.addingTimeInterval(-1), matching: time,
                                       matchingPolicy: .nextTimePreservingSmallerComponents,
                                       repeatedTimePolicy: .first, direction: .forward)
        return result.flatMap { calendar.isDate($0, inSameDayAs: day) ? $0 : nil } ?? day
    }
}

struct CalendarEventDatePopover: View {
    @Binding var selection: Date
    let allDay: Bool
    let calendar: Calendar
    let close: () -> Void
    @State private var month: Date
    @FocusState private var focusedDay: Date?

    init(selection: Binding<Date>, allDay: Bool, calendar: Calendar, close: @escaping () -> Void) {
        _selection = selection
        self.allDay = allDay
        self.calendar = calendar
        self.close = close
        _month = State(initialValue: calendar.dateInterval(of: .month, for: selection.wrappedValue)?.start ?? selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: Tokens.Space.s3) {
            heading
            VStack(spacing: Tokens.Space.s1) {
                CalendarWeekdayHeader(calendar: calendar)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Space.s1), count: 7), spacing: Tokens.Space.s1) {
                    ForEach(CalendarLayout.monthDays(containing: month, calendar: calendar), id: \.self) { day in
                        dayButton(day)
                    }
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
                    let offset = press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 : press.key == .upArrow ? -7 : 7
                    moveFocus(days: offset)
                    return .handled
                }
                .onKeyPress(keys: [.return, .space]) { _ in
                    choose(focusedDay ?? selection)
                    return .handled
                }
            }
            Divider()
            HStack {
                Text(CalendarLayout.format(selection, style: .dateTime.month(.abbreviated).day().year(), calendar: calendar))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Today") { choose(.now) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(Tokens.Space.s4)
        .frame(width: Tokens.Popover.width)
        .background(Tokens.Surface.muted)
        .onAppear { focusedDay = calendar.startOfDay(for: selection) }
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose date")
    }

    private var heading: some View {
        HStack(spacing: Tokens.Space.s2) {
            Menu {
                ForEach(Array(calendar.monthSymbols.enumerated()), id: \.offset) { index, name in
                    Button(name) { setMonth(index + 1) }
                }
            } label: {
                Text(CalendarLayout.format(month, style: .dateTime.month(.wide), calendar: calendar))
                    .font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Month")
            Menu {
                let year = calendar.component(.year, from: month)
                ForEach((year - 10)...(year + 10), id: \.self) { value in
                    Button(String(value)) { setYear(value) }
                }
            } label: {
                Text(CalendarLayout.format(month, style: .dateTime.year(), calendar: calendar))
                    .font(.headline)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Year")
            Spacer(minLength: 0)
            monthButton(-1, symbol: "chevron.left", title: "Previous month")
            monthButton(1, symbol: "chevron.right", title: "Next month")
        }
    }

    private func monthButton(_ offset: Int, symbol: String, title: String) -> some View {
        Button { month = calendar.date(byAdding: .month, value: offset, to: month) ?? month } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .ternHover()
        .accessibilityLabel(title)
        .help(title)
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(day)
        let isCurrentMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isFocused = focusedDay == day
        return Button { choose(day) } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.callout.weight(isSelected || isToday ? .semibold : .regular))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Control.iconButton)
                .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor)
                    : isCurrentMonth ? Color.primary : Color.secondary)
                .background(isSelected ? Color.accentColor : isToday ? Color.accentColor.opacity(Tokens.Opacity.tint) : .clear,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                        .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: Tokens.Border.focus)
                        .padding(-Tokens.Space.s0_5)
                }
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focusedDay, equals: day)
        .ternHover(isEnabled: !isSelected)
        .accessibilityLabel(CalendarLayout.format(day, style: .dateTime.weekday(.wide).month(.wide).day().year(), calendar: calendar))
        .accessibilityValue([isSelected ? "Selected" : nil, isToday ? "Today" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose(_ day: Date) {
        selection = CalendarEventDatePicker.selection(on: day, preserving: selection, allDay: allDay, calendar: calendar)
        close()
    }

    private func moveFocus(days: Int) {
        guard let next = calendar.date(byAdding: .day, value: days, to: focusedDay ?? selection) else { return }
        month = calendar.dateInterval(of: .month, for: next)?.start ?? next
        focusedDay = calendar.startOfDay(for: next)
    }

    private func setMonth(_ value: Int) {
        month = calendar.date(bySetting: .month, value: value, of: month) ?? month
    }

    private func setYear(_ value: Int) {
        month = calendar.date(bySetting: .year, value: value, of: month) ?? month
    }
}
