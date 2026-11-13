import MessageContent
import SwiftUI

/// What the grid shows. While Calendar is hidden or the next range is still
/// loading, the view passes the identity it holds, so the mode, date and
/// calendar here can differ from the model's.
///
/// The selected event is not part of it. A click changes nothing the grid lays
/// out, so the selection reaches the cards through `calendarSelectedEventID`.
struct CalendarGridIdentity: Equatable, Sendable {
    let mode: CalendarDisplayMode
    let date: Date
    let calendar: Calendar
    let revision: Int
    let lifecycle: Int
    let accessRevision: Int
}

private struct CalendarSelectedEventKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The selected event's ID. `CalendarView` sets it above the grid, and it
    /// reaches the cards without the grid's body running again.
    var calendarSelectedEventID: String? {
        get { self[CalendarSelectedEventKey.self] }
        set { self[CalendarSelectedEventKey.self] = newValue }
    }
}

/// Builds one event's card or chip with whether it is selected. When the
/// selection moves, these run again and the grid around them does not.
struct CalendarSelectionReader<Content: View>: View {
    @Environment(\.calendarSelectedEventID) private var selectedID
    let eventID: String
    @ViewBuilder let content: (Bool) -> Content

    var body: some View { content(selectedID == eventID) }
}

/// The grid for the mode shown, behind `CalendarView`'s equatable gate.
///
/// It and the day, week and month grids store closures and no `Binding`. A view
/// that stores a binding runs its body again when the bound property changes,
/// and one that also reads the environment does so whenever any environment
/// value changes. Either would lay the whole grid out again on a selection click.
struct CalendarGridViews: View, Equatable {
    @Environment(\.calendarPresentation) private var presentation
    let presentationID: CalendarGridIdentity
    let events: [CalendarDisplayEvent]
    /// Navigation from inside the grid: shows a date, in another mode when one is given.
    let show: (Date, CalendarDisplayMode?) -> Void
    /// Sets the selected event. The cards read it from `calendarSelectedEventID`.
    let select: (String?) -> Void
    let create: (CalendarEventRange) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    /// Returns once the change is written or refused, so a grid can keep a dropped event in place meanwhile.
    let change: @MainActor (CalendarDisplayEvent, CalendarEventRange) async -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    /// A conversation dropped on the grid, with the slot it landed on.
    let dropMail: (MailLink, CalendarEventRange) -> Void
    /// Kept by the owner, so the hours reopen where they were after another mode replaced them.
    var hourScroll: CalendarHourScroll?

    nonisolated static func ==(lhs: Self, rhs: Self) -> Bool { lhs.presentationID == rhs.presentationID }

    private var calendar: Calendar { presentationID.calendar }

    /// Reads the date the grid shows and writes the model's.
    private var shownDate: Binding<Date> {
        let shown = presentationID.date
        let show = show
        return Binding(get: { shown }, set: { show($0, nil) })
    }

    var body: some View {
        switch presentationID.mode {
        case .day, .week:
            CalendarTimeGrid(date: presentationID.date, isWeek: presentationID.mode == .week, calendar: calendar,
                             events: events, presentation: presentation,
                             select: select, create: create, edit: edit, change: change,
                             delete: delete, duplicate: duplicate, dropMail: dropMail, hourScroll: hourScroll)
        case .month:
            CalendarMonthGrid(date: presentationID.date, calendar: calendar, events: events,
                              showDate: { show($0, nil) }, select: select,
                              create: create, edit: edit, change: change, delete: delete, duplicate: duplicate,
                              dropMail: dropMail, openDay: { show($0, .day) })
        case .schedule:
            CalendarScheduleView(date: presentationID.date, calendar: calendar, events: events, select: select,
                                 create: create, edit: edit, delete: delete, duplicate: duplicate)
        case .year:
            year
        }
    }

    private var year: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Layout.attachmentWidth), spacing: Tokens.Space.s4)], spacing: Tokens.Space.s4) {
                ForEach(1...12, id: \.self) { month in
                    if let monthDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: presentationID.date), month: month, day: 1)) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Button {
                                show(monthDate, .month)
                            } label: {
                                HStack {
                                    Text(CalendarLayout.format(monthDate, style: .dateTime.month(.wide), calendar: calendar))
                                        .font(.title3.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Show " + CalendarLayout.format(monthDate, style: .dateTime.month(.wide).year(), calendar: calendar))
                            CalendarMiniMonth(date: shownDate, calendar: calendar, fixedMonth: monthDate,
                                              events: events, presentation: presentation) { chosen in
                                show(chosen, .day)
                            }
                        }
                        .padding(Tokens.Space.s4)
                        .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                        .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
                    }
                }
            }.padding(Tokens.Space.s4)
        }.background(Tokens.Surface.canvas)
    }
}
