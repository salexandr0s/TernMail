import MessageContent
import SwiftUI

struct CalendarGridIdentity: Equatable, Sendable {
    let mode: String
    let date: Date
    let calendar: Calendar
    let selectedID: String?
    let revision: Int
}

struct CalendarGridViews: View, Equatable {
    @Environment(\.calendarPresentation) private var presentation
    let presentationID: CalendarGridIdentity
    @Binding var mode: CalendarDisplayMode
    @Binding var date: Date
    let calendar: Calendar
    let events: [CalendarDisplayEvent]
    @Binding var selectedID: String?
    let create: (CalendarEventRange) -> Void
    let edit: (CalendarDisplayEvent) -> Void
    let change: (CalendarDisplayEvent, CalendarEventRange) -> Void
    let delete: (CalendarDisplayEvent) -> Void
    let duplicate: (CalendarDisplayEvent) -> Void
    /// A conversation dropped on the grid, with the slot it landed on.
    let dropMail: (MailLink, CalendarEventRange) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.presentationID == rhs.presentationID }

    var body: some View {
        switch mode {
        case .day, .week:
            CalendarTimeGrid(date: date, isWeek: mode == .week, calendar: calendar, events: events, presentation: presentation,
                             selectedID: $selectedID, create: create, edit: edit, change: change,
                             delete: delete, duplicate: duplicate, dropMail: dropMail)
        case .month:
            CalendarMonthGrid(date: $date, calendar: calendar, events: events, selectedID: $selectedID,
                              create: create, edit: edit, change: change, delete: delete, duplicate: duplicate,
                              dropMail: dropMail, openDay: { date = $0; mode = .day })
        case .schedule:
            CalendarScheduleView(date: date, calendar: calendar, events: events, selectedID: $selectedID,
                                 create: create, edit: edit, delete: delete, duplicate: duplicate)
        case .year:
            year
        }
    }

    private var year: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Tokens.Layout.attachmentWidth), spacing: Tokens.Space.s4)], spacing: Tokens.Space.s4) {
                ForEach(1...12, id: \.self) { month in
                    if let monthDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: date), month: month, day: 1)) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                            Button {
                                date = monthDate; mode = .month
                            } label: {
                                HStack {
                                    Text(CalendarLayout.format(monthDate, style: .dateTime.month(.wide), calendar: calendar))
                                        .font(.title3.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Show " + CalendarLayout.format(monthDate, style: .dateTime.month(.wide).year(), calendar: calendar))
                            CalendarMiniMonth(date: $date, calendar: calendar, fixedMonth: monthDate, events: events) { chosen in
                                date = chosen; mode = .day
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
